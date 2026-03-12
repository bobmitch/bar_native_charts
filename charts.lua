--[[
═══════════════════════════════════════════════════════════════════════════
    BAR CHARTS WIDGET — NO ANIMATION
    
    Animation removed entirely. Display lists are rebuilt only when data
    changes (every 10s) or on interaction. DrawScreen is near-zero cost.
    
    Controls:
    - F9: Toggle all charts on/off
    - Click+Drag: Move charts/cards  (only when Edit Mode is ON)
    - Mouse Wheel over chart/card: Scale size  (only when Edit Mode is ON)
    - Right-click: Toggle individual chart/card visibility  (Edit Mode only)

    Edit Mode Toggle:
    - Small RmlUI pill button in top-left corner (default: LOCKED)
    - Click pill to toggle LOCKED ↔ EDIT
    - In LOCKED mode all chart mouse interactions are suppressed so
      mis-clicks/scroll never accidentally move or zoom a chart mid-game.
    - In EDIT mode, disabled charts/cards are shown semi-transparent so
      you can find, move, resize, and re-enable them.
    
    Commands:
    - /barcharts save   : Save layout immediately
    - /barcharts reset  : Delete config and restore defaults
    - /barcharts debug  : Print state to console
    - /barcharts bp     : Print builder efficiency diagnostic
    - /barcharts edit   : Toggle edit mode from chat
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
-- TABLE SERIALIZATION UTILITIES
-------------------------------------------------------------------------------

local function serializeTable(tbl, indent)
    indent = indent or 0
    local indentStr = string.rep("  ", indent)
    local result = "{\n"
    for k, v in pairs(tbl) do
        local keyStr = type(k) == "string" and string.format('["%s"]', k) or string.format("[%s]", k)
        if type(v) == "table" then
            result = result .. indentStr .. "  " .. keyStr .. " = " .. serializeTable(v, indent + 1) .. ",\n"
        elseif type(v) == "string" then
            result = result .. indentStr .. "  " .. keyStr .. " = " .. string.format('"%s"', v) .. ",\n"
        elseif type(v) == "boolean" then
            result = result .. indentStr .. "  " .. keyStr .. " = " .. tostring(v) .. ",\n"
        elseif type(v) == "number" then
            result = result .. indentStr .. "  " .. keyStr .. " = " .. tostring(v) .. ",\n"
        end
    end
    result = result .. indentStr .. "}"
    return result
end

-------------------------------------------------------------------------------
-- CONFIGURATION & CONSTANTS
-------------------------------------------------------------------------------

local vsx, vsy = Spring.GetViewGeometry()
local CONFIG_FILE = "bar_charts_config.lua"

local chartsEnabled     = true
local chartsReady       = false

-- Edit mode: when false all chart mouse interactions are suppressed.
-- This prevents accidental drag/zoom/hide of charts during normal gameplay.
local chartsInteractive = false   -- default: LOCKED

local COLOR = {
    bg          = {0.031, 0.047, 0.078, 0.72},
    border      = {0.353, 0.706, 1.000, 0.18},
    borderHot   = {0.353, 0.706, 1.000, 0.55},
    grid        = {0.353, 0.706, 1.000, 0.08},
    gridBase    = {0.353, 0.706, 1.000, 0.22},
    text        = {0.863, 0.912, 0.973, 1.00},
    muted       = {0.627, 0.745, 0.863, 0.55},
    accent      = {0.290, 0.706, 1.000, 1.00},
    accent2     = {1.000, 0.420, 0.208, 1.00},
    danger      = {1.000, 0.231, 0.361, 1.00},
    success     = {0.188, 0.941, 0.627, 1.00},
    gold        = {0.941, 0.753, 0.251, 1.00},
}

local HISTORY_SIZE    = 60
local UPDATE_INTERVAL = 10

local CHART_WIDTH  = 300
local CHART_HEIGHT = 180
local PADDING      = {left = 40, right = 15, top = 15, bottom = 25}

local CARD_WIDTH  = 140
local CARD_HEIGHT = 70

-- Build efficiency rolling average settings
local BUILD_EFF_TICKS_PER_SAMPLE = 30
local BUILD_EFF_WINDOW_SIZE      = 30

-------------------------------------------------------------------------------
-- GLOBAL STATE
-------------------------------------------------------------------------------

local charts     = {}
local statCards  = {}
local lastUpdateTime = 0
local teamID     = nil
local allyTeamID = nil
local allyTeams  = {}

local masterDisplayList = nil
local masterDirty       = true
local hoverDisplayList  = nil

local myTeamStats = {
    metalIncome      = 0, metalUsage   = 0,
    energyIncome     = 0, energyUsage  = 0,
    damageDealt      = 0, damageTaken  = 0,
    armyValue        = 0, unitCount    = 0,
    kills            = 0, losses       = 0,
    metalLost        = 0,
    buildEfficiency  = 0,
    metalStall       = 0,
    totalBP          = 0,
}

local builderUnits     = {}
local maxMetalUseCache = {}

local buildEffSamples     = {}
local buildEffSampleIndex = 0
local buildEffSampleCount = 0
local buildEffTickCounter = 0

-------------------------------------------------------------------------------
-- RMLUI TOGGLE WIDGET
-------------------------------------------------------------------------------

-- RmlUI state — context, document, data model
local rmlContext    = nil
local rmlDocument   = nil
local rmlModel      = nil
local rmlModelHandle = nil

-- Data model table that RmlUI reads from
local rmlData = {
    labelText = "LOCKED",
    iconClass = "state-locked",
}

-- Called by RmlUI when the user clicks the pill button.
-- This function is registered on the data model so RML can reach it
-- via data-event-click="onToggleClick(event)".
local function onToggleClick(event)
    chartsInteractive = not chartsInteractive

    if rmlDocument then
        local pill = rmlDocument:GetElementById("toggle-pill")
        if pill then
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
    end

    masterDirty = true
    Spring.Echo("BAR Charts: " .. (chartsInteractive and "Edit mode ON — charts are interactive" or "Locked — charts are protected"))
end

local function initRmlToggle()
    if not RmlUi then
        Spring.Echo("BAR Charts: RmlUi not available, toggle widget skipped")
        return
    end

    rmlContext = RmlUi.CreateContext("bar_charts_toggle_ctx")
    if not rmlContext then
        Spring.Echo("BAR Charts: failed to create RmlUI context")
        return
    end

    -- Load fonts into our context. BAR ships these in LuaUI/Fonts/.
    -- Try several common names; RmlUi silently ignores missing files.
    local fonts = {
        "LuaUI/Fonts/Exo2-SemiBold.ttf",
        "LuaUI/Fonts/Exo2-Regular.ttf",
        "LuaUI/Fonts/FreeSansBold.otf",
        "LuaUI/Fonts/FreeSans.otf",
    }
    for _, f in ipairs(fonts) do
        if VFS.FileExists(f) then
            RmlUi.LoadFontFace(f)
        end
    end

    -- No data model needed — we wire the click directly via element:AddEventListener
    rmlDocument = rmlContext:LoadDocument("LuaUI/Widgets/bar_charts_toggle.rml")
    if not rmlDocument then
        Spring.Echo("BAR Charts: failed to load bar_charts_toggle.rml")
        return
    end

    local pill = rmlDocument:GetElementById("toggle-pill")
    if not pill then
        Spring.Echo("BAR Charts: toggle-pill element not found in RML")
        return
    end

    pill:AddEventListener("click", onToggleClick, false)
    pill:SetClass("state-locked", true)
    pill:SetClass("state-edit",   false)

    rmlDocument:Show()
    Spring.Echo("BAR Charts: RmlUI toggle initialized")
end

local function shutdownRmlToggle()
    if rmlDocument then
        rmlDocument:Close()
        rmlDocument = nil
    end
    -- Note: don't destroy the context if it is shared with other widgets
    rmlContext = nil
end

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------

local function formatNumber(n)
    if n >= 1000000 then return string.format("%.1fM", n / 1000000)
    elseif n >= 10000 then return string.format("%.0fK", n / 1000)
    else return string.format("%d", math.floor(n + 0.5)) end
end

local function formatYAxis(n, chartType)
    if chartType == "ratio" or chartType == "percent" or chartType == "demand" or chartType == "storage" then
        return string.format("%.0f%%", n)
    else
        return formatNumber(n)
    end
end

local function drawRoundedRect(x, y, w, h, r, filled)
    if filled then
        gl.BeginEnd(GL.QUADS, function()
            gl.Vertex(x + r, y);         gl.Vertex(x + w - r, y)
            gl.Vertex(x + w - r, y + h); gl.Vertex(x + r, y + h)
            gl.Vertex(x, y + r);         gl.Vertex(x + w, y + r)
            gl.Vertex(x + w, y + h - r); gl.Vertex(x, y + h - r)
        end)
        local segments = 6
        for i = 0, segments - 1 do
            local a1 = (math.pi / 2) * (i / segments)
            local a2 = (math.pi / 2) * ((i + 1) / segments)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + r, y + r)
                gl.Vertex(x + r - r*math.cos(a1), y + r - r*math.sin(a1))
                gl.Vertex(x + r - r*math.cos(a2), y + r - r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + w - r, y + r)
                gl.Vertex(x + w - r + r*math.sin(a1), y + r - r*math.cos(a1))
                gl.Vertex(x + w - r + r*math.sin(a2), y + r - r*math.cos(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + w - r, y + h - r)
                gl.Vertex(x + w - r + r*math.cos(a1), y + h - r + r*math.sin(a1))
                gl.Vertex(x + w - r + r*math.cos(a2), y + h - r + r*math.sin(a2))
            end)
            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + r, y + h - r)
                gl.Vertex(x + r - r*math.sin(a1), y + h - r + r*math.cos(a1))
                gl.Vertex(x + r - r*math.sin(a2), y + h - r + r*math.cos(a2))
            end)
        end
    else
        gl.BeginEnd(GL.LINE_LOOP, function()
            gl.Vertex(x + r, y); gl.Vertex(x + w - r, y)
            for i = 0, 6 do
                local a = (math.pi / 2) * (i / 6)
                gl.Vertex(x + w - r + r*math.sin(a), y + r - r*math.cos(a))
            end
            gl.Vertex(x + w, y + r); gl.Vertex(x + w, y + h - r)
            for i = 0, 6 do
                local a = (math.pi / 2) * (i / 6)
                gl.Vertex(x + w - r + r*math.cos(a), y + h - r + r*math.sin(a))
            end
            gl.Vertex(x + w - r, y + h); gl.Vertex(x + r, y + h)
            for i = 0, 6 do
                local a = (math.pi / 2) * (i / 6)
                gl.Vertex(x + r - r*math.sin(a), y + h - r + r*math.cos(a))
            end
            gl.Vertex(x, y + h - r); gl.Vertex(x, y + r)
            for i = 0, 6 do
                local a = (math.pi / 2) * (i / 6)
                gl.Vertex(x + r - r*math.cos(a), y + r - r*math.sin(a))
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- BUILD EFFICIENCY — TICK-BASED SAMPLER + ROLLING AVERAGE
-------------------------------------------------------------------------------

local function sampleBuildEfficiency()
    local effSum   = 0
    local effCount = 0
    for uid, builderData in pairs(builderUnits) do
        local bp    = builderData.bp
        local defID = builderData.defID
        local targetUnitID = Spring.GetUnitIsBuilding(uid)
        if targetUnitID then
            local targetDefID = Spring.GetUnitDefID(targetUnitID)
            local maxMetal = nil
            if defID and targetDefID then
                local row = maxMetalUseCache[defID]
                if row then maxMetal = row[targetDefID] end
                if maxMetal == nil then
                    local bud = UnitDefs[defID]
                    local tud = UnitDefs[targetDefID]
                    if bud and tud then
                        local bt = tud.buildTime or 1
                        if bt <= 0 then bt = 1 end
                        maxMetal = (bp / bt) * (tud.metalCost or 0)
                    else
                        maxMetal = 0
                    end
                    if not maxMetalUseCache[defID] then maxMetalUseCache[defID] = {} end
                    maxMetalUseCache[defID][targetDefID] = maxMetal
                end
            end
            local _, mPull = Spring.GetUnitResources(uid, "metal")
            local mUsing = mPull or 0
            if maxMetal and maxMetal > 0 then
                local ratio = math.min(1.0, mUsing / maxMetal)
                effSum   = effSum   + ratio
                effCount = effCount + 1
            end
        end
    end
    if effCount == 0 then
        return myTeamStats.totalBP > 0 and 100 or 0
    end
    return (effSum / effCount) * 100
end

local function pushBuildEffSample(value)
    buildEffSampleIndex = (buildEffSampleIndex % BUILD_EFF_WINDOW_SIZE) + 1
    buildEffSamples[buildEffSampleIndex] = value
    if buildEffSampleCount < BUILD_EFF_WINDOW_SIZE then
        buildEffSampleCount = buildEffSampleCount + 1
    end
    local sum = 0
    for i = 1, buildEffSampleCount do
        sum = sum + (buildEffSamples[i] or 0)
    end
    myTeamStats.buildEfficiency = sum / buildEffSampleCount
end

local function resetBuildEffSamples()
    buildEffSamples     = {}
    buildEffSampleIndex = 0
    buildEffSampleCount = 0
    buildEffTickCounter = 0
    myTeamStats.buildEfficiency = 0
end

-------------------------------------------------------------------------------
-- DISPLAY LIST MANAGEMENT
-------------------------------------------------------------------------------

local function freeLists()
    if masterDisplayList then gl.DeleteList(masterDisplayList); masterDisplayList = nil end
    if hoverDisplayList  then gl.DeleteList(hoverDisplayList);  hoverDisplayList  = nil end
end

local function rebuildMasterList()
    if masterDisplayList then gl.DeleteList(masterDisplayList) end
    masterDisplayList = gl.CreateList(function()
        for _, card in pairs(statCards) do
            if card.isDragging then
                card.x = mx - card.dragStartX
                card.y = my - card.dragStartY
                masterDirty = true
                rebuildHoverList()   -- ← keeps outline in sync with card position
                return true
            end
        end
        for _, chart in pairs(charts) do
            if chart.isDragging then
                chart.x = mx - chart.dragStartX
                chart.y = my - chart.dragStartY
                masterDirty = true
                rebuildHoverList()   -- ← keeps outline in sync with chart position
                return true
            end
        end
        -- Hint text: show lock state when charts are visible
        if chartsInteractive then
            gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 0.55)
            gl.Text("✏ EDIT MODE", vsx - 150, 45, 11, "o")
        end
        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.4)
        gl.Text("F9: Toggle Charts", vsx - 150, 30, 11, "o")
    end)
    masterDirty = false
