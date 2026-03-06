--[[
═══════════════════════════════════════════════════════════════════════════
    BAR CHARTS WIDGET
    
    In-game overlay charts matching the streaming system aesthetic.
    Displays real-time resource and combat statistics as animated line charts,
    plus compact numeric stat cards.
    
    Features:
    - Metal Income/Usage chart
    - Energy Income/Usage chart  
    - Damage Dealt/Taken chart
    - Army Value chart
    - K/D Ratio chart
    - Build Efficiency chart (NEW)
    - Team Army Values chart (multi-team)
    - Team Build Power chart (multi-team)
    - Numeric stat cards (Army Value, Units, Kills, Losses, DMG Dealt/Taken, Metal Lost)
    - Smooth animations with lerp interpolation
    - Draggable, scalable, toggleable charts AND cards
    - Auto-save/load layout on exit/start
    - Cyber/tech aesthetic matching streaming overlay
    
    Controls:
    - F9: Toggle all charts on/off
    - Click+Drag: Move charts/cards
    - Mouse Wheel over chart/card: Scale size
    - Right-click: Toggle individual chart/card visibility
    
    Commands:
    - /barcharts save   : Save layout immediately
    - /barcharts reset  : Delete config and restore defaults
    
    Installation:
    Place in: /LuaUI/Widgets/
    Enable in-game via F11 menu
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

local chartsEnabled = true
local chartsReady   = false

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

local ANIM_DURATION   = 0.4
local HISTORY_SIZE    = 60
local UPDATE_INTERVAL = 10

local CHART_WIDTH  = 300
local CHART_HEIGHT = 180
local PADDING      = {left = 40, right = 15, top = 15, bottom = 25}

-- Stat card dimensions
local CARD_WIDTH  = 140
local CARD_HEIGHT = 70

-------------------------------------------------------------------------------
-- GLOBAL STATE
-------------------------------------------------------------------------------

local charts        = {}
local statCards     = {}   -- NEW: numeric stat cards
local lastUpdateTime = 0
local teamID        = nil
local allyTeamID    = nil
local allyTeams     = {}

local myTeamStats = {
    metalIncome  = 0,
    metalUsage   = 0,
    energyIncome = 0,
    energyUsage  = 0,
    damageDealt  = 0,
    damageTaken  = 0,
    armyValue    = 0,
    unitCount    = 0,
    kills        = 0,
    losses       = 0,
    metalLost    = 0,
    buildEfficiency     = 0,
    unitsMetalCompleted = 0,
    lastUnitsMetalCompleted = 0,
}

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------

local function easeOutCubic(t)
    return 1 - math.pow(1 - t, 3)
end

local function formatNumber(n)
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 10000 then
        return string.format("%.0fK", n / 1000)
    else
        return string.format("%d", math.floor(n + 0.5))
    end
end

local function formatYAxis(n, chartType)
    if chartType == "ratio" or chartType == "percent" then
        return string.format("%.0f%%", n)
    else
        return formatNumber(n)
    end
end

local function drawRoundedRect(x, y, w, h, r, filled)
    if filled then
        gl.BeginEnd(GL.QUADS, function()
            gl.Vertex(x + r, y)
            gl.Vertex(x + w - r, y)
            gl.Vertex(x + w - r, y + h)
            gl.Vertex(x + r, y + h)

            gl.Vertex(x, y + r)
            gl.Vertex(x + w, y + r)
            gl.Vertex(x + w, y + h - r)
            gl.Vertex(x, y + h - r)
        end)

        local segments = 6
        for i = 0, segments do
            local angle = (math.pi / 2) * (i / segments)

            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + r, y + r)
                local x1 = x + r - r * math.cos(angle)
                local y1 = y + r - r * math.sin(angle)
                gl.Vertex(x1, y1)
                angle = (math.pi / 2) * ((i + 1) / segments)
                local x2 = x + r - r * math.cos(angle)
                local y2 = y + r - r * math.sin(angle)
                if i < segments then gl.Vertex(x2, y2) end
            end)

            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + w - r, y + r)
                angle = (math.pi / 2) * (i / segments)
                local x1 = x + w - r + r * math.sin(angle)
                local y1 = y + r - r * math.cos(angle)
                gl.Vertex(x1, y1)
                angle = (math.pi / 2) * ((i + 1) / segments)
                local x2 = x + w - r + r * math.sin(angle)
                local y2 = y + r - r * math.cos(angle)
                if i < segments then gl.Vertex(x2, y2) end
            end)

            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + w - r, y + h - r)
                angle = (math.pi / 2) * (i / segments)
                local x1 = x + w - r + r * math.cos(angle)
                local y1 = y + h - r + r * math.sin(angle)
                gl.Vertex(x1, y1)
                angle = (math.pi / 2) * ((i + 1) / segments)
                local x2 = x + w - r + r * math.cos(angle)
                local y2 = y + h - r + r * math.sin(angle)
                if i < segments then gl.Vertex(x2, y2) end
            end)

            gl.BeginEnd(GL.TRIANGLES, function()
                gl.Vertex(x + r, y + h - r)
                angle = (math.pi / 2) * (i / segments)
                local x1 = x + r - r * math.sin(angle)
                local y1 = y + h - r + r * math.cos(angle)
                gl.Vertex(x1, y1)
                angle = (math.pi / 2) * ((i + 1) / segments)
                local x2 = x + r - r * math.sin(angle)
                local y2 = y + h - r + r * math.cos(angle)
                if i < segments then gl.Vertex(x2, y2) end
            end)
        end
    else
        gl.BeginEnd(GL.LINE_LOOP, function()
            gl.Vertex(x + r, y)
            gl.Vertex(x + w - r, y)
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + w - r + r * math.sin(angle), y + r - r * math.cos(angle))
            end
            gl.Vertex(x + w, y + r)
            gl.Vertex(x + w, y + h - r)
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + w - r + r * math.cos(angle), y + h - r + r * math.sin(angle))
            end
            gl.Vertex(x + w - r, y + h)
            gl.Vertex(x + r, y + h)
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + r - r * math.sin(angle), y + h - r + r * math.cos(angle))
            end
            gl.Vertex(x, y + h - r)
            gl.Vertex(x, y + r)
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + r - r * math.cos(angle), y + r - r * math.sin(angle))
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- STAT CARD CLASS  (NEW)
-------------------------------------------------------------------------------

