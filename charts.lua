--[[
═══════════════════════════════════════════════════════════════════════════
    BAR CHARTS WIDGET — SHADER EDITION
    v3.1 by FilthyMitch  (interpolated ringSample on top of v3.0 shader core)

    What changed in v3.1 vs v3.0:
    ─────────────────────────────
    ringSample now uses bilinear interpolation between adjacent ring-buffer
    samples instead of floor-snapping to the nearest index.

    The old code:
        local fi  = math.floor((i-1)/(n-1) * (count-1) + 0.5)
        local idx = ((startIdx-1 + fi) % HISTORY_SIZE) + 1
        pts[i]    = buf[idx]

    computed a floating-point position in the ring buffer and then rounded
    it to the nearest integer index.  Two problems resulted:

      1. Quantisation jitter — as new data arrives, `count` grows by 1 and
         every output slot's source index shifts slightly.  With floor-rounding
         some slots snap to a different raw sample, causing single-frame jumps
         in individual rendered points even when the underlying data did not
         change.  This produced a characteristic "wobble" on otherwise stable
         lines.

      2. Staircase appearance — downsampling 18 000 frames to 300 render
         points with nearest-neighbour means each output pixel can only take
         one of 60 discrete real values (18000/300).  On steep-ish parts of the
         line this creates visible steps.

    The fix:
        local fi  = (i-1) / math.max(n-1, 1) * math.max(count-1, 0)
        local lo  = math.floor(fi)
        local t   = fi - lo                          -- fractional part [0,1)
        local idxA = ((startIdx-1 + lo)              % HISTORY_SIZE) + 1
        local idxB = ((startIdx-1 + math.min(lo+1, count-1)) % HISTORY_SIZE) + 1
        pts[i]   = buf[idxA] + t * (buf[idxB] - buf[idxA])

    Because `fi` is now a true float position, and we lerp between the two
    neighbours, the output value changes *continuously* as `count` grows —
    no snapping.  The staircase is replaced by a smooth curve that passes
    through every raw sample.

    For series that are genuinely step-function data (army value, kills) the
    lerp produces a short diagonal ramp between each step.  That is visually
    indistinguishable from the true step at the render scale (1 step ≈ 1-3px
    of horizontal screen space) but eliminates the jitter.

    Rendering pipeline (unchanged from v3.0):
    ─────────────────────────────────────────
    Three GLSL programs replace all raw gl.LineWidth / GL.LINE_STRIP calls:

    lineShader
      Converts each data series into a screen-space quad strip.  A vertex
      shader expands the centre-line into a ribbon of configurable half-width;
      the fragment shader applies a smooth SDF-based coverage value so the
      line is pixel-perfect anti-aliased at any scale.  A configurable
      glowRadius adds a soft outer bloom using the same signed distance.

    fillShader
      Draws the filled area beneath each line as a TRIANGLE_STRIP.  The
      fragment shader applies a two-stop vertical gradient (opaque at the
      line, transparent at the baseline) with an animated horizontal shimmer
      band — a sine wave that drifts rightward over time, giving the fill a
      subtle pulse without any extra geometry.

    gridShader
      Renders the background panel's grid lines with a low-frequency
      animating "scan-pulse" — a bright ring that sweeps upward over ~4 s,
      giving the otherwise static grid a hint of life.

    All three programs are compiled once in widget:Initialize and reused for
    every chart, every frame.  Data is uploaded to the GPU as a 1-D float
    uniform array (up to MAX_UNIFORM_POINTS floats) so the vertex shader can
    position each sample without any Lua-side geometry loop.

    Display-list strategy (same as v2.6/v3.0):
    ──────────────────────────────────────────
    chromeList  — bg panels, borders, Y-axis labels, titles  (dirty on layout)
    linesList   — all shader-drawn line+fill geometry        (dirty on new data)
    overlayList — stall warnings, hover highlights, cards    (dirty on state)

    Backwards-compatible public API:
    ──────────────────────────────────
    WG.BarCharts is still published with identical fields to v2.6/v3.0.

    Performance notes:
    ──────────────────
    • MAX_CHART_FPS still gates linesList rebuilds (default 30).
    • RENDER_POINTS defaults to 300; shader path is O(n) vertex uploads.
    • Shader compilation happens once at init; no per-frame recompile.
    • Uniform upload of 300 floats ≈ 1.2 KB/frame per series — negligible.
    • The lerp in ringSample adds ~300 multiply-adds per series call —
      completely invisible on any hardware capable of running BAR.
═══════════════════════════════════════════════════════════════════════════
]]

function widget:GetInfo()
    return {
        name      = "BAR Stats Charts",
        desc      = "Real-time resource and combat statistics — shader-rendered lines & fills (v3.1)",
        author    = "FilthyMitch",
        date      = "2026",
        license   = "MIT",
        layer     = 5,
        enabled   = true
    }
end

-------------------------------------------------------------------------------
-- TABLE SERIALIZATION
-------------------------------------------------------------------------------

local function serializeTable(tbl, indent)
    indent = indent or 0
    local ind = string.rep("  ", indent)
    local r   = "{\n"
    for k, v in pairs(tbl) do
        local kstr = type(k) == "string" and ('["'..k..'"]') or ("["..tostring(k).."]")
        if     type(v) == "table"   then r = r..ind.."  "..kstr.." = "..serializeTable(v, indent+1)..",\n"
        elseif type(v) == "string"  then r = r..ind.."  "..kstr..' = "'..v..'",\n'
        elseif type(v) == "boolean" then r = r..ind.."  "..kstr.." = "..tostring(v)..",\n"
        elseif type(v) == "number"  then r = r..ind.."  "..kstr.." = "..tostring(v)..",\n"
        end
    end
    return r..ind.."}"
end

-------------------------------------------------------------------------------
-- CONSTANTS & CONFIG
-------------------------------------------------------------------------------

local CONFIG_FILE = "bar_charts_config.lua"

local GAME_FPS        = 30
local HISTORY_SECONDS = 120
local HISTORY_SIZE    = GAME_FPS * HISTORY_SECONDS   -- 18 000 frames
local RENDER_POINTS   = 300

-- Maximum GPU uniform array size for data points.
-- Must match the array size declared in the GLSL shaders below.
local MAX_UNIFORM_POINTS = 300

local MAX_CHART_FPS = 30

local BUILD_EFF_TICKS_PER_SAMPLE = 12
local BUILD_EFF_WINDOW_SIZE      = 6

local CHART_WIDTH  = 300
local CHART_HEIGHT = 180
local PADDING      = { left = 40, right = 15, top = 15, bottom = 25 }
local CARD_WIDTH   = 140
local CARD_HEIGHT  = 70

local SNAP_GRID = 20

local BASE_TICK_SECS = 30
local MIN_TICK_PX    = 44

-- Line rendering parameters
local LINE_HALF_WIDTH = 0.2   -- core half-width in pixels — ~1px rendered line
local LINE_GLOW_RADIUS = 1.5  -- outer glow radius in pixels (additive bloom only)

local COLOR = {
    bg        = { 0.031, 0.047, 0.078, 0.72 },
    border    = { 0.353, 0.706, 1.000, 0.18 },
    borderHot = { 0.353, 0.706, 1.000, 0.55 },
    grid      = { 0.353, 0.706, 1.000, 0.08 },
    gridBase  = { 0.353, 0.706, 1.000, 0.22 },
    muted     = { 0.627, 0.745, 0.863, 0.55 },
    accent    = { 0.290, 0.706, 1.000, 1.00 },
    accent2   = { 1.000, 0.420, 0.208, 1.00 },
    danger    = { 1.000, 0.231, 0.361, 1.00 },
    success   = { 0.188, 0.941, 0.627, 1.00 },
    gold      = { 0.941, 0.753, 0.251, 1.00 },
}

-------------------------------------------------------------------------------
-- SNAP HELPERS
-------------------------------------------------------------------------------

local function snapTo(val)
    return math.floor(val / SNAP_GRID + 0.5) * SNAP_GRID
end

----
-- misc helpers
----

local function clearAllHoverStates()
    for _, chart in pairs(charts) do chart.isHovered = false end
    for _, card in pairs(statCards) do card.isHovered = false end
end

-------------------------------------------------------------------------------
-- X-AXIS TIMESTAMP HELPERS
-------------------------------------------------------------------------------

local function formatTimestamp(secs)
    local m = math.floor(secs / 60)
    local s = secs % 60
    if m == 0 then return string.format(":%02d", s)
    else            return string.format("%d:%02d", m, s) end
end

local function drawTimeAxis(cX, cW, cY, windowSecs, nowGameSecs, alpha)
    if windowSecs <= 0 then return end
    local tickSecs = BASE_TICK_SECS
    local pxPerSec = cW / windowSecs
    while (tickSecs * pxPerSec) < MIN_TICK_PX do
        tickSecs = tickSecs * 2
        if tickSecs > windowSecs then return end
    end
    local rightSecs = nowGameSecs
    local leftSecs  = nowGameSecs - windowSecs
    local firstTick = math.ceil(leftSecs / tickSecs) * tickSecs
    local c         = COLOR.muted
    local tickH     = 4
    local t         = firstTick
    while t <= rightSecs do
        local frac = (t - leftSecs) / windowSecs
        local xPos = cX + frac * cW
        gl.Color(c[1], c[2], c[3], (c[4] * 0.7) * alpha)
        gl.LineWidth(1.0)
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(xPos, cY); gl.Vertex(xPos, cY - tickH)
        end)
        gl.Color(c[1], c[2], c[3], (c[4] * 0.85) * alpha)
        gl.Text(formatTimestamp(math.floor(t + 0.5)), xPos, cY - tickH - 9, 8, "co")
        t = t + tickSecs
    end
end

-------------------------------------------------------------------------------
-- GLOBAL STATE
-------------------------------------------------------------------------------

local vsx, vsy          = Spring.GetViewGeometry()
local chartsEnabled     = true
local chartsReady       = false
local chartsInteractive = false

local viewedTeamID = nil
local myTeamID     = nil
local myAllyTeamID = nil
local isSpectator  = false

local allyTeams = {}

local history  = {}
local histHead = {}
local histFull = {}

local SERIES_KEYS = {
    "metalIncome", "metalUsage",
    "energyIncome", "energyUsage",
    "damageDealt",  "damageTaken",
    "armyValue",    "buildPower",
    "kills",        "losses",
    "buildEfficiency",
}

local function initTeamBuffers(tid)
    if history[tid] then return end
    history[tid]  = {}
    histHead[tid] = {}
    histFull[tid] = {}
    for _, key in ipairs(SERIES_KEYS) do
        history[tid][key]  = {}
        histHead[tid][key] = 1
        histFull[tid][key] = false
        for i = 1, HISTORY_SIZE do history[tid][key][i] = 0 end
    end
end

local function ringPush(tid, key, value)
    local h = histHead[tid][key]
    history[tid][key][h] = value
    h = h + 1
    if h > HISTORY_SIZE then h = 1; histFull[tid][key] = true end
    histHead[tid][key] = h
end

