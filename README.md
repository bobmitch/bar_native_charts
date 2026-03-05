# BAR Stats Charts Widget v2.0

Real-time resource and combat statistics overlay for Beyond All Reason, with **automatic save/load** and **multi-team comparison charts**.

## 🆕 What's New in v2.0

### Automatic Position/Scale Persistence
- ✅ **Auto-save on exit** - Chart positions, scales, and visibility saved automatically
- ✅ **Auto-load on start** - Restores your layout from previous session
- ✅ **Manual save** - Type `/barcharts save` to save immediately
- ✅ **Reset config** - Type `/barcharts reset` to restore defaults

### Multi-Team Comparison Charts
- ✅ **Team Army Values** - Compare total army value across all allied teams
- ✅ **Team Build Power** - Track combined builder capacity per team
- ✅ **Dynamic colors** - Each team uses their in-game color
- ✅ **Auto-updates** - Adds/removes teams as they join/leave

## Features

### Visual Charts (7 Total)

**Personal Stats (5):**
- Metal Income/Usage
- Energy Income/Usage
- Damage Dealt/Taken
- Army Value
- K/D Ratio

**Team Comparison (2 NEW):**
- Team Army Values (multi-line)
- Team Build Power (multi-line)

### Styling
- Semi-transparent dark backgrounds `rgba(8,12,20,0.72)`
- Cyan accent colors `rgba(90,180,255,0.18)`
- Smooth animations with lerp interpolation (400ms)
- Grid lines and Y-axis labels
- Rounded corners (4px radius)
- Hover effects with border highlighting

### Interaction
- **F9**: Toggle all charts on/off
- **Click + Drag**: Move charts anywhere on screen
- **Mouse Wheel** (over chart): Scale size (0.5x - 2.0x)
- **Right Click**: Toggle individual chart visibility
- **Hover**: Charts highlight when mouse is over them

### Performance
- Updates every 10 seconds (matches FullStatsUpdate frequency)
- Stores last 60 data points per series
- Smooth 60 FPS rendering
- Minimal CPU overhead

## Installation

### Quick Install

1. Download `bar_charts_widget.lua`

2. Copy to BAR widgets folder:
   - **Windows**: `C:\Users\<YourName>\Documents\My Games\Spring\LuaUI\Widgets\`
   - **Linux**: `~/.spring/LuaUI/Widgets/`
   - **Mac**: `~/Library/Application Support/Spring/LuaUI/Widgets/`

3. Launch BAR

4. Press **F11** to open widget menu

5. Enable "BAR Stats Charts"

6. Press **F9** to toggle charts on/off

### Configuration File

Settings are saved to: `bar_charts_config.lua` in your Spring directory

The config stores:
- Chart positions (x, y)
- Chart scales (0.5 - 2.0)
- Chart visibility (hidden/shown)
- Chart enabled state
- Global enabled/disabled state

## Usage

### First Launch

Charts appear in default positions:

```
[Team Army]  [Team Build]
  ↓             ↓