local StatCard = {}
StatCard.__index = StatCard

function StatCard.new(id, label, icon, x, y, color, getValue)
    local self = setmetatable({}, StatCard)

    self.id         = id
    self.label      = label
    self.icon       = icon
    self.x          = x
    self.y          = y
    self.scale      = 1.0
    self.enabled    = true
    self.visible    = true
    self.color      = color  -- accent color for the value text
    self.getValue   = getValue

    self.displayValue = 0
    self.prevValue    = 0
    self.targetValue  = 0
    self.animProgress = 1.0
    self.animStart    = 0

    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    self.isHovered  = false

    return self
end

function StatCard:setTarget(value)
    self.prevValue    = self.displayValue
    self.targetValue  = value
    self.animProgress = 0.0
    self.animStart    = os.clock()
end

function StatCard:update(dt)
    if self.animProgress < 1.0 then
        local elapsed = os.clock() - self.animStart
        self.animProgress = math.min(1.0, elapsed / ANIM_DURATION)
        local ease = easeOutCubic(self.animProgress)
        self.displayValue = self.prevValue + (self.targetValue - self.prevValue) * ease
    end
end

function StatCard:draw()
    if not self.enabled or not self.visible then return end

    local w = CARD_WIDTH
    local h = CARD_HEIGHT
    local c = self.color

    gl.PushMatrix()
    gl.Translate(self.x, self.y, 0)
    gl.Scale(self.scale, self.scale, 1)

    -- Background
    gl.Color(COLOR.bg[1], COLOR.bg[2], COLOR.bg[3], COLOR.bg[4])
    drawRoundedRect(0, 0, w, h, 4, true)

    -- Border (hot or normal)
    local bc = self.isHovered and COLOR.borderHot or COLOR.border
    gl.Color(bc[1], bc[2], bc[3], bc[4])
    gl.LineWidth(1)
    drawRoundedRect(0.5, 0.5, w - 1, h - 1, 4, false)

    -- Left accent bar
    gl.Color(c[1], c[2], c[3], 0.7)
    gl.BeginEnd(GL.QUADS, function()
        gl.Vertex(0,   4)
        gl.Vertex(3,   4)
        gl.Vertex(3,   h - 4)
        gl.Vertex(0,   h - 4)
    end)

    -- Icon + label (top)
    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4])
    gl.Text(self.icon .. "  " .. self.label, 10, h - 18, 9, "o")

    -- Value (large, centered vertically in lower 2/3)
    gl.Color(c[1], c[2], c[3], 1.0)
    local valueStr = formatNumber(math.floor(self.displayValue + 0.5))
    gl.Text(valueStr, w / 2 + 5, 10, 20, "co")

    gl.PopMatrix()