end

local function rebuildHoverList()
    if hoverDisplayList then gl.DeleteList(hoverDisplayList) end
    hoverDisplayList = gl.CreateList(function()
        -- Only render hover highlights when interactive
        if not chartsInteractive then return end
        for _, chart in pairs(charts) do
            -- Show hover highlight for all charts in edit mode (enabled or disabled)
            if chart.isHovered then
                gl.PushMatrix()
                gl.Translate(chart.x, chart.y, 0)
                gl.Scale(chart.scale, chart.scale, 1)
                gl.Color(COLOR.borderHot[1], COLOR.borderHot[2], COLOR.borderHot[3], COLOR.borderHot[4])
                gl.LineWidth(1.5)
                drawRoundedRect(0.5, 0.5, chart.width - 1, chart.height - 1, 4, false)
                gl.PopMatrix()
            end
        end
        for _, card in pairs(statCards) do
            -- Show hover highlight for all cards in edit mode (enabled or disabled)
            if card.isHovered then
                gl.PushMatrix()
                gl.Translate(card.x, card.y, 0)
                gl.Scale(card.scale, card.scale, 1)
                gl.Color(COLOR.borderHot[1], COLOR.borderHot[2], COLOR.borderHot[3], COLOR.borderHot[4])
                gl.LineWidth(1.5)
                drawRoundedRect(0.5, 0.5, CARD_WIDTH - 1, CARD_HEIGHT - 1, 4, false)
                gl.PopMatrix()
            end
        end
    end)
