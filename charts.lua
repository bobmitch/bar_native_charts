--[[
═══════════════════════════════════════════════════════════════════════════
    BAR CHARTS WIDGET — 1-MINUTE RING BUFFER, MULTI-TEAM VIEW SWITCHING
    v2.3 by FilthyMitch

    History window : exactly 60 in-game seconds = 1 800 game frames at 30 fps
    Sampling       : one data point pushed every game frame (30/s)
    Rendering      : chrome (bg/grid/labels) in a display list, rebuilt only
                     on structural changes; line geometry drawn raw every
                     DrawScreen call — always current regardless of GPU fps
    Player switch  : ALL teams buffered simultaneously (player and spectator);
                     switching view is an O(1) pointer swap (no copy, no gap)

    Spectator mode :
      Detected via Spring.GetSpectatingState() at init and re-checked each
      ready-wait cycle.  In spectator mode Spring.GetTeamList() is called with
      no argument to enumerate ALL active game teams (not just one ally group).
      myTeamID is set to nil for spectators — build-efficiency sampling and
      unit-event army-tracking are bypassed (no "my" units exist).
      Default viewed team is the first non-Gaia team found.

    Active-team filtering (v2.3):
      isActiveParticipant(tid) admits a team if:
        (a) it is an AI team, OR
        (b) it has a human leader who is NOT spectating, OR
        (c) it has no valid leader (Gaia-like) but already has live units.
      Dead/resigned teams are always excluded.
      The `active` flag from GetPlayerInfo is intentionally NOT used as a gate
      because in single-player and early-join scenarios the local player can
      appear active=false even though they are a legitimate participant.

    Line-chart rendering (v2.3 fix):
      drawChartLines() no longer depends on chart._range being pre-populated
      by rebuildChromeList().  It computes layout from PADDING constants
      directly and sets chromeDirty=true the first time data arrives so the
      grid/labels get a fresh rebuild.  This fixes the "awaiting data" stuck
      state when the widget is loaded mid-game.

═══════════════════════════════════════════════════════════════════════════
]]