local function ringRange(tid, key)
    local h    = histHead[tid][key]
    local full = histFull[tid][key]
    return full and h or 1, full and HISTORY_SIZE or (h - 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- ringSample  (v3.1 — interpolated)
-- ─────────────────────────────────────────────────────────────────────────────
-- Downsamples the ring buffer to `numPts` output points using linear
-- interpolation between adjacent raw samples.
--
-- Why this eliminates jitter
-- ──────────────────────────
-- The old implementation computed a floating-point source position fi and then
-- rounded it with math.floor(fi + 0.5) (nearest-neighbour).  When `count`
-- incremented by 1 (one new frame of data) the mapping changed slightly, and
-- some output slots snapped to a different raw sample — causing visible single-
-- frame jumps even when the underlying stat value was constant.
--
-- The new implementation keeps fi as a true float, splits it into an integer
-- part `lo` and a fractional part `t`, and returns:
--
--     buf[lo] * (1-t) + buf[lo+1] * t
--
-- Because t changes *continuously* as count grows, output values drift
-- smoothly rather than snapping.  The visual result is a stable line that
-- only moves when the underlying data genuinely changes.
--
-- Edge cases handled
-- ──────────────────
-- • count == 1  → n clamped to 1, single repeated value (no lerp neighbour).
-- • lo+1 > count-1 → clamped to count-1 to avoid reading beyond valid data.
-- • NaN / nil raw samples → guarded by the (v and not (v ~= v)) check in
--   computeRange; ringSample itself trusts the buffer is clean (ringPush only
--   ever writes real numbers).
-- ─────────────────────────────────────────────────────────────────────────────
local DISPLAY_WINDOW_FRAMES = GAME_FPS * HISTORY_SECONDS  -- can be altered for display purposes

local function ringSample(tid, key, numPts)
    local startIdx, count = ringRange(tid, key)
    if count <= 0 then return {} end
    local buf = history[tid][key]

    -- Use a fixed window so the mapping doesn't drift as count grows
    local windowCount = math.min(count, DISPLAY_WINDOW_FRAMES)
    local windowStart = (startIdx - 1 + (count - windowCount)) % HISTORY_SIZE

    local n = math.min(numPts, windowCount)
    if n <= 1 then
        local idx = (windowStart % HISTORY_SIZE) + 1
        pts = { buf[idx] }
        return pts
    end

    local pts    = {}
    local countM1 = windowCount - 1

    for i = 1, n do
        local fi   = (i - 1) / (n - 1) * countM1
        local lo   = math.floor(fi)
        local t    = fi - lo
        local hi   = math.min(lo + 1, countM1)
        local idxA = (windowStart + lo) % HISTORY_SIZE + 1
        local idxB = (windowStart + hi) % HISTORY_SIZE + 1
        pts[i]     = buf[idxA] + t * (buf[idxB] - buf[idxA])
    end

    return pts
end

local builderUnits     = {}
local maxMetalUseCache = {}
local buildEffState    = {}

local charts    = {}
local statCards = {}

-- ── Display lists ─────────────────────────────────────────────────────────
local chromeDisplayList  = nil
local linesDisplayList   = nil
local overlayDisplayList = nil

local chromeDirty  = true
local linesDirty   = true
local overlayDirty = true

local linesLastRebuildTime = nil

local frameCounter          = 0
local FULL_SCAN_INTERVAL    = GAME_FPS
local chartsReadyWaitFrames = 0
local READY_WAIT_FRAMES     = GAME_FPS * 3

local prevStallState = {}

-- Wall-clock start time for shader animations
local widgetStartTimer = nil

-------------------------------------------------------------------------------
-- ═══════════════════════════════════════════════════════════════════════════
--  SHADER PROGRAMS
-- ═══════════════════════════════════════════════════════════════════════════
-------------------------------------------------------------------------------

local shaderLine = nil   -- AA line ribbon shader
local shaderFill = nil   -- animated area fill shader
local shaderGrid = nil   -- animated grid / scan-pulse shader

-- Uniform locations cached after link
local uLine = {}
local uFill = {}
local uGrid = {}

-- ── GLSL sources ────────────────────────────────────────────────────────────

-- lineVS: expands each sample pair into a screen-space quad.
-- Each "vertex" in Lua is actually the LEFT endpoint of a segment;
-- we emit 4 verts per segment (quad) and let the GS… wait, BAR's Spring
-- version may not support geometry shaders reliably.  Instead we use a
-- classic "fat line" trick: upload ALL sample Y-values as a uniform array
-- and draw 2*(N-1) triangles by encoding segment index + side in gl_VertexID.
-- Since Spring's widget GL doesn't expose gl_VertexID we fall back to passing
-- the quad corners as explicit geometry from Lua — but we do it ONCE per
-- display-list rebuild and let the fragment shader own the AA math.
--
-- Vertex layout per quad corner:
--   attrib 0 (vec2) = screen position
--   attrib 1 (float) = signed perpendicular distance from line centre (pixels)
--
-- The fragment shader turns that distance into smooth coverage.

-- aDist is packed into gl_Color.r (the fixed-function colour channel),
-- which is the only reliable per-vertex data channel available in Spring's
-- immediate-mode Lua GL binding.  The actual line colour is passed as a
-- uniform so it is independent of this carrier.
local LINE_VS = [[
#version 120
varying float vDist;
void main() {
    vDist       = gl_Color.r;
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}
]]

local LINE_FS = [[
#version 120
uniform vec4  uColor;
uniform float uHalfWidth;
uniform float uGlowRadius;
varying float vDist;

void main() {
    float d = abs(vDist);

    // ── Core line ──────────────────────────────────────────────────────
    // AA fringe is exactly ±1px around the edge — tight enough to look
    // sharp, wide enough to prevent aliasing on any angle.
    float core = 1.0 - smoothstep(uHalfWidth - 1.0, uHalfWidth + 1.0, d);

    // ── Glow bloom ────────────────────────────────────────────────────
    // Gaussian falloff outside the core edge.  This is combined additively
    // in the Lua draw call (GL_ONE dest blend) so it brightens rather than
    // thickening the line.
    float outerDist = max(0.0, d - uHalfWidth);
    float bloom     = exp(-outerDist * outerDist / (uGlowRadius * 0.5)) * 0.4;

    // Core alpha uses normal src-alpha blend (set before this draw call).
    // Bloom is baked into the alpha here; the Lua side switches blend modes
    // between the two passes.
    float alpha = clamp(core + bloom, 0.0, 1.0);

    // Tint core slightly brighter at centre
    float centreBright = max(0.0, 1.0 - d / uHalfWidth) * 0.15;
    vec3  col = uColor.rgb + centreBright;

    gl_FragColor = vec4(col, uColor.a * alpha);
}
]]

-- Fill shader: triangle strip from baseline to line, with a vertical gradient
-- and a slow horizontal shimmer band animated by time.

-- aT (0=baseline, 1=line) is packed into gl_Color.r
local FILL_VS = [[
#version 120
varying float vT;
varying float vX;
void main() {
    vT          = gl_Color.r;
    vX          = gl_Vertex.x;
    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
}
]]

local FILL_FS = [[
#version 120
uniform vec4  uColor;
uniform float uTime;
uniform float uChartX;
uniform float uChartW;
varying float vT;
varying float vX;

void main() {
    float alpha   = vT * vT * 0.55;
    float nx      = (vX - uChartX) / max(uChartW, 1.0);
    float phase   = nx - uTime * 0.045;
    float band    = sin(phase * 3.14159 * 2.0);
    band          = clamp(band * 0.5 + 0.5, 0.0, 1.0);
    band          = pow(band, 12.0);
    float shimmer = band * 0.18 * vT;
    gl_FragColor  = vec4(uColor.rgb, (alpha + shimmer) * uColor.a);
}
]]

-- Grid shader: draws horizontal grid lines with an upward-sweeping scan pulse.

local GRID_VS = [[
#version 120
attribute vec2 aPos;
varying   vec2 vPos;
void main() {
    vPos        = aPos;
    gl_Position = gl_ModelViewProjectionMatrix * vec4(aPos, 0.0, 1.0);
}
]]

local GRID_FS = [[
#version 120
uniform vec4  uColor;
uniform float uTime;
uniform float uChartY;    // bottom of chart content area
uniform float uChartH;    // height of chart content area
varying vec2  vPos;

void main() {
    // Scan pulse: a band that sweeps from bottom to top over ~4 seconds
    float ny     = (vPos.y - uChartY) / max(uChartH, 1.0);
    float pulse  = mod(uTime * 0.25, 1.0);           // 0→1 every 4 s
    float dist   = abs(ny - pulse);
    float bright = exp(-dist * dist * 120.0) * 0.6;  // tight Gaussian

    float a = uColor.a + bright;
    gl_FragColor = vec4(uColor.rgb + bright * 0.4, clamp(a, 0.0, 1.0));
}
]]

-- ── Shader compilation helper ──────────────────────────────────────────────

local function compileShader(vsSrc, fsSrc)
    local shader = gl.CreateShader({
        vertex   = vsSrc,
        fragment = fsSrc,
    })
    if not shader then
        local log = gl.GetShaderLog() or "(no log)"
        Spring.Echo("BAR Charts v3.1: Shader compile FAILED — " .. log)
        return nil, {}
    end
    return shader, {}
end

local function getUniformLoc(shader, name)
    return gl.GetUniformLocation(shader, name)
end

local function initShaders()
    shaderLine, uLine = compileShader(LINE_VS, LINE_FS)
    if shaderLine then
        uLine.color      = getUniformLoc(shaderLine, "uColor")
        uLine.halfWidth  = getUniformLoc(shaderLine, "uHalfWidth")
        uLine.glowRadius = getUniformLoc(shaderLine, "uGlowRadius")
        Spring.Echo("BAR Charts v3.1: Line shader compiled OK")
    end

    shaderFill, uFill = compileShader(FILL_VS, FILL_FS)
    if shaderFill then
        uFill.color   = getUniformLoc(shaderFill, "uColor")
        uFill.time    = getUniformLoc(shaderFill, "uTime")
        uFill.chartX  = getUniformLoc(shaderFill, "uChartX")
        uFill.chartW  = getUniformLoc(shaderFill, "uChartW")
        Spring.Echo("BAR Charts v3.1: Fill shader compiled OK")
    end

    shaderGrid, uGrid = compileShader(GRID_VS, GRID_FS)
    if shaderGrid then
        uGrid.color   = getUniformLoc(shaderGrid, "uColor")
        uGrid.time    = getUniformLoc(shaderGrid, "uTime")
        uGrid.chartY  = getUniformLoc(shaderGrid, "uChartY")
        uGrid.chartH  = getUniformLoc(shaderGrid, "uChartH")
        Spring.Echo("BAR Charts v3.1: Grid shader compiled OK")
    end
end

local function deleteShaders()
    if shaderLine then gl.DeleteShader(shaderLine); shaderLine = nil end
    if shaderFill then gl.DeleteShader(shaderFill); shaderFill = nil end
    if shaderGrid then gl.DeleteShader(shaderGrid); shaderGrid = nil end
end

-- ── Elapsed seconds for shader animation ──────────────────────────────────

local function elapsedSecs()
    if not widgetStartTimer then return 0 end
    return Spring.DiffTimers(Spring.GetTimer(), widgetStartTimer)
end

-------------------------------------------------------------------------------
-- RMLUI TOGGLE
-------------------------------------------------------------------------------

local rmlContext  = nil
local rmlDocument = nil
local pillVisible = true

local function syncPillState()
    if not rmlDocument then return end
    local pill = rmlDocument:GetElementById("toggle-pill")
    if not pill then return end
    if chartsInteractive then
        pill:SetClass("state-edit",   true)
        pill:SetClass("state-locked", false)
        pill.inner_rml = "CHARTS: EDIT"
    else
        pill:SetClass("state-locked", true)
        pill:SetClass("state-edit",   false)
        pill.inner_rml = "CHARTS: LOCKED"
    end
end

local function setPillVisible(visible)
    pillVisible = visible
    if not rmlDocument then return end
    if visible then syncPillState(); rmlDocument:Show()
    else rmlDocument:Hide() end
end

local function onToggleClick(_event)
    chartsInteractive = not chartsInteractive
    syncPillState()
    chromeDirty  = true
    overlayDirty = true
    Spring.Echo("BAR Charts: " .. (chartsInteractive and "EDIT mode ON" or "LOCKED"))
end

local function initRmlToggle()
    if not RmlUi then return end
    rmlContext = RmlUi.CreateContext("bar_charts_toggle_ctx")
    if not rmlContext then return end
    for _, f in ipairs({
        "LuaUI/Fonts/Exo2-SemiBold.ttf", "LuaUI/Fonts/Exo2-Regular.ttf",
        "LuaUI/Fonts/FreeSansBold.otf",  "LuaUI/Fonts/FreeSans.otf",
    }) do
        if VFS.FileExists(f) then RmlUi.LoadFontFace(f) end
    end
    rmlDocument = rmlContext:LoadDocument("LuaUI/Widgets/bar_charts_toggle.rml")
    if not rmlDocument then return end
    local pill = rmlDocument:GetElementById("toggle-pill")
    if not pill then return end
    pill:AddEventListener("click", onToggleClick, false)
    pill:SetClass("state-locked", true)
    if pillVisible then rmlDocument:Show() end
end

local function shutdownRmlToggle()
    if rmlDocument then rmlDocument:Close(); rmlDocument = nil end
    rmlContext = nil
end

-------------------------------------------------------------------------------
-- HELPERS
-------------------------------------------------------------------------------

local function formatNumber(n)
    if     n >= 1000000 then return string.format("%.1fM", n / 1000000)
    elseif n >= 10000   then return string.format("%.0fK", n / 1000)
    else                     return string.format("%d", math.floor(n + 0.5)) end
end

local function formatYAxis(n, chartType)
    if chartType == "ratio" or chartType == "percent"
    or chartType == "demand" or chartType == "storage" then
        return string.format("%.0f%%", n)
    end
    return formatNumber(n)
end

local function drawRoundedRect(x, y, w, h, r, filled)
    if filled then
        gl.BeginEnd(GL.QUADS, function()
            gl.Vertex(x+r, y);     gl.Vertex(x+w-r, y)
            gl.Vertex(x+w-r, y+h); gl.Vertex(x+r, y+h)
            gl.Vertex(x, y+r);     gl.Vertex(x+w, y+r)
            gl.Vertex(x+w, y+h-r); gl.Vertex(x, y+h-r)
        end)
        local segs = 6
        for i = 0, segs-1 do
            local a1 = (math.pi/2)*(i/segs)
            local a2 = (math.pi/2)*((i+1)/segs)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+r,   y+r);   gl.Vertex(x+r-r*math.cos(a1),   y+r-r*math.sin(a1))
                                          gl.Vertex(x+r-r*math.cos(a2),   y+r-r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+w-r, y+r);   gl.Vertex(x+w-r+r*math.sin(a1), y+r-r*math.cos(a1))
                                          gl.Vertex(x+w-r+r*math.sin(a2), y+r-r*math.cos(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+w-r, y+h-r); gl.Vertex(x+w-r+r*math.cos(a1), y+h-r+r*math.sin(a1))
                                          gl.Vertex(x+w-r+r*math.cos(a2), y+h-r+r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+r,   y+h-r); gl.Vertex(x+r-r*math.sin(a1),   y+h-r+r*math.cos(a1))
                                          gl.Vertex(x+r-r*math.sin(a2),   y+h-r+r*math.cos(a2))
            end)
        end
    else
        gl.BeginEnd(GL.LINE_LOOP, function()
            gl.Vertex(x+r, y); gl.Vertex(x+w-r, y)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+w-r+r*math.sin(a), y+r-r*math.cos(a)) end
            gl.Vertex(x+w, y+r); gl.Vertex(x+w, y+h-r)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+w-r+r*math.cos(a), y+h-r+r*math.sin(a)) end
            gl.Vertex(x+w-r, y+h); gl.Vertex(x+r, y+h)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+r-r*math.sin(a), y+h-r+r*math.cos(a)) end
            gl.Vertex(x, y+h-r); gl.Vertex(x, y+r)
            for i = 0, 6 do local a=(math.pi/2)*(i/6); gl.Vertex(x+r-r*math.cos(a), y+r-r*math.sin(a)) end
        end)
    end