┌─────────────────────────────────────────┐
│                                         │
│  [Metal]   [Energy]  [Army]    [K/D]   │
│                                         │
│  [Damage]                               │
│                                         │
└─────────────────────────────────────────┘
```

### Customizing Layout

1. **Move charts** - Click and drag to desired position
2. **Scale charts** - Hover and scroll wheel to resize
3. **Hide charts** - Right-click to toggle visibility

**Your layout is saved automatically when you exit!**

### Multi-Team Charts

The new team comparison charts show all allied teams:

**Team Army Values Chart:**
- Each line = one teammate
- Line color = teammate's in-game color
- Shows total metal invested in units
- Great for seeing who's ahead/behind

**Team Build Power Chart:**
- Each line = one teammate
- Shows combined buildSpeed of all builders
- Indicates eco/factory capacity
- Useful for coordinating builds

### Commands

Type these in chat:

- `/barcharts save` - Manually save current layout
- `/barcharts reset` - Delete saved config and restore defaults

## Multi-Team Features

### How Team Detection Works

The widget automatically:
1. Detects all teams in your ally team on game start
2. Gets each team's in-game color
3. Gets player/AI name for each team
4. Creates a series in the chart for each team
5. Updates stats every 10 seconds

### Team Colors

Each teammate appears in their chosen team color:
- Red team → red line
- Blue team → blue line
- Green team → green line
- etc.

This makes it easy to identify who is who at a glance.

### Build Power Calculation

Build power = sum of all builder speeds:
- Constructor units
- Factories
- Nano turrets
- Commander
- Any unit with `isBuilder = true`

Higher build power = faster construction/reclaim/repair.

### Dynamic Updates

If teams join/leave mid-game:
- New teams are added automatically
- Old teams remain in history (frozen line)
- Chart legend updates in real-time

## Customization

### Repositioning Defaults

Edit default positions in `widget:Initialize()`:

```lua
charts.allyArmy = Chart.new(
    "chart-ally-army",
    "TEAM ARMY VALUES",
    "⚙",
    100,        -- X position (change this)
    vsy - 250,  -- Y position (change this)
    "multi",
    {},
    true
)
```

### Changing Colors

Edit the COLOR table at top of file:

```lua
local COLOR = {
    bg          = {0.031, 0.047, 0.078, 0.72},
    border      = {0.353, 0.706, 1.000, 0.18},
    accent      = {0.290, 0.706, 1.000, 1.00},  -- Primary
    accent2     = {1.000, 0.420, 0.208, 1.00},  -- Secondary
    success     = {0.188, 0.941, 0.627, 1.00},  -- Damage dealt
    danger      = {1.000, 0.231, 0.361, 1.00},  -- Damage taken
}
```

### Update Frequency

Change how often data refreshes:

```lua
local UPDATE_INTERVAL = 10  -- Seconds (default: 10)
```

Lower = more updates, higher CPU usage.

### History Size

Adjust data point count:

```lua
local HISTORY_SIZE = 60  -- Points per series (default: 60)
```

More points = smoother charts, more memory.

## Troubleshooting

### Config Not Saving

**Symptoms:** Chart positions reset every restart

**Solutions:**
1. Check file permissions on Spring directory
2. Manually save: `/barcharts save`
3. Check console for error messages
4. Verify `bar_charts_config.lua` exists after exit

### Multi-Team Charts Empty

**Symptoms:** Team Army/Build Power charts show "— awaiting data —"

**Solutions:**
1. Wait 10+ seconds for first update
2. Ensure you're in a game with teammates
3. Check you're not spectating (spectators see limited data)
4. Verify teammates are active (not defeated)

### Charts Lag or Stutter

**Solutions:**
1. Reduce `HISTORY_SIZE` to 30
2. Increase `UPDATE_INTERVAL` to 15
3. Hide unused charts (right-click)
4. Disable chart fills in code (see ADVANCED_CONFIG.md)

### Position Reset After Resolution Change

**Explanation:** Charts maintain saved positions but may appear off-screen after resolution change.

**Solutions:**
1. Reset config: `/barcharts reset`
2. Reload widget: `/luaui reload`
3. Manually reposition and save

### Team Colors Not Showing

**Symptoms:** All teams appear in same color

**Cause:** Spring API didn't return team colors (rare bug)

**Solution:**
1. Reload widget: `/luaui reload`
2. Restart game

## Technical Details

### Config File Format

```lua
return {
  version = "1.0",
  enabled = true,
  charts = {
    ["chart-metal"] = {
      x = 420,
      y = 818,
      scale = 1.0,
      visible = true,
      enabled = true
    },
    ["chart-ally-army"] = {
      x = 100,
      y = 818,
      scale = 1.2,
      visible = true,
      enabled = true
    },
    -- ... etc
  }
}
```

### Save Triggers

Config is saved automatically on:
- Widget shutdown (`/luaui reload`)
- Game exit
- Manual command (`/barcharts save`)

### Multi-Team Data Structure

```lua
allyTeams[teamID] = {
    teamID = 0,
    playerName = "Player",
    color = {0.8, 0.2, 0.2, 1.0},  -- RGBA
    metalIncome = 1500,
    energyIncome = 20000,
    armyValue = 15000,
    buildPower = 250,
}
```

### Performance Metrics

- **Single chart**: ~15-20 draw calls, <1% CPU
- **Multi-team chart (4 teams)**: ~50-60 draw calls, ~2% CPU
- **All 7 charts active**: ~100-120 draw calls, ~3% CPU
- **Memory usage**: ~50-100 KB total

## Advanced Usage

### Integrating with Other Widgets

Access chart data from other widgets:

```lua
-- In another widget
if WG.barChartsAPI then
    local armyData = WG.barChartsAPI.getChartData("chart-ally-army")
    local currentValue = WG.barChartsAPI.getCurrentValue("chart-metal", 1)
