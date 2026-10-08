# CNC G-Coder — rebuild plan

A step-by-step plan for recreating CNC G-Coder from scratch with an AI coding agent. It describes what the app does, how it is built, the rules the existing code learned the hard way, and an order of work with acceptance checks for each stage. Read the whole plan before writing code; the later sections constrain the earlier ones.

---

## 1. What the app is

CNC G-Coder is a native macOS app that turns a PCB design export (Gerber + Excellon drill files, as EasyEDA writes them) into ready-to-run G-code for a hobby CNC router, previews every program with a feed-rate-accurate simulator, and streams the programs to a GRBL 1.1 / FluidNC controller over Wi‑Fi or USB, with probing, autolevel and live monitoring.

One sentence per subsystem:

1. **Detection**: find the layer files in an export folder by name and content.
2. **Parameters**: every machining value, per settings group, with per-drill-file overrides, tool library integration, presets, undo.
3. **Toolpath engines**: pcb2gcode (bundled subprocess) or a native Clipper2-based engine; both write identically-shaped `.ngc` programs.
4. **Post-processing**: dwells, spindle direction, extra cut, pecks, plunge optimisation, origin normalisation, applied uniformly to any engine's output.
5. **Preview**: parse the programs, draw them in 2D and 3D, play them back at real machining speed, show a Z side view, estimate times.
6. **Editors**: hand-drawn custom layers (shapes, text) and in-place editing of imported Gerber/drill files.
7. **Project**: a `.cncproj` package holding parameters and the layer files; app-wide undo.
8. **Generate/export**: write all programs to a folder, export one program, export laser artwork (SVG/PDF/PNG).
9. **Calibration**: parameter-sweep test board, backlash test and compensation, steps/mm calibration.
10. **Machine control**: transports, protocol, controller session, streamer with flow control, tool-change suspension, probing, height maps, saved positions, macros, console, a bundled simulator.
11. **Help**: tooltips on every control, an in-app guide, HELP.md.

The user is a hobbyist milling PCBs on a small machine. The app's voice is plain, concrete, and explains *why* (what the machine will do), never just *what*.

---

## 2. Platform and toolchain

- **Language/UI**: Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; SwiftUI for all views, AppKit where SwiftUI is not enough (NSTextView-backed text views, NSOpenPanel/NSSavePanel, window sizing, serial I/O, event monitors). SceneKit for the 3D view.
- **Target**: macOS 26+, Apple Silicon. Liquid Glass styling where the system offers it (floating glass bars over the canvas).
- **Project**: one Xcode project, one app target, two schemes:
  - `CNC G-Coder` — bundles pcb2gcode (direct distribution).
  - `CNC G-Coder (App Store)` — an `AppStore` build configuration with `BUNDLE_PCB2GCODE=NO`; native engine only, no engine picker, no GPL binary.
- **Sandbox**: App Sandbox on, entitlements: user-selected read/write, app-scope bookmarks, network client+server, serial and USB devices. pcb2gcode runs as a child signed with `app-sandbox` + `inherit` entitlements and only ever reads copies of inputs placed in the app's own temp folder.
- **Dependencies** (no SPM needed):
  - **Clipper2** vendored under `ThirdParty/Clipper2` with a tiny C shim (`ThirdParty/ClipperShim`, exposed through the bridging header) for union/difference/intersection/clip-lines/inflate on integer coordinates (0.1 µm units).
  - **pcb2gcode** from Homebrew at build time; a build-phase script copies the binary and its ~35 dylibs into `Contents/Helpers`, rewrites load paths to `@rpath`, signs them, and drops the GPL notice into `Resources`.
  - **python3** at runtime only for the optional simulator (`Scripts/fake-grbl.py`, copied into `Resources`).
- **Build commands**:
  ```
  xcodebuild -project "CNC G-Coder.xcodeproj" -scheme "CNC G-Coder" -configuration Release build
  xcodebuild -project "CNC G-Coder.xcodeproj" -scheme "CNC G-Coder (App Store)" build
  ```
- No unit-test target exists today. Verification is done by launching the app headless with debug launch arguments (section 12). Adding a test target for the pure, `nonisolated` parts (protocol parsing, G-code parsing, post-processing, height map maths) is encouraged.

---

## 3. Architecture

### 3.1 Layers

```
App entry (scenes, menus, AppDelegate)
└── AppModel (@MainActor ObservableObject, the root)
    ├── ParametersStore      machining parameters (AppStorage + per-drill-file dict)
    ├── ToolLibrary          cutters with cutting data (Application Support JSON)
    ├── PreviewController    debounced regeneration, PreviewDocument
    ├── PlaybackState        simulated clock, selected layer, running job identity
    ├── ShapeEditor          custom-layer drawing state + undo
    ├── LayerFileEditor      editing imported Gerber/drill files
    ├── UndoManager          one history for the whole app
    └── MachineController    GRBL/FluidNC session (owns transports, JobStreamer)
Services (nonisolated, mostly pure): detector, engines, post-processing, parsers,
  readers/writers for Gerber/Excellon, export, test boards, backlash, protocol…
Views: ContentView (3-column split), sidebar form, preview pane with canvases,
  machine panel/window, tool library, settings, help, dialogs.
```

### 3.2 Rules