end

-------------------------------------------------------------------------------
-- STAT CARD CLASS
-------------------------------------------------------------------------------

local StatCard = {}
StatCard.__index = StatCard

function StatCard.new(id, label, icon, x, y, color, getValue)
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
    self.getValue     = getValue
    self.displayValue = 0
    self.isDragging   = false
    self.dragStartX   = 0
    self.dragStartY   = 0
    self.isHovered    = false
    return self
end

function StatCard:setValue(value)
    self.displayValue = value
    masterDirty = true
end

function StatCard:drawToList()
    local w = CARD_WIDTH
    local h = CARD_HEIGHT
    local c = self.color
    
    -- In edit mode, show disabled cards semi-transparent
    local alphaMultiplier = (not self.enabled and chartsInteractive) and 0.35 or 1.0

    gl.PushMatrix()
    gl.Translate(self.x, self.y, 0)
    gl.Scale(self.scale, self.scale, 1)

    gl.Color(COLOR.bg[1], COLOR.bg[2], COLOR.bg[3], COLOR.bg[4] * alphaMultiplier)
    drawRoundedRect(0, 0, w, h, 4, true)

    gl.Color(COLOR.border[1], COLOR.border[2], COLOR.border[3], COLOR.border[4] * alphaMultiplier)
    gl.LineWidth(1)
    drawRoundedRect(0.5, 0.5, w - 1, h - 1, 4, false)

    gl.Color(c[1], c[2], c[3], 0.7 * alphaMultiplier)
    gl.BeginEnd(GL.QUADS, function()
        gl.Vertex(0, 4); gl.Vertex(3, 4); gl.Vertex(3, h - 4); gl.Vertex(0, h - 4)
    end)

    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4] * alphaMultiplier)
    gl.Text(self.icon .. "  " .. self.label, 10, h - 18, 9, "o")

    if self.id == "card-build-efficiency" and self.enabled then
        local stall = myTeamStats.metalStall
        if stall == 2 then
            gl.Color(COLOR.danger[1], COLOR.danger[2], COLOR.danger[3], 1.0 * alphaMultiplier)
            gl.Text("⚠ STALL", w - 6, h - 18, 9, "ro")
        elseif stall == 1 then
            gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 1.0 * alphaMultiplier)
            gl.Text("⚠ STALL", w - 6, h - 18, 9, "ro")
        end
    end

    gl.Color(c[1], c[2], c[3], 1.0 * alphaMultiplier)
    gl.Text(formatNumber(math.floor(self.displayValue + 0.5)), w / 2 + 5, 10, 20, "co")
    
    -- Show "DISABLED" label when in edit mode and card is disabled
    if not self.enabled and chartsInteractive then
        gl.Color(COLOR.danger[1], COLOR.danger[2], COLOR.danger[3], 0.8)
        gl.Text("DISABLED", w / 2, h / 2, 10, "co")
    end

    gl.PopMatrix()
end

function StatCard:isMouseOver(mx, my)
    return mx >= self.x and mx <= self.x + CARD_WIDTH  * self.scale
       and my >= self.y and my <= self.y + CARD_HEIGHT * self.scale
end

-------------------------------------------------------------------------------
-- CHART CLASS
-------------------------------------------------------------------------------

local Chart = {}
Chart.__index = Chart

function Chart.new(id, label, icon, x, y, chartType, series, multiTeam)
    local self = setmetatable({}, Chart)
    self.id        = id
    self.label     = label
    self.icon      = icon
    self.x         = x
    self.y         = y
    self.width     = CHART_WIDTH
    self.height    = CHART_HEIGHT
    self.scale     = 1.0
    self.enabled   = true
    self.visible   = true
    self.chartType = chartType
    self.series    = series
    self.multiTeam = multiTeam or false
    self.history   = {}
    for i = 1, #series do self.history[i] = {} end
    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    self.isHovered  = false
    return self
end

function Chart:rebuildMultiTeamSeries()
    if not self.multiTeam then return end
    self.history = {}
    self.series  = {}
    local idx = 1
    if type(allyTeams) == "table" then
        for tid, teamData in pairs(allyTeams) do
            local seriesConfig = {
                label    = teamData.playerName,
                color    = teamData.color,
                teamID   = tid,
                getValue = nil,
            }
            if self.id == "chart-ally-army" then
                seriesConfig.getValue = function()
                    return allyTeams[tid] and allyTeams[tid].armyValue or 0
                end
            elseif self.id == "chart-ally-buildpower" then
                seriesConfig.getValue = function()
                    return allyTeams[tid] and allyTeams[tid].buildPower or 0
                end
            elseif self.id == "chart-ally-metal" then
                seriesConfig.getValue = function()
                    return allyTeams[tid] and allyTeams[tid].metalIncome or 0
                end
            elseif self.id == "chart-ally-energy" then
                seriesConfig.getValue = function()
                    return allyTeams[tid] and allyTeams[tid].energyIncome or 0
                end
            end
            self.series[idx]  = seriesConfig
            self.history[idx] = {}
            idx = idx + 1
        end
    end
