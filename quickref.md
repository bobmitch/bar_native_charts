# Quick Reference - Multi-Team Charts & Auto-Save

## New Charts Added

### 1. Team Army Values Chart
**Default Position:** Left side, top  
**What it shows:** Total metal cost of all units for each allied team  
**Use cases:**
- Compare army sizes across teammates
- Identify who needs support
- Track who's rebuilding after losses
- See economic recovery rates

**Reading the chart:**
- Each line = one teammate
- Line color = their in-game team color
- Higher line = bigger army
- Crossovers = one team overtaking another

### 2. Team Build Power Chart
**Default Position:** Left side, bottom  
**What it shows:** Combined buildSpeed of all builders per team  
**Use cases:**
- Coordinate factory timing
- See who can reclaim fastest
- Track eco development
- Identify who needs more factories

**Reading the chart:**
- Each line = one teammate
- Line color = their in-game team color
- Higher line = more construction capacity
- Spikes = new factories/cons built

## Auto-Save System

### What Gets Saved
✅ Chart positions (X, Y coordinates)  
✅ Chart scales (0.5x - 2.0x)  
✅ Chart visibility (shown/hidden)  
✅ Chart enabled state  
✅ Global enabled/disabled (F9 toggle state)

### When It Saves
- Automatically on widget shutdown
- Automatically on game exit
- Manually via `/barcharts save` command

### Config File Location
```
Windows: C:\Users\<You>\Documents\My Games\Spring\bar_charts_config.lua
Linux: ~/.spring/bar_charts_config.lua
Mac: ~/Library/Application Support/Spring/bar_charts_config.lua
```

## Commands

| Command | Effect |
|---------|--------|
| `/barcharts save` | Save current layout immediately |
| `/barcharts reset` | Delete config, restore defaults (requires reload) |
| `/luaui reload` | Reload widget with saved config |

## Typical Workflow

### First Time Setup
1. Enable widget (F11 menu)
2. Press F9 to show charts
3. Drag each chart to desired position
4. Scroll wheel to scale charts
5. Right-click to hide unwanted charts
6. **Exit game** → positions saved automatically

### Next Session
1. Start game
2. Press F9 to show charts
3. **Charts appear in saved positions** ✨
4. Make any adjustments
5. Exit game → new positions saved

## Multi-Team Chart Behavior

### In Different Game Modes

**1v1:**
- Shows only your team (single line)
- Still useful for tracking your own stats

**2v2:**
- Shows 2 lines (you + ally)
- Easy comparison

**4v4:**
- Shows 4 lines (you + 3 allies)
- Colors help identify teammates

**FFA (teams but different allies):**
- Only shows your actual allies
- Updates if alliances change

### Team Colors

Colors match in-game team colors:
```
Team 0 (Red)    → Red line
Team 1 (Blue)   → Blue line  
Team 2 (Green)  → Green line
Team 3 (Yellow) → Yellow line
etc.
```

### Label Format

Multi-team charts show abbreviated names:
```
PlayerNam.. 15K    (Name truncated if >8 chars)
AI(2) 12K          (AI names shown full)
Team 5 8K          (Fallback if no name)
```

## Performance Tips

### For Potato PCs

Edit these values at top of widget file:

```lua
local HISTORY_SIZE = 30        -- Reduced from 60
local UPDATE_INTERVAL = 15     -- Increased from 10
```

### For High-End PCs

```lua
local HISTORY_SIZE = 120       -- Doubled
local UPDATE_INTERVAL = 5      -- Halved for smoother updates
```

### Selective Visibility

Hide charts you don't need:
1. Right-click chart to hide
2. Reduces draw calls by ~20% per chart
3. Config remembers hidden state

## Common Layouts

### Minimalist (4 charts)
```
Keep:
- Metal (income/usage)
- Energy (income/usage)
- Team Army Values (comparison)
- K/D Ratio (performance)

Hide:
- Damage chart (redundant with K/D)
- Army Value (personal, redundant with team chart)
- Team Build Power (situational)
```