- Everything that touches UI state is on the main actor. Heavy work (pcb2gcode, native engine, parsing multi-MB programs, bitmap painting) runs in detached tasks on **value snapshots** (`ParameterSnapshot`, `DetectedFiles`, arrays of custom layers). Never hand a class to a background task.
- Units are millimetres, mm/min, rpm, percent everywhere internally. `UnitSystem` converts only at the edges of text fields (imperial display).
- All geometry is in **design coordinates** (the Gerber frame, Y up). Programs are in **program frames**: front = design, back = mirrored about the mirror axis (X or Y), both then shifted by origin normalisation. `ProjectFrame` holds `designToFront` / `designToBack` transforms and every view/editor goes through it.
- The preview regenerates from a **signature** string (parameters + files + custom layers). Equal signature = nothing to do; the signature includes resolved values (drill bit specs from the library, the automatic mask clear width) so indirect edits also refresh.
- Programs are plain G-code files on disk; anything applied for the machine (backlash, height map, Z clamp) is applied to a **copy that is streamed**, never to the files.

---

## 4. Domain model

### 4.1 Layer roles and program kinds

```swift
enum LayerSlot { front, back, outline, topMask, bottomMask, topSilk, bottomSilk, drill }  // drill holds a list
struct DetectedFiles { front, back, outline, topMask, bottomMask, topSilk, bottomSilk: URL?; drills: [URL] }

enum LayerKind: Hashable, Comparable {
  front, back, outline
  drill(index: Int, name: String)        // one per drill file (name = file stem)
  millDrill(index: Int, name: String)    // "… milled": large holes of the same file, helical
  maskTop, maskBottom, silkTop, silkBottom
  custom(CustomLayerRef)                 // drawn layer
  test                                   // an externally loaded .ngc
}
```
Each kind has a display name, a `fileSlug` (`front-copper`, `drill-npth-through`, `top-mask-etch`…), a board side (back, bottom mask, bottom silk and back-side custom layers are mirrored), a colour, a settings section, an ordering rank (copper, outline, drills with milled right after each, masks, silk, custom, test), an edit target (the file it came from), and `drillSibling` (drilled ↔ milled of the same file).

### 4.2 Parameters

`ParametersStore` is an `ObservableObject` whose fields are `@AppStorage("param.<key>")` so a new project inherits the last-used values. A static table maps preset keys to key paths for every string and bool field; `exportValues()`/`apply()`/`signature` all derive from that one table so a new field cannot be forgotten.

Groups and their keys (all strings unless noted):