function widget:GetInfo()
    return {
        name      = "BAR Stats Charts",
        desc      = "Real-time resource and combat statistics overlay charts and cards",
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
local HISTORY_SIZE    = GAME_FPS * HISTORY_SECONDS  -- 1800 frames
local RENDER_POINTS   = 300

local BUILD_EFF_TICKS_PER_SAMPLE = 15
local BUILD_EFF_WINDOW_SIZE      = 8

local CHART_WIDTH  = 300
local CHART_HEIGHT = 180
local PADDING      = {left = 40, right = 15, top = 15, bottom = 25}
local CARD_WIDTH   = 140
local CARD_HEIGHT  = 70

local COLOR = {
    bg        = {0.031, 0.047, 0.078, 0.72},
    border    = {0.353, 0.706, 1.000, 0.18},
    borderHot = {0.353, 0.706, 1.000, 0.55},
    grid      = {0.353, 0.706, 1.000, 0.08},
    gridBase  = {0.353, 0.706, 1.000, 0.22},
    muted     = {0.627, 0.745, 0.863, 0.55},
    accent    = {0.290, 0.706, 1.000, 1.00},
    accent2   = {1.000, 0.420, 0.208, 1.00},
    danger    = {1.000, 0.231, 0.361, 1.00},
    success   = {0.188, 0.941, 0.627, 1.00},
    gold      = {0.941, 0.753, 0.251, 1.00},
}

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
    if full then
        return h, HISTORY_SIZE
    else
        return 1, h - 1
    end
end

local function ringSample(tid, key, numPts)
    local startIdx, count = ringRange(tid, key)
    if count <= 0 then return {} end
    local buf = history[tid][key]
    local n   = math.min(numPts, count)
    if n <= 0 then return {} end
    local pts = {}
    for i = 1, n do
        local fi  = math.floor((i - 1) / math.max(n - 1, 1) * (count - 1) + 0.5)
        local idx = ((startIdx - 1 + fi) % HISTORY_SIZE) + 1
        pts[i] = buf[idx]
    end
    return pts
end

local builderUnits    = {}
local maxMetalUseCache = {}
local buildEffState   = {}

local charts    = {}
local statCards = {}

local chromeDisplayList = nil
local chromeDirty       = true
local hoverDisplayList  = nil

local frameCounter       = 0
local FULL_SCAN_INTERVAL = GAME_FPS

local chartsReadyWaitFrames = 0
local READY_WAIT_FRAMES     = GAME_FPS * 3

-------------------------------------------------------------------------------
-- RMLUI TOGGLE
-------------------------------------------------------------------------------

local rmlContext  = nil
local rmlDocument = nil
local pillVisible = true   -- tracks whether the pill UI is shown

-- Update pill label/classes to match current chartsInteractive state.
-- Safe to call whether or not the document exists.
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

-- Show or hide the pill document without affecting chartsInteractive.
local function setPillVisible(visible)
    pillVisible = visible
    if not rmlDocument then return end
    if visible then
        syncPillState()
        rmlDocument:Show()
    else
        rmlDocument:Hide()
    end
end

-- Called when the pill is clicked in-game.
local function onToggleClick(event)
    chartsInteractive = not chartsInteractive
    syncPillState()
    chromeDirty = true
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
    if pillVisible then
        rmlDocument:Show()
    end
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
                gl.Vertex(x+r, y+r)
                gl.Vertex(x+r-r*math.cos(a1), y+r-r*math.sin(a1))
                gl.Vertex(x+r-r*math.cos(a2), y+r-r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+w-r, y+r)
                gl.Vertex(x+w-r+r*math.sin(a1), y+r-r*math.cos(a1))
                gl.Vertex(x+w-r+r*math.sin(a2), y+r-r*math.cos(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+w-r, y+h-r)
                gl.Vertex(x+w-r+r*math.cos(a1), y+h-r+r*math.sin(a1))
                gl.Vertex(x+w-r+r*math.cos(a2), y+h-r+r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x+r, y+h-r)
                gl.Vertex(x+r-r*math.sin(a1), y+h-r+r*math.cos(a1))
                gl.Vertex(x+r-r*math.sin(a2), y+h-r+r*math.cos(a2))
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
-- BUILD EFFICIENCY (per-team)
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
        -- keeping old logic just in case below - we counted no workers as 100% efficient
        -- local stats = allyTeams[tid]
        -- return (stats and (stats.buildPower or 0) > 0) and 100 or 0
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
        for t, stats in pairs(allyTeams) do stats.buildEfficiency = 0 end
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
    self._cX   = nil; self._cY  = nil; self._cW   = nil; self._cH = nil
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

-- ── StatCard ──────────────────────────────────────────────────────────────────

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
    if chromeDisplayList then gl.DeleteList(chromeDisplayList); chromeDisplayList = nil end
    if hoverDisplayList  then gl.DeleteList(hoverDisplayList);  hoverDisplayList  = nil end
end

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

        -- ── Charts ────────────────────────────────────────────────────────
        for _, chart in pairs(charts) do
            local show = (chart.enabled and chart.visible) or (not chart.enabled and chartsInteractive)
            if show then
                local w    = chart.width
                local h    = chart.height
                local pad  = PADDING
                local cX   = pad.left
                local cY   = pad.bottom
                local cW   = w - pad.left - pad.right
                local cH   = h - pad.top  - pad.bottom
                local am   = (not chart.enabled and chartsInteractive) and 0.35 or 1.0

                gl.PushMatrix()
                gl.Translate(chart.x, chart.y, 0)
                gl.Scale(chart.scale, chart.scale, 1)

                gl.Color(COLOR.bg[1],     COLOR.bg[2],     COLOR.bg[3],     COLOR.bg[4]*am)
                drawRoundedRect(0, 0, w, h, 4, true)
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
                    local allV = {}
                    for i = 1, #chart.series do
                        local pts = chart:getSamples(i)
                        for _, v in ipairs(pts) do
                            if v and not (v ~= v) then allV[#allV+1] = v end
                        end
                    end
                    local minV, maxV
                    if #allV > 0 then
                        minV = allV[1]; maxV = allV[1]
                        for j = 2, #allV do
                            local v = allV[j]
                            if v < minV then minV = v end
                            if v > maxV then maxV = v end
                        end
                    else
                        minV, maxV = 0, 100
                    end

                    -- Y-axis range clamping
                    if chart.chartType == "percent" then
                        minV = 0; maxV = 100
                    elseif chart.chartType == "storage" then
                        local ab = math.max(math.abs(minV), math.abs(maxV), 100)
                        local p  = ab * 0.12
                        minV = -(ab+p); maxV = (ab+p)
                    elseif chart.chartType == "demand" then
                        local ab = math.max(math.abs(minV), math.abs(maxV), 100)
                        local p  = ab * 0.15
                        minV = -(ab+p); maxV = (ab+p)
                    else
                        -- single / dual / multi / ratio: always anchor to 0
                        minV = 0
                        local p = maxV > 0 and maxV*0.12 or 100
                        maxV = maxV + p
                    end
                    local range = maxV - minV
                    if range == 0 then range = 1 end

                    chart._minV = minV; chart._maxV = maxV; chart._range = range
                    chart._cX   = cX;  chart._cY   = cY
                    chart._cW   = cW;  chart._cH   = cH

                    -- Grid lines + Y labels
                    for i = 0, 4 do
                        local v    = minV + (range * i / 4)
                        local yPos = cY   + (cH   * i / 4)
                        local gc   = (i == 0) and COLOR.gridBase or COLOR.grid
                        gl.Color(gc[1], gc[2], gc[3], gc[4]*am)
                        gl.BeginEnd(GL.LINES, function()
                            gl.Vertex(cX, yPos); gl.Vertex(cX+cW, yPos)
                        end)
                        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4]*am)
                        gl.Text(formatYAxis(v, chart.chartType), cX-5, yPos-4, 9, "ro")
                    end

                    -- Zero line for demand/storage
                    if chart.chartType == "demand" or chart.chartType == "storage" then
                        local zeroY = cY + ((0 - minV) / range) * cH
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

        -- Edit-mode hint
        if chartsInteractive then
            gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 0.55)
            gl.Text("✏ EDIT MODE", vsx-150, 45, 11, "o")
        end
        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.4)
        gl.Text("F9: Toggle  |  /barcharts view <name>", vsx-240, 30, 11, "o")
    end)
    chromeDirty = false