end

-------------------------------------------------------------------------------
-- BUILD EFFICIENCY
-------------------------------------------------------------------------------

local function ensureBuildEffState(tid)
    if not buildEffState[tid] then
        buildEffState[tid] = { samples = {}, index = 0, count = 0, tickCounter = 0 }
        for i = 1, BUILD_EFF_WINDOW_SIZE do buildEffState[tid].samples[i] = 0 end
    end
end

local function sampleBuildEfficiencyForTeam(tid)
    local teamBuilders = builderUnits[tid]
    if not teamBuilders then return 0 end
    local effSum, effCount = 0, 0
    for uid, bd in pairs(teamBuilders) do
        local defID    = bd.defID
        local targetID = Spring.GetUnitIsBuilding(uid)
        if targetID then
            local tDefID   = Spring.GetUnitDefID(targetID)
            local maxMetal = nil
            if defID and tDefID then
                local row = maxMetalUseCache[defID]
                if row then maxMetal = row[tDefID] end
                if maxMetal == nil then
                    local bud = UnitDefs[defID]
                    local tud = UnitDefs[tDefID]
                    if bud and tud then
                        local bt = math.max(tud.buildTime or 1, 1)
                        maxMetal = (bd.bp / bt) * (tud.metalCost or 0)
                    else
                        maxMetal = 0
                    end
                    if not maxMetalUseCache[defID] then maxMetalUseCache[defID] = {} end
                    maxMetalUseCache[defID][tDefID] = maxMetal
                end
            end
            local _, mPull = Spring.GetUnitResources(uid, "metal")
            local mUsing   = mPull or 0
            if maxMetal and maxMetal > 0 then
                effSum   = effSum   + math.min(1.0, mUsing / maxMetal)
                effCount = effCount + 1
            end
        end
    end
    if effCount == 0 then
        return 0
    end
    return (effSum / effCount) * 100
end

local function pushBuildEffSampleForTeam(tid, value)
    ensureBuildEffState(tid)
    local s = buildEffState[tid]
    s.index = (s.index % BUILD_EFF_WINDOW_SIZE) + 1
    s.samples[s.index] = value
    if s.count < BUILD_EFF_WINDOW_SIZE then s.count = s.count + 1 end
    local sum = 0
    for i = 1, s.count do sum = sum + (s.samples[i] or 0) end
    local stats = allyTeams[tid]
    if stats then stats.buildEfficiency = sum / s.count end
end

local function resetBuildEffForTeam(tid)
    if tid then
        buildEffState[tid] = nil
        local stats = allyTeams[tid]
        if stats then stats.buildEfficiency = 0 end
    else
        buildEffState = {}
        for _, stats in pairs(allyTeams) do stats.buildEfficiency = 0 end
    end
end

-------------------------------------------------------------------------------
-- CHART & CARD CLASSES
-------------------------------------------------------------------------------

local Chart = {}
Chart.__index = Chart

function Chart.new(id, label, icon, x, y, chartType, series, multiTeam)
    local self = setmetatable({}, Chart)
    self.id         = id
    self.label      = label
    self.icon       = icon
    self.x          = x
    self.y          = y
    self.width      = CHART_WIDTH
    self.height     = CHART_HEIGHT
    self.scale      = 1.0
    self.enabled    = true
    self.visible    = true
    self.chartType  = chartType
    self.series     = series
    self.multiTeam  = multiTeam or false
    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    self.isHovered  = false
    self._minV = nil; self._maxV = nil; self._range = nil
    return self
end

function Chart:rebuildMultiTeamSeries()
    if not self.multiTeam then return end
    self.series = {}
    local idx = 1
    for tid, teamData in pairs(allyTeams) do
        local seriesKey
        if     self.id == "chart-ally-army"       then seriesKey = "armyValue"
        elseif self.id == "chart-ally-buildpower" then seriesKey = "buildPower"
        elseif self.id == "chart-ally-metal"      then seriesKey = "metalIncome"
        elseif self.id == "chart-ally-energy"     then seriesKey = "energyIncome"
        end
        if seriesKey then
            self.series[idx] = {
                label     = teamData.playerName,
                color     = teamData.color,
                seriesKey = seriesKey,
                teamID    = tid,
            }
            idx = idx + 1
        end
    end
    chromeDirty = true
    linesDirty  = true
end

function Chart:isMouseOver(mx, my)
    return mx >= self.x and mx <= self.x + self.width  * self.scale
       and my >= self.y and my <= self.y + self.height * self.scale
end

function Chart:getSamples(i)
    local s   = self.series[i]
    if not s then return {} end
    local tid = s.teamID or viewedTeamID
    if not tid or not history[tid] or not history[tid][s.seriesKey] then return {} end
    return ringSample(tid, s.seriesKey, RENDER_POINTS)
end

function Chart:hasData()
    for i = 1, #self.series do
        local s   = self.series[i]
        local tid = s.teamID or viewedTeamID
        if tid and history[tid] and history[tid][s.seriesKey] then
            local _, cnt = ringRange(tid, s.seriesKey)
            if cnt >= 2 then return true end
        end
    end
    return false
end

function Chart:timeWindow()
    local s = self.series[1]
    if not s then return 0, 0 end
    local tid = s.teamID or viewedTeamID
    if not tid or not history[tid] then return 0, 0 end
    local key = s.seriesKey
    if not history[tid][key] then return 0, 0 end
    local _, count = ringRange(tid, key)
    local nowGameSecs = Spring.GetGameFrame() / GAME_FPS
    return count / GAME_FPS, nowGameSecs
end

-- ── StatCard ───────────────────────────────────────────────────────────────

local StatCard = {}
StatCard.__index = StatCard

function StatCard.new(id, label, icon, x, y, color, getValueFn)
    local self = setmetatable({}, StatCard)
    self.id           = id
    self.label        = label
    self.icon         = icon
    self.x            = x
    self.y            = y
    self.scale        = 1.0
    self.enabled      = true
    self.visible      = true
    self.color        = color
    self.getValueFn   = getValueFn
    self.displayValue = 0
    self.isDragging   = false
    self.dragStartX   = 0
    self.dragStartY   = 0
    self.isHovered    = false
    return self
end

function StatCard:update()
    if self.enabled then self.displayValue = self.getValueFn() end
end

function StatCard:isMouseOver(mx, my)
    return mx >= self.x and mx <= self.x + CARD_WIDTH  * self.scale
       and my >= self.y and my <= self.y + CARD_HEIGHT * self.scale
end

-------------------------------------------------------------------------------
-- DISPLAY-LIST MANAGEMENT
-------------------------------------------------------------------------------

local function freeLists()
    if chromeDisplayList  then gl.DeleteList(chromeDisplayList);  chromeDisplayList  = nil end
    if linesDisplayList   then gl.DeleteList(linesDisplayList);   linesDisplayList   = nil end
    if overlayDisplayList then gl.DeleteList(overlayDisplayList); overlayDisplayList = nil end
end

-- ── computeRange ──────────────────────────────────────────────────────────

