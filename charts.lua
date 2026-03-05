--[[
═══════════════════════════════════════════════════════════════════════════
    BAR CHARTS WIDGET
    
    In-game overlay charts matching the streaming system aesthetic.
    Displays real-time resource and combat statistics as animated line charts.
    
    Features:
    - Metal Income/Usage chart
    - Energy Income/Usage chart  
    - Damage Dealt/Taken chart
    - Army Value chart
    - K/D Ratio chart
    - Smooth animations with lerp interpolation
    - Draggable, scalable, toggleable widgets
    - Cyber/tech aesthetic matching streaming overlay
    
    Controls:
    - F9: Toggle all charts on/off
    - Click+Drag: Move charts
    - Mouse Wheel over chart: Scale size
    - Double-click: Toggle individual chart
    
    Installation:
    Place in: /LuaUI/Widgets/
    Enable in-game via F11 menu
═══════════════════════════════════════════════════════════════════════════
]]

function widget:GetInfo()
    return {
        name      = "BAR Stats Charts",
        desc      = "Real-time resource and combat statistics overlay charts",
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

-- Global enable/disable
local chartsEnabled = true

-- Chart styling (matching streaming system)
local COLOR = {
    bg          = {0.031, 0.047, 0.078, 0.72},  -- rgba(8,12,20,0.72)
    border      = {0.353, 0.706, 1.000, 0.18},  -- rgba(90,180,255,0.18)
    borderHot   = {0.353, 0.706, 1.000, 0.55},  -- rgba(90,180,255,0.55)
    grid        = {0.353, 0.706, 1.000, 0.08},  -- grid lines
    gridBase    = {0.353, 0.706, 1.000, 0.22},  -- baseline grid
    text        = {0.863, 0.912, 0.973, 1.00},  -- rgba(220,233,248,1)
    muted       = {0.627, 0.745, 0.863, 0.55},  -- rgba(160,190,220,0.55)
    accent      = {0.290, 0.706, 1.000, 1.00},  -- #4ab4ff
    accent2     = {1.000, 0.420, 0.208, 1.00},  -- #ff6b35
    danger      = {1.000, 0.231, 0.361, 1.00},  -- #ff3b5c
    success     = {0.188, 0.941, 0.627, 1.00},  -- #30f0a0
    gold        = {0.941, 0.753, 0.251, 1.00},  -- #f0c040
}

-- Animation settings
local ANIM_DURATION = 0.4  -- seconds for lerp animation
local HISTORY_SIZE = 60    -- number of data points to keep
local UPDATE_INTERVAL = 10 -- update every 10 seconds (matches FullStatsUpdate)

-- Chart dimensions
local CHART_WIDTH = 300
local CHART_HEIGHT = 180
local PADDING = {left = 40, right = 15, top = 15, bottom = 25}

-------------------------------------------------------------------------------
-- HELPER FUNCTIONS
-------------------------------------------------------------------------------

-- Easing function for smooth animations
local function easeOutCubic(t)
    return 1 - math.pow(1 - t, 3)
end

-- Format numbers for display
local function formatNumber(n)
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 10000 then
        return string.format("%.0fK", n / 1000)
    else
        return string.format("%d", math.floor(n + 0.5))
    end
end

-- Format Y-axis labels
local function formatYAxis(n, chartType)
    if chartType == "ratio" then
        return string.format("%.1f", n)
    else
        return formatNumber(n)
    end
end

-- Clamp value between min and max
local function clamp(val, min, max)
    if val < min then return min end
    if val > max then return max end
    return val
end

-- Draw rounded rectangle (approximate with line segments)
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
        
        -- Corners (approximate)
        local segments = 6
        for i = 0, segments do
            local angle = (math.pi / 2) * (i / segments)
            
            -- Top-left
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
            
            -- Top-right
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
            
            -- Bottom-right
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
            
            -- Bottom-left
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
        -- Outline only
        gl.BeginEnd(GL.LINE_LOOP, function()
            -- Top edge
            gl.Vertex(x + r, y)
            gl.Vertex(x + w - r, y)
            -- Top-right corner
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + w - r + r * math.sin(angle), y + r - r * math.cos(angle))
            end
            -- Right edge
            gl.Vertex(x + w, y + r)
            gl.Vertex(x + w, y + h - r)
            -- Bottom-right corner
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + w - r + r * math.cos(angle), y + h - r + r * math.sin(angle))
            end
            -- Bottom edge
            gl.Vertex(x + w - r, y + h)
            gl.Vertex(x + r, y + h)
            -- Bottom-left corner
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + r - r * math.sin(angle), y + h - r + r * math.cos(angle))
            end
            -- Left edge
            gl.Vertex(x, y + h - r)
            gl.Vertex(x, y + r)
            -- Top-left corner
            for i = 0, 6 do
                local angle = (math.pi / 2) * (i / 6)
                gl.Vertex(x + r - r * math.cos(angle), y + r - r * math.sin(angle))
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- CHART CLASS
-------------------------------------------------------------------------------