end

function StatCard:isMouseOver(mx, my)
    return mx >= self.x
       and mx <= self.x + CARD_WIDTH  * self.scale
       and my >= self.y
       and my <= self.y + CARD_HEIGHT * self.scale
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

    self.history = {}
    for i = 1, #series do self.history[i] = {} end

    self.displayData = {}
    for i = 1, #series do self.displayData[i] = {} end

    self.animProgress = 1.0
    self.animStartTime = 0
    self.prevData   = {}
    self.targetData = {}

    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    self.isHovered  = false

    return self
end

function Chart:rebuildMultiTeamSeries()
    if not self.multiTeam then return end

    self.history     = {}
    self.displayData = {}
    self.series      = {}

    Spring.Echo("rebuild: allyTeams type=" .. type(allyTeams))
    local c = 0
    for tid, _ in pairs(allyTeams) do
        c = c + 1
        Spring.Echo("  rebuild sees tid=" .. tostring(tid))
    end
    Spring.Echo("  rebuild count=" .. c)

    local idx = 1
    if type(allyTeams) == "table" then
        for tid, teamData in pairs(allyTeams) do
            local seriesConfig = {
                label   = teamData.playerName,
                color   = teamData.color,
                teamID  = tid,
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

            self.series[idx]      = seriesConfig
            self.history[idx]     = {}
            self.displayData[idx] = {}
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

    self.animProgress  = 0.0
    self.animStartTime = os.clock()

    for i = 1, #self.series do
        self.prevData[i]   = {}
        self.targetData[i] = {}
        for j, v in ipairs(self.displayData[i]) do self.prevData[i][j]   = v end
        for j, v in ipairs(self.history[i])     do self.targetData[i][j] = v end
    end
end

function Chart:update(dt)
    if self.animProgress < 1.0 then
        local elapsed = os.clock() - self.animStartTime
        self.animProgress = math.min(1.0, elapsed / ANIM_DURATION)
        local ease = easeOutCubic(self.animProgress)

        for i = 1, #self.series do
            local prev   = self.prevData[i]   or {}
            local target = self.targetData[i] or {}
            for j = 1, math.max(#prev, #target) do
                local fromVal = prev[j]   or target[j] or 0
                local toVal   = target[j] or fromVal
                self.displayData[i][j] = fromVal + (toVal - fromVal) * ease
            end
        end
    end
end

function Chart:draw()
    if not self.enabled or not self.visible then return end

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

    gl.Color(COLOR.bg[1], COLOR.bg[2], COLOR.bg[3], COLOR.bg[4])
    drawRoundedRect(0, 0, w, h, 4, true)

    local bc = self.isHovered and COLOR.borderHot or COLOR.border
    gl.Color(bc[1], bc[2], bc[3], bc[4])
    gl.LineWidth(1)
    drawRoundedRect(0.5, 0.5, w - 1, h - 1, 4, false)

    local hasData = false
    for i = 1, #self.series do
        if #self.displayData[i] >= 2 then hasData = true; break end
    end

    if not hasData then
        self:drawNoData(cX, cY, cW, cH)
        self:drawHeader(w, h)
        gl.PopMatrix()
        return
    end

    local allValues = {}
    for i = 1, #self.series do
        for _, v in ipairs(self.displayData[i]) do
            if v and not (v ~= v) then table.insert(allValues, v) end
        end
    end

    local minV    = math.min(unpack(allValues))
    local maxV    = math.max(unpack(allValues))
    
    -- Special handling for percent charts
    if self.chartType == "percent" then
        minV = 0
        maxV = math.max(100, maxV)
    else
        local span    = maxV - minV
        local rangePad = span > 0 and span * 0.12 or math.max(maxV * 0.1, 100)
        minV = math.max(0, minV - rangePad)
        maxV = maxV + rangePad
    end
    
    local range = maxV - minV
    if range == 0 then range = 1 end

    for i = 0, 4 do
        local v    = minV + (range * i / 4)
        local yPos = cY + (cH * i / 4)

        local gc = (i == 0) and COLOR.gridBase or COLOR.grid
        gl.Color(gc[1], gc[2], gc[3], gc[4])
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(cX,      yPos)
            gl.Vertex(cX + cW, yPos)
        end)

        gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4])
        gl.Text(formatYAxis(v, self.chartType), cX - 5, yPos - 4, 9, "ro")
    end

    local function toX(idx, total)
        return cX + ((idx - 1) / (total - 1)) * cW
    end

    local function toY(value)
        return cY + ((value - minV) / range) * cH
    end

    for seriesIdx, s in ipairs(self.series) do
        local data = self.displayData[seriesIdx]
        if #data >= 2 then
            local color = s.color

            gl.Color(color[1], color[2], color[3], 1.0)
            gl.LineWidth(2.0)
            gl.BeginEnd(GL.LINE_STRIP, function()
                for i, value in ipairs(data) do
                    if value and not (value ~= value) then
                        gl.Vertex(toX(i, #data), toY(value))
                    end
                end
            end)

            gl.Color(color[1], color[2], color[3], 0.15)
            gl.BeginEnd(GL.TRIANGLE_STRIP, function()
                for i, value in ipairs(data) do
                    if value and not (value ~= value) then
                        local x = toX(i, #data)
                        gl.Vertex(x, cY)
                        gl.Vertex(x, toY(value))
                    end
                end
            end)

            if #data > 0 then
                local lastValue = data[#data]
                if lastValue and not (lastValue ~= lastValue) then
                    gl.Color(color[1], color[2], color[3], 0.8)
                    gl.PointSize(6)
                    gl.BeginEnd(GL.POINTS, function()
                        gl.Vertex(toX(#data, #data), toY(lastValue))
                    end)

                    gl.Color(color[1], color[2], color[3], 1.0)
                    local valueText
                    if self.chartType == "percent" then
                        valueText = string.format("%.0f%%", lastValue)
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

    self:drawHeader(w, h)
    gl.PopMatrix()
end

function Chart:drawHeader(w, h)
    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], COLOR.muted[4])
    gl.Text(self.icon .. "  " .. self.label, PADDING.left + 2, h - PADDING.top - 10, 10, "o")
end

function Chart:drawNoData(cX, cY, cW, cH)
    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.25)
    gl.Text("— awaiting data —", cX + cW / 2, cY + cH / 2, 10, "c")
end

function Chart:isMouseOver(mx, my)
    return mx >= self.x
       and mx <= self.x + self.width  * self.scale
       and my >= self.y
       and my <= self.y + self.height * self.scale
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
    for tid, teamData in pairs(allyTeams) do
        teamData.buildPower = 0
        local tUnits = Spring.GetTeamUnits(tid) or {}
        for _, uid in ipairs(tUnits) do
            local ud = UnitDefs[Spring.GetUnitDefID(uid) or 0]
            if ud and ud.isBuilder then
                teamData.buildPower = teamData.buildPower + (ud.buildSpeed or 0)
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
    if unitTeam == teamID then
        myTeamStats.armyValue = myTeamStats.armyValue + cost
        myTeamStats.unitCount = myTeamStats.unitCount + 1
        -- Track total metal value of units completed for build efficiency
        myTeamStats.unitsMetalCompleted = myTeamStats.unitsMetalCompleted + cost
    end
    if allyTeams[unitTeam] then
        allyTeams[unitTeam].armyValue = allyTeams[unitTeam].armyValue + cost
    end

    local ud = UnitDefs[unitDefID]
    if ud and ud.isBuilder and allyTeams[unitTeam] then
        allyTeams[unitTeam].buildPower = allyTeams[unitTeam].buildPower + (ud.buildSpeed or 0)
    end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam)
    local cost = unitMetalCost(unitDefID)
    if unitTeam == teamID then
        myTeamStats.armyValue = math.max(0, myTeamStats.armyValue - cost)
        myTeamStats.unitCount = math.max(0, myTeamStats.unitCount - 1)
        myTeamStats.losses    = myTeamStats.losses + 1
        myTeamStats.metalLost = myTeamStats.metalLost + cost
    end
    if allyTeams[unitTeam] then
        allyTeams[unitTeam].armyValue = math.max(0, allyTeams[unitTeam].armyValue - cost)
    end

    -- Credit kill to attacker's team
    if attackerTeam == teamID and attackerTeam ~= unitTeam then
        myTeamStats.kills = myTeamStats.kills + 1
    end

    local ud = UnitDefs[unitDefID]
    if ud and ud.isBuilder and allyTeams[unitTeam] then
        allyTeams[unitTeam].buildPower = math.max(0, allyTeams[unitTeam].buildPower - (ud.buildSpeed or 0))
    end
end

function widget:UnitGiven(unitID, unitDefID, newTeam, oldTeam)
    local cost = unitMetalCost(unitDefID)

    if oldTeam == teamID then
        myTeamStats.armyValue = math.max(0, myTeamStats.armyValue - cost)
        myTeamStats.unitCount = math.max(0, myTeamStats.unitCount - 1)
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
        if allyTeams[oldTeam] then
            allyTeams[oldTeam].buildPower = math.max(0, allyTeams[oldTeam].buildPower - bp)
        end
        if allyTeams[newTeam] then
            allyTeams[newTeam].buildPower = allyTeams[newTeam].buildPower + bp
        end
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
        local r, g, b   = Spring.GetTeamColor(tid)
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
-- BUILD POWER TRACKING
-------------------------------------------------------------------------------

local function getCurrentBuildPower()
    local totalBuildPower = 0
    if not teamID then return 0 end
    
    local myUnits = Spring.GetTeamUnits(teamID) or {}
    for _, uid in ipairs(myUnits) do
        local unitDefID = Spring.GetUnitDefID(uid)
        if unitDefID then
            local ud = UnitDefs[unitDefID]
            if ud and ud.isBuilder then
                totalBuildPower = totalBuildPower + (ud.buildSpeed or 0)
            end
        end
    end
    
    return totalBuildPower
end

-------------------------------------------------------------------------------
-- CONFIG SAVE / LOAD
-------------------------------------------------------------------------------

local function saveConfig()
    local config = { version = "1.0", enabled = chartsEnabled, charts = {}, cards = {} }

    for _, chart in pairs(charts) do
        config.charts[chart.id] = {
            x       = chart.x,
            y       = chart.y,
            scale   = chart.scale,
            visible = chart.visible,
            enabled = chart.enabled,
        }
    end

    for id, card in pairs(statCards) do
        config.cards[id] = {
            x       = card.x,
            y       = card.y,
            scale   = card.scale,
            visible = card.visible,
            enabled = card.enabled,
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
    return result.charts or {}, result.cards or {}
end

local savedChartConfig = nil

-------------------------------------------------------------------------------
-- INITIALIZATION
-------------------------------------------------------------------------------

function widget:Initialize()
    Spring.Echo("BAR Charts: Initialize START")
    vsx, vsy     = Spring.GetViewGeometry()
    teamID       = Spring.GetMyTeamID()
    allyTeamID   = Spring.GetMyAllyTeamID()
    chartsReady  = false

    charts   = {}
    statCards = {}

    -- ── LINE CHARTS ──────────────────────────────────────────────────────────

    charts.metal = Chart.new("chart-metal", "METAL", "⚙", vsx - 350, vsy - 230, "dual", {
        { label = "Income", color = COLOR.accent,  getValue = function() return myTeamStats.metalIncome end },
        { label = "Usage",  color = COLOR.accent2, getValue = function() return myTeamStats.metalUsage  end },
    }, false)

    charts.energy = Chart.new("chart-energy", "ENERGY", "⚡", vsx - 660, vsy - 230, "dual", {
        { label = "Income", color = COLOR.accent,  getValue = function() return myTeamStats.energyIncome end },
        { label = "Usage",  color = COLOR.accent2, getValue = function() return myTeamStats.energyUsage  end },
    }, false)

    charts.damage = Chart.new("chart-damage", "DAMAGE", "✕", vsx - 970, vsy - 230, "dual", {
        { label = "Dealt", color = COLOR.success, getValue = function() return myTeamStats.damageDealt end },
        { label = "Taken", color = COLOR.danger,  getValue = function() return myTeamStats.damageTaken end },
    }, false)

    charts.army = Chart.new("chart-army", "ARMY VALUE", "⚙", vsx - 350, vsy - 430, "single", {
        { label = "Value", color = COLOR.accent, getValue = function() return myTeamStats.armyValue end },
    }, false)

    charts.kd = Chart.new("chart-kd", "K/D RATIO", "✕", vsx - 660, vsy - 430, "ratio", {
        { label = "Ratio", color = COLOR.success, getValue = function()
            local k, d = myTeamStats.kills, myTeamStats.losses
            return d == 0 and (k > 0 and 5 or 0) or math.min(5, k / d)
        end },
    }, false)

    -- NEW: Build Efficiency Chart
    charts.buildEfficiency = Chart.new("chart-build-efficiency", "BUILD EFFICIENCY", "🔧", vsx - 970, vsy - 430, "percent", {
        { label = "Efficiency", color = COLOR.success, getValue = function() 
            return myTeamStats.buildEfficiency 
        end },
    }, false)

    charts.allyArmy       = Chart.new("chart-ally-army",       "TEAM ARMY", "⚙",  vsx - 1280, vsy - 430, "multi", {}, true)
    charts.allyBuildPower = Chart.new("chart-ally-buildpower", "TEAM BP",   "🔧", vsx - 1280, vsy - 230, "multi", {}, true)

    -- ── NUMERIC STAT CARDS ───────────────────────────────────────────────────
    local cardY    = vsy - 650
    local cardStep = 80
    local col1X    = vsx - 350
    local col2X    = vsx - 200

    statCards["card-army-value"] = StatCard.new(
        "card-army-value", "ARMY VALUE", "⚙",
        col1X, cardY,
        COLOR.accent,
        function() return myTeamStats.armyValue end
    )

    statCards["card-unit-count"] = StatCard.new(
        "card-unit-count", "UNITS", "▣",
        col2X, cardY,
        COLOR.accent,
        function() return myTeamStats.unitCount end
    )

    statCards["card-kills"] = StatCard.new(
        "card-kills", "KILLS", "✕",
        col1X, cardY - cardStep,
        COLOR.success,
        function() return myTeamStats.kills end
    )

    statCards["card-losses"] = StatCard.new(
        "card-losses", "LOSSES", "↓",
        col2X, cardY - cardStep,
        COLOR.danger,
        function() return myTeamStats.losses end
    )

    statCards["card-dmg-dealt"] = StatCard.new(
        "card-dmg-dealt", "DMG DEALT", "▲",
        col1X, cardY - cardStep * 2,
        COLOR.success,
        function() return myTeamStats.damageDealt end
    )

    statCards["card-dmg-taken"] = StatCard.new(
        "card-dmg-taken", "DMG TAKEN", "▼",
        col2X, cardY - cardStep * 2,
        COLOR.danger,
        function() return myTeamStats.damageTaken end
    )

    statCards["card-metal-lost"] = StatCard.new(
        "card-metal-lost", "METAL LOST", "◆",
        col1X, cardY - cardStep * 3,
        COLOR.gold,
        function() return myTeamStats.metalLost end
    )

    -- ── APPLY SAVED CONFIG ───────────────────────────────────────────────────

    local chartCfg, cardCfg = loadConfig()

    local chartById = {}
    for _, chart in pairs(charts) do
        chartById[chart.id] = chart
    end
    for id, cfg in pairs(type(chartCfg) == "table" and chartCfg or {}) do
        local chart = chartById[id]
        if chart and type(cfg) == "table" then
            chart.x     = cfg.x     or chart.x
            chart.y     = cfg.y     or chart.y
            chart.scale = cfg.scale or chart.scale
            if cfg.visible ~= nil then chart.visible = cfg.visible end
            if cfg.enabled ~= nil then chart.enabled = cfg.enabled end
        end
    end

    for id, cfg in pairs(type(cardCfg) == "table" and cardCfg or {}) do
        local card = statCards[id]
        if card and type(cfg) == "table" then
            card.x     = cfg.x     or card.x
            card.y     = cfg.y     or card.y
            card.scale = cfg.scale or card.scale
            if cfg.visible ~= nil then card.visible = cfg.visible end
            if cfg.enabled ~= nil then card.enabled = cfg.enabled end
        end
    end

    Spring.Echo("BAR Charts: Initialized, waiting for team data...")
end

-------------------------------------------------------------------------------
-- UPDATE LOOP
-------------------------------------------------------------------------------

function widget:Update(dt)
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
            end
        end
        return
    end

    for _, chart in pairs(charts) do
        chart:update(dt)
    end
    for _, card in pairs(statCards) do
        card:update(dt)
    end

    local gameTime = Spring.GetGameSeconds()
    if gameTime - lastUpdateTime >= UPDATE_INTERVAL then
        lastUpdateTime = gameTime

        if not teamID then
            teamID = Spring.GetMyTeamID()
            if not teamID then return end
        end

        -- My team resource stats
        local m_inc, m_use = Spring.GetTeamResourceStats(teamID, "metal")
        local e_inc, e_use = Spring.GetTeamResourceStats(teamID, "energy")
        myTeamStats.metalIncome  = m_inc or 0
        myTeamStats.metalUsage   = m_use or 0
        myTeamStats.energyIncome = e_inc or 0
        myTeamStats.energyUsage  = e_use or 0

        if Spring.GetTeamDamageStats then
            local dmg_dealt, dmg_taken = Spring.GetTeamDamageStats(teamID)
            myTeamStats.damageDealt = dmg_dealt or 0
            myTeamStats.damageTaken = dmg_taken or 0
        end

        -- Calculate build efficiency
        local currentBuildPower = getCurrentBuildPower()
        local theoreticalMax = currentBuildPower * UPDATE_INTERVAL
        local actualBuilt = myTeamStats.unitsMetalCompleted - myTeamStats.lastUnitsMetalCompleted
        
        if theoreticalMax > 0 then
            myTeamStats.buildEfficiency = math.min(100, (actualBuilt / theoreticalMax) * 100)
        else
            myTeamStats.buildEfficiency = 0
        end
        
        myTeamStats.lastUnitsMetalCompleted = myTeamStats.unitsMetalCompleted

        -- Ally team resource stats
        if type(allyTeams) == "table" then
            for tid, teamData in pairs(allyTeams) do
                local tm_inc, tm_use = Spring.GetTeamResourceStats(tid, "metal")
                local te_inc, te_use = Spring.GetTeamResourceStats(tid, "energy")
                teamData.metalIncome  = tm_inc or 0
                teamData.energyIncome = te_inc or 0
            end
        end

        for _, chart in pairs(charts) do
            if chart.id == "chart-ally-army" then
                -- Spring.Echo("addDataPoint: ally-army series count=" .. #chart.series)
            end
            chart:addDataPoint()
        end

        for _, card in pairs(statCards) do
            card:setTarget(card.getValue())
        end
    end
end

-------------------------------------------------------------------------------
-- GAME START
-------------------------------------------------------------------------------

function widget:GameStart()
    chartsReady    = false
    lastUpdateTime = 0
    myTeamStats.armyValue  = 0
    myTeamStats.unitCount  = 0
    myTeamStats.kills      = 0
    myTeamStats.losses     = 0
    myTeamStats.metalLost  = 0
    myTeamStats.damageDealt = 0
    myTeamStats.damageTaken = 0
    myTeamStats.buildEfficiency = 0
    myTeamStats.unitsMetalCompleted = 0
    myTeamStats.lastUnitsMetalCompleted = 0
    for tid, teamData in pairs(allyTeams) do
        teamData.armyValue  = 0
        teamData.buildPower = 0
    end
    Spring.Echo("BAR Charts: Game started, waiting for team data...")
end

-------------------------------------------------------------------------------
-- RENDERING
-------------------------------------------------------------------------------

function widget:DrawScreen()
    if not chartsEnabled then return end

    for _, chart in pairs(charts) do
        chart:draw()
    end

    for _, card in pairs(statCards) do
        card:draw()
    end

    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.4)
    gl.Text("F9: Toggle Charts", vsx - 150, 30, 11, "o")
end

-------------------------------------------------------------------------------
-- INPUT HANDLING
-------------------------------------------------------------------------------

function widget:KeyPress(key, mods, isRepeat)
    if key == Spring.GetKeyCode("f9") then
        chartsEnabled = not chartsEnabled
        Spring.Echo("BAR Charts: " .. (chartsEnabled and "Enabled" or "Disabled"))
        return true
    end
    return false
end

local function findHitElement(mx, my)
    for id, card in pairs(statCards) do
        if card:isMouseOver(mx, my) then return card, "card" end
    end
    for id, chart in pairs(charts) do
        if chart:isMouseOver(mx, my) then return chart, "chart" end
    end
    return nil, nil
end

function widget:MousePress(mx, my, button)
    if not chartsEnabled then return false end

    local elem, kind = findHitElement(mx, my)
    if not elem then return false end

    if button == 1 then
        elem.isDragging = true
        elem.dragStartX = mx - elem.x
        elem.dragStartY = my - elem.y
        return true
    elseif button == 3 then
        elem.visible = not elem.visible
        return true
    end

    return false
end

function widget:MouseRelease(mx, my, button)
    if not chartsEnabled then return false end

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

    for _, card in pairs(statCards) do
        if card.isDragging then
            card.x = mx - card.dragStartX
            card.y = my - card.dragStartY
            return true
        end
    end

    for _, chart in pairs(charts) do
        if chart.isDragging then
            chart.x = mx - chart.dragStartX
            chart.y = my - chart.dragStartY
            return true
        end
    end

    local anyHovered = false
    for _, card in pairs(statCards) do
        card.isHovered = card:isMouseOver(mx, my)
        if card.isHovered then anyHovered = true end
    end
    for _, chart in pairs(charts) do
        chart.isHovered = chart:isMouseOver(mx, my)
        if chart.isHovered then anyHovered = true end
    end

    return anyHovered
end

function widget:MouseWheel(up, value)
    if not chartsEnabled then return false end

    local mx, my = Spring.GetMouseState()

    for _, card in pairs(statCards) do
        if card:isMouseOver(mx, my) then
            card.scale = up and math.min(2.0, card.scale + 0.1)
                            or  math.max(0.5, card.scale - 0.1)
            return true
        end
    end

    for _, chart in pairs(charts) do
        if chart:isMouseOver(mx, my) then
            chart.scale = up and math.min(2.0, chart.scale + 0.1)
                             or  math.max(0.5, chart.scale - 0.1)
            return true
        end
    end

    return false
end

function widget:ViewResize()
    local oldVsx, oldVsy = vsx, vsy
    vsx, vsy = Spring.GetViewGeometry()

    if not savedChartConfig then
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
    end
end

function widget:TextCommand(command)
    if command == "barcharts save" then
        saveConfig()
        Spring.Echo("BAR Charts: Configuration saved manually")
        return true
    elseif command == "barcharts reset" then
        os.remove(CONFIG_FILE)
        Spring.Echo("BAR Charts: Configuration reset - restart widget to apply")
        return true
    elseif command == "barcharts debug" then
        Spring.Echo("=== BAR Charts Debug ===")
        Spring.Echo("vsx=" .. tostring(vsx) .. " vsy=" .. tostring(vsy))
        Spring.Echo("chartsEnabled=" .. tostring(chartsEnabled) .. " chartsReady=" .. tostring(chartsReady))
        Spring.Echo("-- CARDS --")
        for id, card in pairs(statCards) do
            Spring.Echo(string.format("  %s: x=%.0f y=%.0f scale=%.1f visible=%s enabled=%s",
                id, card.x, card.y, card.scale, tostring(card.visible), tostring(card.enabled)))
        end
        Spring.Echo("-- CHARTS --")
        for _, chart in pairs(charts) do
            Spring.Echo(string.format("  %s: x=%.0f y=%.0f scale=%.1f visible=%s",
                chart.id, chart.x, chart.y, chart.scale, tostring(chart.visible)))
        end
        return true
    end
    return false
end

function widget:Shutdown()
    saveConfig()
    Spring.Echo("BAR Charts: Shutdown")
end