local function computeRange(chart)
    local mn, mx
    for i = 1, #chart.series do
        local pts = chart:getSamples(i)
        for _, v in ipairs(pts) do
            if v and not (v ~= v) then
                if mn == nil or v < mn then mn = v end
                if mx == nil or v > mx then mx = v end
            end
        end
    end
    if mn == nil then return nil end
    if chart.chartType == "percent" then
        mn = 0; mx = 100
    elseif chart.chartType == "storage" then
        local ab = math.max(math.abs(mn), math.abs(mx), 100)
        local p  = ab*0.12; mn = -(ab+p); mx = (ab+p)
    elseif chart.chartType == "demand" then
        local ab = math.max(math.abs(mn), math.abs(mx), 100)
        local p  = ab*0.15; mn = -(ab+p); mx = (ab+p)
    else
        mn = 0
        local p = mx > 0 and mx*0.12 or 100
        mx = mx + p
    end
    local r = mx - mn
    if r == 0 then r = 1 end
    chart._minV = mn; chart._maxV = mx; chart._range = r
    return mn, mx, r
end

-------------------------------------------------------------------------------
-- SHADER-BASED LINE DRAWING HELPERS
-- These helpers are called INSIDE a gl.CreateList() call.
-- They emit GL geometry that references the compiled shader programs.
-------------------------------------------------------------------------------

-- drawShaderLine: emits a fat-quad ribbon for a single data series.
-- pts   : array of Y values (already sampled, length >= 2)
-- cX,cY : chart content area origin (pixels)
-- cW,cH : chart content area size (pixels)
-- mn,r  : data range (minV, range)
-- color : {r,g,b,a}
-- halfW : ribbon half-width in pixels (after chart scale is applied)
-- glowR : glow radius in pixels

local function drawShaderLine(pts, cX, cY, cW, cH, mn, r, color, halfW, glowR)
    if not shaderLine then return end
    local n = #pts
    if n < 2 then return end

    gl.UseShader(shaderLine)
    if uLine.color      then gl.Uniform(uLine.color,      color[1], color[2], color[3], color[4] or 1) end
    if uLine.halfWidth  then gl.Uniform(uLine.halfWidth,  halfW) end
    if uLine.glowRadius then gl.Uniform(uLine.glowRadius, glowR) end

    -- 1px padding beyond glow radius is enough for the tighter AA fringe.
    local totalHalfW = halfW + glowR + 1.0

    -- Pre-compute all screen-space positions so we can derive true
    -- segment-perpendicular directions rather than always expanding in Y.
    local sx, sy = {}, {}
    for i = 1, n do
        -- RIGHT-PINNED: sample i=n maps to cX+cW, i=1 maps leftward.
        -- This keeps the right edge anchored so that as new data arrives
        -- and points shift left, the rendered line doesn't appear to crawl.
        sx[i] = cX + cW - ((n - i) / (n - 1)) * cW
        sy[i] = cY + ((pts[i] - mn) / r) * cH
        sy[i] = math.max(cY - totalHalfW, math.min(cY + cH + totalHalfW, sy[i]))
    end

    -- gl.Color.r carries the signed perpendicular distance from the centreline.
    gl.BeginEnd(GL.TRIANGLES, function()
        for i = 1, n - 1 do
            local x0, y0 = sx[i],   sy[i]
            local x1, y1 = sx[i+1], sy[i+1]

            -- Segment direction, normalised
            local dx = x1 - x0
            local dy = y1 - y0
            local len = math.sqrt(dx*dx + dy*dy)
            if len < 0.0001 then len = 0.0001 end
            -- Perpendicular (rotate 90°): (-dy, dx) / len
            local px = (-dy / len) * totalHalfW
            local py = ( dx / len) * totalHalfW

            -- Six vertices (two triangles) forming the quad.
            -- gl.Color.r = +totalHalfW on one side, -totalHalfW on the other.
            gl.Color(-totalHalfW, 0, 0, 1);  gl.Vertex(x0 - px, y0 - py)
            gl.Color( totalHalfW, 0, 0, 1);  gl.Vertex(x0 + px, y0 + py)
            gl.Color(-totalHalfW, 0, 0, 1);  gl.Vertex(x1 - px, y1 - py)

            gl.Color( totalHalfW, 0, 0, 1);  gl.Vertex(x1 + px, y1 + py)
            gl.Color(-totalHalfW, 0, 0, 1);  gl.Vertex(x1 - px, y1 - py)
            gl.Color( totalHalfW, 0, 0, 1);  gl.Vertex(x0 + px, y0 + py)
        end
    end)

    gl.UseShader(0)
end

-- drawShaderFill: emits the area-fill triangle strip using the fill shader.

local function drawShaderFill(pts, cX, cY, cW, cH, mn, r, color, time, isMulti)
    if not shaderFill then return end
    local n = #pts
    if n < 2 then return end
    if isMulti then return end

    local fillBaseY = cY

    gl.UseShader(shaderFill)
    if uFill.color  then gl.Uniform(uFill.color,  color[1], color[2], color[3], color[4] or 1) end
    if uFill.time   then gl.Uniform(uFill.time,   time) end
    if uFill.chartX then gl.Uniform(uFill.chartX, cX) end
    if uFill.chartW then gl.Uniform(uFill.chartW, cW) end

    -- RIGHT-PINNED: mirrors the line draw so fill and line never drift apart.
    gl.BeginEnd(GL.TRIANGLE_STRIP, function()
        for i = 1, n do
            local x    = cX + cW - ((n - i) / (n - 1)) * cW
            local y    = cY + ((pts[i] - mn) / r) * cH
            y = math.max(cY, math.min(cY + cH, y))
            local tVal = math.max(0, (y - cY) / math.max(cH, 1))

            gl.Color(0, 0, 0, 1);    gl.Vertex(x, fillBaseY)
            gl.Color(tVal, 0, 0, 1); gl.Vertex(x, y)
        end
    end)

    gl.UseShader(0)
end

-- drawShaderGrid: draws a single grid line with the scan-pulse fragment shader.

local function drawShaderGridLine(x0, y0, x1, y1, cY, cH, color, time)
    if not shaderGrid then
        -- fallback to plain line
        gl.Color(color[1], color[2], color[3], color[4])
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(x0, y0); gl.Vertex(x1, y1)
        end)
        return
    end

    gl.UseShader(shaderGrid)
    if uGrid.color  then gl.Uniform(uGrid.color,  color[1], color[2], color[3], color[4]) end
    if uGrid.time   then gl.Uniform(uGrid.time,   time) end
    if uGrid.chartY then gl.Uniform(uGrid.chartY, cY) end
    if uGrid.chartH then gl.Uniform(uGrid.chartH, cH) end

    gl.LineWidth(1.0)
    gl.BeginEnd(GL.LINES, function()
        gl.Vertex(x0, y0)
        gl.Vertex(x1, y1)
    end)

    gl.UseShader(0)
end

-------------------------------------------------------------------------------
-- CHROME DISPLAY LIST
-- Background panels, grid lines, Y-axis labels, chart titles, card frames.
-- NOTE: grid lines here call drawShaderGridLine — the shader is baked into
-- the display list commands at the time of rebuild.  Because display lists
-- record raw GL calls, time-uniform updates happen in DrawScreen by calling
-- gl.Uniform BEFORE gl.CallList (see the shader-time-patch pattern below).
--
-- IMPORTANT: Spring display lists DO replay gl.UseShader and gl.Uniform calls,
-- so the animation-time must be updated externally each frame.  We work around
-- this by NOT baking grid lines into the chrome display list — instead we draw
-- animated grid lines live in DrawScreen (outside any display list).
-- This is a deliberate trade-off: grid lines are cheap geometry.
-------------------------------------------------------------------------------

local function rebuildChromeList()
    if chromeDisplayList then gl.DeleteList(chromeDisplayList) end
    chromeDisplayList = gl.CreateList(function()

        -- ── Stat Cards ────────────────────────────────────────────────────
        for _, card in pairs(statCards) do
            local show = (card.enabled and card.visible) or (not card.enabled and chartsInteractive)
            if show then
                local am = (not card.enabled and chartsInteractive) and 0.35 or 1.0
                local c  = card.color
                gl.PushMatrix()
                gl.Translate(card.x, card.y, 0)
                gl.Scale(card.scale, card.scale, 1)
                gl.Color(COLOR.bg[1],     COLOR.bg[2],     COLOR.bg[3],     COLOR.bg[4]*am)
                drawRoundedRect(0, 0, CARD_WIDTH, CARD_HEIGHT, 4, true)
                gl.Color(COLOR.border[1], COLOR.border[2], COLOR.border[3], COLOR.border[4]*am)
                gl.LineWidth(1)
                drawRoundedRect(0.5, 0.5, CARD_WIDTH-1, CARD_HEIGHT-1, 4, false)
                gl.Color(c[1], c[2], c[3], 0.7*am)
                gl.BeginEnd(GL.QUADS, function()
                    gl.Vertex(0, 4); gl.Vertex(3, 4)
                    gl.Vertex(3, CARD_HEIGHT-4); gl.Vertex(0, CARD_HEIGHT-4)
                end)
                gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4]*am)
                gl.Text(card.icon.."  "..card.label, 10, CARD_HEIGHT-18, 9, "o")
                if not card.enabled and chartsInteractive then
                    gl.Color(COLOR.danger[1], COLOR.danger[2], COLOR.danger[3], 0.8)
                    gl.Text("DISABLED", CARD_WIDTH/2, CARD_HEIGHT/2, 10, "co")
                end
                gl.PopMatrix()
            end
        end

        -- ── Charts — background panels only (no grid lines here) ──────────
        for _, chart in pairs(charts) do
            local show = (chart.enabled and chart.visible) or (not chart.enabled and chartsInteractive)
            if show then
                local w   = chart.width
                local h   = chart.height
                local pad = PADDING
                local cX  = pad.left
                local cY  = pad.bottom
                local cW  = w - pad.left - pad.right
                local cH  = h - pad.top  - pad.bottom
                local am  = (not chart.enabled and chartsInteractive) and 0.35 or 1.0

                gl.PushMatrix()
                gl.Translate(chart.x, chart.y, 0)
                gl.Scale(chart.scale, chart.scale, 1)

                -- Background
                gl.Color(COLOR.bg[1], COLOR.bg[2], COLOR.bg[3], COLOR.bg[4]*am)
                drawRoundedRect(0, 0, w, h, 4, true)

                -- Border
                gl.Color(COLOR.border[1], COLOR.border[2], COLOR.border[3], COLOR.border[4]*am)
                gl.LineWidth(1)
                drawRoundedRect(0.5, 0.5, w-1, h-1, 4, false)

                local hasData = chart:hasData()
                if not hasData or not chart.enabled then
                    local txt = not chart.enabled and "— DISABLED —" or "— awaiting data —"
                    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.25*am)
                    gl.Text(txt, cX+cW/2, cY+cH/2, 10, "c")
                    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4]*am)
                    gl.Text(chart.icon.."  "..chart.label, pad.left+2, h-pad.top-10, 10, "o")
                    gl.PopMatrix()
                else
                    local mn, mx, r = computeRange(chart)
                    if not mn then
                        gl.PopMatrix()
                    else
                        -- Y-axis labels (static)
                        for i = 0, 4 do
                            local v    = mn + (r * i / 4)
                            local yPos = cY + (cH * i / 4)
                            gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4]*am)
                            gl.Text(formatYAxis(v, chart.chartType), cX-5, yPos-4, 9, "ro")
                        end

                        -- Zero line for demand/storage (static)
                        if chart.chartType == "demand" or chart.chartType == "storage" then
                            local zeroY = cY + ((0 - mn) / r) * cH
                            gl.Color(COLOR.accent[1], COLOR.accent[2], COLOR.accent[3], 0.45*am)
                            gl.LineWidth(1.0)
                            gl.BeginEnd(GL.LINES, function()
                                gl.Vertex(cX, zeroY); gl.Vertex(cX+cW, zeroY)
                            end)
                            gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.5*am)
                            gl.Text("0", cX-5, zeroY-4, 9, "ro")
                        end

                        -- Chart title
                        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4]*am)
                        gl.Text(chart.icon.."  "..chart.label, pad.left+2, h-pad.top-10, 10, "o")

                        gl.PopMatrix()
                    end
                end
            end
        end

        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.4)
        gl.Text("F9: Toggle  |  /barcharts view <name>", vsx-240, 30, 11, "o")
    end)
    chromeDirty = false