end

-------------------------------------------------------------------------------
-- DRAW CHART LINES (raw every frame)
-- v2.3: no longer depends on chrome having been built first.
-- Layout is computed directly from PADDING constants so lines render
-- as soon as hasData() is true, even on mid-game widget restart.
-------------------------------------------------------------------------------

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
        -- single / dual / multi / ratio: always anchor to 0
        mn = 0
        local p = mx > 0 and mx*0.12 or 100
        mx = mx + p
    end
    local r = mx - mn
    if r == 0 then r = 1 end
    chart._minV = mn; chart._maxV = mx; chart._range = r
    return mn, mx, r
end

local function drawChartLines(chart)
    local show = (chart.enabled and chart.visible) or (not chart.enabled and chartsInteractive)
    if not show or not chart.enabled then return end
    if not chart:hasData() then return end

    local mn, mx, r = computeRange(chart)
    if not mn then return end

    -- Compute layout from constants directly — never rely on chrome having
    -- been built first.  This is the v2.3 fix for mid-game widget restart.
    local cX = PADDING.left
    local cY = PADDING.bottom
    local cW = chart.width  - PADDING.left - PADDING.right
    local cH = chart.height - PADDING.top  - PADDING.bottom

    -- Keep cached values in sync so chrome rebuilds use correct coords.
    chart._cX = cX; chart._cY = cY
    chart._cW = cW; chart._cH = cH

    -- If chrome hasn't rendered with data yet, force a rebuild so the
    -- grid lines and Y-axis labels appear at the correct scale.
    if chromeDirty == false and chart._range ~= nil then
        -- already in sync, nothing to do
    else
        chromeDirty = true
    end

    local am = 1.0
    local function toY(v) return cY + ((v - mn) / r) * cH end

    gl.PushMatrix()
    gl.Translate(chart.x, chart.y, 0)
    gl.Scale(chart.scale, chart.scale, 1)

    for si, s in ipairs(chart.series) do
        local pts  = chart:getSamples(si)
        local nPts = #pts
        if nPts >= 2 then
            local clr = s.color
            local fillBase = (chart.chartType == "demand" or chart.chartType == "storage")
                             and toY(0) or cY

            if chart.chartType ~= "multi" then
                gl.Color(clr[1], clr[2], clr[3], 0.15*am)
                gl.BeginEnd(GL.TRIANGLE_STRIP, function()
                    for i, v in ipairs(pts) do
                        if v and not (v ~= v) then
                            local x = cX + ((i-1)/(nPts-1)) * cW
                            gl.Vertex(x, fillBase); gl.Vertex(x, toY(v))
                        end
                    end
                end)
            end

            -- soft halo pass — wide, semi-transparent
            gl.Color(clr[1], clr[2], clr[3], 0.25*am)
            gl.LineWidth(3.5)
            gl.BeginEnd(GL.LINE_STRIP, function()
                for i, v in ipairs(pts) do
                    if v and not (v ~= v) then
                        local x = cX + ((i-1)/(nPts-1)) * cW
                        gl.Vertex(x, toY(v))
                    end
                end
            end)
            -- crisp core pass — thin, fully opaque
            gl.Color(clr[1], clr[2], clr[3], 1.0*am)
            gl.LineWidth(1.0)
            gl.BeginEnd(GL.LINE_STRIP, function()
                for i, v in ipairs(pts) do
                    if v and not (v ~= v) then
                        local x = cX + ((i-1)/(nPts-1)) * cW
                        gl.Vertex(x, toY(v))
                    end
                end
            end)

            local last = pts[nPts]
            if last and not (last ~= last) then
                gl.Color(clr[1], clr[2], clr[3], 0.8*am)
                gl.PointSize(6)
                gl.BeginEnd(GL.POINTS, function() gl.Vertex(cX+cW, toY(last)) end)
            end
        end
    end

    gl.PopMatrix()

    -- ── Per-view overlays drawn raw (viewedTeamID must be live) ──────────
    local pad    = PADDING
    local w      = chart.width
    local h      = chart.height
    local vStats = allyTeams[viewedTeamID]

    gl.PushMatrix()
    gl.Translate(chart.x, chart.y, 0)
    gl.Scale(chart.scale, chart.scale, 1)

    if chart.id == "chart-build-efficiency" then
        local stall = vStats and vStats.metalStall or 0
        if stall == 2 then
            gl.Color(COLOR.danger[1], COLOR.danger[2], COLOR.danger[3], 1.0)
            gl.Text("⚠ STALL", w-pad.right-2, h-pad.top-10, 10, "ro")
        elseif stall == 1 then
            gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 1.0)
            gl.Text("⚠ STALL", w-pad.right-2, h-pad.top-10, 10, "ro")
        end
    end

    -- Removed: "▶ playerName" overlay — names are not shown on charts

    gl.PopMatrix()
