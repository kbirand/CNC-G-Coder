# CNC G-Coder

A native macOS app for milling PCBs on a hobby CNC — from an EasyEDA Gerber export to ready-to-run G-code, with a live, feed-rate-accurate toolpath simulator.

CNC G-Coder drives [pcb2gcode](https://github.com/pcb2gcode/pcb2gcode) under the hood and adds everything around it: automatic layer detection, a full graphical preview with playback, a Z side view for verifying depths, honest machining-time estimates, solder-mask etching programs, and a parameter-calibration test board generator.

## Features

### Complete PCB workflow
- **Isolation milling** for front and back copper (back side automatically mirrored around your flip axis, CNC-ready)
- **Drilling** — one program per EasyEDA drill file (PTH / via / NPTH), with tool-change pauses
- **Board cutout** with configurable holding bridges (width, count, depth)
- **Solder mask etching** — after you paint and UV-cure the mask, generated programs mill the pad/via openings clear (pcb2gcode's `--invert-gerbers` pocketing; also supports SVG export for laser ablation instead)
- One-click **Generate** writes all `.ngc` programs into a folder you choose (create one on the spot with the dialog's New Folder button)

### Live preview
- **Per-program toolpath view** with cursor-anchored zoom/pan, real cutter-width swaths, drill hits, and white bridge-tab markers
- **Head travel in yellow** — rapids are visually distinct from cutting, and the tool never drags through waste copper between contours (path finding disabled: cleaner boards, honest travel)
- **Playback simulator** — scrub or play any program at 1× real machining speed (or 2–200×); the tool glides along every move using the actual programmed feeds, with the current G-code line highlighted in the source view
- **Side view** — X–Z / Y–Z projections or a Z-vs-distance profile with labeled reference lines (Z0, zwork, zdrill, zcut, zbridge, zsafe) for verifying every depth before cutting
- **Flip back view** — un-mirrors back-side programs on screen to verify front/back registration (output stays mirrored)
- **Machining-time estimates** — per program and total, computed from path lengths and programmed feeds
- **Plunge optimization** — vertical moves rapid through the air and feed only near the board (configurable clearance), often halving program time vs raw pcb2gcode output
- Preview regenerates automatically as you edit parameters (debounced; manual mode available in Settings)

### Calibration
- **File → Generate Test Board…** creates a parameter-sweep test board: a grid of patches where rows sweep cut depth and columns sweep XY feed. Each patch contains 0.2 / 0.3 / 0.4 mm trace-survival tests and a pad with a production-style cleared moat. Engraved spreadsheet-style headers (A B C… / 1 2 3…) plus a legend file let you read the winning combination straight off the milled board.

### Quality of life
- **Layer-focused sidebar** — pick a program in the layer menu and see just that program's settings (native Liquid Glass design on macOS 26)
- Parameter **presets** (save/recall complete setups per material or machine)
- Detailed **tooltips on every control** and a built-in user guide (⌘?)
- All settings, window layout, and panel sizes persist across launches

## Requirements

- macOS 13+ (Apple Silicon or Intel)
- [pcb2gcode](https://github.com/pcb2gcode/pcb2gcode) and optionally [gerbv](https://gerbv.github.io) (for laser-SVG mask export):

```bash
brew install pcb2gcode gerbv
```

## Building

Open `CNC G-Coder.xcodeproj` in Xcode 15+ and press Run, or:

```bash
xcodebuild -project "CNC G-Coder.xcodeproj" -scheme "CNC G-Coder" -configuration Release build
```

> Note: the app launches Homebrew binaries via `Process`, so App Sandbox is intentionally disabled in the project settings.

## Quick start

1. In EasyEDA, export Gerber + drill files into a folder.
2. Launch CNC G-Coder → **Choose Folder** — layers are detected by filename (`Gerber_TopLayer.GTL`, `Gerber_BottomLayer.GBL`, `Gerber_BoardOutlineLayer.GKO`, `.GTS`/`.GBS` masks, all `.DRL` files).
3. Set tools, depths and feeds — the sidebar shows the selected program's settings (Machine setup holds the shared ones); watch the preview and the Σ time estimate update.
4. Inspect each program: play it back, check depths in the side view.
5. **Generate G-code** and send the `.ngc` files to your machine (UGS, Candle, …).

Machining order: front isolation → drills (bit changes at M0 pauses) → flip → back isolation → outline cutout → snap/file the bridge tabs → paint & cure solder mask → run the mask etch programs.

## ⚠️ Know your tool: V-bits and effective diameter

Every diameter parameter must be the **effective cutting diameter at depth** — with the exact bit you'll machine with.

- Straight bits / end mills: effective = printed diameter.
- **V-bits** (the common choice for isolation): the cone widens with depth:

  ```
  effective ≈ tip + 2 × |cut depth| × tan(half-angle)
  ```

  A 0.1 mm-tip 60° V-bit at −0.06 mm cut depth really cuts ≈ **0.17 mm**. Enter *that*, not 0.1 — otherwise every trace comes out thinner than designed and your isolation clearance is silently wrong.

The built-in test board is the cross-check: measure the 0.2 mm test trace after milling; any deviation tells you exactly how far off your entered diameter is.

## Notes on machine setup

- All programs share one origin per side (the app normalizes pcb2gcode's per-invocation origins): zero X/Y once at the project corner for the front-side programs, once more after flipping for the back side, and Z on the board surface — copper, drills and masks stay registered.
- Choose the flip direction (*Mirror around Y axis*) to match how you physically turn the board and verify with *Flip Back View* — the flipped back must sit exactly over the front.
- The app intentionally generates **no probing/height-map G-code** — use your sender's autolevel (e.g. UGS AutoLeveler) for the isolation programs on anything less than perfectly flat stock.
- Playback rapids are simulated at 2000 mm/min (G-code carries no rapid feed); cutting times are exact per the programmed feeds.

## Roadmap

Planned: turning CNC G-Coder from a G-code generator into a complete milling station — no external sender needed.

- [ ] **Direct machine control over USB (GRBL)** — connect to a GRBL controller via USB/serial, jog the machine, and stream the generated programs straight from the app; the playback simulator becomes the live machining monitor (real tool position on the toolpath, current line, time remaining)
- [ ] **Z probing & X/Y zeroing** — touch-off the board surface for Z0 and set the X/Y work origin from the app, guided per side to match the shared-origin scheme
- [ ] **Auto height / auto-leveling** — probe a height map across the copper and warp the isolation G-code to the measured surface, replacing external autolevel tools (UGS AutoLeveler)

## Documentation

The full user guide lives in the app (**⌘?** or the *?* button) and in [HELP.md](HELP.md): workflow details, a parameter reference with machining guidance, preview/playback semantics, and troubleshooting.

## Acknowledgments

- [pcb2gcode](https://github.com/pcb2gcode/pcb2gcode) — the isolation-routing engine this app drives
- [gerbv](https://gerbv.github.io) — Gerber → SVG export for laser solder-mask workflows