local Chart = {}
Chart.__index = Chart

function Chart.new(id, label, icon, x, y, chartType, series, multiTeam)
    local self = setmetatable({}, Chart)
    
    self.id = id
    self.label = label
    self.icon = icon
    self.x = x
    self.y = y
    self.width = CHART_WIDTH
    self.height = CHART_HEIGHT
    self.scale = 1.0
    self.enabled = true
    self.visible = true
    
    self.chartType = chartType  -- "single", "dual", or "multi"
    self.series = series        -- Array of series configs
    self.multiTeam = multiTeam or false  -- If true, generates series from allyTeams
    
    -- Data storage
    self.history = {}  -- Historical data points
    for i = 1, #series do
        self.history[i] = {}
    end
    
    -- Animation state
    self.displayData = {}  -- Smoothly interpolated display values
    for i = 1, #series do
        self.displayData[i] = {}
    end
    
    self.animProgress = 1.0
    self.animStartTime = 0
    self.prevData = {}
    self.targetData = {}
    
    -- Interaction state
    self.isDragging = false
    self.dragStartX = 0
    self.dragStartY = 0
    self.isHovered = false
    
    return self
end

-- Special method for multi-team charts to rebuild series from current ally teams
function Chart:rebuildMultiTeamSeries()
    if not self.multiTeam then return end
    
    -- Clear old history
    self.history = {}
    self.displayData = {}
    self.series = {}
    
    local idx = 1
    for teamID, teamData in pairs(allyTeams) do
        -- Create series for this team
        local seriesConfig = {
            label = teamData.playerName,
            color = teamData.color,
            teamID = teamID,  -- Store team ID for data retrieval
            getValue = nil    -- Will be set by chart type
        }
        
        -- Assign getValue function based on chart type
        if self.id == "chart-ally-army" then
            seriesConfig.getValue = function()
                return allyTeams[teamID] and allyTeams[teamID].armyValue or 0
            end
        elseif self.id == "chart-ally-buildpower" then
            seriesConfig.getValue = function()
                return allyTeams[teamID] and allyTeams[teamID].buildPower or 0
            end
        elseif self.id == "chart-ally-metal" then
            seriesConfig.getValue = function()
                return allyTeams[teamID] and allyTeams[teamID].metalIncome or 0
            end
        elseif self.id == "chart-ally-energy" then
            seriesConfig.getValue = function()
                return allyTeams[teamID] and allyTeams[teamID].energyIncome or 0
            end
        end
        
        self.series[idx] = seriesConfig
        self.history[idx] = {}
        self.displayData[idx] = {}
        idx = idx + 1
    end
end

function Chart:addDataPoint()
    local now = Spring.GetGameSeconds()
    
    -- Collect new data from all series
    for i, s in ipairs(self.series) do
        local value = s.getValue()
        
        -- Add to history
        table.insert(self.history[i], value)
        if #self.history[i] > HISTORY_SIZE then
            table.remove(self.history[i], 1)
        end
    end
    
    -- Start animation
    self.animProgress = 0.0
    self.animStartTime = os.clock()
    
    -- Copy current display as prev, target as new history
    for i = 1, #self.series do
        self.prevData[i] = {}
        self.targetData[i] = {}
        
        for j, v in ipairs(self.displayData[i]) do
            self.prevData[i][j] = v
        end
        
        for j, v in ipairs(self.history[i]) do
            self.targetData[i][j] = v
        end
    end
