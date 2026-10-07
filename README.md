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

- macOS 26+ (Apple Silicon)
- Nothing else to install: the app carries its own copy of
  [pcb2gcode](https://github.com/pcb2gcode/pcb2gcode), and has a native
  toolpath engine of its own (Machine setup → Toolpath engine).

## Building

Open `CNC G-Coder.xcodeproj` in Xcode and press Run, or:

```bash
xcodebuild -project "CNC G-Coder.xcodeproj" -scheme "CNC G-Coder" -configuration Release build
```

The **Bundle pcb2gcode** build phase ([Scripts/bundle-pcb2gcode.sh](Scripts/bundle-pcb2gcode.sh))
copies pcb2gcode and the ~35 libraries it loads into `Contents/Helpers`,
rewrites their load paths to stay inside the app and signs them — so the
*build* machine needs `brew install pcb2gcode`, the people using the app do
not. Built without it, the app still works on the native engine.

The native engine uses [Clipper2](https://github.com/AngusJohnson/Clipper2)
(vendored in `CNC G-Coder/ThirdParty`, Boost licence) for polygon offsetting.

> The app is sandboxed. pcb2gcode runs as a subprocess that inherits the app's sandbox (signed with `Scripts/pcb2gcode-helper.entitlements`), working on copies of the input files in the app's temporary folder.
>
> Two schemes: **CNC G-Coder** bundles pcb2gcode (direct distribution); **CNC G-Coder (App Store)** builds the AppStore configuration without it — native engine only, no engine picker. Listing details for App Store Connect: [appconnect.md](appconnect.md).

## Quick start

1. In EasyEDA, export Gerber + drill files into a folder.
2. Launch CNC G-Coder → **Choose Folder** — layers are detected by filename (`Gerber_TopLayer.GTL`, `Gerber_BottomLayer.GBL`, `Gerber_BoardOutlineLayer.GKO`, `.GTS`/`.GBS` masks, all `.DRL` files).
3. Set tools, depths and feeds — the sidebar shows the selected program's settings (Machine setup holds the shared ones); watch the preview and the Σ time estimate update.
4. Inspect each program: play it back, check depths in the side view.
5. **Generate G-code**, then open the **Machine** window (⇧⌘M) to connect to your GRBL/FluidNC controller, zero, probe and send each program — or save the `.ngc` files for another sender.

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
- Choose the flip direction (*Board flips*) to match how you physically turn the board and verify with *Un-mirror Back Side* — the flipped back must sit exactly over the front.
- Probing and height maps are done live from the Machine panel (Probe and Height Map tabs); the generated programs themselves stay plain G-code, and the height map is applied to the copy that is streamed.
- Playback rapids are simulated at 2000 mm/min (G-code carries no rapid feed); cutting times are exact per the programmed feeds.

## Machine control

The **Machine** panel (toolbar button or View → Machine Panel, ⇧⌘M; a right-hand inspector of the main window, also openable as its own window) is a native sender for GRBL 1.1 and FluidNC controllers, over Wi‑Fi (TCP/telnet, port 23) or USB serial:

- Connection bar with live state, firmware badge and decoded alarms; DRO with work and machine positions, feed/spindle, buffer and pin readouts; zero X/Y/Z, set an axis, go to work zero, safe Z; saved machine positions and go-to.
- Jog pad with step and continuous (hold) jogging, diagonals and keyboard control; feed, rapid and spindle overrides; spindle and coolant control; Home, Unlock, Reset, Hold/Resume, Check mode.
- **Program tab**: pick any generated layer (or an external `.ngc`), optionally apply backlash compensation and the height map, verify it in check mode, and stream it with per-line progress. The main window's canvases, side view, 3D view and G-code tab follow the running job, with a blue marker at the machine's actual position. Tool changes suspend the job at the change point so you can swap the bit and re-probe Z before continuing; Send-from-line resumes safely.
- **Probe tab**: two-pass Z touch-off (bit on copper with a clip, or a touch plate of known thickness) that sets the active work origin from the exact trigger point.
- **Height Map tab**: probe a grid over the board, see the deviation, and warp the streamed program to the measured surface (bilinear, per side).
- Console with command history and user macros.
- **Simulator** transport (shown in the connection picker once enabled in Settings → Machine): a built-in FluidNC simulator (`Scripts/fake-grbl.py`, bundled; needs python3) the app launches on a private port, for trying the whole Machine panel — jogging, programs, probing, height maps — without a machine. The state pill is tagged SIM while it is connected.

## Roadmap

- [x] Direct machine control (GRBL/FluidNC over Wi‑Fi or USB), live machining monitor
- [x] Z probing & X/Y zeroing from the app
- [x] Auto-leveling with a probed height map
- [ ] X/Y edge and corner probing with a known probe diameter
- [ ] WebSocket transport for FluidNC WebUI setups

## Documentation

The full user guide lives in the app (**⌘?** or the *?* button) and in [HELP.md](HELP.md): workflow details, a parameter reference with machining guidance, preview/playback semantics, and troubleshooting.

## Acknowledgments

- [pcb2gcode](https://github.com/pcb2gcode/pcb2gcode) — the isolation-routing engine the app bundles and drives (GPL-3.0, shipped as a separate program)
- [Clipper2](https://github.com/AngusJohnson/Clipper2) — polygon clipping and offsetting for the native engine (Boost Software License)