end

function Chart:addDataPoint()
    for i, s in ipairs(self.series) do
        local value = s.getValue()
        table.insert(self.history[i], value)
        if #self.history[i] > HISTORY_SIZE then
            table.remove(self.history[i], 1)
        end
    end
    masterDirty = true
end

function Chart:drawToList()
    gl.PushMatrix()
    gl.Translate(self.x, self.y, 0)
    gl.Scale(self.scale, self.scale, 1)

    local w   = self.width
    local h   = self.height
    local pad = PADDING
    local cX  = pad.left
    local cY  = pad.bottom
    local cW  = w - pad.left - pad.right
    local cH  = h - pad.top  - pad.bottom
    
    -- In edit mode, show disabled charts semi-transparent
    local alphaMultiplier = (not self.enabled and chartsInteractive) and 0.35 or 1.0

    gl.Color(COLOR.bg[1], COLOR.bg[2], COLOR.bg[3], COLOR.bg[4] * alphaMultiplier)
    drawRoundedRect(0, 0, w, h, 4, true)

    gl.Color(COLOR.border[1], COLOR.border[2], COLOR.border[3], COLOR.border[4] * alphaMultiplier)
    gl.LineWidth(1)
    drawRoundedRect(0.5, 0.5, w - 1, h - 1, 4, false)

    local hasData = false
    for i = 1, #self.series do
        if #self.history[i] >= 2 then hasData = true; break end
    end

    if not hasData or not self.enabled then
        local displayText = not self.enabled and "— DISABLED —" or "— awaiting data —"
        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.25 * alphaMultiplier)
        gl.Text(displayText, cX + cW / 2, cY + cH / 2, 10, "c")
        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4] * alphaMultiplier)
        gl.Text(self.icon .. "  " .. self.label, pad.left + 2, h - pad.top - 10, 10, "o")
        gl.PopMatrix()
        return
    end

    local allValues = {}
    for i = 1, #self.series do
        for _, v in ipairs(self.history[i]) do
            if v and not (v ~= v) then table.insert(allValues, v) end
        end
    end

    local minV = math.min(unpack(allValues))
    local maxV = math.max(unpack(allValues))

    if self.chartType == "percent" then
        minV = 0
        maxV = 100
    elseif self.chartType == "storage" then
        local absMax = math.max(math.abs(minV), math.abs(maxV), 100)
        local axisPad = absMax * 0.12
        minV = -(absMax + axisPad)
        maxV =  (absMax + axisPad)
    elseif self.chartType == "demand" then
        local absMax = math.max(math.abs(minV), math.abs(maxV), 100)
        local p    = absMax * 0.15
        minV = -(absMax + p)
        maxV =  (absMax + p)
    else
        local span     = maxV - minV
        local rangePad = span > 0 and span * 0.12 or math.max(maxV * 0.1, 100)
        minV = math.max(0, minV - rangePad)
        maxV = maxV + rangePad
    end

    local range = maxV - minV
    if range == 0 then range = 1 end

    for i = 0, 4 do
        local v    = minV + (range * i / 4)
        local yPos = cY + (cH * i / 4)
        local gc   = (i == 0) and COLOR.gridBase or COLOR.grid
        gl.Color(gc[1], gc[2], gc[3], gc[4] * alphaMultiplier)
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(cX, yPos); gl.Vertex(cX + cW, yPos)
        end)
        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4] * alphaMultiplier)
        gl.Text(formatYAxis(v, self.chartType), cX - 5, yPos - 4, 9, "ro")
    end

    local function toX(idx, total)
        return cX + ((idx - 1) / (total - 1)) * cW
    end
    local function toY(value)
        return cY + ((value - minV) / range) * cH
    end

    if self.chartType == "demand" or self.chartType == "storage" then
        local zeroY = toY(0)
        gl.Color(COLOR.accent[1], COLOR.accent[2], COLOR.accent[3], 0.45 * alphaMultiplier)
        gl.LineWidth(1.0)
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(cX, zeroY); gl.Vertex(cX + cW, zeroY)
        end)
        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.5 * alphaMultiplier)
        gl.Text("0", cX - 5, zeroY - 4, 9, "ro")
    end

    for seriesIdx, s in ipairs(self.series) do
        local data = self.history[seriesIdx]
        if #data >= 2 then
            local color = s.color

            gl.Color(color[1], color[2], color[3], 1.0 * alphaMultiplier)
            gl.LineWidth(2.0)
            gl.BeginEnd(GL.LINE_STRIP, function()
                for i, value in ipairs(data) do
                    if value and not (value ~= value) then
                        gl.Vertex(toX(i, #data), toY(value))
                    end
                end
            end)

            gl.Color(color[1], color[2], color[3], 0.15 * alphaMultiplier)
            gl.BeginEnd(GL.TRIANGLE_STRIP, function()
                local fillBase = (self.chartType == "demand" or self.chartType == "storage") and toY(0) or cY
                for i, value in ipairs(data) do
                    if value and not (value ~= value) then
                        local x = toX(i, #data)
                        gl.Vertex(x, fillBase); gl.Vertex(x, toY(value))
                    end
                end
            end)

            if #data > 0 then
                local lastValue = data[#data]
                if lastValue and not (lastValue ~= lastValue) then
                    gl.Color(color[1], color[2], color[3], 0.8 * alphaMultiplier)
                    gl.PointSize(6)
                    gl.BeginEnd(GL.POINTS, function()
                        gl.Vertex(toX(#data, #data), toY(lastValue))
                    end)

                    gl.Color(color[1], color[2], color[3], 1.0 * alphaMultiplier)
                    local valueText
                    if self.chartType == "percent" then
                        valueText = string.format("%.0f%%", lastValue)
                    elseif self.chartType == "storage" then
                        valueText = string.format("%+.0f%%", lastValue)
                    elseif self.chartType == "multi" then
                        local shortName = s.label
                        if #shortName > 8 then shortName = string.sub(shortName, 1, 6) .. ".." end
                        valueText = shortName .. " " .. formatNumber(lastValue)
                    elseif self.chartType == "dual" then
                        valueText = s.label .. " " .. formatNumber(lastValue)
                    else
                        valueText = formatNumber(lastValue)
                    end

                    local labelOffset = 0
                    if self.chartType == "multi" or self.chartType == "dual" then
                        labelOffset = (seriesIdx - 1) * 13
                    end
                    gl.Text(valueText, cX + cW + 2, toY(lastValue) - 4 + labelOffset, 9, "o")
                end
            end
        end
    end

    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4] * alphaMultiplier)
    gl.Text(self.icon .. "  " .. self.label, pad.left + 2, h - pad.top - 10, 10, "o")

    if self.id == "chart-build-efficiency" and self.enabled then
        local stall = myTeamStats.metalStall
        if stall == 2 then
            gl.Color(COLOR.danger[1], COLOR.danger[2], COLOR.danger[3], 1.0 * alphaMultiplier)
            gl.Text("⚠ STALL", w - pad.right - 2, h - pad.top - 10, 10, "ro")
        elseif stall == 1 then
            gl.Color(COLOR.gold[1], COLOR.gold[2], COLOR.gold[3], 1.0 * alphaMultiplier)
            gl.Text("⚠ STALL", w - pad.right - 2, h - pad.top - 10, 10, "ro")
        end
    end

    gl.PopMatrix()
end

function Chart:isMouseOver(mx, my)
    return mx >= self.x and mx <= self.x + self.width  * self.scale
       and my >= self.y and my <= self.y + self.height * self.scale
end

-------------------------------------------------------------------------------
-- ARMY VALUE & BUILD POWER HELPERS
-------------------------------------------------------------------------------

local function unitMetalCost(unitDefID)
    if not unitDefID then return 0 end
    local ud = UnitDefs[unitDefID]
    return ud and (ud.metalCost or 0) or 0
end

local function seedArmyValues()
    myTeamStats.armyValue = 0
    if allyTeams[teamID] then allyTeams[teamID].armyValue = 0 end
    local myUnits = Spring.GetTeamUnits(teamID) or {}
    for _, uid in ipairs(myUnits) do
        local cost = unitMetalCost(Spring.GetUnitDefID(uid))
        myTeamStats.armyValue = myTeamStats.armyValue + cost
        if allyTeams[teamID] then
            allyTeams[teamID].armyValue = allyTeams[teamID].armyValue + cost
        end
    end
    for tid, teamData in pairs(allyTeams) do
        if tid ~= teamID then
            teamData.armyValue = 0
            local tUnits = Spring.GetTeamUnits(tid) or {}
            for _, uid in ipairs(tUnits) do
                teamData.armyValue = teamData.armyValue + unitMetalCost(Spring.GetUnitDefID(uid))
            end
        end
    end
end

local function seedBuildPower()
    builderUnits = {}
    for tid, teamData in pairs(allyTeams) do
        teamData.buildPower = 0
        local tUnits = Spring.GetTeamUnits(tid) or {}
        for _, uid in ipairs(tUnits) do
            local ud = UnitDefs[Spring.GetUnitDefID(uid) or 0]
            if ud and ud.isBuilder then
                local bp = ud.buildSpeed or 0
                teamData.buildPower = teamData.buildPower + bp
                if tid == teamID then
                    builderUnits[uid] = { bp = bp, defID = Spring.GetUnitDefID(uid) }
                end
            end
        end
    end
end

local function seedUnitCount()
    local myUnits = Spring.GetTeamUnits(teamID) or {}
    myTeamStats.unitCount = #myUnits
end

-------------------------------------------------------------------------------
-- UNIT EVENT CALLBACKS
-------------------------------------------------------------------------------

function widget:UnitFinished(unitID, unitDefID, unitTeam)
    local cost = unitMetalCost(unitDefID)
    local ud   = UnitDefs[unitDefID]
    local bp   = (ud and ud.isBuilder) and (ud.buildSpeed or 0) or 0
    if unitTeam == teamID then
        myTeamStats.armyValue = myTeamStats.armyValue + cost
        myTeamStats.unitCount = myTeamStats.unitCount + 1
        if bp > 0 then builderUnits[unitID] = { bp = bp, defID = unitDefID } end
    end
    if allyTeams[unitTeam] then
        allyTeams[unitTeam].armyValue  = allyTeams[unitTeam].armyValue + cost
        if bp > 0 then
            allyTeams[unitTeam].buildPower = allyTeams[unitTeam].buildPower + bp
        end
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
    local cost = unitMetalCost(unitDefID)
    if unitTeam == teamID then
        myTeamStats.armyValue = math.max(0, myTeamStats.armyValue - cost)
        myTeamStats.unitCount = math.max(0, myTeamStats.unitCount - 1)
        myTeamStats.metalLost = myTeamStats.metalLost + cost
        builderUnits[unitID] = nil
    end
    if allyTeams[unitTeam] then
        allyTeams[unitTeam].armyValue = math.max(0, allyTeams[unitTeam].armyValue - cost)
    end
    local ud = UnitDefs[unitDefID]
    if ud and ud.isBuilder then
        local bp = ud.buildSpeed or 0
        if allyTeams[unitTeam] then
            allyTeams[unitTeam].buildPower = math.max(0, allyTeams[unitTeam].buildPower - bp)
        end
    end
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
    local cost = unitMetalCost(unitDefID)
    if oldTeam == teamID then
        myTeamStats.armyValue = math.max(0, myTeamStats.armyValue - cost)
        myTeamStats.unitCount = math.max(0, myTeamStats.unitCount - 1)
        builderUnits[unitID] = nil
    elseif allyTeams[oldTeam] then
        allyTeams[oldTeam].armyValue = math.max(0, allyTeams[oldTeam].armyValue - cost)
    end
    if newTeam == teamID then
        myTeamStats.armyValue = myTeamStats.armyValue + cost
        myTeamStats.unitCount = myTeamStats.unitCount + 1
    elseif allyTeams[newTeam] then
        allyTeams[newTeam].armyValue = allyTeams[newTeam].armyValue + cost
    end
    local ud = UnitDefs[unitDefID]
    if ud and ud.isBuilder then
        local bp = ud.buildSpeed or 0
        if newTeam == teamID then builderUnits[unitID] = { bp = bp, defID = unitDefID } end
        if allyTeams[oldTeam] then allyTeams[oldTeam].buildPower = math.max(0, allyTeams[oldTeam].buildPower - bp) end
        if allyTeams[newTeam] then allyTeams[newTeam].buildPower = allyTeams[newTeam].buildPower + bp end
    end
end

function widget:UnitCaptured(unitID, unitDefID, oldTeam, newTeam)
    widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
end

-------------------------------------------------------------------------------
-- ALLY TEAM INIT
-------------------------------------------------------------------------------

local function initAllyTeams()
    local currentAllyID = Spring.GetMyAllyTeamID()
    if not currentAllyID then return false end
    local teamList = Spring.GetTeamList(currentAllyID)
    if not teamList or #teamList == 0 then return false end
    allyTeamID = currentAllyID
    local newAllyTeams = {}
    for _, tid in ipairs(teamList) do
        local r, g, b    = Spring.GetTeamColor(tid)
        local playerName = "Team " .. tid
        local _, leaderID, _, isAI = Spring.GetTeamInfo(tid)
        if isAI then
            local _, name = Spring.GetAIInfo(tid)
            playerName = name or playerName
        elseif leaderID then
            local name = Spring.GetPlayerInfo(leaderID)
            playerName = name or playerName
        end
        newAllyTeams[tid] = {
            teamID       = tid,
            playerName   = playerName,
            color        = {r or 1, g or 1, b or 1, 1},
            metalIncome  = 0,
            energyIncome = 0,
            armyValue    = 0,
            buildPower   = 0,
        }
    end
    allyTeams = newAllyTeams
    return true
end

-------------------------------------------------------------------------------
-- CONFIG SAVE / LOAD
-------------------------------------------------------------------------------

local function saveConfig()
    local config = {
        version           = "1.0",
        enabled           = chartsEnabled,
        chartsInteractive = chartsInteractive,
        charts            = {},
        cards             = {},
    }
    for _, chart in pairs(charts) do
        config.charts[chart.id] = {
            x = chart.x, y = chart.y, scale = chart.scale,
            visible = chart.visible, enabled = chart.enabled,
        }
    end
    for id, card in pairs(statCards) do
        config.cards[id] = {
            x = card.x, y = card.y, scale = card.scale,
            visible = card.visible, enabled = card.enabled,
        }
    end
    local file = io.open(CONFIG_FILE, "w")
    if file then
        file:write("return " .. serializeTable(config, 0))
        file:close()
        Spring.Echo("BAR Charts: Config saved to " .. CONFIG_FILE)
    else
        Spring.Echo("BAR Charts: Failed to save config")
    end
end

local function loadConfig()
    if not VFS.FileExists(CONFIG_FILE) then return {}, {} end
    local fileContent = VFS.LoadFile(CONFIG_FILE)
    if not fileContent then return {}, {} end
    local chunk, err = loadstring(fileContent)
    if not chunk then
        Spring.Echo("BAR Charts: Parse error: " .. tostring(err))
        return {}, {}
    end
    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
        Spring.Echo("BAR Charts: Invalid config")
        return {}, {}
    end
    if result.enabled ~= nil then chartsEnabled = result.enabled end
    -- Restore interactive/locked state (always default to locked on fresh install)
    if result.chartsInteractive ~= nil then chartsInteractive = result.chartsInteractive end
    return result.charts or {}, result.cards or {}
end

-------------------------------------------------------------------------------
-- INITIALIZATION
-------------------------------------------------------------------------------

function widget:Initialize()
    Spring.Echo("BAR Charts: Initialize START")
    vsx, vsy    = Spring.GetViewGeometry()
    teamID      = Spring.GetMyTeamID()
    allyTeamID  = Spring.GetMyAllyTeamID()
    chartsReady = false
    charts      = {}
    statCards   = {}

    resetBuildEffSamples()

    -- ── LINE CHARTS ───────────────────────────────────────────────────────────

    charts.metal = Chart.new("chart-metal", "METAL", "⚙", vsx - 350, vsy - 230, "dual", {
        { label = "Income", color = COLOR.accent,  getValue = function() return myTeamStats.metalIncome end },
        { label = "Usage",  color = COLOR.accent2, getValue = function() return myTeamStats.metalUsage  end },
    })

    charts.energy = Chart.new("chart-energy", "ENERGY", "⚡", vsx - 660, vsy - 230, "dual", {
        { label = "Income", color = COLOR.accent,  getValue = function() return myTeamStats.energyIncome end },
        { label = "Usage",  color = COLOR.accent2, getValue = function() return myTeamStats.energyUsage  end },
    })

    charts.damage = Chart.new("chart-damage", "DAMAGE", "✕", vsx - 970, vsy - 230, "dual", {
        { label = "Dealt", color = COLOR.success, getValue = function() return myTeamStats.damageDealt end },
        { label = "Taken", color = COLOR.danger,  getValue = function() return myTeamStats.damageTaken end },
    })

    charts.army = Chart.new("chart-army", "ARMY VALUE", "⚙", vsx - 350, vsy - 430, "single", {
        { label = "Value", color = COLOR.accent, getValue = function() return myTeamStats.armyValue end },
    })

    charts.kd = Chart.new("chart-kd", "K/D RATIO", "✕", vsx - 660, vsy - 430, "ratio", {
        { label = "Ratio", color = COLOR.success, getValue = function()
            local k, d = myTeamStats.kills, myTeamStats.losses
            return d == 0 and (k > 0 and 5 or 0) or math.min(5, k / d)
        end },
    })

    charts.buildEfficiency = Chart.new("chart-build-efficiency", "BUILDER EFFICIENCY", "🔧", vsx - 970, vsy - 430, "percent", {
        { label = "Efficiency", color = COLOR.gold, getValue = function()
            return myTeamStats.buildEfficiency
        end },
    })

    charts.allyArmy       = Chart.new("chart-ally-army",       "TEAM ARMY", "⚙",  vsx - 1280, vsy - 430, "multi", {}, true)
    charts.allyBuildPower = Chart.new("chart-ally-buildpower", "TEAM BP",   "🔧", vsx - 1280, vsy - 230, "multi", {}, true)

    -- ── NUMERIC STAT CARDS ────────────────────────────────────────────────────
    local cardY    = vsy - 650
    local cardStep = 80
    local col1X    = vsx - 350
    local col2X    = vsx - 200

    statCards["card-army-value"]        = StatCard.new("card-army-value",        "ARMY VALUE", "⚙",  col1X, cardY,                COLOR.accent,  function() return myTeamStats.armyValue        end)
    statCards["card-unit-count"]        = StatCard.new("card-unit-count",        "UNITS",      "▣",  col2X, cardY,                COLOR.accent,  function() return myTeamStats.unitCount        end)
    statCards["card-kills"]             = StatCard.new("card-kills",             "KILLS",      "✕",  col1X, cardY - cardStep,     COLOR.success, function() return myTeamStats.kills            end)
    statCards["card-losses"]            = StatCard.new("card-losses",            "LOSSES",     "↓",  col2X, cardY - cardStep,     COLOR.danger,  function() return myTeamStats.losses           end)
    statCards["card-dmg-dealt"]         = StatCard.new("card-dmg-dealt",         "DMG DEALT",  "▲",  col1X, cardY - cardStep * 2, COLOR.success, function() return myTeamStats.damageDealt      end)
    statCards["card-dmg-taken"]         = StatCard.new("card-dmg-taken",         "DMG TAKEN",  "▼",  col2X, cardY - cardStep * 2, COLOR.danger,  function() return myTeamStats.damageTaken      end)
    statCards["card-metal-lost"]        = StatCard.new("card-metal-lost",        "METAL LOST", "◆",  col1X, cardY - cardStep * 3, COLOR.gold,    function() return myTeamStats.metalLost        end)
    statCards["card-build-efficiency"]  = StatCard.new("card-build-efficiency",  "BUILD EFF",  "🔧", col2X, cardY - cardStep * 3, COLOR.gold,    function() return myTeamStats.buildEfficiency  end)

    -- ── APPLY SAVED CONFIG ────────────────────────────────────────────────────
    local chartCfg, cardCfg = loadConfig()
    local chartById = {}
    for _, chart in pairs(charts) do chartById[chart.id] = chart end

    for id, cfg in pairs(type(chartCfg) == "table" and chartCfg or {}) do
        local chart = chartById[id]
        if chart and type(cfg) == "table" then
            chart.x = cfg.x or chart.x; chart.y = cfg.y or chart.y
            chart.scale = cfg.scale or chart.scale
            if cfg.visible ~= nil then chart.visible = cfg.visible end
            if cfg.enabled ~= nil then chart.enabled = cfg.enabled end
        end
    end

    for id, cfg in pairs(type(cardCfg) == "table" and cardCfg or {}) do
        local card = statCards[id]
        if card and type(cfg) == "table" then
            card.x = cfg.x or card.x; card.y = cfg.y or card.y
            card.scale = cfg.scale or card.scale
            if cfg.visible ~= nil then card.visible = cfg.visible end
            if cfg.enabled ~= nil then card.enabled = cfg.enabled end
        end
    end

    -- ── RMLUI TOGGLE ─────────────────────────────────────────────────────────
    initRmlToggle()

    masterDirty = true
    Spring.Echo("BAR Charts: Initialized, waiting for team data...")
end

-------------------------------------------------------------------------------
-- UPDATE LOOP
-------------------------------------------------------------------------------

function widget:Update(dt)
    -- Always rebuild display list if dirty, so placeholders render before data is ready
    if masterDirty then
        rebuildMasterList()
    end

    if not chartsReady then
        local gameTime = Spring.GetGameSeconds()
        if gameTime - lastUpdateTime >= UPDATE_INTERVAL then
            lastUpdateTime = gameTime
            teamID = teamID or Spring.GetMyTeamID()
            if initAllyTeams() then
                charts.allyArmy:rebuildMultiTeamSeries()
                charts.allyBuildPower:rebuildMultiTeamSeries()
                seedArmyValues()
                seedBuildPower()
                seedUnitCount()
                chartsReady    = true
                lastUpdateTime = -UPDATE_INTERVAL
                masterDirty    = true
            end
        end
        return
    end

    local gameTime = Spring.GetGameSeconds()
    if gameTime - lastUpdateTime >= UPDATE_INTERVAL then
        lastUpdateTime = gameTime
        if not teamID then
            teamID = Spring.GetMyTeamID()
            if not teamID then return end
        end

        local m_level, m_storage, m_pull, m_income, m_expense = Spring.GetTeamResources(teamID, "metal")
        local e_level, e_storage, e_pull, e_income, e_expense = Spring.GetTeamResources(teamID, "energy")
        myTeamStats.metalIncome  = m_income  or 0
        myTeamStats.metalUsage   = m_expense or 0
        myTeamStats.energyIncome = e_income  or 0
        myTeamStats.energyUsage  = e_expense or 0

        local totalBP = 0
        for uid, builderData in pairs(builderUnits) do
            totalBP = totalBP + builderData.bp
        end
        myTeamStats.totalBP = totalBP

        local pull    = m_pull    or 0
        local expense = m_expense or 0
        if pull > 1 then
            local ratio = expense / pull
            if ratio < 0.60 then
                myTeamStats.metalStall = 2
            elseif ratio < 0.98 then
                myTeamStats.metalStall = 1
            else
                myTeamStats.metalStall = 0
            end
        else
            myTeamStats.metalStall = 0
        end

        if Spring.GetTeamDamageStats then
            local dmg_dealt, dmg_taken = Spring.GetTeamDamageStats(teamID)
            myTeamStats.damageDealt = dmg_dealt or 0
            myTeamStats.damageTaken = dmg_taken or 0
        end

        local uKilled, uDied = Spring.GetTeamUnitStats(teamID)
        if uKilled then myTeamStats.kills  = uKilled end
        if uDied   then myTeamStats.losses = uDied   end

        if type(allyTeams) == "table" then
            for tid, teamData in pairs(allyTeams) do
                local _, _, _, tm_income = Spring.GetTeamResources(tid, "metal")
                local _, _, _, te_income = Spring.GetTeamResources(tid, "energy")
                teamData.metalIncome  = tm_income or 0
                teamData.energyIncome = te_income or 0
            end
        end

        for _, chart in pairs(charts) do chart:addDataPoint() end
        for _, card  in pairs(statCards) do card:setValue(card.getValue()) end

        masterDirty = true
    end
end

-------------------------------------------------------------------------------
-- GAME FRAME — build efficiency sampler
-------------------------------------------------------------------------------

function widget:GameFrame(n)
    if not chartsReady then return end
    buildEffTickCounter = buildEffTickCounter + 1
    if buildEffTickCounter >= BUILD_EFF_TICKS_PER_SAMPLE then
        buildEffTickCounter = 0
        pushBuildEffSample(sampleBuildEfficiency())
    end
end

-------------------------------------------------------------------------------
-- GAME START
-------------------------------------------------------------------------------

function widget:GameStart()
    chartsReady = false
    lastUpdateTime = 0
    myTeamStats.armyValue      = 0; myTeamStats.unitCount      = 0
    myTeamStats.kills          = 0; myTeamStats.losses         = 0
    myTeamStats.metalLost      = 0; myTeamStats.damageDealt    = 0
    myTeamStats.damageTaken    = 0; myTeamStats.buildEfficiency = 0
    myTeamStats.metalStall     = 0; myTeamStats.totalBP        = 0
    builderUnits = {}
    resetBuildEffSamples()
    for tid, teamData in pairs(allyTeams) do
        teamData.armyValue = 0; teamData.buildPower = 0
    end
    masterDirty = true
    Spring.Echo("BAR Charts: Game started, waiting for team data...")
end

-------------------------------------------------------------------------------
-- RENDERING
-------------------------------------------------------------------------------

function widget:DrawScreen()
    if not chartsEnabled then return end
    if masterDisplayList then gl.CallList(masterDisplayList) end
    if hoverDisplayList  then gl.CallList(hoverDisplayList)  end
end

-------------------------------------------------------------------------------
-- INPUT HANDLING
-------------------------------------------------------------------------------

function widget:KeyPress(key, mods, isRepeat)
    if key == Spring.GetKeyCode("f9") then
        chartsEnabled = not chartsEnabled
        Spring.Echo("BAR Charts: " .. (chartsEnabled and "Enabled" or "Disabled"))
        masterDirty = true
        return true
    end
    return false
end

local function findHitElement(mx, my)
    -- In edit mode, allow interaction with disabled charts/cards too
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
    -- Gate: all chart mouse interactions require edit mode
    if not chartsEnabled or not chartsInteractive then return false end

    local elem, kind = findHitElement(mx, my)
    if not elem then return false end
    if button == 1 then
        elem.isDragging = true
        elem.dragStartX = mx - elem.x
        elem.dragStartY = my - elem.y
        return true
    elseif button == 3 then
        -- Right-click toggles enabled state when in edit mode
        elem.enabled = not elem.enabled
        masterDirty = true
        rebuildHoverList()
        return true
    end
    return false
end

function widget:MouseRelease(mx, my, button)
    if not chartsEnabled or not chartsInteractive then return false end

    if button == 1 then
        for _, card in pairs(statCards) do
            if card.isDragging then card.isDragging = false; return true end
        end
        for _, chart in pairs(charts) do
            if chart.isDragging then chart.isDragging = false; return true end
        end
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if not chartsEnabled then return false end

    -- Drag is gated behind interactive mode; only hover detection proceeds in locked mode
    if chartsInteractive then
        for _, card in pairs(statCards) do
            if card.isDragging then
                card.x = mx - card.dragStartX
                card.y = my - card.dragStartY
                masterDirty = true
                return true
            end
        end
        for _, chart in pairs(charts) do
            if chart.isDragging then
                chart.x = mx - chart.dragStartX
                chart.y = my - chart.dragStartY
                masterDirty = true
                return true
            end
        end
    end

    -- Hover highlight updates (visual only, harmless in locked mode)
    local hoverChanged = false
    for id, card in pairs(statCards) do
        local h = chartsInteractive and card:isMouseOver(mx, my) or false
        if h ~= card.isHovered then hoverChanged = true end
        card.isHovered = h
    end
    for id, chart in pairs(charts) do
        local h = chartsInteractive and chart:isMouseOver(mx, my) or false
        if h ~= chart.isHovered then hoverChanged = true end
        chart.isHovered = h
    end
    if hoverChanged then rebuildHoverList() end

    -- In locked mode, never consume mouse events (game input passes through)
    if not chartsInteractive then return false end

    for _, card in pairs(statCards) do if card.isHovered then return true end end
    for _, chart in pairs(charts) do if chart.isHovered then return true end end
    return false
end

function widget:MouseWheel(up, value)
    -- Scroll is gated behind interactive mode
    if not chartsEnabled or not chartsInteractive then return false end

    local mx, my = Spring.GetMouseState()
    for _, card in pairs(statCards) do
        if card:isMouseOver(mx, my) then
            card.scale = up and math.min(2.0, card.scale + 0.1)
                            or  math.max(0.5, card.scale - 0.1)
            masterDirty = true
            return true
        end
    end
    for _, chart in pairs(charts) do
        if chart:isMouseOver(mx, my) then
            chart.scale = up and math.min(2.0, chart.scale + 0.1)
                             or  math.max(0.5, chart.scale - 0.1)
            masterDirty = true
            return true
        end
    end
    return false
end

function widget:ViewResize()
    local oldVsx, oldVsy = vsx, vsy
    vsx, vsy = Spring.GetViewGeometry()
    local ratioX = vsx / oldVsx
    local ratioY = vsy / oldVsy
    for _, chart in pairs(charts) do
        chart.x = chart.x * ratioX
        chart.y = chart.y * ratioY
    end
    for _, card in pairs(statCards) do
        card.x = card.x * ratioX
        card.y = card.y * ratioY
    end
    masterDirty = true
    rebuildHoverList()
end

function widget:TextCommand(command)
    if command == "barcharts save" then
        saveConfig()
        return true
    elseif command == "barcharts reset" then
        os.remove(CONFIG_FILE)
        Spring.Echo("BAR Charts: Configuration reset - restart widget to apply")
        return true
    elseif command == "barcharts edit" then
        -- Allow toggling edit mode from chat as a fallback (no RmlUI dependency)
        onToggleClick(nil)
        return true
    elseif command == "barcharts debug" then
        Spring.Echo("=== BAR Charts Debug ===")
        Spring.Echo("vsx=" .. tostring(vsx) .. " vsy=" .. tostring(vsy))
        Spring.Echo("chartsEnabled=" .. tostring(chartsEnabled) .. " chartsReady=" .. tostring(chartsReady))
        Spring.Echo("chartsInteractive=" .. tostring(chartsInteractive) .. " (edit mode: " .. (chartsInteractive and "ON" or "OFF/LOCKED") .. ")")
        Spring.Echo("masterDirty=" .. tostring(masterDirty) .. " masterDisplayList=" .. tostring(masterDisplayList))
        Spring.Echo(string.format("buildEfficiency=%.1f%% (rolling avg over %d/%d samples)",
            myTeamStats.buildEfficiency, buildEffSampleCount, BUILD_EFF_WINDOW_SIZE))
        Spring.Echo("-- CARDS --")
        for id, card in pairs(statCards) do
            Spring.Echo(string.format("  %s: x=%.0f y=%.0f scale=%.1f visible=%s enabled=%s",
                id, card.x, card.y, card.scale, tostring(card.visible), tostring(card.enabled)))
        end
        Spring.Echo("-- CHARTS --")
        for _, chart in pairs(charts) do
            Spring.Echo(string.format("  %s: x=%.0f y=%.0f scale=%.1f visible=%s enabled=%s",
                chart.id, chart.x, chart.y, chart.scale, tostring(chart.visible), tostring(chart.enabled)))
        end
        return true
    elseif command == "barcharts bp" then
        Spring.Echo("=== Builder Efficiency Diagnostic ===")
        Spring.Echo(string.format("  Rolling average: %.1f%% (%d/%d samples, window=%ds)",
            myTeamStats.buildEfficiency, buildEffSampleCount, BUILD_EFF_WINDOW_SIZE,
            BUILD_EFF_WINDOW_SIZE * (BUILD_EFF_TICKS_PER_SAMPLE / 30)))
        local totalBP      = 0
        local builderCount = 0
        local effSum       = 0
        local effCount     = 0
        for uid, builderData in pairs(builderUnits) do
            builderCount = builderCount + 1
            local bp    = builderData.bp
            local defID = builderData.defID
            totalBP = totalBP + bp
            local targetUnitID = Spring.GetUnitIsBuilding(uid)
            local bud = defID and UnitDefs[defID]
            local targetDefID = targetUnitID and Spring.GetUnitDefID(targetUnitID)
            local maxMetal = (defID and targetDefID and maxMetalUseCache[defID]) and maxMetalUseCache[defID][targetDefID] or 0
            local _, mPull = Spring.GetUnitResources(uid, "metal")
            local mUsing = mPull or 0
            local ratio = (maxMetal > 0) and math.min(1.0, mUsing / maxMetal) or nil
            Spring.Echo(string.format("    uid=%d  name=%s  bp=%.1f  building=%s  maxMetal=%.2f  using=%.2f  ratio=%s",
                uid, bud and bud.name or "?", bp, tostring(targetUnitID ~= nil),
                maxMetal, mUsing, ratio and string.format("%.0f%%", ratio * 100) or "idle"))
            if ratio then
                effSum   = effSum   + ratio
                effCount = effCount + 1
            end
        end
        local instantEff = effCount > 0 and (effSum / effCount * 100) or (totalBP > 0 and 100 or 0)
        Spring.Echo(string.format("  builders=%d  totalBP=%.1f  active=%d  instant=%.1f%%  rolling=%.1f%%",
            builderCount, totalBP, effCount, instantEff, myTeamStats.buildEfficiency))
        return true
    end
    return false
end

function widget:Shutdown()
    saveConfig()
    shutdownRmlToggle()
    freeLists()
    Spring.Echo("BAR Charts: Shutdown")
end