end

-------------------------------------------------------------------------------
-- LINES DISPLAY LIST  (shader-rendered)
-- Rebuilds fill + line geometry for every chart using the GLSL programs.
-- Grid lines are drawn LIVE in DrawScreen (outside any display list) so their
-- time-based animation can be updated every frame cheaply.
-------------------------------------------------------------------------------

local function rebuildLinesList()
    if linesDisplayList then gl.DeleteList(linesDisplayList) end
    local t = elapsedSecs()

    linesDisplayList = gl.CreateList(function()
        gl.Blending(true)
        gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

        for _, chart in pairs(charts) do
            local show = (chart.enabled and chart.visible) or (not chart.enabled and chartsInteractive)
            if show and chart.enabled and chart:hasData() then
                local mn, mx, r = computeRange(chart)
                if mn then
                    local cX = PADDING.left
                    local cY = PADDING.bottom
                    local cW = chart.width  - PADDING.left - PADDING.right
                    local cH = chart.height - PADDING.top  - PADDING.bottom

                    local am       = 1.0
                    local isMulti  = chart.multiTeam
                    local scl      = chart.scale

                    -- Effective pixel sizes after chart scale
                    local halfW = LINE_HALF_WIDTH  / scl
                    local glowR = LINE_GLOW_RADIUS / scl

                    gl.PushMatrix()
                    gl.Translate(chart.x, chart.y, 0)
                    gl.Scale(scl, scl, 1)

                    for si, s in ipairs(chart.series) do
                        local pts  = chart:getSamples(si)
                        local nPts = #pts
                        if nPts >= 2 then
                            local clr = { s.color[1], s.color[2], s.color[3], am }

                            -- 1. Area fill — normal alpha blend
                            gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
                            drawShaderFill(pts, cX, cY, cW, cH, mn, r, clr, t, isMulti)

                            -- 2. Line — additive blend so the glow brightens
                            --    surrounding pixels without widening the core.
                            gl.BlendFunc(GL.SRC_ALPHA, GL.ONE)
                            drawShaderLine(pts, cX, cY, cW, cH, mn, r, clr, halfW, glowR)

                            -- 3. Endpoint dot — restore normal blend first
                            gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)
                            local last = pts[nPts]
                            if last and not (last ~= last) then
                                local dotY = cY + ((last - mn) / r) * cH
                                dotY = math.max(cY, math.min(cY + cH, dotY))
                                gl.Color(clr[1], clr[2], clr[3], 0.9)
                                gl.PointSize(5)
                                gl.BeginEnd(GL.POINTS, function() gl.Vertex(cX + cW, dotY) end)
                            end
                        end
                    end

                    -- Restore normal blend before time axis labels
                    gl.BlendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA)

                    -- X-axis time labels
                    local windowSecs, nowGameSecs = chart:timeWindow()
                    if windowSecs >= BASE_TICK_SECS then
                        drawTimeAxis(cX, cW, cY, windowSecs, nowGameSecs, am)
                    end

                    gl.PopMatrix()
                end
            end
        end

        gl.Blending(false)
    end)

    linesDirty           = false
    linesLastRebuildTime = Spring.GetTimer()
end

-------------------------------------------------------------------------------
-- LIVE GRID DRAWING  (called every DrawScreen frame, outside display lists)
-- These are cheap horizontal lines; drawing them live lets the scan-pulse
-- animation update at full monitor refresh rate.
-------------------------------------------------------------------------------

local function drawLiveGridLines()
    local t = elapsedSecs()

    for _, chart in pairs(charts) do
        local show = (chart.enabled and chart.visible) or (not chart.enabled and chartsInteractive)
        if show and chart.enabled and chart:hasData() and chart._range then
            local mn  = chart._minV
            local r   = chart._range
            local w   = chart.width
            local h   = chart.height
            local cX  = PADDING.left
            local cY  = PADDING.bottom
            local cW  = w - PADDING.left - PADDING.right
            local cH  = h - PADDING.top  - PADDING.bottom
            local scl = chart.scale

            gl.PushMatrix()
            gl.Translate(chart.x, chart.y, 0)
            gl.Scale(scl, scl, 1)

            for i = 0, 4 do
                local yPos = cY + (cH * i / 4)
                local gc   = (i == 0) and COLOR.gridBase or COLOR.grid
                drawShaderGridLine(cX, yPos, cX + cW, yPos, cY, cH, gc, t)
            end

            gl.PopMatrix()
        end
    end
end

-------------------------------------------------------------------------------
-- OVERLAY DISPLAY LIST
-------------------------------------------------------------------------------

local function rebuildOverlayList()
    if overlayDisplayList then gl.DeleteList(overlayDisplayList) end
    overlayDisplayList = gl.CreateList(function()

        -- Stat card values
        for _, card in pairs(statCards) do
            local show = (card.enabled and card.visible) or (not card.enabled and chartsInteractive)
            if show and card.enabled then
                gl.PushMatrix()
                gl.Translate(card.x, card.y, 0)
                gl.Scale(card.scale, card.scale, 1)
                local c = card.color
                gl.Color(c[1], c[2], c[3], 1.0)
                gl.Text(formatNumber(math.floor(card.displayValue+0.5)), CARD_WIDTH/2+5, 10, 20, "co")

                if card.id == "card-build-efficiency" then
                    local vStats = allyTeams[viewedTeamID]
                    local stall  = vStats and vStats.metalStall or 0
                    if stall == 2 then
                        gl.Color(COLOR.danger[1], COLOR.danger[2], COLOR.danger[3], 1.0)
                        gl.Text("! STALL", CARD_WIDTH-6, CARD_HEIGHT-18, 9, "ro")
                    elseif stall == 1 then
                        gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 1.0)
                        gl.Text("! STALL", CARD_WIDTH-6, CARD_HEIGHT-18, 9, "ro")
                    end
                end
                gl.PopMatrix()
            end
        end

        -- Per-chart stall overlay
        local vStats = allyTeams[viewedTeamID]
        local stall  = vStats and vStats.metalStall or 0
        for _, chart in pairs(charts) do
            local show = (chart.enabled and chart.visible) or (not chart.enabled and chartsInteractive)
            if show and chart.enabled and chart.id == "chart-build-efficiency" then
                gl.PushMatrix()
                gl.Translate(chart.x, chart.y, 0)
                gl.Scale(chart.scale, chart.scale, 1)
                if stall == 2 then
                    gl.Color(COLOR.danger[1], COLOR.danger[2], COLOR.danger[3], 1.0)
                    gl.Text("! STALL", chart.width-PADDING.right-2, chart.height-PADDING.top-10, 10, "ro")
                elseif stall == 1 then
                    gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 1.0)
                    gl.Text("! STALL", chart.width-PADDING.right-2, chart.height-PADDING.top-10, 10, "ro")
                end
                gl.PopMatrix()
            end
        end

        -- Hover highlights
        for _, chart in pairs(charts) do
            if chart.isHovered or (chartsInteractive and chart.isDragging) then
                gl.PushMatrix()
                gl.Translate(chart.x, chart.y, 0)
                gl.Scale(chart.scale, chart.scale, 1)
                gl.Color(COLOR.borderHot[1], COLOR.borderHot[2], COLOR.borderHot[3], 0.8)
                gl.LineWidth(2.0)
                drawRoundedRect(0.5, 0.5, chart.width-1, chart.height-1, 4, false)
                gl.PopMatrix()
            end
        end
        for _, card in pairs(statCards) do
            if card.isHovered or (chartsInteractive and card.isDragging) then
                gl.PushMatrix()
                gl.Translate(card.x, card.y, 0)
                gl.Scale(card.scale, card.scale, 1)
                gl.Color(COLOR.borderHot[1], COLOR.borderHot[2], COLOR.borderHot[3], 0.8)
                gl.LineWidth(2.0)
                drawRoundedRect(0.5, 0.5, CARD_WIDTH-1, CARD_HEIGHT-1, 4, false)
                gl.PopMatrix()
            end
        end

        -- Edit-mode badge
        if chartsInteractive then
            gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 0.55)
            gl.Text("EDIT MODE", vsx-150, 45, 11, "o")
        end
    end)
    overlayDirty = false
end

-------------------------------------------------------------------------------
-- ARMY & BUILD POWER HELPERS
-------------------------------------------------------------------------------

local function unitMetalCost(udid)
    if not udid then return 0 end
    local ud = UnitDefs[udid]
    return ud and (ud.metalCost or 0) or 0
end

local function seedArmyValues()
    for tid in pairs(allyTeams) do
        local stats   = allyTeams[tid]
        stats.armyValue = 0
        local units = Spring.GetTeamUnits(tid) or {}
        for _, uid in ipairs(units) do
            stats.armyValue = stats.armyValue + unitMetalCost(Spring.GetUnitDefID(uid))
        end
    end
end

local function seedBuildPower()
    builderUnits = {}
    for tid in pairs(allyTeams) do
        builderUnits[tid] = {}
        local stats = allyTeams[tid]
        stats.buildPower = 0
        local units = Spring.GetTeamUnits(tid) or {}
        for _, uid in ipairs(units) do
            local udid = Spring.GetUnitDefID(uid)
            local ud   = UnitDefs[udid or 0]
            if ud and ud.isBuilder then
                local bp = ud.buildSpeed or 0
                stats.buildPower = stats.buildPower + bp
                if bp > 0 then
                    builderUnits[tid][uid] = { bp = bp, defID = udid }
                end
            end
        end
        ensureBuildEffState(tid)
    end
end

local function seedUnitCount()
    for tid in pairs(allyTeams) do
        local units = Spring.GetTeamUnits(tid) or {}
        allyTeams[tid].unitCount = #units
    end
end

