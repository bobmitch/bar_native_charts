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
| Hide one chart | Edit mode → right-click |

> Charts are **locked by default** to prevent accidental moves during play.

---

## Layout Saving

Positions, scales, visibility, and sampling methods save automatically on exit and restore next session.

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

## Sampling Methods

Each chart independently controls how its raw 30 fps ring-buffer data is downsampled to the ~300 render points drawn on screen. Three algorithms are available:

### `default` — Uniform linear interpolation
Output points are spaced evenly across the history window. Each point is linearly interpolated between its two nearest raw samples, eliminating the quantisation jitter present in older nearest-neighbour approaches. Fast and appropriate for most charts.

### `lttb` — Largest Triangle Three Buckets
For each interior output bucket, the raw sample that maximises the triangle area formed with the previously-selected point and the mean of the next bucket is chosen. This ensures that every significant peak and valley in the signal appears in the rendered line, regardless of where the uniform grid would have landed.

**Applied by default to the Builder Efficiency chart**, where a momentary stall or spike should always be visible even in a long game window.

### `minmax` — Min/Max interleaved per bucket
Each bucket emits two output points: its minimum value and its maximum value, in their actual time order. No transient spike or trough can be hidden between grid points. The rendered line will appear thicker or more jagged in highly variable sections — which is the information this method is designed to show.

Best for high-variance rate signals such as metal and energy income/usage, where a brief stall or windfall should never be lost to downsampling.

### Changing a chart's sampling method

Set the method at the top of `charts.lua` in `buildChartsAndCards()` by passing the constant as the 9th argument to `Chart.new()`:

```lua
-- Available constants: SAMPLE_DEFAULT, SAMPLE_LTTB, SAMPLE_MINMAX
charts.metal = Chart.new("chart-metal", "METAL", "⚙",
    vsx-350, vsy-230, "dual", {
        { label="Income", color=COLOR.accent,  seriesKey="metalIncome" },
        { label="Usage",  color=COLOR.accent2, seriesKey="metalUsage"  },
    }, false, SAMPLE_MINMAX)   -- ← swap method here
```

You can also set it directly on a chart object at runtime — the change takes effect on the next render frame:

```lua
charts.metal.samplingMethod = "minmax"
```

The method is persisted in the config file, so it survives widget reloads.

| Chart | Default method | Recommended alternatives |
|---|---|---|
| Metal Income/Usage | `default` | `minmax` to preserve income spikes |
| Energy Income/Usage | `default` | `minmax` to preserve energy spikes |
| Damage Dealt/Taken | `default` | — (cumulative data; minmax adds no value) |
| Army Value | `default` | — |
| K/D Ratio | `default` | `lttb` for smoother curve at long timescales |
| **Builder Efficiency** | **`lttb`** | `default` for lighter CPU use |
| Team Army / Team BP | `default` | — |

---

## Technical Notes

**History:** 120-second ring buffer (18,000 frames at 30 fps), sampled every frame, downsampled to 300 render points per chart.

**Rendering:** Three GLSL shader programs handle all line and fill drawing — an AA ribbon shader, an animated area-fill shader, and a background scan-pulse grid shader. Display lists are rebuilt at up to 30 fps and only when data changes.

**Interpolation (v3.1+):** The default sampler uses true floating-point linear interpolation between adjacent raw samples. This eliminates the quantisation jitter that older nearest-neighbour approaches produced as the ring buffer grew frame by frame.

**LTTB (v3.2+):** The Largest Triangle Three Buckets algorithm (Steinarsson 2013) preserves the visual shape of a signal far better than uniform sampling when the data is noisy or has sharp, short-lived peaks. CPU cost is ~2–5× higher than the default sampler per series call, which is negligible on any hardware capable of running BAR.

**MinMax (v3.2+):** Guarantees spike and trough visibility at the cost of a noisier-looking line. Each bucket contributes a min/max pair (150 buckets × 2 = 300 output points), so temporal density is halved compared to the default method.

**Multi-team buffering:** All ally teams (or all teams in spectator mode) are buffered simultaneously. Switching view is an O(1) pointer swap — no data gaps.

**Spectator mode:** Detected automatically. All active game teams are tracked; the pill and `/barcharts view` can switch between them.

**Builder Efficiency:** Measures how much metal active builders are pulling vs. their theoretical maximum. A **⚠ STALL** warning appears when metal demand outpaces supply. Uses LTTB sampling by default so brief efficiency drops are always visible.

---

## Performance Tuning

Edit near the top of `charts.lua`:

```lua
local HISTORY_SECONDS = 120   -- history window length; try 60 for less memory
local RENDER_POINTS   = 300   -- output points per chart; try 100 for lighter GPU uploads
local MAX_CHART_FPS   = 30    -- display list rebuild rate; try 5–10 for lighter CPU
```

Switching the Builder Efficiency chart from `SAMPLE_LTTB` to `SAMPLE_DEFAULT` saves a small amount of CPU if you are running many charts at low frame rates.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Charts won't save | Check write permissions on your Spring folder |
| Team charts show "awaiting data" | Wait ~10s after game start |
| Charts off-screen after resolution change | `/barcharts reset` |
| Wrong team colors | `/luaui reload` |
| Can't move charts | Confirm pill shows **CHARTS: EDIT** |
| Efficiency chart looks too smooth / too noisy | Change its `samplingMethod` to `default` or `minmax` |

---

## Support

- BAR Discord: [discord.gg/NK7QWfVE9M](https://discord.gg/NK7QWfVE9M) → `#widgets`
- GitHub Issues

**Author:** FilthyMitch · **License:** MIT · **Thanks to:** SuperKitowiec and SHiFT_DeL3TE for testing