end

function Chart:update(dt)
    if self.animProgress < 1.0 then
        local elapsed = os.clock() - self.animStartTime
        self.animProgress = math.min(1.0, elapsed / ANIM_DURATION)
        local ease = easeOutCubic(self.animProgress)
        
        -- Interpolate display data
        for i = 1, #self.series do
            for j = 1, math.max(#self.prevData[i], #self.targetData[i]) do
                local fromVal = self.prevData[i][j] or self.targetData[i][j] or 0
                local toVal = self.targetData[i][j] or fromVal
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
    
    local w = self.width
    local h = self.height
    local pad = PADDING
    local cX = pad.left
    local cY = pad.bottom
    local cW = w - pad.left - pad.right
    local cH = h - pad.top - pad.bottom
    
    -- Background
    gl.Color(COLOR.bg)
    drawRoundedRect(0, 0, w, h, 4, true)
    
    -- Border (highlighted if hovered)
    if self.isHovered then
        gl.Color(COLOR.borderHot)
    else
        gl.Color(COLOR.border)
    end
    gl.LineWidth(1)
    drawRoundedRect(0.5, 0.5, w - 1, h - 1, 4, false)
    
    -- Check if we have data
    local hasData = false
    for i = 1, #self.series do
        if #self.displayData[i] >= 2 then
            hasData = true
            break
        end
    end
    
    if not hasData then
        self:drawNoData(cX, cY, cW, cH)
        self:drawHeader(w, h)
        gl.PopMatrix()
        return
    end
    
    -- Calculate Y range across all series
    local allValues = {}
    for i = 1, #self.series do
        for _, v in ipairs(self.displayData[i]) do
            if v and not (v ~= v) then  -- Check for valid number (not NaN)
                table.insert(allValues, v)
            end
        end
    end
    
    local minV = math.min(unpack(allValues))
    local maxV = math.max(unpack(allValues))
    local span = maxV - minV
    local rangePad = span > 0 and span * 0.12 or math.max(maxV * 0.1, 100)
    minV = math.max(0, minV - rangePad)
    maxV = maxV + rangePad
    local range = maxV - minV
    if range == 0 then range = 1 end
    
    -- Draw gridlines and Y labels
    gl.Color(COLOR.muted)
    for i = 0, 4 do
        local v = minV + (range * i / 4)
        local yPos = cY + cH - (cH * i / 4)
        
        -- Grid line
        if i == 0 then
            gl.Color(COLOR.gridBase)
        else
            gl.Color(COLOR.grid)
        end
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(cX, yPos)
            gl.Vertex(cX + cW, yPos)
        end)
        
        -- Y-axis label
        gl.Color(COLOR.muted)
        local labelText = formatYAxis(v, self.chartType == "ratio" and "ratio" or "normal")
        gl.Text(labelText, cX - 5, yPos - 4, 9, "ro")
    end
    
    -- Helper functions for coordinate conversion
    local function toX(idx, total)
        return cX + ((idx - 1) / (total - 1)) * cW
    end
    
    local function toY(value)
        return cY + cH - ((value - minV) / range) * cH
    end
    
    -- Draw each series
    for seriesIdx, s in ipairs(self.series) do
        local data = self.displayData[seriesIdx]
        if #data >= 2 then
            local color = s.color
            
            -- Draw line
            gl.Color(color[1], color[2], color[3], 1.0)
            gl.LineWidth(2.0)
            gl.BeginEnd(GL.LINE_STRIP, function()
                for i, value in ipairs(data) do
                    if value and not (value ~= value) then
                        gl.Vertex(toX(i, #data), toY(value))
                    end
                end
            end)
            
            -- Draw fill (semi-transparent)
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
            
            -- Draw current value indicator
            if #data > 0 then
                local lastValue = data[#data]
                if lastValue and not (lastValue ~= lastValue) then
                    gl.Color(color[1], color[2], color[3], 0.8)
                    gl.PointSize(6)
                    gl.BeginEnd(GL.POINTS, function()
                        gl.Vertex(toX(#data, #data), toY(lastValue))
                    end)
                    
                    -- Value label on right edge
                    gl.Color(color[1], color[2], color[3], 1.0)
                    local valueText
                    
                    if self.chartType == "multi" then
                        -- Multi-team: show abbreviated name + value
                        local shortName = s.label
                        if #shortName > 8 then
                            shortName = string.sub(shortName, 1, 6) .. ".."
                        end
                        valueText = shortName .. " " .. formatNumber(lastValue)
                    elseif self.chartType == "dual" then
                        valueText = s.label .. " " .. formatNumber(lastValue)
                    else
                        valueText = formatNumber(lastValue)
                    end
                    
                    -- Offset labels vertically for multi-series to prevent overlap
                    local labelOffset = 0
                    if self.chartType == "multi" or self.chartType == "dual" then
                        labelOffset = (seriesIdx - 1) * 13
                    end
                    
                    gl.Text(valueText, cX + cW + 2, toY(lastValue) - 4 + labelOffset, 9, "o")
                end
            end
        end
    end
    
    -- Draw header
    self:drawHeader(w, h)
    
    gl.PopMatrix()
end

function Chart:drawHeader(w, h)
    gl.Color(COLOR.muted)
    local headerText = self.icon .. "  " .. self.label
    gl.Text(headerText, PADDING.left + 2, h - PADDING.top - 10, 10, "o")
end

function Chart:drawNoData(cX, cY, cW, cH)
    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.25)
    gl.Text("— awaiting data —", cX + cW / 2, cY + cH / 2, 10, "c")
end

function Chart:isMouseOver(mx, my)
    local x1 = self.x
    local y1 = self.y
    local x2 = self.x + self.width * self.scale
    local y2 = self.y + self.height * self.scale
    return mx >= x1 and mx <= x2 and my >= y1 and my <= y2
end

-------------------------------------------------------------------------------
-- GLOBAL STATE
-------------------------------------------------------------------------------

local charts = {}
local lastUpdateTime = 0
local teamID = nil
local allyTeamID = nil
local allyTeams = {}  -- Track all ally team stats

local myTeamStats = {
    metalIncome = 0,
    metalUsage = 0,
    energyIncome = 0,
    energyUsage = 0,
    damageDealt = 0,
    damageTaken = 0,
    armyValue = 0,
    kills = 0,
    losses = 0,
}

-- Ally team stats storage
-- Structure: allyTeams[teamID] = {metalIncome, energyIncome, armyValue, buildPower, playerName, color}
local function initAllyTeams()
    -- Get the ID first
    local currentAllyID = Spring.GetMyAllyTeamID()
    if not currentAllyID then return end
    
    allyTeamID = currentAllyID
    
    -- ONLY clear the table once we are sure we have data to put back in it
    local newAllyTeams = {}
    local teamList = Spring.GetTeamList(allyTeamID)
    
    if teamList then
        for _, tid in ipairs(teamList) do
            local r, g, b = Spring.GetTeamColor(tid)
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
                teamID = tid,
                playerName = playerName,
                color = {r or 1, g or 1, b or 1, 1},
                metalIncome = 0,
                energyIncome = 0,
                armyValue = 0,
                buildPower = 0,
            }
        end
        -- Atomic swap: allyTeams is only updated if the collection succeeded
        allyTeams = newAllyTeams
    end
end

-------------------------------------------------------------------------------
-- CONFIG SAVE/LOAD
-------------------------------------------------------------------------------

local function saveConfig()
    local config = {
        version = "1.0",
        enabled = chartsEnabled,
        charts = {}
    }
    
    for id, chart in pairs(charts) do
        config.charts[id] = {
            x = chart.x,
            y = chart.y,
            scale = chart.scale,
            visible = chart.visible,
            enabled = chart.enabled,
        }
    end
    
    local configStr = "return " .. serializeTable(config, 0)
    
    -- Write to VFS
    local file = io.open(CONFIG_FILE, "w")
    if file then
        file:write(configStr)
        file:close()
        Spring.Echo("BAR Charts: Config saved to " .. CONFIG_FILE)
    else
        Spring.Echo("BAR Charts: Failed to save config")
    end
end

local function loadConfig()
    if not VFS.FileExists(CONFIG_FILE) then
        return {} -- Return empty table instead of false
    end
    
    local success, config = pcall(VFS.Include, CONFIG_FILE)
    
    -- Check if the file loaded and contains the expected 'charts' table
    if success and type(config) == "table" and type(config.charts) == "table" then
        chartsEnabled = config.enabled ~= nil and config.enabled or true
        return config.charts
    end
    
    Spring.Echo("BAR Charts: Config file was corrupt or empty, using defaults")
    return {} -- Return empty table as a safety fallback
end

local savedChartConfig = nil

-------------------------------------------------------------------------------
-- INITIALIZATION
-------------------------------------------------------------------------------

function widget:Initialize()
    -- 1. Refresh screen geometry
    vsx, vsy = Spring.GetViewGeometry()
    teamID = Spring.GetMyTeamID()
    allyTeamID = Spring.GetMyAllyTeamID()
    
    if not teamID then
        Spring.Echo("BAR Charts: Could not get team ID")
        return
    end
    
    -- 2. Initialize ally team tracking
    initAllyTeams()
    
    -- 3. Define Charts (Standardizing the table 'charts')
    charts = {} 

    -- Resource Column (Right)
    charts.metal = Chart.new("chart-metal", "METAL", "⚙", vsx - 350, 250, "dual", {
        { label = "Income", color = COLOR.accent, getValue = function() return myTeamStats.metalIncome end },
        { label = "Usage", color = COLOR.accent2, getValue = function() return myTeamStats.metalUsage end }
    }, false)

    charts.energy = Chart.new("chart-energy", "ENERGY", "⚡", vsx - 350, 50, "dual", {
        { label = "Income", color = COLOR.accent, getValue = function() return myTeamStats.energyIncome end },
        { label = "Usage", color = COLOR.accent2, getValue = function() return myTeamStats.energyUsage end }
    }, false)

    -- Combat Column (Middle)
    charts.damage = Chart.new("chart-damage", "DAMAGE", "✕", vsx - 680, 250, "dual", {
        { label = "Dealt", color = COLOR.success, getValue = function() return myTeamStats.damageDealt end },
        { label = "Taken", color = COLOR.danger, getValue = function() return myTeamStats.damageTaken end }
    }, false)

    charts.army = Chart.new("chart-army", "ARMY VALUE", "⚙", vsx - 680, 50, "single", {
        { label = "Value", color = COLOR.accent, getValue = function() return myTeamStats.armyValue end }
    }, false)

    -- Stats Column (Left)
    charts.kd = Chart.new("chart-kd", "K/D RATIO", "✕", 50, 450, "ratio", {
        { label = "Ratio", color = COLOR.success, getValue = function() 
            local k, d = myTeamStats.kills, myTeamStats.losses
            return d == 0 and (k > 0 and 5 or 0) or math.min(5, k / d)
        end }
    }, false)

    charts.allyArmy = Chart.new("chart-ally-army", "TEAM ARMY", "⚙", 50, 250, "multi", {}, true)
    charts.allyArmy:rebuildMultiTeamSeries()

    charts.allyBuildPower = Chart.new("chart-ally-buildpower", "TEAM BP", "🔧", 50, 50, "multi", {}, true)
    charts.allyBuildPower:rebuildMultiTeamSeries()
    
    -- 4. THE ULTIMATE FIX FOR LINE 312
    -- We define a local variable and force it to be a table NO MATTER WHAT.
    local rawConfig = loadConfig() 
    local safeConfig = (type(rawConfig) == "table") and rawConfig or {}

    -- We iterate over 'safeConfig', which is guaranteed to be a table by the line above.
    for id, config in pairs(safeConfig) do
        if charts[id] and type(config) == "table" then
            charts[id].x = config.x or charts[id].x
            charts[id].y = config.y or charts[id].y
            charts[id].scale = config.scale or charts[id].scale
            charts[id].visible = (config.visible ~= nil) and config.visible or charts[id].visible
            charts[id].enabled = (config.enabled ~= nil) and config.enabled or charts[id].enabled
        end
    end
    
    Spring.Echo("BAR Charts: Loaded successfully.")
end

-------------------------------------------------------------------------------
-- UPDATE LOOP
-------------------------------------------------------------------------------

function widget:Update(dt)
    if not chartsEnabled then return end
    
    -- Update chart animations
    for _, chart in pairs(charts) do
        chart:update(dt)
    end
    
    -- Collect stats at regular intervals
    local gameTime = Spring.GetGameSeconds()
    if gameTime - lastUpdateTime >= UPDATE_INTERVAL then
        lastUpdateTime = gameTime
        
        -- ========== MY TEAM STATS ==========
        
        -- Get resource stats
        local m_inc, m_use, m_stor, m_pull, m_share, m_sent, m_rec, m_excs = 
            Spring.GetTeamResourceStats(teamID, "metal")
        local e_inc, e_use, e_stor, e_pull, e_share, e_sent, e_rec, e_excs = 
            Spring.GetTeamResourceStats(teamID, "energy")
        
        myTeamStats.metalIncome = m_inc or 0
        myTeamStats.metalUsage = m_use or 0
        myTeamStats.energyIncome = e_inc or 0
        myTeamStats.energyUsage = e_use or 0
        
        -- Get combat stats
        if Spring.GetTeamDamageStats then
            local dmg_dealt, dmg_taken = Spring.GetTeamDamageStats(teamID)
            myTeamStats.damageDealt = dmg_dealt or 0
            myTeamStats.damageTaken = dmg_taken or 0
        end
        
        if Spring.GetTeamUnitStats then
            local u_killed, u_died = Spring.GetTeamUnitStats(teamID)
            myTeamStats.kills = u_killed or 0
            myTeamStats.losses = u_died or 0
        end
        
        -- Calculate army value
        local units = Spring.GetTeamUnits(teamID)
        local totalValue = 0
        for _, unitID in ipairs(units) do
            local unitDefID = Spring.GetUnitDefID(unitID)
            if unitDefID then
                local ud = UnitDefs[unitDefID]
                if ud then
                    totalValue = totalValue + (ud.metalCost or 0)
                end
            end
        end
        myTeamStats.armyValue = totalValue
        
        -- ========== ALLY TEAM STATS ==========
        if type(allyTeams) == "table" then
            for tid, teamData in pairs(allyTeams) do
                -- Get resource stats for this team
                local tm_inc, tm_use = Spring.GetTeamResourceStats(tid, "metal")
                local te_inc, te_use = Spring.GetTeamResourceStats(tid, "energy")
                
                teamData.metalIncome = tm_inc or 0
                teamData.energyIncome = te_inc or 0
                
                -- Calculate army value for this team
                local teamUnits = Spring.GetTeamUnits(tid)
                local teamArmyValue = 0
                local teamBuildPower = 0
                
                for _, unitID in ipairs(teamUnits) do
                    local unitDefID = Spring.GetUnitDefID(unitID)
                    if unitDefID then
                        local ud = UnitDefs[unitDefID]
                        if ud then
                            teamArmyValue = teamArmyValue + (ud.metalCost or 0)
                            
                            -- Calculate build power (sum of builder speeds)
                            if ud.isBuilder then
                                teamBuildPower = teamBuildPower + (ud.buildSpeed or 0)
                            end
                        end
                    end
                end
                
                teamData.armyValue = teamArmyValue
                teamData.buildPower = teamBuildPower
            end
        end
        
        -- Add data points to all charts
        for _, chart in pairs(charts) do
            chart:addDataPoint()
        end
    end
end

-------------------------------------------------------------------------------
-- RENDERING
-------------------------------------------------------------------------------

function widget:GameStart()
    -- Reinitialize ally teams when game starts (handles spectator mode, etc.)
    initAllyTeams()
    
    -- Rebuild multi-team chart series
    if charts.allyArmy then
        charts.allyArmy:rebuildMultiTeamSeries()
    end
    if charts.allyBuildPower then
        charts.allyBuildPower:rebuildMultiTeamSeries()
    end
    
    Spring.Echo("BAR Charts: Game started, tracking " .. (#Spring.GetTeamList(allyTeamID) or 0) .. " teams")
end

function widget:DrawScreen()
    if not chartsEnabled then return end
    
    gl.PushMatrix()
    
    -- Draw all charts
    for _, chart in pairs(charts) do
        chart:draw()
    end
    
    -- Draw toggle hint
    gl.Color(COLOR.muted[1], COLOR.muted[2], COLOR.muted[3], 0.4)
    gl.Text("F9: Toggle Charts", vsx - 150, 30, 11, "o")
    
    gl.PopMatrix()
end

-------------------------------------------------------------------------------
-- INPUT HANDLING
-------------------------------------------------------------------------------

function widget:KeyPress(key, mods, isRepeat)
    if key == 0x120 then  -- F9
        chartsEnabled = not chartsEnabled
        Spring.Echo("BAR Charts: " .. (chartsEnabled and "Enabled" or "Disabled"))
        return true
    end
    return false
end

function widget:MousePress(mx, my, button)
    if not chartsEnabled then return false end
    
    -- Convert from top-left to bottom-left coordinates
    my = vsy - my
    
    if button == 1 then  -- Left click
        for _, chart in pairs(charts) do
            if chart:isMouseOver(mx, my) then
                chart.isDragging = true
                chart.dragStartX = mx - chart.x
                chart.dragStartY = my - chart.y
                return true
            end
        end
    elseif button == 3 then  -- Right click (double-click to toggle)
        for _, chart in pairs(charts) do
            if chart:isMouseOver(mx, my) then
                chart.visible = not chart.visible
                return true
            end
        end
    end
    
    return false
end

function widget:MouseRelease(mx, my, button)
    if not chartsEnabled then return false end
    
    if button == 1 then
        for _, chart in pairs(charts) do
            if chart.isDragging then
                chart.isDragging = false
                return true
            end
        end
    end
    
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if not chartsEnabled then return false end
    
    -- Convert from top-left to bottom-left coordinates
    my = vsy - my
    
    -- Handle dragging
    for _, chart in pairs(charts) do
        if chart.isDragging then
            chart.x = mx - chart.dragStartX
            chart.y = my - chart.dragStartY
            return true
        end
    end
    
    -- Update hover state
    local anyHovered = false
    for _, chart in pairs(charts) do
        chart.isHovered = chart:isMouseOver(mx, my)
        if chart.isHovered then 
            anyHovered = true 
        end -- Correctly closing the 'if chart.isHovered'
    end -- Correctly closing the 'for' loop
    
    return anyHovered
end

function widget:MouseWheel(up, value)
    if not chartsEnabled then return false end
    
    local mx, my = Spring.GetMouseState()
    my = vsy - my
    
    for _, chart in pairs(charts) do
        if chart:isMouseOver(mx, my) then
            if up then
                chart.scale = math.min(2.0, chart.scale + 0.1)
            else
                chart.scale = math.max(0.5, chart.scale - 0.1)
            end
            return true
        end
    end
    
    return false
end

function widget:ViewResize()
    local oldVsx, oldVsy = vsx, vsy
    vsx, vsy = Spring.GetViewGeometry()
    
    -- Only adjust positions if no saved config exists
    -- Otherwise positions are already set from saved config
    if not savedChartConfig then
        -- Calculate ratio for proportional repositioning
        local ratioX = vsx / oldVsx
        local ratioY = vsy / oldVsy
        
        -- Reposition charts proportionally
        for _, chart in pairs(charts) do
            chart.x = chart.x * ratioX
            chart.y = chart.y * ratioY
        end
    end
end

function widget:TextCommand(command)
    if command == "barcharts save" then
        saveConfig()
        Spring.Echo("BAR Charts: Configuration saved manually")
        return true
    elseif command == "barcharts reset" then
        -- Delete config file
        os.remove(CONFIG_FILE)
        Spring.Echo("BAR Charts: Configuration reset - restart widget to apply")
        return true
    end
    return false
end

function widget:Shutdown()
    -- Auto-save config on shutdown
    saveConfig()
    Spring.Echo("BAR Charts: Shutdown")
end