-------------------------------------------------------------------------------
-- UNIT EVENT CALLBACKS
-------------------------------------------------------------------------------

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    local cost = unitMetalCost(unitDefID)
    local ud   = UnitDefs[unitDefID]
    local bp   = (ud and ud.isBuilder) and (ud.buildSpeed or 0) or 0
    local ts   = allyTeams[unitTeam]
    if ts then
        ts.armyValue = ts.armyValue + cost
        if bp > 0 then
            ts.buildPower = ts.buildPower + bp
            if not builderUnits[unitTeam] then builderUnits[unitTeam] = {} end
            builderUnits[unitTeam][unitID] = { bp = bp, defID = unitDefID }
        end
        ts.unitCount = ts.unitCount + 1
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, _attackerID, _attackerDefID, _attackerTeam)
    local cost = unitMetalCost(unitDefID)
    local ud   = UnitDefs[unitDefID]
    local bp   = (ud and ud.isBuilder) and (ud.buildSpeed or 0) or 0
    local ts   = allyTeams[unitTeam]
    if ts then
        ts.armyValue  = math.max(0, ts.armyValue - cost)
        ts.metalLost  = ts.metalLost + cost
        ts.unitCount  = math.max(0, ts.unitCount - 1)
        if bp > 0 then
            ts.buildPower = math.max(0, ts.buildPower - bp)
            if builderUnits[unitTeam] then builderUnits[unitTeam][unitID] = nil end
        end
    end
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
    local cost = unitMetalCost(unitDefID)
    local ud   = UnitDefs[unitDefID]
    local bp   = (ud and ud.isBuilder) and (ud.buildSpeed or 0) or 0
    local ots  = allyTeams[oldTeam]
    local nts  = allyTeams[newTeam]
    if ots then
        ots.armyValue = math.max(0, ots.armyValue - cost)
        ots.unitCount = math.max(0, ots.unitCount - 1)
        if bp > 0 then
            ots.buildPower = math.max(0, ots.buildPower - bp)
            if builderUnits[oldTeam] then builderUnits[oldTeam][unitID] = nil end
        end
    end
    if nts then
        nts.armyValue = nts.armyValue + cost
        nts.unitCount = nts.unitCount + 1
        if bp > 0 then
            nts.buildPower = nts.buildPower + bp
            if not builderUnits[newTeam] then builderUnits[newTeam] = {} end
            builderUnits[newTeam][unitID] = { bp = bp, defID = unitDefID }
        end
    end
end

function widget:UnitCaptured(unitID, unitDefID, oldTeam, newTeam)
    widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
end

-------------------------------------------------------------------------------
-- ALLY TEAM INIT
-------------------------------------------------------------------------------

local function isActiveParticipant(tid)
    local _, leaderID, isDead, isAI = Spring.GetTeamInfo(tid)
    if isDead then return false end
    if isAI then return true end
    if myTeamID ~= nil and tid == myTeamID then return true end
    if not leaderID or leaderID < 0 then
        local units = Spring.GetTeamUnits(tid)
        return units and #units > 0
    end
    local _, _, spectator = Spring.GetPlayerInfo(leaderID)
    if spectator then
        local units = Spring.GetTeamUnits(tid)
        return units and #units > 0
    end
    return true
end

local function resolveTeamName(tid)
    local _, leaderID, _, isAI = Spring.GetTeamInfo(tid)
    if isAI then
        local _, aiName = Spring.GetAIInfo(tid)
        return aiName or ("AI "..tid)
    end
    if leaderID and leaderID >= 0 then
        local pName = Spring.GetPlayerInfo(leaderID)
        if pName and pName ~= "" then return pName end
    end
    return "Team "..tid
end

