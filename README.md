# BAR Stats Charts Widget v2.0

Real-time resource and combat stats overlay for Beyond All Reason.

For audio triggers, animations and a more streamer oriented tool, see the sister project: [Bar Announcer](https://github.com/bobmitch/bar)

![New Project (1)](https://github.com/user-attachments/assets/77d7a8c6-b317-4e65-8e11-7e71cd9578f6)


## Installation

1. Download `charts.lua` and `bar_charts_toggle.rml`
2. Copy both files to your BAR widgets folder:
   - **Windows:** `C:\Users\<YourName>\Documents\My Games\Spring\LuaUI\Widgets\`
   - **Linux:** `~/.spring/LuaUI/Widgets/`
   - **Mac:** `~/Library/Application Support/Spring/LuaUI/Widgets/`
3. Launch BAR → press **F11** → enable **"BAR Stats Charts"**
4. Press **F9** to show/hide the charts

## Charts Included

**Personal (line charts):**
- Metal Income / Usage
- Energy Income / Usage
- Damage Dealt / Taken
- Army Value
- K/D Ratio
- Builder Efficiency

**Team Comparison (multi-line):**
- Team Army Values — compare army sizes across all allies
- Team Build Power — compare total construction capacity

**Stat Cards (numeric readouts):**
Army Value, Unit Count, Kills, Losses, Damage Dealt/Taken, Metal Lost, Build Efficiency

## Controls

| Action | How |
|--------|-----|
| Show/hide all charts | **F9** |
| Enable edit mode | Click the **CHARTS: LOCKED** pill (top-right) |
| Move a chart | Edit mode ON → click and drag |
| Resize a chart | Edit mode ON → scroll wheel over chart |
| Hide one chart | Edit mode ON → right-click chart |
| Toggle edit from chat | `/barcharts edit` |

> Charts are **locked by default** during gameplay so you can't accidentally move them. Click the pill button or type `/barcharts edit` to unlock.

## Layout Saving

Your chart positions, sizes, and visibility are saved automatically when you exit. They restore next session.

- **Save now:** `/barcharts save`
- **Reset to defaults:** `/barcharts reset` (then `/luaui reload`)

Config is stored at:
- **Windows:** `C:\Users\<You>\Documents\My Games\Spring\bar_charts_config.lua`
- **Linux:** `~/.spring/bar_charts_config.lua`

## Build Efficiency Card

Shows how efficiently your builders are using available metal (0–100%). A **⚠ STALL** warning appears on affected charts/cards when your metal demand is outpacing supply.

## Performance

Default settings are fine for most PCs. If you experience lag, open the widget file and adjust these values near the top:

```lua
local HISTORY_SIZE    = 60   -- lower = less memory (try 30)
local UPDATE_INTERVAL = 10   -- higher = less CPU (try 15)
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Charts won't save | Check write permissions on your Spring folder |
| Team charts show "awaiting data" | Wait 10s after game start; must have live teammates |
| Charts off-screen after resolution change | `/barcharts reset` then reposition |
| Wrong team colors | `/luaui reload` |
| Can't move charts | Make sure edit mode is ON (pill shows **CHARTS: EDIT**) |

## Commands

| Command | Effect |
|---------|--------|
| `/barcharts save` | Save layout immediately |
| `/barcharts reset` | Restore default layout (requires `/luaui reload`) |
| `/barcharts edit` | Toggle edit/locked mode |
| `/barcharts debug` | Print current state to console |
| `/barcharts bp` | Print builder efficiency diagnostic |

## Support

- BAR Discord: [discord.gg/NK7QWfVE9M](https://discord.gg/NK7QWfVE9M) → `#widgets`
- GitHub issues

## Thanks

Thanks to SuperKitowiec and SHiFT_DeL3TE for early feedback and testing.

**Author:** FilthyMitch | **License:** MIT
