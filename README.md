# BAR Stats Charts Widget v2.0

Real-time resource and combat stats overlay for Beyond All Reason.

For audio triggers, animations and a more streamer oriented tool, see the sister project: [Bar Announcer](https://github.com/bobmitch/bar)

![New Project (1)](https://github.com/user-attachments/assets/77d7a8c6-b317-4e65-8e11-7e71cd9578f6)


## Installation
 
1. Download `charts.lua` and `bar_charts_toggle.rml`
2. Copy both to your BAR widgets folder:
   - **Windows:** `Documents\My Games\Spring\LuaUI\Widgets\`
   - **Linux:** `~/.spring/LuaUI/Widgets/`
   - **Mac:** `~/Library/Application Support/Spring/LuaUI/Widgets/`
3. In-game: **F11** → enable **BAR Stats Charts**
4. **F9** to show/hide
 
---
 
## Charts & Cards
 
**Line charts (your team):** Metal Income/Usage · Energy Income/Usage · Damage Dealt/Taken · Army Value · K/D Ratio · Builder Efficiency
 
**Multi-line charts (all allies):** Team Army Values · Team Build Power
 
**Stat cards:** Army Value · Unit Count · Kills · Losses · Damage Dealt/Taken · Metal Lost · Build Efficiency
 
---
 
## Controls
 
| Action | How |
|---|---|
| Show/hide all | **F9** |
| Toggle edit mode | Click the **CHARTS: LOCKED** pill (top-right), or `/barcharts edit` |
| Move a chart | Edit mode → drag |
| Resize a chart | Edit mode → scroll wheel |
| Hide one chart | Edit mode → right-click |
 
> Charts are **locked by default** to prevent accidental moves during play.
 
---
 
## Layout Saving
 
Positions, scales, and visibility save automatically on exit and restore next session.
 
| Command | Effect |
|---|---|
| `/barcharts save` | Save immediately |
| `/barcharts reset` | Restore defaults (then `/luaui reload`) |
| `/barcharts edit` | Toggle edit/locked mode |
| `/barcharts view <name\|id>` | Switch viewed team (spectator / ally) |
| `/barcharts debug` | Print state to console |
| `/barcharts bp` | Builder efficiency diagnostic |
| `/barcharts hidepill` / `showpill` | Hide/restore the pill button |
 
**Config file location:**
- **Windows:** `Documents\My Games\Spring\bar_charts_config.lua`
- **Linux:** `~/.spring/bar_charts_config.lua`
 
---
 
## Technical Notes
 
**History:** 60-second ring buffer (1800 frames at 30 fps), sampled every frame, rendered at up to 150 points.
 
**Multi-team buffering:** All ally teams (or all teams in spectator mode) are buffered simultaneously. Switching view is an O(1) pointer swap — no data gaps.
 
**Spectator mode:** Detected automatically. All active game teams are tracked; the pill and `/barcharts view` can switch between them.
 
**Builder Efficiency:** Measures how much metal active builders are pulling vs. their theoretical maximum. A **⚠ STALL** warning appears when metal demand outpaces supply.
 
---
 
## Performance Tuning
 
Edit near the top of `charts.lua`:
 
```lua
local HISTORY_SIZE    = 1800  -- lower = less memory (try 900)
local UPDATE_INTERVAL = 30    -- higher = less CPU (try 60)
```
 
---
 
## Troubleshooting
 
| Problem | Fix |
|---|---|
| Charts won't save | Check write permissions on your Spring folder |
| Team charts show "awaiting data" | Wait ~10s after game start |
| Charts off-screen after resolution change | `/barcharts reset` |
| Wrong team colors | `/luaui reload` |
| Can't move charts | Confirm pill shows **CHARTS: EDIT** |
 
---
 
## Support
 
- BAR Discord: [discord.gg/NK7QWfVE9M](https://discord.gg/NK7QWfVE9M) → `#widgets`
- GitHub Issues
 
**Author:** FilthyMitch · **License:** MIT · **Thanks to:** SuperKitowiec and SHiFT_DeL3TE for testing