local function initAllyTeams()
    local spec = Spring.GetSpectatingState()
    isSpectator = spec or false
    myTeamID    = isSpectator and nil or Spring.GetMyTeamID()

    local tlist
    if isSpectator then
        local allyTeamList = Spring.GetAllyTeamList()
        local seen = {}
        tlist = {}
        if allyTeamList then
            for _, atid in ipairs(allyTeamList) do
                local teams = Spring.GetTeamList(atid) or {}
                for _, tid in ipairs(teams) do
                    if not seen[tid] then seen[tid] = true; tlist[#tlist+1] = tid end
                end
            end
        end
        local bare = Spring.GetTeamList() or {}
        for _, tid in ipairs(bare) do
            if not seen[tid] then seen[tid] = true; tlist[#tlist+1] = tid end
        end
    else
        local aid = Spring.GetMyAllyTeamID()
        if not aid then return false end
        tlist = Spring.GetTeamList(aid)
        myAllyTeamID = aid
    end

    if not tlist or #tlist == 0 then return false end

    local newTeams = {}
    local firstTID = nil
    local function addTeam(tid)
        local r, g, b = Spring.GetTeamColor(tid)
        newTeams[tid] = {
            teamID=tid, playerName=resolveTeamName(tid), color={r or 1, g or 1, b or 1, 1},
            metalIncome=0, metalUsage=0, energyIncome=0, energyUsage=0,
            damageDealt=0, damageTaken=0, armyValue=0, buildPower=0,
            kills=0, losses=0, unitCount=0, metalLost=0,
            buildEfficiency=0, metalStall=0, totalBP=0,
        }
        initTeamBuffers(tid)
        if not firstTID then firstTID = tid end
    end

    for _, tid in ipairs(tlist) do
        if isActiveParticipant(tid) then addTeam(tid) end
    end

    if not next(newTeams) then
        for _, tid in ipairs(tlist) do
            local _, _, isDead = Spring.GetTeamInfo(tid)
            if not isDead then
                local units = Spring.GetTeamUnits(tid)
                if units and #units > 0 then addTeam(tid) end
            end
        end
    end

    if not next(newTeams) then return false end
    allyTeams = newTeams

    if isSpectator then
        viewedTeamID = firstTID
    else
        viewedTeamID = (myTeamID and newTeams[myTeamID]) and myTeamID or firstTID
    end
    return true
end

-------------------------------------------------------------------------------
-- STAT COLLECTION
-------------------------------------------------------------------------------

local function collectStats(gameFrame)
    frameCounter = frameCounter + 1
    if frameCounter >= FULL_SCAN_INTERVAL then
        frameCounter = 0
        for tid, stats in pairs(allyTeams) do
            if Spring.GetTeamDamageStats then
                local dd, dt = Spring.GetTeamDamageStats(tid)
                stats.damageDealt = dd or stats.damageDealt
                stats.damageTaken = dt or stats.damageTaken
            end
            local uK, uD = Spring.GetTeamUnitStats(tid)
            if uK then stats.kills  = uK end
            if uD then stats.losses = uD end
        end
    end

    local stallChanged = false
    for tid, stats in pairs(allyTeams) do
        local ml, ms, mpull, minc, mexp = Spring.GetTeamResources(tid, "metal")
        local el, es, epull, einc, eexp = Spring.GetTeamResources(tid, "energy")

        if minc ~= nil then
            stats.metalIncome  = minc
            stats.metalUsage   = mexp  or 0
            stats.energyIncome = einc  or 0
            stats.energyUsage  = eexp  or 0

            local pull    = mpull or 0
            local expense = mexp  or 0
            local newStall
            if pull > 1 then
                local ratio = expense / pull
                if     ratio < 0.60 then newStall = 2
                elseif ratio < 0.98 then newStall = 1
                else                     newStall = 0 end
            else
                newStall = 0
            end

            if newStall ~= (prevStallState[tid] or 0) then
                prevStallState[tid] = newStall
                stallChanged = true
            end
            stats.metalStall = newStall
        end

        if history[tid] then
            ringPush(tid, "metalIncome",     stats.metalIncome)
            ringPush(tid, "metalUsage",      stats.metalUsage)
            ringPush(tid, "energyIncome",    stats.energyIncome)
            ringPush(tid, "energyUsage",     stats.energyUsage)
            ringPush(tid, "armyValue",       stats.armyValue)
            ringPush(tid, "buildPower",      stats.buildPower)
            ringPush(tid, "kills",           stats.kills)
            ringPush(tid, "losses",          stats.losses)
            ringPush(tid, "damageDealt",     stats.damageDealt)
            ringPush(tid, "damageTaken",     stats.damageTaken)
            ringPush(tid, "buildEfficiency", stats.buildEfficiency)
        end
    end

    for _, card in pairs(statCards) do card:update() end

    linesDirty = true
    if stallChanged then overlayDirty = true end

    if not chromeDirty then
        for _, chart in pairs(charts) do
            if chart.enabled and chart._range == nil and chart:hasData() then
                chromeDirty = true
                break
            end
        end
    end
end

-------------------------------------------------------------------------------
-- CHART / CARD LAYOUT BUILDERS
-------------------------------------------------------------------------------

local function buildChartsAndCards()
    charts    = {}
    statCards = {}

    charts.metal = Chart.new("chart-metal", "METAL", "⚙",
        vsx-350, vsy-230, "dual", {
            { label="Income", color=COLOR.accent,  seriesKey="metalIncome"  },
            { label="Usage",  color=COLOR.accent2, seriesKey="metalUsage"   },
        })
    charts.energy = Chart.new("chart-energy", "ENERGY", "⚡",
        vsx-660, vsy-230, "dual", {
            { label="Income", color=COLOR.accent,  seriesKey="energyIncome" },
            { label="Usage",  color=COLOR.accent2, seriesKey="energyUsage"  },
        })
    charts.damage = Chart.new("chart-damage", "DAMAGE", "✕",
        vsx-970, vsy-230, "dual", {
            { label="Dealt", color=COLOR.success, seriesKey="damageDealt" },
            { label="Taken", color=COLOR.danger,  seriesKey="damageTaken" },
        })
    charts.army = Chart.new("chart-army", "ARMY VALUE", "⚙",
        vsx-350, vsy-430, "single", {
            { label="Value", color=COLOR.accent, seriesKey="armyValue" },
        })
    charts.kd = Chart.new("chart-kd", "K/D", "✕",
        vsx-660, vsy-430, "ratio", {
            { label="Ratio", color=COLOR.success, seriesKey="kills" },
        })
    charts.buildEfficiency = Chart.new("chart-build-efficiency",
        "BUILDER EFFICIENCY", "🔧", vsx-970, vsy-430, "percent", {
            { label="Efficiency", color=COLOR.gold, seriesKey="buildEfficiency" },
        })
    charts.allyArmy       = Chart.new("chart-ally-army",       "TEAM ARMY", "⚙",
        vsx-1280, vsy-430, "multi", {}, true)
    charts.allyBuildPower = Chart.new("chart-ally-buildpower", "TEAM BP",   "🔧",
        vsx-1280, vsy-230, "multi", {}, true)

    -- K/D override: compute ratio from raw kills/losses samples, then the
    -- interpolation in ringSample handles the smoothing automatically since
    -- each underlying series is already interpolated before the ratio is taken.
    do
        charts.kd.getSamples = function(self, i)
            local tid = viewedTeamID
            if not tid or not history[tid] then return {} end
            local kPts = ringSample(tid, "kills",  RENDER_POINTS)
            local lPts = ringSample(tid, "losses", RENDER_POINTS)
            local n    = math.min(#kPts, #lPts)
            local pts  = {}
            for j = 1, n do
                local k = kPts[j] or 0
                local l = lPts[j] or 0
                pts[j]  = l == 0 and (k > 0 and 5 or 0) or math.min(5, k / l)
            end
            return pts
        end
        charts.kd.hasData = function(self)
            local tid = viewedTeamID
            if not tid or not history[tid] then return false end
            local _, cnt = ringRange(tid, "kills")
            return cnt >= 2
        end
        charts.kd.timeWindow = function(self)
            local tid = viewedTeamID
            if not tid or not history[tid] then return 0, 0 end
            local _, count = ringRange(tid, "kills")
            return count / GAME_FPS, Spring.GetGameFrame() / GAME_FPS
        end
    end

    -- Stat cards
    local cardY    = vsy - 650
    local cardStep = 80
    local col1X    = vsx - 350
    local col2X    = vsx - 200

    local function vStat(key)
        return function()
            local s = allyTeams[viewedTeamID]
            return s and (s[key] or 0) or 0
        end
    end

    statCards["card-army-value"]       = StatCard.new("card-army-value",       "ARMY VALUE", "⚙",  col1X, cardY,            COLOR.accent,  vStat("armyValue"))
    statCards["card-unit-count"]       = StatCard.new("card-unit-count",       "UNITS",      "▣",  col2X, cardY,            COLOR.accent,  vStat("unitCount"))
    statCards["card-kills"]            = StatCard.new("card-kills",            "KILLS",      "✕",  col1X, cardY-cardStep,   COLOR.success, vStat("kills"))
    statCards["card-losses"]           = StatCard.new("card-losses",           "LOSSES",     "↓",  col2X, cardY-cardStep,   COLOR.danger,  vStat("losses"))
    statCards["card-dmg-dealt"]        = StatCard.new("card-dmg-dealt",        "DMG DEALT",  "▲",  col1X, cardY-cardStep*2, COLOR.success, vStat("damageDealt"))
    statCards["card-dmg-taken"]        = StatCard.new("card-dmg-taken",        "DMG TAKEN",  "▼",  col2X, cardY-cardStep*2, COLOR.danger,  vStat("damageTaken"))
    statCards["card-metal-lost"]       = StatCard.new("card-metal-lost",       "METAL LOST", "◆",  col1X, cardY-cardStep*3, COLOR.gold,    vStat("metalLost"))
    statCards["card-build-efficiency"] = StatCard.new("card-build-efficiency", "BUILD EFF",  "🔧", col2X, cardY-cardStep*3, COLOR.gold,    vStat("buildEfficiency"))
end

-------------------------------------------------------------------------------
-- CONFIG SAVE / LOAD
-------------------------------------------------------------------------------

local function saveConfig()
    local config = {
        version           = "3.1",
        enabled           = chartsEnabled,
        chartsInteractive = chartsInteractive,
        maxChartFps       = MAX_CHART_FPS,
        charts            = {},
        cards             = {},
    }
    for _, chart in pairs(charts) do
        config.charts[chart.id] = {
            x=chart.x, y=chart.y, scale=chart.scale,
            visible=chart.visible, enabled=chart.enabled,
        }
    end
    for id, card in pairs(statCards) do
        config.cards[id] = {
            x=card.x, y=card.y, scale=card.scale,
            visible=card.visible, enabled=card.enabled,
        }
    end
    local f = io.open(CONFIG_FILE, "w")
    if f then
        f:write("return "..serializeTable(config, 0))
        f:close()
        Spring.Echo("BAR Charts: Config saved.")
    else
        Spring.Echo("BAR Charts: Config save failed.")
    end
end

local function loadConfig()
    if not VFS.FileExists(CONFIG_FILE) then return {}, {} end
    local fc = VFS.LoadFile(CONFIG_FILE)
    if not fc then return {}, {} end
    local chunk, err = loadstring(fc)
    if not chunk then
        Spring.Echo("BAR Charts: Config parse error: "..tostring(err))
        return {}, {}
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
        Spring.Echo("BAR Charts: Invalid config")
        return {}, {}
    end
    if result.enabled           ~= nil then chartsEnabled     = result.enabled           end
    if result.chartsInteractive ~= nil then chartsInteractive = result.chartsInteractive end
    return result.charts or {}, result.cards or {}
end

local function applyConfig(chartCfg, cardCfg)
    local byId = {}
    for _, c in pairs(charts) do byId[c.id] = c end
    for id, cfg in pairs(chartCfg) do
        local c = byId[id]
        if c and type(cfg) == "table" then
            c.x = cfg.x or c.x; c.y = cfg.y or c.y; c.scale = cfg.scale or c.scale
            if cfg.visible ~= nil then c.visible = cfg.visible end
            if cfg.enabled ~= nil then c.enabled = cfg.enabled end
        end
    end
    for id, cfg in pairs(cardCfg) do
        local c = statCards[id]
        if c and type(cfg) == "table" then
            c.x = cfg.x or c.x; c.y = cfg.y or c.y; c.scale = cfg.scale or c.scale
            if cfg.visible ~= nil then c.visible = cfg.visible end
            if cfg.enabled ~= nil then c.enabled = cfg.enabled end
        end
    end
end

-------------------------------------------------------------------------------
-- VIEW SWITCHING
-------------------------------------------------------------------------------

local function switchView(targetTeamID)
    if not allyTeams[targetTeamID] then
        Spring.Echo("BAR Charts: switchView FAILED — teamID "..tostring(targetTeamID).." not tracked")
        return
    end
    viewedTeamID = targetTeamID
    if charts.allyArmy       then charts.allyArmy:rebuildMultiTeamSeries()       end
    if charts.allyBuildPower then charts.allyBuildPower:rebuildMultiTeamSeries() end
    chromeDirty  = true
    linesDirty   = true
    overlayDirty = true
    Spring.Echo(string.format("BAR Charts: now viewing team %d ('%s')",
        viewedTeamID, allyTeams[viewedTeamID].playerName))
end

local function findTeamByName(nameQuery)
    local q = string.lower(nameQuery)
    for tid, stats in pairs(allyTeams) do
        if string.lower(stats.playerName):find(q, 1, true) then return tid end
    end
    return nil
end

-------------------------------------------------------------------------------
-- DIAGNOSTIC
-------------------------------------------------------------------------------

local function debugInitState()
    Spring.Echo("=== BAR Charts Init Diagnostic ===")
    local spec, fullSpec = Spring.GetSpectatingState()
    local myTID  = Spring.GetMyTeamID()
    local myATID = Spring.GetMyAllyTeamID()
    Spring.Echo(string.format("  spec=%s fullSpec=%s myTeamID=%s myAllyTeamID=%s",
        tostring(spec), tostring(fullSpec), tostring(myTID), tostring(myATID)))
    local tlistAll  = Spring.GetTeamList()
    local tlistAlly = myATID and Spring.GetTeamList(myATID) or {}
    Spring.Echo(string.format("  GetTeamList() all=%d  ally=%d",
        tlistAll and #tlistAll or 0, tlistAlly and #tlistAlly or 0))
    for _, tid in ipairs(tlistAll or {}) do
        local _, leaderID, isDead, isAI = Spring.GetTeamInfo(tid)
        local units = Spring.GetTeamUnits(tid) or {}
        local pName, pSpec = "n/a", "n/a"
        if leaderID and leaderID >= 0 then
            local a, _, c = Spring.GetPlayerInfo(leaderID)
            pName = tostring(a); pSpec = tostring(c)
        end
        Spring.Echo(string.format(
            "  tid=%-3d  dead=%-5s  ai=%-5s  units=%-4d  pName=%-16s  pSpec=%s  admit=%s",
            tid, tostring(isDead), tostring(isAI), #units, pName, pSpec,
            tostring(isActiveParticipant(tid))))
    end
    Spring.Echo("=== end diagnostic ===")
end

-------------------------------------------------------------------------------
-- INITIALIZE
-------------------------------------------------------------------------------

function widget:Initialize()
    Spring.Echo("BAR Charts v3.1 (Interpolated Sampling): Initialize")
    vsx, vsy = Spring.GetViewGeometry()

    local spec = Spring.GetSpectatingState()
    isSpectator  = spec or false
    myTeamID     = isSpectator and nil or Spring.GetMyTeamID()
    viewedTeamID = myTeamID

    chartsReady           = false
    frameCounter          = 0
    chartsReadyWaitFrames = 0
    allyTeams             = {}
    history               = {}
    histHead              = {}
    histFull              = {}
    builderUnits          = {}
    buildEffState         = {}
    maxMetalUseCache      = {}
    prevStallState        = {}
    linesLastRebuildTime  = nil
    widgetStartTimer      = Spring.GetTimer()

    resetBuildEffForTeam(nil)
    initShaders()
    buildChartsAndCards()
    local chartCfg, cardCfg = loadConfig()
    applyConfig(chartCfg, cardCfg)
    initRmlToggle()

    chromeDirty  = true
    linesDirty   = true
    overlayDirty = true

    -- Public API (backwards-compatible with v2.6 / v3.0)
    WG.BarCharts = {
        version            = "3.1",
        getTrackedTeams    = function()
            local out = {}
            for tid in pairs(allyTeams) do out[#out+1] = tid end
            table.sort(out)
            return out
        end,
        getViewedTeamID    = function() return viewedTeamID end,
        isSpectator        = function() return isSpectator end,
        getTeamStats       = function(teamID) return allyTeams[teamID] end,
        getViewedTeamStats = function() return allyTeams[viewedTeamID] end,
        seriesKeys         = SERIES_KEYS,
        getSamples         = function(teamID, seriesKey, numPoints)
            numPoints = numPoints or RENDER_POINTS
            if not history[teamID] or not history[teamID][seriesKey] then return nil end
            return ringSample(teamID, seriesKey, numPoints)
        end,
        getBufferInfo      = function(teamID, seriesKey)
            if not history[teamID] or not history[teamID][seriesKey] then return 0, 0 end
            return ringRange(teamID, seriesKey)
        end,
        getRawBuffer       = function(teamID, seriesKey)
            if not history[teamID] then return nil end
            return history[teamID][seriesKey]
        end,
        getBufferConstants = function() return HISTORY_SIZE, GAME_FPS end,
        getTimeWindow      = function(teamID, seriesKey)
            if not history[teamID] or not history[teamID][seriesKey] then return 0, 0 end
            local _, count = ringRange(teamID, seriesKey)
            return count / GAME_FPS, Spring.GetGameFrame() / GAME_FPS
        end,
        isReady            = function() return chartsReady end,
        isEnabled          = function() return chartsEnabled end,
        getMaxChartFps     = function() return MAX_CHART_FPS end,
    }

    Spring.Echo(string.format(
        "BAR Charts v3.1: Initialized%s, MAX_CHART_FPS=%d, RENDER_POINTS=%d, waiting…",
        isSpectator and " (SPECTATOR)" or "", MAX_CHART_FPS, RENDER_POINTS))
end

-------------------------------------------------------------------------------
-- UPDATE & GAME FRAME
-------------------------------------------------------------------------------

local function pollLocalTeam()
    if not chartsReady then return end
    local teamID = Spring.GetLocalTeamID()
    if teamID == nil or teamID == viewedTeamID then return end
    if not allyTeams[teamID] then return end
    viewedTeamID = teamID
    chromeDirty  = true
    linesDirty   = true
    overlayDirty = true
end

function widget:Update(_dt)
    pollLocalTeam()
end

function widget:GameFrame(n)
    if not chartsReady then
        chartsReadyWaitFrames = chartsReadyWaitFrames + 1
        if chartsReadyWaitFrames >= READY_WAIT_FRAMES then
            chartsReadyWaitFrames = 0
            debugInitState()
            if initAllyTeams() then
                charts.allyArmy:rebuildMultiTeamSeries()
                charts.allyBuildPower:rebuildMultiTeamSeries()
                seedArmyValues()
                seedBuildPower()
                seedUnitCount()
                chartsReady  = true
                frameCounter = 0
                chromeDirty  = true
                linesDirty   = true
                overlayDirty = true
                local teamCount = 0
                for _ in pairs(allyTeams) do teamCount = teamCount + 1 end
                Spring.Echo(string.format(
                    "BAR Charts v3.1: Ready — %s, buffering %d active team(s)",
                    isSpectator and "SPECTATOR" or "player", teamCount))
            end
        end
        return
    end

    for tid in pairs(allyTeams) do
        ensureBuildEffState(tid)
        local s = buildEffState[tid]
        s.tickCounter = s.tickCounter + 1
        if s.tickCounter >= BUILD_EFF_TICKS_PER_SAMPLE then
            s.tickCounter = 0
            pushBuildEffSampleForTeam(tid, sampleBuildEfficiencyForTeam(tid))
        end
    end

    collectStats(n)
end

function widget:GameStart()
    chartsReady           = false
    chartsReadyWaitFrames = 0
    frameCounter          = 0
    builderUnits          = {}
    buildEffState         = {}
    maxMetalUseCache      = {}
    history               = {}
    histHead              = {}
    histFull              = {}
    prevStallState        = {}
    linesLastRebuildTime  = nil
    widgetStartTimer      = Spring.GetTimer()
    for _, stats in pairs(allyTeams) do
        stats.armyValue=0; stats.unitCount=0; stats.kills=0; stats.losses=0
        stats.metalLost=0; stats.damageDealt=0; stats.damageTaken=0
        stats.buildEfficiency=0; stats.metalStall=0; stats.totalBP=0; stats.buildPower=0
    end
    chromeDirty  = true
    linesDirty   = true
    overlayDirty = true
    Spring.Echo("BAR Charts v3.1: Game started")
end

-------------------------------------------------------------------------------
-- RENDERING
-------------------------------------------------------------------------------

function widget:DrawScreen()
    if not chartsEnabled then return end

    -- Chrome (static layout)
    if chromeDirty then rebuildChromeList() end

    -- Lines (rate-limited by MAX_CHART_FPS)
    do
        local minInterval = 1.0 / math.max(1, math.min(60, MAX_CHART_FPS))
        local timeReady   = (linesLastRebuildTime == nil)
                         or (Spring.DiffTimers(Spring.GetTimer(), linesLastRebuildTime) >= minInterval)
        if timeReady and linesDirty then
            rebuildLinesList()
            overlayDirty = true
        end
    end

    -- Overlay (card values, stall, hover)
    if overlayDirty then rebuildOverlayList() end

    -- Call cached display lists
    if chromeDisplayList  then gl.CallList(chromeDisplayList)  end

    -- Draw animated grid lines LIVE (outside display list) so the scan-pulse
    -- animation runs at full monitor refresh rate.
    drawLiveGridLines()

    if linesDisplayList   then gl.CallList(linesDisplayList)   end
    if overlayDisplayList then gl.CallList(overlayDisplayList) end
end

-------------------------------------------------------------------------------
-- INPUT
-------------------------------------------------------------------------------

function widget:KeyPress(key, _mods, _isRepeat)
    if key == Spring.GetKeyCode("f9") then
        chartsEnabled = not chartsEnabled
        chromeDirty   = true
        if not chartsEnabled then clearAllHoverStates() end
        Spring.Echo("BAR Charts: "..(chartsEnabled and "Enabled" or "Disabled"))
        return true
    end
    return false
end

local function findHit(mx, my)
    for _, card in pairs(statCards) do
        if (card.enabled or chartsInteractive) and card:isMouseOver(mx, my) then
            return card, "card"
        end
    end
    for _, chart in pairs(charts) do
        if (chart.enabled or chartsInteractive) and chart:isMouseOver(mx, my) then
            return chart, "chart"
        end
    end
    return nil, nil
end

function widget:MousePress(mx, my, button)
    if not chartsEnabled or not chartsInteractive then return false end
    local elem = findHit(mx, my)
    if not elem then return false end
    if button == 1 then
        elem.isDragging = true
        elem.dragStartX = mx - elem.x
        elem.dragStartY = my - elem.y
        overlayDirty = true
        return true
    elseif button == 3 then
        elem.enabled = not elem.enabled
        chromeDirty  = true
        linesDirty   = true
        overlayDirty = true
        return true
    end
    return false
end

function widget:MouseRelease(_mx, _my, button)
    if not chartsEnabled or not chartsInteractive then return false end
    if button == 1 then
        for _, card in pairs(statCards) do
            if card.isDragging then card.isDragging = false; overlayDirty = true; return true end
        end
        for _, chart in pairs(charts) do
            if chart.isDragging then chart.isDragging = false; overlayDirty = true; return true end
        end
    end
    return false
end

function widget:MouseMove(mx, my, _dx, _dy)
    if not chartsEnabled then return false end
    if chartsInteractive then
        for _, card in pairs(statCards) do
            if card.isDragging then
                card.x = snapTo(mx - card.dragStartX)
                card.y = snapTo(my - card.dragStartY)
                chromeDirty  = true; linesDirty = true; overlayDirty = true
                return true
            end
        end
        for _, chart in pairs(charts) do
            if chart.isDragging then
                chart.x = snapTo(mx - chart.dragStartX)
                chart.y = snapTo(my - chart.dragStartY)
                chromeDirty  = true; linesDirty = true; overlayDirty = true
                return true
            end
        end
    end

    local changed = false
    for _, card in pairs(statCards) do
        local h = chartsInteractive and card:isMouseOver(mx, my) or false
        if h ~= card.isHovered then changed = true end
        card.isHovered = h
    end
    for _, chart in pairs(charts) do
        local h = chartsInteractive and chart:isMouseOver(mx, my) or false
        if h ~= chart.isHovered then changed = true end
        chart.isHovered = h
    end
    if changed then overlayDirty = true end

    if not chartsInteractive then return false end
    for _, c in pairs(statCards) do if c.isHovered then return true end end
    for _, c in pairs(charts)    do if c.isHovered then return true end end
    return false
end

function widget:MouseWheel(up, _value)
    if not chartsEnabled or not chartsInteractive then return false end
    local mx, my = Spring.GetMouseState()
    for _, card in pairs(statCards) do
        if card:isMouseOver(mx, my) then
            card.scale   = up and math.min(2.0, card.scale+0.1) or math.max(0.5, card.scale-0.1)
            chromeDirty  = true; linesDirty = true; overlayDirty = true
            return true
        end
    end
    for _, chart in pairs(charts) do
        if chart:isMouseOver(mx, my) then
            chart.scale  = up and math.min(2.0, chart.scale+0.1) or math.max(0.5, chart.scale-0.1)
            chromeDirty  = true; linesDirty = true; overlayDirty = true
            return true
        end
    end
    return false
end

function widget:ViewResize()
    local ox, oy = vsx, vsy
    vsx, vsy     = Spring.GetViewGeometry()
    local rx, ry = vsx/ox, vsy/oy
    for _, c in pairs(charts)    do c.x = c.x*rx; c.y = c.y*ry end
    for _, c in pairs(statCards) do c.x = c.x*rx; c.y = c.y*ry end
    chromeDirty  = true; linesDirty = true; overlayDirty = true
end

-------------------------------------------------------------------------------
-- TEXT COMMANDS
-------------------------------------------------------------------------------

function widget:TextCommand(command)
    if command:sub(1, 14) == "barcharts view" then
        local arg = command:sub(16)
        if arg and #arg > 0 then
            local tid = tonumber(arg)
            if tid then switchView(tid)
            else
                local found = findTeamByName(arg)
                if found then switchView(found)
                else Spring.Echo("BAR Charts: No active team matching '"..arg.."'") end
            end
        else
            Spring.Echo("BAR Charts: Active teams" .. (isSpectator and " (spectator)" or " (allies)") .. ":")
            for tid, stats in pairs(allyTeams) do
                local marker = (tid == viewedTeamID) and " <- viewing" or ""
                local mine   = (myTeamID and tid == myTeamID) and " (you)" or ""
                Spring.Echo(string.format("  %d  %s%s%s", tid, stats.playerName, mine, marker))
            end
        end
        return true
    end

    if command:sub(1, 12) == "barcharts fps" then
        local n = tonumber(command:sub(14))
        if n then
            MAX_CHART_FPS = math.max(1, math.min(30, math.floor(n)))
            Spring.Echo(string.format("BAR Charts: MAX_CHART_FPS set to %d", MAX_CHART_FPS))
        else
            Spring.Echo(string.format("BAR Charts: MAX_CHART_FPS = %d", MAX_CHART_FPS))
        end
        return true
    end

    if command == "barcharts save" then
        saveConfig(); return true
    elseif command == "barcharts reset" then
        os.remove(CONFIG_FILE)
        Spring.Echo("BAR Charts: Config reset — restart widget to apply")
        return true
    elseif command == "barcharts edit" then
        chartsInteractive = not chartsInteractive
        syncPillState()
        chromeDirty  = true
        overlayDirty = true
        Spring.Echo("BAR Charts: " .. (chartsInteractive and "EDIT mode ON" or "LOCKED"))
        return true
    elseif command == "barcharts hidepill" then
        setPillVisible(false); return true
    elseif command == "barcharts showpill" then
        setPillVisible(true);  return true
    elseif command == "barcharts debug" then
        Spring.Echo("=== BAR Charts v3.1 Debug ===")
        Spring.Echo(string.format("vsx=%d vsy=%d  enabled=%s ready=%s interactive=%s",
            vsx, vsy, tostring(chartsEnabled), tostring(chartsReady), tostring(chartsInteractive)))
        Spring.Echo(string.format("HISTORY_SIZE=%d (%.0fs @ %dfps)  RENDER_POINTS=%d",
            HISTORY_SIZE, HISTORY_SECONDS, GAME_FPS, RENDER_POINTS))
        Spring.Echo(string.format("MAX_CHART_FPS=%d", MAX_CHART_FPS))
        Spring.Echo(string.format("dirty flags: chrome=%s  lines=%s  overlay=%s",
            tostring(chromeDirty), tostring(linesDirty), tostring(overlayDirty)))
        Spring.Echo(string.format("shaderLine=%s  shaderFill=%s  shaderGrid=%s",
            tostring(shaderLine ~= nil), tostring(shaderFill ~= nil), tostring(shaderGrid ~= nil)))
        Spring.Echo(string.format("isSpectator=%s  myTeamID=%s  viewedTeamID=%s",
            tostring(isSpectator), tostring(myTeamID), tostring(viewedTeamID)))
        for tid, stats in pairs(allyTeams) do
            Spring.Echo(string.format("  [%d] %s  metal=%.0f/%.0f  army=%.0f%s",
                tid, stats.playerName, stats.metalIncome, stats.metalUsage, stats.armyValue,
                (tid == viewedTeamID) and " <-" or ""))
        end
        return true
    elseif command == "barcharts diag" then
        debugInitState(); return true
    elseif command == "barcharts bp" then
        local tid    = viewedTeamID
        local stats  = allyTeams[tid]
        local tB     = builderUnits[tid] or {}
        Spring.Echo(string.format("=== Builder Efficiency: team %s ('%s') ===",
            tostring(tid), stats and stats.playerName or "?"))
        local s = buildEffState[tid]
        Spring.Echo(string.format("  Rolling avg: %.1f%%  (%d/%d samples)",
            stats and stats.buildEfficiency or 0, s and s.count or 0, BUILD_EFF_WINDOW_SIZE))
        for uid, bd in pairs(tB) do
            local tuid = Spring.GetUnitIsBuilding(uid)
            local bud  = bd.defID and UnitDefs[bd.defID]
            Spring.Echo(string.format("    uid=%d  %s  bp=%.0f  building=%s",
                uid, bud and bud.name or "?", bd.bp, tostring(tuid ~= nil)))
        end
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- SHUTDOWN
-------------------------------------------------------------------------------

function widget:Shutdown()
    WG.BarCharts = nil
    saveConfig()
    shutdownRmlToggle()
    freeLists()
    deleteShaders()
    Spring.Echo("BAR Charts v3.1: Shutdown")
end
