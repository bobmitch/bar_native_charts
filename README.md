# BAR Stats Charts Widget v3.2

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
| Toggle a chart on/off | Edit mode → right-click |

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
| `/barcharts fps <n>` | Set max chart render FPS (1–30) at runtime |
| `/barcharts debug` | Print state to console |
| `/barcharts diag` | Print widget initialisation diagnostics |
| `/barcharts bp` | Builder efficiency diagnostic |
| `/barcharts hidepill` / `showpill` | Hide/restore the pill button |

**Config file location:**
- **Windows:** `Documents\My Games\Spring\bar_charts_config.lua`
- **Linux:** `~/.spring/bar_charts_config.lua`

---

## Chart Filtering (Sampling Methods)

Each chart uses a configurable downsampling algorithm to reduce the raw history buffer to the number of screen-space render points. The method is persisted in the config file and survives widget reloads.

| Method | Key | Description |
|---|---|---|
| **Default** | `"default"` | Uniform linear interpolation. Fast and jitter-free; appropriate for most charts. |
| **LTTB** | `"lttb"` | Largest-Triangle-Three-Buckets. Preserves the visual shape of noisy or spiky signals far better than uniform sampling. Used by default on the Builder Efficiency chart. |
| **MinMax** | `"minmax"` | Emits the minimum and maximum value within each bucket as two render points. Ensures no transient spike or trough is hidden. Useful for high-variance rate signals such as metal/energy income. |

The sampling method can be set manually in `bar_charts_config.lua` by adding a `samplingMethod` field to a chart entry (e.g. `samplingMethod = "lttb"`).

---

## Technical Notes

**History:** 120-second ring buffer (18,000 frames at 30 fps), sampled every frame, rendered at 300 points.

**Multi-team buffering:** All ally teams (or all teams in spectator mode) are buffered simultaneously. Switching view is an O(1) pointer swap — no data gaps.

**Spectator mode:** Detected automatically. All active game teams are tracked; the pill and `/barcharts view` can switch between them.

**Builder Efficiency:** Measures how much metal active builders are pulling vs. their theoretical maximum. A **⚠ STALL** warning appears when metal demand outpaces supply.

**Rendering:** Three GLSL shader programs handle all line, fill, and grid drawing — anti-aliased lines with a soft glow, animated fill gradients, and a grid scan-pulse effect. No per-frame Lua geometry loops.

---

## Performance Tuning

Edit near the top of `charts.lua`:

```lua
local HISTORY_SECONDS = 120   -- shorter = less memory (try 60)
local RENDER_POINTS   = 300   -- fewer = less GPU work (try 100)
local MAX_CHART_FPS   = 30    -- lower = less CPU (try 5)
```

You can also change `MAX_CHART_FPS` at runtime without reloading:

```
/barcharts fps 5
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