| Group | Keys |
|---|---|
| Isolation | millToolID, millShape (flat/vbit), millDiameter, millVTip, millVAngle, isolationWidth, zWork, millInfeed, millOverlap, millFeed, millVertFeed, millSpeed, millDwell |
| Drilling | drillToolID, zDrill, drillFeed, drillSpeed, drillPeck, drillBitIDs (comma list of library IDs), drillBitTolerance, drillHoleAllowance, drillDwell |
| Hole milling | drillMillLarge (bool), drillMillFrom, holeMillToolID, holeMillDiameter, holeMillDepth, holeMillInfeed, holeMillFeed, holeMillVertFeed, holeMillSpeed, holeMillDwell |
| Cutout | cutToolID, cutterDiameter, zCut, cutFeed, cutVertFeed, cutSpeed, cutInfeed, bridgeWidth, bridgeCount, zBridge, cutDwell |
| Mask | maskMode (off/gcode/svg), maskToolID, maskShape, maskTool, maskVTip, maskVAngle, maskDepth, maskClearWidth, maskClearAuto (bool), maskOverlap, maskFeed, maskVertFeed, maskSpeed, maskDwell |
| Silk | silkMode (off/gcode), silkToolID, silkShape, silkTool, silkVTip, silkVAngle, silkDepth, silkClearWidth, silkOverlap, silkFeed, silkVertFeed, silkSpeed, silkDwell |
| Setup | zSafe, zChange, plungeClearance, millDirection (any/climb/conventional), mirrorAxis, mirrorYAxis (bool), zeroStart (bool), originMode (bottomLeft/bottomRight/topLeft/topRight/center/custom), originX, originY, rapidFeed, engine (pcb2gcode/native) |
| Per motion group (prefix iso/drill/holeMill/cut/mask/silk) | `<g>TravelZ`, `<g>ChangeZ` (empty = Machine setup's), `<g>ExtraCut` (iso/mask/silk), `<g>Direction` (iso/cut/mask/silk; empty = machine default), `<g>SpindleDir` (cw/ccw) |

Derived values: effective V-bit diameter `tip + 2·|depth|·tan(angle/2)`; isolation pass count; the automatic mask clear width `ceil((widestOpening/2 + 0.05)·100)/100` from the measured mask layers.

**Per drill file.** `drillLayerValues: [fileName: [key: value]]` (published, not in UserDefaults). Any key of the Drilling/Hole milling groups, their heights and spindle directions may be overridden per drill file; a missing key follows the default. The sidebar edits the selected drill program's file; new files start from the defaults; replacing a file carries its values over; New Project / Open Gerber Folder clear the dictionary (EasyEDA names files identically in every export); applying a preset clears it. Saved in the project next to each drill entry.

**Snapshot.** `ParameterSnapshot` is a `Sendable` value with effective diameters resolved, drill bits resolved to pcb2gcode `--drills-available` specs (`"1mm:-0.1mm:+0.1mm"`), per-group dictionaries for travel/change/extra-cut/direction/spindle, and `drillLayers: [fileName: ParameterSnapshot]`. Engines call `forDrill(file:)` / `forLayer(kind, files:)`.

**State for undo.** `ParameterState { values, drillLayers }` with `changedKeys(from:)`; consecutive edits of one key within 1.5 s coalesce into one undo step.

**Validation.** `validationError` names the first non-numeric field (per drill file as "file: field"); the preview and Generate refuse while it is non-nil.

**Tools.** `toolValues(tool, for: section)` is the one mapping from a library tool to a group's keys (shape, diameter or tip+angle, depth, depth per pass, feeds, spindle, overlap, dwell, travel/change Z, extra cut, direction, spindle direction; zero feeds mean "leave alone"). `applyTool` copies, `matches` compares, so the sidebar can show "Edited".

### 4.3 Tool library

`MachineTool { id, name, use (general/isolation/drilling/cutout/mask/silk), shape (flat/ball/vBit), diameter, tipDiameter, tipAngle, toleranceMin/Max (drills' hole range), cutDepth, depthPerPass, feedXY, feedZ, spindle, overlap, dwell, notes, travelZ, toolChangeZ, extraCut, direction, spindleCCW }`. Stored as JSON in Application Support. Import/export the whole library; import FlatCAM Tools Database exports (name matching updates instead of duplicating). Each settings section lists the tools whose `use` fits it (hole milling takes cutout tools; mask and silk also take isolation tools; custom layers take any milling bit). A 3D model of each tool (`ToolGeometry`: V-bit cone, end mill, drill with 118° point, ball nose; 1/8″ shank, coloured ring) is shared by the library editor and the 3D preview.

### 4.4 Custom layers

`CustomLayer { id, name, side, operation (engrave/outside/inside/filled), toolID, toolDiameter, shape, tip/angle, cutDepth, depthPerPass, feeds, spindle, dwell, strokeWidth, shapes: [DrawnShape] }`. `ShapeGeometry`: line/polygon (points, closed), rect (origin, size, corner radius, rotation), circle, text (string, height, rotation, style: built-in single-stroke font or any installed font via CoreText outlines). Shapes are in design mm. Each non-empty layer becomes a program via `CustomLayerGenerator` (tessellate → offset by tool radius per operation → passes for wide strokes/pockets → G-code with the same conventions as the engines).

### 4.5 Project document

`.cncproj` is a package (declared UTI, `conformingTo: public.package`):
```
Board.cncproj/
  project.json   { format, version: 3, layers: {slot: StoredFile}, drills: [StoredFile],
                   parameters: {key: value}, outputFolder?, guidesX?, guidesY?, customLayers? }
  Layers/        the layer files, unchanged, names made unique
StoredFile { name, file ("Layers/x.GTL"), path (origin), bookmark?, parameters? (drill files' own values) }
```
Open copies the package's files into a private per-process working folder and never reads the package again. Versions 1 (links) and 2 (base64-embedded) still open and become packages on save. Save builds the package in a staging folder and swaps it in. Recent projects are kept with security-scoped bookmarks. Opening a project replaces the parameters with the project's.

### 4.6 Machine settings

App-wide `machine.*` UserDefaults, never project fields: transport (tcp/serial/simulator), host, port, serialPath, baud, pollMs, autoReconnect, consoleShowStatus, showSimulator, jogFeed, jogStep, jogSegmentMs, probe feeds/maxTravel/retract/plateThickness, safeZWork, safeZBelowTop, spindleMin/Max, spindleWarmupSeconds, applyBacklash, heightMapApplyBelowZ, confirmContinue, macros (JSON), configFilename. Saved positions and height maps live in Application Support (height maps keyed by project path and side). Backlash play X/Y is app-wide too.

---

## 5. The generation pipeline

### 5.1 Detection

`GerberDetector.detect(in:)` scores candidates per slot by extension and name tokens: `.gtl`/top copper, `.gbl`/bottom, `.gko`/`.gml`/outline/edge, `.gts`/`.gbs` masks, `.gto`/`.gbo`/silk/legend/overlay, drills by `.drl .xln .exc .drd` sorted by name. `guessSlot(for:)` for single imports also sniffs the Excellon `M48` header. The Import Layers sheet lets the user confirm or change each role (drill files are appended, other roles replace).

### 5.2 Engines

Both engines produce, per layer, a file named `<fileSlug>.ngc` in an output directory, with pcb2gcode's layout: metric G21/G90, `G00 S<rpm>` header, tool changes as `G00 Z<change>` / `T<n>` / `M5` / `G04` / `(MSG, …)` / `M6` / `M0` / `M3`, a `( Bit sizes: [1mm] [3.1mm] )` comment line in drill programs, `G04 P` dwell right after `M3`/`M5`.

**pcb2gcode service** builds one job per layer so edits re-run only what changed; jobs run in parallel (half the cores) and are cached by a hash of the command line (output paths masked) plus every input file's contents. Key arguments:
- Isolation: `--metric --metricoutput --path-finding-limit 0 --mill-diameters --isolation-width --milling-overlap --zwork --mill-feed --mill-vertfeed --mill-speed --zsafe --zchange --mirror-axis [--mill-infeed] [--mill-feed-direction climb|conventional --tsp-2opt=0] --spinup-time 1s --nog64 [--mirror-yaxis=1] --front/--back … --outline` (the outline goes along as input so isolation is clipped to the board; its output is discarded).
- Outline: `--outline --cutter-diameter --zcut --cut-feed --cut-vertfeed --cut-speed --cut-infeed --bridges --bridgesnum --zbridges`.
- Drill (per file, with that file's snapshot): `--drill --zdrill --drill-feed --drill-speed --drill-side front --nog81 --drill-output [--drills-available a,b,c] [--min-milldrill-hole-diameter --milldrill-diameter --zmilldrill --milldrill-output --cutter-diameter --zcut --cut-feed --cut-vertfeed --cut-speed --cut-infeed]`. Hole allowance is applied by writing a copy of the drill file with its tool table enlarged.
- Mask / silk: `--invert-gerbers --path-finding-limit 0 --mill-diameters <tool> --milling-overlap --isolation-width <clear width> --zwork <depth> …` with front/back in ONE run (the shared raster grid matters).
- Never `--zero-start` (per-invocation origins differ by millimetres); never `G64`; the dwell argument is a placeholder rewritten later.

**Native engine** reads Gerber (RS-274X incl. aperture macros, regions, polarity) and Excellon itself, builds copper with Clipper2 (`copper(image)`: flashes as outlines, tracks inflated by width, regions unioned, polarity runs), then: isolation rings = successive inward/outward offsets spread evenly across the width, clipped to the board; outline = board contour offset by the cutter radius with tabs on the longest edges; drilling with bits on hand and peck-free strokes; helical hole milling; mask/silk pocketing inward. Nearest-neighbour path ordering; climb/conventional honoured.

### 5.3 Post-processing (engine-independent, in `runBatch`)

Applied per program with that program's own snapshot (a drill program's = its file's):
1. **Dwells**: pcb2gcode writes milliseconds (`G04 P2000`) but GRBL/LinuxCNC read seconds → rewrite the `G04` right after every `M3`/`M5` to the group's dwell in seconds (drop if 0); convert any other non-zero dwell from ms.
2. **Spindle direction**: `M3` → `M4` for groups set to ccw.
3. **Extra cut**: for closed XY loops below Z0, continue past the closing point along the loop's first segments by the group's length; if the loop closes mid-run, retrace back along the groove so only cut copper is re-cut.
4. **Peck drilling**: split each Z plunge into pecks of the file's peck depth, rapid out to `max(plungeClearance, 0.2)` to clear chips, rapid back to 0.1 above the previous bottom.
5. **Plunge optimisation**: for feed moves that cross the clearance plane, descend rapid to the clearance then feed; ascend feed to the clearance then rapid.
6. **Origin normalisation**: union all program extents (back programs un-mirrored into the Gerber frame), compute one origin per side from `originMode`/custom point, shift every front program by the front origin and every back program by the mirrored one. Returns a `ProjectFrame` the whole UI uses.
7. Bits-on-hand warnings from the `Bit sizes:` header; a log line per step.

The same batch serves the live preview (temp dir, cached) and Generate (fresh, then copied to the destination; backlash compensation applied to the written files if the machine setting says so; mask SVGs via gerbv when `maskMode == svg`).

### 5.4 Parsing and preview document

`GCodeParser` turns each `.ngc` into `ToolpathMove { start, end, zStart, zEnd, kind (rapid/cut/plunge), feed, sourceLine, cumulativeTime, cumulativeDistance }` plus drill hits/holes (bit size from the tool-change message), modal state tracking, `G2/G3` arcs flattened, dwells added to time, rapids assumed at 2000 mm/min. `ParsedLayer { id, fileURL, moves, drillHoles, bounds, cutBounds, totalTime, toolDiameter }`. `PreviewDocument { layers (sorted), bounds, tempDir, token, frame, mirrorAxis, mirrorYAxis }`.

---

## 6. Main window UI

Three columns: **sidebar** (settings), **preview pane**, optional **Machine panel** inspector. A `WindowSizePolicy` keeps the window at least as wide as the visible columns, collapses the sidebar when the panel would not fit, and remembers widths.

### 6.1 Sidebar (`ParameterFormView`)

- **Project** section: name/folder, detected summary, "edited" mark, Open menu (project, Gerber folder, import, recents), a disclosure of layer files with context menus (Edit…, Replace…, Show Original in Finder, Remove).
- **Layer menu**: every generated program with its time estimate (and "▶ running"), empty custom layers, New Custom Layer, settings groups without a program (Hole milling only while some drill file mills large holes), Machine setup. Picking a program selects it for the preview and shows only its group below.
- **Contextual sections** per group as listed in 4.2, each with a Tool picker row ("Edited" button restores the tool), a "Heights & direction" section (travel/change Z with greyed machine defaults, extra cut, direction, spindle), Feeds & spindle, and group-specific extras: isolation pass count and V-bit width at depth; drilling → Bits on hand (library drills as checkboxes + tolerance), Hole milling toggle with the file's hole sizes split into milled/drilled and a too-large-bit warning; mask → output mode, clear width automatic/manual with the widest opening in the footer; silk → output mode; setup → origin picker + Set Origin in View, board flip direction, mirror axis, engine picker (not in App Store builds), safety heights, rapid feed, plunge clearance, milling direction, backlash X/Y with Backlash Test and Compensate a G-code File.
- Drilling/Hole milling headers name the drill file; footers say the values belong to that file alone.
- **Layer file** section with Edit; while editing, the file's aperture/tool table replaces the settings.
- **CNC export** (Export this .ngc, Send to Machine, origin link) and **Laser export** (format SVG/PDF/PNG, polarity, dpi, frame mode board/origin/project/layer).
- Footer warnings: pcb2gcode missing, invalid value.
- Every control has `.help(...)` written for the user (see section 14). Numeric rows (`ParamRow`) keep their own text while typing, commit every parseable value, convert to/from inches when the unit system says so, and refresh when the bound value changes while not focused.

### 6.2 Preview pane

Tabs Toolpath / G-code / Log with a status header (stale badge, Refresh in manual mode), a 2D/3D switch, View Options (tool width, all-layers overlay, un-mirror back side, height map, travel moves, snap to grid, fit machine travel), a measure button, a scope button to set the origin, the side view (X–Z / Y–Z / profile with reference lines and Z exaggeration), and a floating glass playback bar (play/pause, speed 1×–200×, scrub, time/line readout). While a job streams, the playback bar becomes the compact job bar.

**2D canvas**: fit computed every frame from the canvas size and the focused layer's bounds, with user zoom/pan as relative adjustments; cursor-anchored zoom; rulers, grid, guides (draggable, snapping), origin marker with X/Y arrows (draggable, snaps to corners/centre/holes/grid); per-layer colours, yellow dashed rapids, white bridge tabs, translucent tool-width swaths, drill hits; playback renders completed moves solid and the rest ghosted using prefix checkpoints (`ToolpathRender`); the tool position marker; the machine's live position as a blue crosshair when connected; the height map wireframe; the shape editor and layer-file editor overlays; the tape measure.

**3D view** (SceneKit): translucent FR4 slab sized from the cutout, copper faces as bitmaps with cuts punched out (`BoardSurface`), real groove geometry extruded per depth (`GrooveMesh`), programs as lines, travel faint, the tool model following playback and spinning, orbit/pan/zoom, an axis gizmo, standard views, perspective/ortho, machine travel box, height map wireframe.

### 6.3 Other windows and dialogs

Tool Library window; Machine window; Help window (the guide, mirrored in HELP.md); Settings (General: units, refresh mode and debounce; Machine: section 4.6 plus axis calibration); Generate sheet (target CNC/laser, destination with New Folder, per-stage progress, summary); Test Board dialog (parameter sweep, holes test, backlash test, with its legend file); Import Layers sheet (roles + origin choice).

Menus: File (New/Open/Open Recent/Open Gerber Folder/Import Layer/New Custom Layer/Generate Test Board/Tool Library/Save/Save As), Edit (one undo history; Select All/Duplicate/Delete/Align/Distribute shapes), View (Snap to Grid ⌘', Machine Panel ⇧⌘M, Emergency Stop ⇧⌘.), Help (⌘?). The app asks before discarding an edited project and before quitting with a job running. Double-clicked `.cncproj` files open through the app delegate.

---

## 7. Editors

**Shape editor**: tools Select/Line/Rectangle/Circle/Text (V/L/R/C/T); click/drag drawing, double-click or Return finishes a line, closing on the first point; Shift constrains; snapping to grid, guides and other shapes' corners/vertices/centres/quadrants with a green ring; marquee selection (left-to-right encloses, right-to-left touches); handles for resize and vertex moves; arrow nudges 0.1/1 mm; duplicate, delete, align, distribute; a floating properties panel with exact numbers; everything in design mm; undo through the shared manager. A floating toolbar over the canvas holds the tools and the new-shape text/stroke settings.

**Layer-file editor**: parse a Gerber or Excellon file into `LayerArtwork` objects (flash, track, region, hole); select, select similar, move, delete, resize (track width, pad size, hole size), edit the aperture/tool table to change every use at once; each edit writes an edited copy under the working folder with the same file name and points the layer at it (so per-file settings keyed by name survive); the preview does not regenerate while editing, only on Done; the Gerber writer emits clean RS-274X in the input's units; macro pads and regions can be moved or deleted but not resized.

---

## 8. Machine control

### 8.1 Protocol layer (pure, `nonisolated`)

Status report parser for `<State|MPos:|WPos:|WCO:|FS:|Ov:|Bf:|Pn:|A:|Ln:>`; response classification (`ok`, `error:n`, `ALARM:n`, `[MSG:…]`, `[PRB:x,y,z:1]`, `[GC:…]`, `[VER:/OPT:]`, FluidNC `$/…` replies); firmware identification from `$I` (Grbl 1.1 vs FluidNC, with version); real-time bytes (`?`, `!`, `~`, `0x18` reset, `0x85` jog cancel, override bytes); line builders (`$J=G91 …`, `G53 G90 G1`, `G10 L20 P0`, `G10 L2 P0`, `G38.2`, `$H`, `$X`, `$C`, `$SLP`); safe move legs (Z first when rising, last when descending); error/alarm code tables merged from Grbl and FluidNC.

### 8.2 Transports (actors)

TCP (telnet, port 23, line-oriented), serial (`/dev/cu.*`, 115200, `O_EXLOCK` so other senders cannot open the port underneath), simulator (launches the bundled `fake-grbl.py` on a free localhost port and connects by TCP). All deliver lines and accept lines/bytes; dead-link detection by status-poll deadlines; optional auto-reconnect.

### 8.3 Controller (main actor)

Connection lifecycle and phases (disconnected/connecting/connected/unresponsive); identification; status polling at `pollMs`; a single serialised send queue with an acknowledgement FIFO shared, in order, with the streamer; derived state: `isConnected`, `machineState`, `alarmCode`, `positionTrusted` (false after alarms that lose position until homed or unlocked), `workOffset`, `activeWCS`, `parserState`, `canJog`, `canProbe`, `jobLocksControls`, `manualControlsEnabled`, `positioningEnabled`. Commands: jog (step, vector, continuous with cancel or segment streaming depending on firmware/soft limits), stop (jog cancel + hold + reset once at rest), emergency stop (all at once), home, unlock, soft reset, sleep, door, check mode, spindle/coolant, overrides, zero axes / set axis, go to (machine coords), go to work zero (via safe work Z), safe Z (below top of travel), probe Z (two-pass, origin at the exact trigger point), probe Z at work origin (height-mapped tool changes), set work origin to a stored machine point, macros (`@goto <position>` expands to safe legs), steps/mm read/write/save for FluidNC, console with history. The last refusal/error is published for the UI ("a silent refusal looks like a dead button").

### 8.4 Program preparation and streaming

`ProgramPreparer` turns a parsed layer into the exact text sent, line-for-line (line N on disk = line N sent = `sourceLine` N drawn): optional backlash compensation, optional height map warp (bilinear, only moves at or below `applyBelowZ`, through the side's design frame), optional Z clamp (retract heights above the top of travel lowered to just below it), tool-change words (`T`, `M6`, `M0`) turned into comments so the streamer suspends *before* the line instead of letting the controller park in `Hold:0`; segments per tool; modal-state scan for resume preambles. Pre-flight checks the whole program against the machine's travel and the current work offset and reports the first problem in full (with "Clamp Z to top" when that alone fixes it).

`JobStreamer`: character-counting flow control (`StreamWindow`, 128-byte buffer, EEPROM-touching lines sent alone on Grbl serial), states idle/verifying/running/pausedByUser/suspended(toolChange | programPause)/probing/stopping/completed/failed, pause/resume, stateful stop (hold → wait for rest → reset → spindle off), error prompt (ignore and continue / stop), tool-change suspension (spindle off, park at the safe height, banner; jog/zero/probe allowed), continue with a preamble (retract, spindle on + warm-up, rapid over the resume point, plunge), send from line with the same preamble shown for confirmation, verify in check mode, height-map probing runs, elapsed/remaining, and **position-matched progress** that drives the preview clock so the canvases, side view, 3D view and G-code tab follow the running job (a display-link ticker and a motion interpolator smooth the reported position between status reports).

### 8.5 Height map

`HeightMap { origin, size, nx, ny (2–15), side, zClear, zMaxDepth, feedFast, feedSlow, values, referenceZ, probedAt, probedDesignOrigin }` in design coordinates; probing first references Z at work X0/Y0 so maps stay valid after re-zeroing Z there; validity checks (other side, work offset unknown, origin moved, Z re-zeroed, incomplete) warn before applying; Auto grid from the shown program's cut bounds + 1 mm margin, ~10 mm spacing; JSON load/save; per project and side in Application Support; drawn as a coloured wireframe in 2D and 3D.

### 8.6 Machine UI

A panel (inspector in the main window) and a window share the same views: connection bar (transport picker, endpoint fields, Connect, state pill with SIM tag, firmware badge, decoded alarm banner with Unlock/Home/Reset, spindle-running warning), error line, DRO (work large, machine small, F/S with overrides, buffer, pins; click a value to set that axis; button grid Zero XY/Z/All, Probe Z, Work Zero, Safe Z, Home, Unlock), E-STOP, then tabs: Control (jog pad with diagonals, Z column, step/feed presets, keyboard jog; machine controls Reset/Hold/Resume/Check/spindle+rpm/coolant/More; overrides; user buttons), Positions (save current, save work zero, go to…, list with Go / Use as zero, context menu), Program (picker, open external .ngc, save sent program, summary and badges, Apply height map / Backlash / Clamp Z toggles, tool-change banner, job bar with Send/Verify/Send from line/Continue/Hold/Stop/E-STOP; the window variant shows the program text with the current line highlighted), Probe (fields + Probe Z + last probe), Height Map (grid fields, Probe/Stop/Clear/Load/Save, use-for-sending, progress, summary, value table), Macros (list, add/edit/duplicate/delete/restore), Console (window only; the main window has a Console tab in the preview pane).

---

## 9. Calibration and export extras

- **Test board**: grid of patches, rows sweep cut depth, columns sweep XY feed; each patch has 0.2/0.3/0.4 mm trace-survival tests between probe pads and a pad with a cleared moat; engraved spreadsheet headers; a legend `.txt`; also a holes test (hole-milling settings as a tool) and a backlash test (two half-lines per axis approached from opposite directions, a square and a circle).
- **Backlash compensation**: G-code post-process that tracks each axis' last direction and writes positions reached moving − lower by the play; applied to generated files on request and always to the streamed copy when enabled; a header comment prevents double application; "Compensate a G-code File…" for external programs.
- **Laser artwork export**: the parsed toolpath (cut moves swept at the cutter width, never rapids) at 1:1 as SVG/PDF/PNG with polarity and frame modes; Generate's laser target writes every layer.
- **Engine comparison** (dev): run both engines, measure swept-area overlap, safety against copper, hole sets, overlay images.

---

## 10. Rules learned the hard way (do not relearn)

1. pcb2gcode's `--zero-start` zeroes each invocation on its own extents → programs misregister by millimetres. Run everything in the Gerber frame and normalise origins yourself, one shift per side.
2. pcb2gcode writes `G04 P` in **milliseconds** whatever `--software` says; GRBL/LinuxCNC read **seconds** (a 2 s dwell becomes 33 minutes). Rewrite every dwell.
3. pcb2gcode emits `G64 P…` unless `--nog64`; GRBL rejects it with error 20 and most senders abort.
4. `--mirror-yaxis` must carry a value (`=1`) or it eats the next argument.
5. `--drills-available` without an explicit range per bit makes pcb2gcode round **every** hole to the nearest bit (a 3 mm hole drilled at 1 mm). Always pass ranges.
6. Mask and silk front/back must run in one invocation: pcb2gcode rasterises all layers of a run on a shared grid, and splitting moves points by ~5 µm.
7. The outline must be an input of the copper runs (isolation clipped to the board) even though its program from those runs is discarded.
8. Path finding (`--path-finding-limit 0`) must be off or the tool drags across waste copper at depth between contours.
9. Tool-change lines (`T`/`M6`/`M0`) must never reach the controller during streaming: it parks in `Hold:0` where nothing is accepted. Suspend before the line instead.
10. Each `ok`/`error:` acknowledges exactly one line in order; keep the FIFO shared between the streamer and manual commands or responses get attributed to the wrong line.
11. Use the `cu.` serial node, not `tty.`; open with `O_EXLOCK`.
12. A sandboxed child process (pcb2gcode) only inherits the app's static sandbox: copy inputs into the app's temp space first; the helper must be signed with sandbox + inherit entitlements, and crashes with SIGTRAP if its parent is not sandboxed.
13. Reading a multi-megabyte process output with `waitUntilExit` + `readDataToEndOfFile` deadlocks at 64 KB; drain the pipe while the process runs.
14. SwiftUI: a `.frame(minWidth:)` on the root re-measures the whole hierarchy every update; answer window sizing from AppKit. `@AppStorage` inside an `ObservableObject` publishes changes. Text fields must never take focus at launch. Keep edits in the field's own text and only commit parseable values.
15. V-bit diameters must be the **effective** width at depth; all engines receive the effective value.
16. Mask clear width must be at least half the widest opening or the centre stays covered; measure it from the files (inradius via binary search on inward offsets) instead of trusting a typed value.
17. Per-process temp roots named after the pid; startup removes only folders of dead processes so two instances never delete each other's files.
18. Edited layer copies keep the original file name (per-file settings and project packing key on it).
19. EasyEDA names files identically in every export; never let per-file settings leak between projects.

---

## 11. Implementation phases

Build in this order. Each phase ends with the listed checks passing before the next starts. Keep every phase shippable.

### Phase 0 — Skeleton
- Xcode project, both schemes/configurations, entitlements, bridging header with the Clipper shim, vendored Clipper2, bundle scripts (pcb2gcode, simulator), `Info.plist` with the `.cncproj` package UTI.
- `AppModel`, `ContentView` three-column split, empty sidebar/preview, Settings and Help windows, menus.
- Check: both schemes build; the App Store build has no `Helpers` folder and no engine picker.

### Phase 1 — Detection, parameters, pcb2gcode preview
- `DetectedFiles`, `GerberDetector`, Open Gerber Folder, Import Layers sheet.
- `ParametersStore` with the full key table, snapshot, validation, presets, `ParameterState` undo.
- `Pcb2GcodeService`: jobs, cache, `runBatch` with all post-processing passes, origin normalisation, `ProjectFrame`.
- `GCodeParser`, `PreviewDocument`, `PreviewController` (signature, debounce, manual mode, staleness).
- Sidebar with all groups and tooltips; 2D canvas with fit/zoom/pan, colours, rapids, tool width, drill hits; playback bar and `PlaybackState`; side view; G-code and Log tabs; Generate sheet; single-program export.
- Check: from a sample EasyEDA export, Generate writes front/back/outline/drill/mask programs; dwells are in seconds; no `G64`; all programs share one origin per side (overlay registers); peck and plunge passes appear in the files; the time estimates match `length ÷ feed`.

### Phase 2 — Native engine and geometry
- `Clipper` wrapper, Gerber/Excellon readers and writer (`LayerFileFormats`), `NativeToolpathEngine` with isolation, outline+tabs, drilling, hole milling, mask/silk pocketing; engine picker; `EngineComparison` dev hook.
- Automatic mask clear width from the widest opening.
- Check: both engines produce the same set of files from the sample; the comparison report shows overlapping swept areas and identical hole sets; a 3.1 mm mask opening is cleared to its centre.

### Phase 3 — Tool library, per-file drill settings, projects, undo
- `ToolLibrary`, library window with 3D tool models, FlatCAM import, library import/export, Tool picker rows with "Edited".
- `drillLayerValues` per drill file in the store, snapshot, engines, post-processing, sidebar scoping, project persistence.
- `ProjectDocument` package save/open with migration from v1/v2, recents with bookmarks, edited-state tracking, app-wide `UndoManager` for parameters and layer files.
- Check: turning on Mill large holes for one drill file leaves the others unchanged in the generated command lines and files; save → reopen restores the per-file values; ⌘Z steps through parameter edits and file replacements in order.

### Phase 4 — 3D view, editors, measuring, origin tools
- SceneKit scene: slab, copper faces with cuts punched out, groove geometry, programs, travel, tool model, gizmo, views, travel box.
- Shape editor + custom layers + `CustomLayerGenerator` + `TextOutlines`; layer-file editor with artwork overlay and aperture/tool tables; tape measure; guides; origin marker dragging and Set Origin in View; snap to grid.
- Check: a drawn rectangle with "Cut outside" produces a program whose inner edge equals the drawn size; editing a track width in a Gerber regenerates with the new width and the original file is untouched; the tool model's cone matches tip/angle.

### Phase 5 — Calibration and laser export
- Test board generator and dialog (parameters, holes, backlash tests + legend); backlash compensation service and "Compensate a G-code File"; artwork export (SVG/PDF/PNG, frames, polarity).
- Check: the parameter test board's legend matches the engraved headers; a compensated file carries the header and reversed-direction moves are shifted by the play.

### Phase 6 — Machine control
- Protocol layer with tests; transports (TCP, serial, simulator launcher + `fake-grbl.py`); controller; `StreamWindow`, `ProgramPreparer`, `JobStreamer`; probing routines; height maps; saved positions; macros; machine settings pane; the Machine panel and window with every view in section 8.6; the preview following the job; emergency stop shortcuts; quit/switch-project guards.
- Check with the simulator: connect, home, jog, zero, probe Z (work Z reads the plate thickness), send a program to completion with the canvases following, a tool change suspends and continues, Send from line resumes, a height map probes and warps the streamed copy (saved sent program differs from the file), E-STOP marks the position untrusted.

### Phase 7 — Help and polish
- `.help` on every control (section 14), the in-app guide and HELP.md in sync, README, App Store listing text.
- Window size policy, remembered widths, keyboard shortcuts, imperial display, presets menu.

---

## 12. Dev hooks and headless verification

Launch arguments read from `UserDefaults` (every `param.*`, `machine.*`, `export.*` key can be overridden the same way):

| Argument | Effect |
|---|---|
| `-debugProjectFolder <dir>` | open an export folder without the panel |
| `-debugOpenProject <x.cncproj>` | open a saved project |
| `-debugDrillSettings "a.drl:k=v,k=v;b.drl:k=v"` | per-drill-file values |
| `-debugSaveProject <path>` | save at once |
| `-debugGenerate 1` / `-debugGenerateLaser 1` | generate into a folder beside the project |
| `-debugGenerateLog <file>` | write the Log and quit when generation ends |
| `-debugGenerateDialog 1`, `-debugImport a,b`, `-debugRefreshAfter n -debugEdit key=value`, `-debugCustomDemo 1`, `-debugUndoTest 1`, `-debugEditLayer front|drill0 …`, `-debugCompareEngines <dir>`, `-debugMachineWindow 1 -debugMachineConnect sim`, `-debugMachineSend <layer>`, `-debugMachineScript`, `-debugMachineProbeMap`, `-debugSnapshot3D <png>`, `-debugRenderLog 1`, `-debugWindowSize 1` | see the code's startup section |

Headless test recipe: build an unsandboxed variant into a scratch folder with its own bundle ID (`CODE_SIGN_ENTITLEMENTS=<empty plist> ENABLE_APP_SANDBOX=NO PRODUCT_BUNDLE_IDENTIFIER=…devtest`), re-sign `Contents/Helpers/pcb2gcode` and its dylibs ad hoc (the sandbox-inherit helper dies with SIGTRAP under an unsandboxed parent), run the binary in the background with the hooks above, poll for the log file, then inspect `Generated_GCode/*.ngc` with grep (Z depths, `peck`, `G04 P`, `M4`, `G2` arcs, `( Bit sizes:`). macOS has no `timeout`; use a polling loop.

---

## 13. Source layout to reproduce

```
CNC G-Coder/
  CNC_G_CoderApp.swift            scenes, menus, AppDelegate
  ContentView.swift               split view, toolbar, presets menu, column width policy
  Geometry/Clipper.swift          Clipper2 wrapper
  Models/  AppModel(+Project,+Undo,+CustomLayers), ParametersStore, DetectedFiles,
           PreviewModels (LayerKind, moves, document), PlaybackState, ProjectDocument,
           ToolLibrary, CustomLayer, ShapeEditor, LayerArtwork, LayerFileEditor,
           MachineSettings, PreviewGuides, UnitSystem, DebugFlags
  Services/ GerberDetector, Pcb2GcodeService, NativeToolpathEngine, LayerFileFormats,
           ExcellonReader, GCodeParser, PreviewController, ProcessRunner, ToolLocator,
           FileAccess, CustomLayerGenerator, ShapeMath, TextOutlines, TestBoardGenerator,
           BacklashCompensation, ArtworkExportService, EngineComparison
  Services/Machine/ GRBLProtocol, GRBLCodes, MachineTransport, SerialPorts, SimulatorLauncher,
           MachineController, StreamWindow, JobStreamer, ProgramPreparer, ProbeRoutines,
           HeightMap, SavedPositions, MotionInterpolator, FrameTicker
  Views/   ParameterFormView, PreviewPane, ToolpathCanvasView(+Editor,+LayerEdit,+Measure),
           ToolpathRender, SideViewCanvas, Toolpath3DView, BoardSurface, GrooveMesh,
           ToolModel3D, HeightMapOverlay, PlaybackControls, ShapeEditorToolbar,
           CustomLayerSettings, LayerEditViews, ImportLayersSheet, GenerateDialog,
           TestBoardDialog, ToolLibraryView, SettingsView, HelpView, LogView,
           GCodeTextView, MonoTextView, ViewUtilities, WindowSizePolicy
  Views/Machine/ MachineInspector, MachineWindow, MachineConnectionBar, MachineDRO,
           MachineControls, JogPad, OverridesView, PositionsSection, GoToSheet,
           ProgramControls, ProgramTab, JobBar, ProbeTab, HeightMapTab, MacrosTab,
           UserButtons, ConsoleTab, EmergencyStopButton, MachineSettingsPane
  ThirdParty/Clipper2, ThirdParty/ClipperShim
Scripts/ bundle-pcb2gcode.sh, pcb2gcode-helper.entitlements, fake-grbl.py
HELP.md, README.md, appconnect.md
```

Approximate sizes: ~35 k lines of Swift; the largest files are the machine controller (~1.9 k), the 2D canvas and sidebar (~1.6 k each), the 3D view (~1.6 k), pcb2gcode service (~1.3 k), app model (~1.2 k), job streamer (~1 k).

---

## 14. Writing conventions

- **Tooltips** (`.help`): every button, field, picker, toggle and row label gets one. Say what the control does, what the machine or file will get (the G-code word or flag where it helps: `G10 L20`, `$H`, `--isolation-width`), a typical value, and when it is disabled and why. Full sentences, no jargon without a gloss, no references to other apps.
- **Footers and help text** explain consequences ("deeper widens V-bit cuts and thins traces"), not UI mechanics.
- **Log lines** are terse and factual, one per step, with timings; warnings start with `WARNING:`, failures with `ERROR:`.
- **Code comments** explain *why* (the rule, the firmware quirk, the SwiftUI trap), not what the line does. Every file starts with a doc comment stating its role in the architecture.
- No external tool names in user-facing text except pcb2gcode, FluidNC, Grbl, EasyEDA and FlatCAM, which the user works with directly.