end
```

### Adding Custom Charts

See `ADVANCED_CONFIG.md` for examples of:
- Metal efficiency tracking
- Energy stall detection
- Unit production rate
- Combat intensity heatmap

### Export to CSV

Add this function to export chart data:

```lua
function exportToCSV(chartId)
    local chart = charts[chartId]
    local csv = "timestamp,value\n"
    
    for i, value in ipairs(chart.displayData[1]) do
        csv = csv .. i .. "," .. value .. "\n"
    end
    
    local file = io.open(chartId .. ".csv", "w")
    file:write(csv)
    file:close()
end
```

## Comparison to Streaming Overlay

| Feature | Web Overlay | LUA Widget | Notes |
|---------|------------|------------|-------|
| Auto-save positions | ❌ | ✅ | Widget only |
| Team comparison | ❌ | ✅ | Widget only |
| Zero latency | ❌ | ✅ | No WebSocket delay |
| OBS integration | ✅ | ❌ | Web overlay only |
| External viewers | ✅ | ❌ | Web overlay only |
| In-game overlay | ❌ | ✅ | Widget only |
| Customizable per user | ❌ | ✅ | Each player's layout |

## Credits

- **Author**: FilthyMitch
- **Inspired by**: BAR Streaming Overlay System
- **License**: MIT
- **Version**: 2.0

## Changelog

### v2.0.0 (2026-03-05)
- ✅ Added automatic save/load for positions and scales
- ✅ Added Team Army Values comparison chart
- ✅ Added Team Build Power comparison chart
- ✅ Multi-team support with dynamic colors
- ✅ Manual save/reset commands
- ✅ Improved ViewResize handling
- ✅ Better label positioning for multi-series charts

### v1.0.0 (2026-03-05)
- Initial release
- 5 personal stat charts
- Drag/scale/toggle functionality
- Smooth animations
- Matching streaming overlay aesthetic

## Support

For bugs, feature requests, or questions:

1. Check existing issues on GitHub
2. Join BAR Discord: [discord.gg/NK7QWfVE9M](https://discord.gg/NK7QWfVE9M)
3. Post in #widgets channel

## FAQ

**Q: Where is the config file saved?**  
A: In your Spring directory, same location as the widget: `bar_charts_config.lua`

**Q: Can I share my layout with teammates?**  
A: Yes! Just copy your `bar_charts_config.lua` file and send it to them.

**Q: Do multi-team charts work in 1v1?**  
A: Yes, but they'll only show your team (single line).

**Q: Can I see enemy team stats?**  
A: No, Spring API doesn't expose enemy stats for balance reasons.

**Q: Why does Build Power show 0 early game?**  
A: Because you haven't built any constructors/factories yet. It updates as you build.

**Q: Can I change which stats are tracked for teams?**  
A: Yes! Edit the `rebuildMultiTeamSeries()` function to add metal income, energy, etc.

**Q: Performance impact with many teams (6v6, 8v8)?**  
A: Minimal. Each team adds ~10 draw calls. Even 8 teams = <5% CPU.