end

local function drawCardValues()
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
                    gl.Text("⚠ STALL", CARD_WIDTH-6, CARD_HEIGHT-18, 9, "ro")
                elseif stall == 1 then
                    gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 1.0)
                    gl.Text("⚠ STALL", CARD_WIDTH-6, CARD_HEIGHT-18, 9, "ro")
                end
            end

            gl.PopMatrix()
        end
    end
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

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
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

-- v2.3: isActiveParticipant — simplified and robust.
-- Admits a team if it is alive and either:
--   (a) an AI team,
--   (b) led by a non-spectating human player, or
--   (c) has live units (fallback for edge cases / mid-game restart).
-- The `active` flag is intentionally NOT used — it can be false for the
-- local player in single-player or early LAN joins.
local function isActiveParticipant(tid)
    local _, leaderID, isDead, isAI = Spring.GetTeamInfo(tid)

    -- Exclude dead/resigned teams.
    if isDead then return false end

    -- AI teams are always legitimate participants.
    if isAI then return true end

    -- Always admit our own team unconditionally.
    if myTeamID ~= nil and tid == myTeamID then return true end

    -- Exclude Gaia and leaderless slots unless they have units.
    if not leaderID or leaderID < 0 then
        local units = Spring.GetTeamUnits(tid)
        return units and #units > 0
    end

    -- Human-led: exclude only if the leader is a spectator.
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
    -- Re-resolve spectator status and myTeamID on every attempt.
    local spec = Spring.GetSpectatingState()
    isSpectator = spec or false
    myTeamID    = isSpectator and nil or Spring.GetMyTeamID()

    local tlist
    if isSpectator then
        -- GetTeamList() with no argument can miss teams in other ally groups
        -- depending on engine version. Enumerate every ally group explicitly.
        local allyTeamList = Spring.GetAllyTeamList()
        local seen = {}
        tlist = {}
        if allyTeamList then
            for _, atid in ipairs(allyTeamList) do
                local teams = Spring.GetTeamList(atid) or {}
                for _, tid in ipairs(teams) do
                    if not seen[tid] then
                        seen[tid] = true
                        tlist[#tlist + 1] = tid
                    end
                end
            end
        end
        -- Fallback: also sweep GetTeamList() bare in case engine behaviour differs
        local bare = Spring.GetTeamList() or {}
        for _, tid in ipairs(bare) do
            if not seen[tid] then
                seen[tid] = true
                tlist[#tlist + 1] = tid
            end
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
    for _, tid in ipairs(tlist) do
        if isActiveParticipant(tid) then
            local r, g, b = Spring.GetTeamColor(tid)
            newTeams[tid] = {
                teamID          = tid,
                playerName      = resolveTeamName(tid),
                color           = {r or 1, g or 1, b or 1, 1},
                metalIncome     = 0, metalUsage      = 0,
                energyIncome    = 0, energyUsage     = 0,
                damageDealt     = 0, damageTaken     = 0,
                armyValue       = 0, buildPower      = 0,
                kills           = 0, losses          = 0,
                unitCount       = 0, metalLost       = 0,
                buildEfficiency = 0,
                metalStall      = 0, totalBP         = 0,
            }
            initTeamBuffers(tid)
            if not firstTID then firstTID = tid end
        end
    end

    -- Mid-game restart fallback: if isActiveParticipant filtered everything
    -- (engine state may be partially settled), admit any non-dead team with units.
    if not next(newTeams) then
        Spring.Echo("BAR Charts: isActiveParticipant filtered all teams — using unit-presence fallback")
        for _, tid in ipairs(tlist) do
            local _, _, isDead = Spring.GetTeamInfo(tid)
            if not isDead then
                local units = Spring.GetTeamUnits(tid)
                if units and #units > 0 then
                    local r, g, b = Spring.GetTeamColor(tid)
                    newTeams[tid] = {
                        teamID          = tid,
                        playerName      = resolveTeamName(tid),
                        color           = {r or 1, g or 1, b or 1, 1},
                        metalIncome     = 0, metalUsage      = 0,
                        energyIncome    = 0, energyUsage     = 0,
                        damageDealt     = 0, damageTaken     = 0,
                        armyValue       = 0, buildPower      = 0,
                        kills           = 0, losses          = 0,
                        unitCount       = 0, metalLost       = 0,
                        buildEfficiency = 0,
                        metalStall      = 0, totalBP         = 0,
                    }
                    initTeamBuffers(tid)
                    if not firstTID then firstTID = tid end
                end
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
-- STAT COLLECTION (every GameFrame)
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

    for tid, stats in pairs(allyTeams) do
        local ml, ms, mpull, minc, mexp = Spring.GetTeamResources(tid, "metal")
        local el, es, epull, einc, eexp = Spring.GetTeamResources(tid, "energy")

        if minc ~= nil then
            stats.metalIncome  = minc
            stats.metalUsage   = mexp or 0
            stats.energyIncome = einc or 0
            stats.energyUsage  = eexp or 0

            local pull    = mpull or 0
            local expense = mexp  or 0
            if pull > 1 then
                local ratio = expense / pull
                if     ratio < 0.60 then stats.metalStall = 2
                elseif ratio < 0.98 then stats.metalStall = 1
                else                     stats.metalStall = 0 end
            else
                stats.metalStall = 0
            end
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

    -- Trigger a chrome rebuild the first time any chart transitions from
    -- no-data to has-data, so the grid and axis labels appear correctly.
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
            { label="Dealt", color=COLOR.success, seriesKey="damageDealt"  },
            { label="Taken", color=COLOR.danger,  seriesKey="damageTaken"  },
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

    -- K/D chart: override getSamples to compute ratio from kills+losses buffers
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
    end

    -- ── Stat Cards ─────────────────────────────────────────────────────────
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
        version           = "2.3",
        enabled           = chartsEnabled,
        chartsInteractive = chartsInteractive,
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
-- PLAYER VIEW SWITCHING
-------------------------------------------------------------------------------

local function switchView(targetTeamID)
    if not allyTeams[targetTeamID] then
        Spring.Echo("BAR Charts: switchView FAILED — teamID "
            ..tostring(targetTeamID).." not in tracked set")
        Spring.Echo("BAR Charts: Tracked teams are:")
        for tid, stats in pairs(allyTeams) do
            Spring.Echo(string.format("  teamID=%-3d  '%s'", tid, stats.playerName))
        end
        return
    end

    local oldStats = allyTeams[viewedTeamID]
    Spring.Echo(string.format(
        "BAR Charts: switchView  %s (team %d) → %s (team %d)",
        oldStats and oldStats.playerName or tostring(viewedTeamID), viewedTeamID or -1,
        allyTeams[targetTeamID].playerName, targetTeamID))

    viewedTeamID = targetTeamID

    if charts.allyArmy       then charts.allyArmy:rebuildMultiTeamSeries()       end
    if charts.allyBuildPower then charts.allyBuildPower:rebuildMultiTeamSeries() end

    chromeDirty = true

    Spring.Echo(string.format(
        "BAR Charts: viewedTeamID is now %d ('%s')  chromeDirty=true",
        viewedTeamID, allyTeams[viewedTeamID].playerName))
end

local function findTeamByName(nameQuery)
    local q = string.lower(nameQuery)
    for tid, stats in pairs(allyTeams) do
        if string.lower(stats.playerName):find(q, 1, true) then
            return tid
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- DIAGNOSTIC (used during ready-wait to log engine state)
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
        local pName, pActive, pSpec = "n/a", "n/a", "n/a"
        if leaderID and leaderID >= 0 then
            local a, b, c = Spring.GetPlayerInfo(leaderID)
            pName = tostring(a); pActive = tostring(b); pSpec = tostring(c)
        end
        Spring.Echo(string.format(
            "  tid=%-3d  leader=%-3s  dead=%-5s  ai=%-5s  units=%-4d  pName=%-16s  pActive=%-5s  pSpec=%s  admit=%s",
            tid, tostring(leaderID), tostring(isDead), tostring(isAI),
            #units, pName, pActive, pSpec, tostring(isActiveParticipant(tid))))
    end
    Spring.Echo("=== end diagnostic ===")
end

-------------------------------------------------------------------------------
-- INITIALIZE
-------------------------------------------------------------------------------

function widget:Initialize()
    Spring.Echo("BAR Charts v2.3: Initialize")
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
    resetBuildEffForTeam(nil)
    buildChartsAndCards()
    local chartCfg, cardCfg = loadConfig()
    applyConfig(chartCfg, cardCfg)
    initRmlToggle()
    chromeDirty = true
    Spring.Echo("BAR Charts v2.3: Initialized"
        .. (isSpectator and " (SPECTATOR)" or "")
        .. ", waiting for team data…")
end

-------------------------------------------------------------------------------
-- UPDATE
-------------------------------------------------------------------------------

local function pollLocalTeam()
    if not chartsReady then return end

    local teamID = Spring.GetLocalTeamID()
    if teamID == nil then return end
    if teamID == viewedTeamID then return end

    Spring.Echo(string.format(
        "BAR Charts [poll] GetLocalTeamID=%d  (current viewedTeamID=%s)",
        teamID, tostring(viewedTeamID)))

    if not allyTeams[teamID] then
        Spring.Echo(string.format(
            "BAR Charts [poll] teamID=%d NOT in tracked set — ignoring",
            teamID))
        return
    end

    local oldStats = allyTeams[viewedTeamID]
    Spring.Echo(string.format(
        "BAR Charts [poll] VIEW SWITCH  '%s' (team %s) → '%s' (team %d)",
        oldStats and oldStats.playerName or tostring(viewedTeamID),
        tostring(viewedTeamID),
        allyTeams[teamID].playerName, teamID))

    viewedTeamID = teamID
    chromeDirty  = true
end

function widget:Update(dt)
    pollLocalTeam()
end

-------------------------------------------------------------------------------
-- GAME FRAME
-------------------------------------------------------------------------------

function widget:GameFrame(n)
    if not chartsReady then
        chartsReadyWaitFrames = chartsReadyWaitFrames + 1
        if chartsReadyWaitFrames >= READY_WAIT_FRAMES then
            chartsReadyWaitFrames = 0  -- always reset so we retry every 3s until success
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
                local teamCount = 0
                for _ in pairs(allyTeams) do teamCount = teamCount + 1 end
                Spring.Echo(string.format(
                    "BAR Charts v2.3: Ready — %s, buffering %d active team(s)",
                    isSpectator and "SPECTATOR" or "player", teamCount))
                Spring.Echo("BAR Charts: Tracked teams:")
                for tid, stats in pairs(allyTeams) do
                    Spring.Echo(string.format("  teamID=%-3d  '%s'%s",
                        tid, stats.playerName,
                        (tid == viewedTeamID) and "  ◀ default view" or ""))
                end
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

-------------------------------------------------------------------------------
-- GAME START
-------------------------------------------------------------------------------

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
    for _, stats in pairs(allyTeams) do
        stats.armyValue       = 0; stats.unitCount      = 0
        stats.kills           = 0; stats.losses         = 0
        stats.metalLost       = 0; stats.damageDealt    = 0
        stats.damageTaken     = 0; stats.buildEfficiency = 0
        stats.metalStall      = 0; stats.totalBP        = 0
        stats.buildPower      = 0
    end
    chromeDirty = true
    Spring.Echo("BAR Charts v2.3: Game started")
end

-------------------------------------------------------------------------------
-- RENDERING
-------------------------------------------------------------------------------

function widget:DrawScreen()
    if not chartsEnabled then return end
    if chromeDirty then rebuildChromeList() end
    if chromeDisplayList then gl.CallList(chromeDisplayList) end
    for _, chart in pairs(charts) do drawChartLines(chart) end
    drawCardValues()
    for _, chart in pairs(charts) do
        -- draw raw hover outlines without displaylists - would need to redraw when dragging anyway
        if chart.isHovered or (chartsInteractive and chart.isDragging) then
            gl.PushMatrix()
            gl.Translate(chart.x, chart.y, 0)
            gl.Scale(chart.scale, chart.scale, 1)
            
            -- Use COLOR.borderHot (the blue/cyan outline)
            gl.Color(COLOR.borderHot[1], COLOR.borderHot[2], COLOR.borderHot[3], 0.8)
            gl.LineWidth(2.0)
            
            -- Draw the rectangle based on the current live x/y
            drawRoundedRect(0.5, 0.5, chart.width-1, chart.height-1, 4, false)
            gl.PopMatrix()
        end
    end

    -- Repeat for statCards if necessary
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
end

-------------------------------------------------------------------------------
-- INPUT
-------------------------------------------------------------------------------

function widget:KeyPress(key, mods, isRepeat)
    if key == Spring.GetKeyCode("f9") then
        chartsEnabled = not chartsEnabled
        chromeDirty   = true
        Spring.Echo("BAR Charts: "..(chartsEnabled and "Enabled" or "Disabled"))
        return true
    end
    return false
end

local function findHit(mx, my)
    for id, card in pairs(statCards) do
        if (card.enabled or chartsInteractive) and card:isMouseOver(mx, my) then
            return card, "card"
        end
    end
    for id, chart in pairs(charts) do
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
        return true
    elseif button == 3 then
        elem.enabled = not elem.enabled
        chromeDirty  = true
        return true
    end
    return false
end

function widget:MouseRelease(mx, my, button)
    if not chartsEnabled or not chartsInteractive then return false end
    if button == 1 then
        for _, card  in pairs(statCards) do if card.isDragging  then card.isDragging  = false; return true end end
        for _, chart in pairs(charts)    do if chart.isDragging then chart.isDragging = false; return true end end
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if not chartsEnabled then return false end
    if chartsInteractive then
        for _, card in pairs(statCards) do
            if card.isDragging then
                card.x = mx - card.dragStartX; card.y = my - card.dragStartY
                chromeDirty = true; return true
            end
        end
        for _, chart in pairs(charts) do
            if chart.isDragging then
                chart.x = mx - chart.dragStartX; chart.y = my - chart.dragStartY
                chromeDirty = true; return true
            end
        end
    end
    local changed = false
    for id, card in pairs(statCards) do
        local h = chartsInteractive and card:isMouseOver(mx, my) or false
        if h ~= card.isHovered then changed = true end; card.isHovered = h
    end
    for id, chart in pairs(charts) do
        local h = chartsInteractive and chart:isMouseOver(mx, my) or false
        if h ~= chart.isHovered then changed = true end; chart.isHovered = h
    end
    if not chartsInteractive then return false end
    for _, c in pairs(statCards) do if c.isHovered then return true end end
    for _, c in pairs(charts)    do if c.isHovered then return true end end
    return false
end

function widget:MouseWheel(up, value)
    if not chartsEnabled or not chartsInteractive then return false end
    local mx, my = Spring.GetMouseState()
    for _, card in pairs(statCards) do
        if card:isMouseOver(mx, my) then
            card.scale  = up and math.min(2.0, card.scale+0.1) or math.max(0.5, card.scale-0.1)
            chromeDirty = true; return true
        end
    end
    for _, chart in pairs(charts) do
        if chart:isMouseOver(mx, my) then
            chart.scale = up and math.min(2.0, chart.scale+0.1) or math.max(0.5, chart.scale-0.1)
            chromeDirty = true; return true
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
    chromeDirty = true; 
end

-------------------------------------------------------------------------------
-- TEXT COMMANDS
-------------------------------------------------------------------------------

function widget:TextCommand(command)
    if command:sub(1, 14) == "barcharts view" then
        local arg = command:sub(16)
        if arg and #arg > 0 then
            local tid = tonumber(arg)
            if tid then
                switchView(tid)
            else
                local found = findTeamByName(arg)
                if found then
                    switchView(found)
                else
                    Spring.Echo("BAR Charts: No active team matching '"..arg.."'")
                end
            end
        else
            Spring.Echo("BAR Charts: Active participant teams"
                .. (isSpectator and " (spectator)" or " (allies)") .. ":")
            for tid, stats in pairs(allyTeams) do
                local marker = (tid == viewedTeamID) and " ◀ viewing" or ""
                local mine   = (myTeamID and tid == myTeamID) and " (you)" or ""
                Spring.Echo(string.format("  %d  %s%s%s", tid, stats.playerName, mine, marker))
            end
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
        -- Toggle edit mode directly — does not affect pill visibility.
        chartsInteractive = not chartsInteractive
        syncPillState()
        chromeDirty = true
        Spring.Echo("BAR Charts: " .. (chartsInteractive and "EDIT mode ON" or "LOCKED"))
        return true
    elseif command == "barcharts hidepill" then
        setPillVisible(false)
        Spring.Echo("BAR Charts: Pill hidden  (/barcharts showpill to restore,  /barcharts edit to toggle edit mode)")
        return true
    elseif command == "barcharts showpill" then
        setPillVisible(true)
        Spring.Echo("BAR Charts: Pill visible")
        return true
    elseif command == "barcharts debug" then
        Spring.Echo("=== BAR Charts v2.3 Debug ===")
        Spring.Echo(string.format("vsx=%d vsy=%d  enabled=%s ready=%s interactive=%s",
            vsx, vsy, tostring(chartsEnabled), tostring(chartsReady), tostring(chartsInteractive)))
        Spring.Echo(string.format("HISTORY_SIZE=%d (%.0fs @ %dfps)  RENDER_POINTS=%d",
            HISTORY_SIZE, HISTORY_SECONDS, GAME_FPS, RENDER_POINTS))
        Spring.Echo(string.format("isSpectator=%s  myTeamID=%s  viewedTeamID=%s",
            tostring(isSpectator), tostring(myTeamID), tostring(viewedTeamID)))
        Spring.Echo("-- ACTIVE PARTICIPANT TEAMS --")
        for tid, stats in pairs(allyTeams) do
            local full = history[tid] and histFull[tid] and histFull[tid]["metalIncome"] or false
            local head = history[tid] and histHead[tid] and histHead[tid]["metalIncome"] or 0
            local viewing = (tid == viewedTeamID) and " ◀" or ""
            local mine    = (tid == myTeamID)     and " (you)" or ""
            Spring.Echo(string.format("  [%d] %s%s%s  metal=%.0f/%.0f  army=%.0f  full=%s head=%d",
                tid, stats.playerName, mine, viewing,
                stats.metalIncome, stats.metalUsage,
                stats.armyValue, tostring(full), head))
        end
        return true
    elseif command == "barcharts viewdebug" then
        local tid   = viewedTeamID
        local stats = allyTeams[tid]
        Spring.Echo(string.format("=== ViewDebug: team %s (%s) ===",
            tostring(tid), stats and stats.playerName or "?"))
        if not history[tid] then
            Spring.Echo("  ERROR: no ring buffer for this team!")
            return true
        end
        for _, key in ipairs(SERIES_KEYS) do
            local startIdx, count = ringRange(tid, key)
            local vals = {}
            local buf  = history[tid][key]
            for i = math.max(1, count-4), count do
                local idx = ((startIdx - 1 + (i-1)) % HISTORY_SIZE) + 1
                vals[#vals+1] = string.format("%.1f", buf[idx] or 0)
            end
            Spring.Echo(string.format("  %-20s  count=%d  last5: %s",
                key, count, table.concat(vals, ", ")))
        end
        return true
    elseif command == "barcharts bp" then
        local tid    = viewedTeamID
        local stats  = allyTeams[tid]
        local tBuilders = builderUnits[tid] or {}
        Spring.Echo(string.format("=== Builder Efficiency Diagnostic: team %s ('%s') ===",
            tostring(tid), stats and stats.playerName or "?"))
        local s = buildEffState[tid]
        Spring.Echo(string.format("  Rolling avg: %.1f%%  (samples %d/%d)",
            stats and stats.buildEfficiency or 0,
            s and s.count or 0, BUILD_EFF_WINDOW_SIZE))
        local total, active, effSum, effCount = 0, 0, 0, 0
        for uid, bd in pairs(tBuilders) do
            total = total + 1
            local tuid = Spring.GetUnitIsBuilding(uid)
            local tdef = tuid and Spring.GetUnitDefID(tuid)
            local mm   = (bd.defID and tdef and maxMetalUseCache[bd.defID])
                         and maxMetalUseCache[bd.defID][tdef] or 0
            local _, mp = Spring.GetUnitResources(uid, "metal")
            local mu = mp or 0
            local r  = (mm > 0) and math.min(1.0, mu/mm) or nil
            local bud = bd.defID and UnitDefs[bd.defID]
            Spring.Echo(string.format("    uid=%d  %s  bp=%.0f  building=%s  eff=%s",
                uid, bud and bud.name or "?", bd.bp, tostring(tuid ~= nil),
                r and string.format("%.0f%%", r*100) or "idle"))
            if r then effSum = effSum+r; effCount = effCount+1; active = active+1 end
        end
        local inst = effCount > 0 and (effSum/effCount*100)
                     or ((stats and (stats.buildPower or 0) > 0) and 100 or 0)
        Spring.Echo(string.format("  total=%d active=%d instant=%.1f%% rolling=%.1f%%",
            total, active, inst, stats and stats.buildEfficiency or 0))
        return true
    elseif command == "barcharts diag" then
        debugInitState()
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- SHUTDOWN
-------------------------------------------------------------------------------

function widget:Shutdown()
    saveConfig()
    shutdownRmlToggle()
    freeLists()
    Spring.Echo("BAR Charts v2.3: Shutdown")
end