### Streamer (all visible, compact)
```
Arrange in 2 rows:
Top row: Metal, Energy, Army, K/D
Bottom row: Damage, Team Army, Team Build Power

Scale all to 0.8x for compactness
Position in top-right corner (non-intrusive)
```

### Competitive (data-heavy)
```
Keep all 7 charts
Scale to 1.2x for readability
Spread across screen edges
Team charts on left (easy glance at allies)
Personal stats on right (main focus)
```

## Troubleshooting Quick Fixes

| Problem | Quick Fix |
|---------|-----------|
| Config not saving | Check Spring folder write permissions |
| Charts overlap | `/barcharts reset` then reposition |
| Wrong colors on teams | `/luaui reload` to refresh colors |
| Chart off-screen after resolution change | `/barcharts reset` |
| Laggy multi-team charts | Reduce HISTORY_SIZE to 30 |
| Missing teammate on chart | Wait 10s for update or restart |

## Integration with Streaming Overlay

You can use **both** systems simultaneously:

**In-game (LUA Widget):**
- Personal reference
- Quick glances
- Team comparison

**Streaming Overlay (Web):**
- Viewer engagement
- OBS scenes
- External displays

They complement each other!

## Data Update Cycle

```
Every 10 seconds:
1. Widget calls Spring.GetTeamResourceStats() for all teams
2. Widget calculates army values (iterates all units)
3. Widget calculates build power (sums builder speeds)
4. Widget adds data point to history (max 60 points)
5. Animation starts (400ms lerp)
6. Chart redraws with new data

Timeline:
0.0s  - Data collected
0.4s  - Animation complete
10.0s - Next update
```

## Build Power Breakdown

Units that contribute to build power:

| Unit Type | Typical buildSpeed |
|-----------|-------------------|
| Commander | 300 |
| T1 Constructor | 75 |
| T2 Constructor | 150 |
| T1 Factory | 100 |
| T2 Factory | 200 |
| T3 Factory | 300 |
| Nano Turret | 50 |
| Repair Pad | 100 |

**Total Build Power = Sum of all above**

Example:
- 1 Commander (300)
- 3 T1 Cons (225)
- 2 T1 Factories (200)
= **725 total build power**

## Advanced: Manual Config Edit

You can manually edit `bar_charts_config.lua`:

```lua
return {
  version = "1.0",
  enabled = true,
  charts = {
    ["chart-ally-army"] = {
      x = 100,           -- Move to x=100
      y = 818,           -- Move to y=818
      scale = 1.5,       -- Make 1.5x larger
      visible = true,    -- Show
      enabled = true     -- Enabled
    }
  }
}
```

Save file, then `/luaui reload` to apply.

## Keyboard Shortcuts Summary

| Key | Action |
|-----|--------|
| F9 | Toggle all charts on/off |
| F11 | Widget menu (enable/disable widget) |
| Left Click + Drag | Move chart |
| Right Click | Hide/show individual chart |
| Scroll Wheel (over chart) | Scale chart |
| Esc | Release drag (if stuck) |

## Example Usage Scenarios

### Scenario 1: Eco Advisor
**Goal:** Help struggling teammate

1. Watch Team Build Power chart
2. Notice ally's line is flat while others climb
3. Check Team Army Values - they're also behind
4. Conclusion: They're stalling, need metal
5. Action: Share metal or suggest mexes

### Scenario 2: Army Comparison
**Goal:** Decide when to attack

1. Watch Team Army Values chart
2. Your team's lines are higher than usual
3. Means you have army advantage
4. Good time to coordinate push

### Scenario 3: Comeback Detection
**Goal:** Know when you're recovering

1. After big loss, your army value drops
2. Watch Team Build Power - still high
3. Army value line starts climbing again
4. You're rebuilding successfully

### Scenario 4: Factory Timing
**Goal:** Match teammate's production

1. Watch Team Build Power chart
2. Ally's line suddenly jumps up
3. Means they built new factory
4. You should consider same to keep pace
