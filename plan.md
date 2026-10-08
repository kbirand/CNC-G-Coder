# CNC G-Coder — rebuild plan

A step-by-step plan for recreating CNC G-Coder from scratch with an AI coding agent. It describes what the app does, how it is built, the rules the existing code learned the hard way, and an order of work with acceptance checks for each stage. Read the whole plan before writing code; the later sections constrain the earlier ones.

---

## 1. What the app is

CNC G-Coder is a native macOS app that turns a PCB design export (Gerber + Excellon drill files, as EasyEDA and KiCad write them) into ready-to-run G-code for a hobby CNC router, previews every program with a feed-rate-accurate simulator, and streams the programs to a GRBL 1.1 / FluidNC controller over Wi‑Fi or USB, with probing, autolevel and live monitoring.

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
12. **Localization and documentation**: the interface and the guide in English, French, Spanish and Turkish; a generated web user guide with screenshots.

The user is a hobbyist milling PCBs on a small machine. The app's voice is plain, concrete, and explains *why* (what the machine will do), never just *what*.

---

## 2. Platform and toolchain

- **Language/UI**: Swift 5 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; SwiftUI for all views, AppKit where SwiftUI is not enough (NSTextView-backed text views, NSOpenPanel/NSSavePanel, window sizing, serial I/O, event monitors). SceneKit for the 3D view.
- **Target**: macOS 26+, Apple Silicon. Liquid Glass styling where the system offers it (floating glass bars over the canvas).
- **Project**: one Xcode project, one app target, two schemes:
  - `CNC G-Coder` — bundles pcb2gcode (direct distribution).
  - `CNC G-Coder (App Store)` — an `AppStore` build configuration with `BUNDLE_PCB2GCODE=NO`; native engine only, no engine picker, no GPL binary.
- **Sandbox**: App Sandbox on, entitlements: user-selected read/write, app-scope bookmarks, network client+server, serial and USB devices. pcb2gcode runs as a child signed with `app-sandbox` + `inherit` entitlements and only ever reads copies of inputs placed in the app's own temp folder.
- **Localization**: `SWIFT_EMIT_LOC_STRINGS` + string catalogs (`Localizable.xcstrings`, generated — section 10), `knownRegions` en/Base/fr/es/tr.
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

App-wide `machine.*` UserDefaults, never project fields: transport (tcp/serial/simulator), host, port, serialPath, baud, pollMs, autoReconnect, consoleShowStatus, showSimulator, jogFeed, jogStep, jogSegmentMs, probe feeds/maxTravel/retract/plateThickness, safeZWork, safeZBelowTop, spindleMin/Max, spindleWarmupSeconds, applyBacklash, heightMapApplyBelowZ, confirmContinue, autoSaveWorkZero (record the work zero in Positions at every Send, default on), streamWindowBytes (0 = automatic), positionsKind (the Positions tab's Machine/Work switch), macros (JSON), configFilename. Saved positions (`savedPositions.json`: `SavedPosition { id, name, position, createdAt, kind: machine|workZero, automatic }`, older files decode with the kind inferred from a "Work zero" name prefix) and height maps live in Application Support (height maps keyed by project path and side). Backlash play X/Y is app-wide too. UI state lives in `ui.*` (`sidebarWidth`, `machineInspectorWidth`, `sidebarVisible`, `machineInspector`, `sectionOverride`), the guide's language in `help.language`, the interface language in `AppleLanguages` + `app.languageOverride`.

---

## 5. The generation pipeline

### 5.1 Detection

`GerberDetector.detect(in:)` understands two naming schemes. KiCad first: every plot is `<board>-<layer>.<ext>`; the layer id after the last `-` (lowercased, dots folded to `_` for KiCad 4 names) decides the role alone — `f_cu`/`b_cu` copper, `edge_cuts` outline, `f_mask`/`b_mask`, `f_silks`/`f_silkscreen` and the `b_` twins — and files with other KiCad ids (paste, adhesive, fab, courtyard, user/inner-copper plots, `drl_map`, `job`, `pth`/`npth` `.gbr` drill plots, `.gbrjob`) are excluded from every slot. Files whose name is no KiCad id fall to the generic rules, scored per slot by extension and name tokens: `.gtl`/top copper, `.gbl`/bottom, `.gko`/`.gml`/outline/edge, `.gts`/`.gbs` masks, `.gto`/`.gbo`/silk/legend/overlay. Drills by extension `.drl .xln .exc .drd` sorted by name. `warnings(in:)` is logged on folder open (KiCad drills exported as Gerber X2 instead of Excellon). `guessSlot(for:)` for single imports also sniffs the Excellon `M48` header. The Import Layers sheet lets the user confirm or change each role (drill files are appended, other roles replace).

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

## 6. User interface

Everything the user sees, in one place. The views are SwiftUI; the logic they bind to is in sections 4, 5, 7 and 8. Every control carries a `.help` tooltip written to the conventions of section 15.

### 6.1 Scenes and windows

| Scene | Content |
|---|---|
| `WindowGroup` (main) | `ContentView`: sidebar, preview pane, optional Machine panel. Root view is `RootSizeIsolator` (6.2). |
| `Window("Tool Library", id: "tools")` | `ToolLibraryView` (6.16). ⇧⌘L. |
| `Window("Machine", id: "machine")` | `MachineWindow` (6.13), opened from the panel's "Open in a window". |
| `Window("CNC G-Coder Help", id: "help")` | `HelpView` (6.17). ⌘?. |
| `Settings` | General + Machine panes (6.15). ⌘,. The window is titled after its tab. |

The `AppDelegate` opens double-clicked `.cncproj` packages, asks before quitting with a job running, and refuses to quit while the sandbox helper is mid-generation. New Project / Open / Quit ask before discarding an edited project. Appearance follows the system (the screenshots are dark).

### 6.2 Main window layout and size policy

Three columns: **sidebar** (settings form, 360 pt by default), **detail** (preview pane, ≥ 420 pt), **Machine panel** (360…560 pt, hidden until toggled). The panel is *not* a SwiftUI `.inspector` (that one grows the window past the screen and overlaps the split view); `ContentView` lays out `GeometryReader → HStack { NavigationSplitView.frame(width: total − panel − 1); a 1 pt divider with a 9 pt drag zone; MachineInspector.frame(width: panel) }` with `panel = min(stored, max(360, total − sidebar − 8 − 420 − 1))`.

`WindowSizePolicy` (AppKit, attached through `WindowAccessor`) sets the window's `contentMinSize` to sidebar + 8 + 420 + panel + 1, grows the window when the panel is shown or widened (left edge kept, clamped to the screen, debounced, never during a live resize), and on a small screen lets the panel yield and finally collapses the sidebar. `RootSizeIsolator` is a `Layout` that answers min/ideal size queries itself without measuring its child, so `NSHostingView`'s per-update minimum-size walk is O(1). Widths persist in `ui.sidebarWidth`, `ui.machineInspectorWidth`, `ui.sidebarVisible`; the panel's visibility in `ui.machineInspector`. Panel content must lay out at any width from 360 to 560: wide rows fold with `ViewThatFits`, texts wrap, no fixed-width subviews.

### 6.3 Toolbar, menus, shortcuts

**Toolbar**: sidebar toggle · **Presets** menu (Save Current as Preset…, the presets, Delete Preset ▸) · **More** menu (Open Output Folder, Copy pcb2gcode Command, New Custom Layer, Generate Test Board…) · **Help** · **Machine** toggle (icon shows connected / streaming) · **Generate** (prominent). The window subtitle is the project name, "No project", and " — Edited".

**Menus**: File — New Project ⌘N, Open Project… ⌘O, Open Recent ▸ (Clear Menu), Open Gerber Folder… ⇧⌘O, Import Layer… ⌘I, New Custom Layer ⇧⌘N, Generate Test Board… ⇧⌘T, Tool Library… ⇧⌘L, Save Project ⌘S, Save Project As… ⇧⌘S. Edit — Undo ⌘Z / Redo ⇧⌘Z (one app-owned `UndoManager`, driven by `CommandGroup(replacing: .undoRedo)`; SwiftUI's `\.undoManager` environment never reaches the model), Select All Shapes ⇧⌘A, Duplicate Shapes ⌘D, Delete Shapes, Align ▸, Distribute ▸. View — Snap to Grid ⌘', Machine Panel ⇧⌘M, Emergency Stop ⇧⌘.. Help — CNC G-Coder Help ⌘?. Drawing tools while the canvas has focus: V select, L line, R rectangle, C circle, T text; M tape measure; Esc leaves a tool. Keyboard jog (6.13): ← → X, ↑ ↓ Y, Page ↑/↓ Z, ⇧ ×10, hold = continuous, Esc stops.

### 6.4 Sidebar (`ParameterFormView`)

- **Project** section: name, folder, "7 layers · 4 drill files · modified", Open menu (project, Gerber folder, import, recents) and, with no project, "No project — Open a project, a Gerber folder, or import layers". A **Layer files** disclosure lists every slot with its file and a context menu (Edit…, Replace…, Show Original in Finder, Remove) plus "Import Layer…".
- **Layer menu** (the program picker): every generated program with its time estimate ("est. 15:07 · 7 731 moves", "▶ running" while streamed), empty custom layers, New Custom Layer, settings groups without a program (Hole milling only while some drill file mills large holes), Machine setup. Picking a program selects it for the preview and shows only its group below. "Σ est. 49:14, 10 programs — rapids assumed 2000 mm/min" under it.
- **Layer file** section (the selected program's file, Edit button); while editing (6.12) the file's aperture/tool table replaces the settings.
- **Contextual sections** per group of 4.2: a Tool picker row (library tools fitting the group, "Custom", "Edited" button restores the tool, Edit Tool Library…), the group's numeric rows, **Feeds & spindle**, **Heights & direction** (travel/change Z with greyed machine defaults, extra cut, direction, spindle direction), and group extras: isolation → pass count and V-bit width at depth, footer "Traces are never cut into…"; drilling → Bits on hand (library drills as checkboxes + tolerance), Mill large holes toggle with the file's hole sizes split into milled/drilled and a too-large-bit warning, headers naming the drill file and footers saying the values belong to that file alone; mask → output mode, clear width automatic/manual with the widest opening in the footer; silk → output mode; custom layer → name, side, type, operation, tool, duplicate/delete, the shape list (6.11); Machine setup → origin picker ("X0 Y0 at": the design's own origin or a board corner/centre/custom, Set Origin in View), board flip direction, mirror axis, engine picker (not in App Store builds), safety heights, rapid feed, plunge clearance, milling direction, backlash X/Y with Backlash Test and Compensate a G-code File….
- **CNC export** (Export this .ngc…, Send … to Machine…, the origin note) and **Laser export** (format SVG/PDF/PNG, polarity, dpi, frame mode board/origin/project/layer, "Export artwork…").
- Footer warnings: pcb2gcode missing, invalid value. `ParamRow` numeric rows keep their own text while typing, commit every parseable value, convert to/from inches when the unit system says so, and refresh when the bound value changes while not focused. Never give a field focus at launch.

### 6.5 Preview pane

Header: tabs **Toolpath / G-code / Log / Console** (`PreviewPane.Tab`), the status ("Preview ready", "Out of date" badge, "Preview empty", a red failure with Show Log / Try Again / Close), **Refresh** (manual mode or stale), the **2D / 3D** switch, **View Options** menu and the layout toggle (side view shown/hidden). While a run is in progress a card shows "Generating preview / Updating preview" with per-stage progress and a Stop button ("the previous result stays visible until the new one is ready"); in auto mode a "Preview updates after your edits…" card during the debounce. In 3D while an editor is active: "Drawing tools are in the 2D view — Edit in 2D".

**View Options**: Tool Width, Rulers, Guides, Clear Guides, Snap to Grid ⌘', All Layers Overlay, Un-mirror Back Side, Height Map + exaggeration ×1…×50, Toolpath Lines, Drill Holes (3D cylinders), Material Removal (3D grooves and copper mask), Machine Travel (dashed travel area while connected), Fit Machine Travel (never part of the default fit).

### 6.6 2D canvas (`ToolpathCanvasView`)

Fit computed every frame from the canvas size and the focused layer's bounds, user zoom/pan as relative adjustments (survive layer switches); cursor-anchored wheel/pinch zoom, drag pan, double-click fit. **Canvas buttons** (top left): zoom in, zoom out, fit, set origin by clicking, tape measure, centre on origin. Rulers with draggable guides (pull out of a ruler; saved with the project; snap everything). Origin marker with X/Y arrows, draggable with a caption ("Drop at X… Y…", "Drop: bottom-left corner · …", snaps to corners/centre/holes/grid). Drawing: per-layer colours, yellow dashed rapids, white bridge tabs, translucent tool-width swaths, drill hits; playback renders completed moves solid and the rest ghosted using prefix checkpoints (`ToolpathRender`, every 1000 moves) so scrubbing is O(interval); the tool position marker; the machine's live position as a blue crosshair when connected (`smoothedWorkPosition`, ~30 Hz); the machine travel rectangle; the height map wireframe (`HeightMapOverlay`, the live target while probing, else the stored map; shown while the View Options toggle is on, the panel is on the Height Map tab, a probe runs, or the loaded program carries a map); the shape editor and layer-file editor overlays; the tape measure (snaps to cut endpoints, drill hits, drawn shapes, origin, guides, grid). Canvas caches live in reference boxes rebuilt lazily inside the draw closure — never invalidate them from `onChange`.

### 6.7 Side view (`SideViewCanvas`)

X–Z / Y–Z projection or Z-vs-travel **Profile** with labelled reference lines (Z0, zwork/zdrill/zcut/zbridge per layer kind, zsafe, zchange, the machine's Z top while connected). The Z domain is capped at the highest reference line so tool-change retracts do not flatten the working depths; travel above zsafe is compressed into a thin top band; the exaggeration factor is printed ("Z scale ×4,5"). Playback and the live position draw the same marker as the 2D canvas.

### 6.8 3D view (`Toolpath3DView`, SceneKit)

Translucent 1.6 mm FR4 slab sized from the cutout; copper faces as bitmaps with cuts and hole discs punched to alpha 0 (`BoardSurface`, cut-out shader, incremental repaint per playback tick, throttled to 80 ms); real groove geometry extruded per depth bin (`GrooveMesh`, Clipper inflate per bin, one `SCNShape` per bin; the copper mask hides it until cut); drill holes as cylinders revealed by progress; programs as lines in their colours, travel faint yellow; the tool model (`ToolModel3D`: V-bit cone at tip/angle, end mill, drill with 118° point, ball nose, 1/8″ × 38 mm shank, coloured ring) following playback and spinning; while connected the bit sits at the machine's live position, placed from the motion interpolator by a `CADisplayLink` on the main thread (never from the render thread). Orbit / right- or middle-drag pan / wheel or pinch zoom; **gizmo** with X/Y/Z balls (click = look along the axis), a standard-views menu, Iso, Fit, perspective/orthographic, travel on/off; machine travel box; height map wireframe (`HeightMapSurface`, rainbow interpolation grid). `-debugDumpViews 1` prints groove build time, mask repaint time, face flips and render fps every 5 s.

### 6.9 Playback bar and compact job bar (`PlaybackControls`, `JobBar(compact:)`)

A floating glass bar over the canvas: play/pause, speed 1× real / 2× / 5× / 10× / 50× / 200×, scrub slider, time and line readout. `PlaybackState` is time based (`currentTime` on `PlaybackClock`, published at most every 1/45 s; the move index derived from `cumulativeTime`), drives both canvases, the side view, the 3D view and the G-code tab's highlighted source line. While a job streams, `player.job` replaces the layer with the exact text sent and the bar becomes the compact job bar: state, progress, line a / b, elapsed · remaining, Hold/Resume, Stop, E-STOP.

### 6.10 G-code, Log and Console tabs

**G-code** (`GCodeTextView`, NSTextView-backed): the selected program's text with the playback line highlighted (UTF-16 line offsets; files over 8 MB truncated with a note), a "Sent to machine: …" banner for the streamed copy, a File menu (reveal, export). **Log**: generation log with per-step timings, the command lines, warnings/errors; the Machine log lines (`[machine] …`). **Console** (`ConsoleTab`): the controller conversation with Show status reports, Clear, an input with history (a lone `! ~ ?` is sent as a real-time byte; locked while a program runs), "N lines".

### 6.11 Shape editor UI (custom layers)

A floating toolbar over the 2D canvas: Select / Line / Rectangle / Circle / Hole / Text tools (V L R C H T), the new shape's stroke width, text and height, font (Single stroke engraving font or any installed font, Bold/Italic), closed/filled toggles. Click/drag drawing; double-click or Return finishes a line, clicking the first point closes it; Shift constrains to 45° / squares; snapping to grid, guides and other shapes' corners/vertices/centres/quadrants with a green ring; marquee selection (left-to-right encloses, right-to-left touches); handles for resize and vertex moves; arrow-key nudges 0.1 / 1 mm; duplicate, delete, align, distribute. `ShapeInspectorPanel`, a floating glass panel top-right of the canvas while something is selected, shows exact numbers (position, size, radius, rotation, text, "N shapes selected"). The sidebar's custom-layer section lists the shapes ("Shapes", Select All, Duplicate, Delete, Properties). While editing, the canvas auto-fit is frozen per layer so regeneration never moves the drawing under the cursor. All edits go through the shared undo manager with named actions (Add Rectangle, Move, Resize, Edit Text…).

### 6.12 Layer-file editor UI

"Edit" on the layer file section enters the editor: the artwork (flashes, tracks, regions, holes) drawn over the canvas, selection and Select Similar, Properties (track width / pad size / hole size with "Mixed … — a new value sets them all"), Delete, the aperture/tool table (hole counts per tool), "Editing <file>" with Done. The preview does not regenerate while editing, only on Done.

### 6.13 Machine panel and window

`MachineInspector` (the panel) and `MachineWindow` share the same views. Panel: a fixed header — **connection strip** (Wi‑Fi / USB / Simulator segmented picker (Simulator only with `machine.showSimulator` or while stored), host:port or serial port + baud, Connect / Disconnect, state pill with SIM tag, firmware badge, "Stop Job and Disconnect" confirmation, decoded alarm banner with Unlock / Home / Reset, spindle-running warning with Stop spindle), the **error line** (the last refusal — a silent refusal looks like a dead button), the **DRO** (work coordinates large, machine small, WCS name, F/S with overrides, Bf buffer, pins; click an axis value to set it; button grid Zero XY / Zero Z / Zero All (`G10 L20 P0`), Probe Z, Work Zero, Safe Z, Home, Unlock with a Home confirmation), the full-width red **E-STOP** — then a segmented tab bar (`machine.inspectorTab`) whose content scrolls:

- **Control**: jog pad with diagonals and a Z column, step presets 0.01 / 0.1 / 1 / 5 / 10 / Cont., feed presets 10…2000, Keyboard jog toggle; machine controls Reset, Hold, Resume, Check, Spindle (rpm field clamped to the settings' min/max), Coolant, More ▸ (Sleep, Safety Door, Query Parser State $G, Query Offsets $#, Build Info $I); overrides (feed −10/−1/100/+1/+10, rapid 25/50/100, spindle); **User buttons**: one per macro (icon, "allow while running").
- **Positions** (`PositionsSection`): a **Machine / Work** switch (`machine.positionsKind`). Machine: Save current…, Go to… (typed machine target, `GoToSheet`), rows with **Go** (confirmed, Z first when rising / last when descending, at the jog feed). Work: Save work zero; rows with **Use as zero** (`G10 L2 P0`, confirmed, no motion); entries the app recorded at Send carry a clock icon ("Front copper – 8 Oct 14:07", newest 20 kept, hand-saved never pruned). Context menu: the other kind's action, Rename…, Overwrite with Current Position / Current Work Zero, Delete; drag to reorder; "Could not save positions" error line.
- **Program** (`ProgramControls`): program picker (every parsed layer) + Open .ngc file… + Save sent program…, summary ("646 lines · 612 moves · est. 4:56", "2 tool segments", orange "Height map 5×4, max dev 0.1 mm, probed 17:22, board at X… Y… Z…" badge, orange "Z clamped" badge), toggles Apply height map / Backlash compensation / Clamp Z to top, the pre-flight problem in full ("Can't send: line 12 rises to Z 30.0, which is 29.0 mm above the top of Z travel…"), the **tool-change banner** (title from the `(MSG,…)`, what to do, "Will send: G21 G90 G17 · G0 Z5.000 · G0 F300 · then line 19", Probe Z / Probe Z at origin (height-mapped jobs), **Continue** — the only Continue — and Stop), the error prompt (Ignore and Continue / Stop Job), the height-map validity sheet (Re-probe / Run Without Map / Apply Anyway / Cancel), and the **job bar**: state label, progress, line a / b, elapsed · remaining (each its own small view so only they re-render per ack), Send / Verify / Send from line… (sheet with the resume preamble), Hold/Resume, Stop, E-STOP. The window variant adds the program text with the current line highlighted.
- **Probe**: Max travel, Retract after, Fast feed, Slow feed, Plate thickness (0 = bit on copper), Probe Z, "Probe input closed" indicator, last probe result in machine coordinates.
- **Height Map**: Border X/Y, W/H (Auto from the shown program's cut bounds + 1 mm), Points X/Y (2–15), Z clear / Z max depth, probe feed, interpolation grid X/Y (4–60 lines), Use height map for sending (the same switch as the Program tab's toggle), Probe / Stop / Clear / Load… / Save…, progress "k / n points", summary "5×4 · max dev 0.1 mm", the value table. Works on the shown program's side; validity issues listed in words.
- **Macros**: list with Run / Edit / Duplicate / Delete, Add, Restore Defaults; the editor sheet (name, SF Symbol icon, lines, Allow while a program runs).
- The window: a pendant column (DRO, controls, Positions short list, jog pad, overrides) beside the tabs with the program text; its toolbar has the Stop button.

### 6.14 Dialogs and sheets

- **Generate** (`GenerateDialog`): Produce CNC G-code / Artwork, destination with Choose… and New Folder, artwork Format / Polarity / Resolution (300–2400 dpi) / Frame, per-stage progress, summary, Open Folder, Cancel Run, Generate / Generate Again.
- **Test Board** (`TestBoardDialog`, ⇧⌘T): kind Parameters / Holes / Backlash, Bit (each kind remembers its own), Board size, Grid feeds × depths with Suggest, Cut depth sweep (rows), XY feed sweep (columns), hole sizes and clearance variants, the legend file; Generate…
- **Import Layers**: each file's detected role with a picker (Skip…), X0 Y0 choice (Gerber file's origin / Board corner), Import.
- **Go to coordinates** (machine coordinates, G53, current position, feed).
- **Resume preamble sheet** (Send from line…, or Continue when `machine.confirmContinue`).
- Alerts: Save position / Save work zero (name), Rename position, Move to … ?, Use … as work zero?, work offset unknown; discard changes; stop a job before switching project; the stop-did-not-complete sheet; "Use the Gerber files' own origin?" on folder open.

### 6.15 Settings window

**General**: Language (System / English / French / Spanish / Turkish; writes `AppleLanguages`, "takes effect the next time CNC G-Coder is opened"), Units (Metric / Imperial), Preview refresh (Automatic with "Delay after last edit" slider / Manual). **Machine**: Connection (Transport, Host, Port, Serial port, Baud, Status poll, Reconnect automatically, Show status reports in the console, Show the Simulator in the connection picker), Jog (default feed, step, continuous segment ms), Z probe (feeds, max travel, retract, plate thickness), Motion (safe work Z, Safe Z below top, spindle min/max, warm-up), Programs (Apply backlash compensation when sending, Confirm before continuing after a tool change, Save the work zero when a program is sent, Stream window bytes 0 = automatic, Height map applies at or below Z), Axis calibration (steps/mm; FluidNC only: read, measured vs commanded, apply, save to the config file `$CD=`).

### 6.16 Tool Library window

A list of tools (name, use, shape) with Add / Duplicate / Delete, Import… / Export… (library JSON, FlatCAM Tools Database), the editor: Used for, Shape, Tool (diameter or tip + angle), Hole range (drills), Cutting data (depth, depth per pass, feeds, spindle, overlap, dwell), Heights & direction, Milling direction, Spindle direction, Notes, and the live 3D tool model.

### 6.17 Help window

The guide (`HelpGuide`, generated from HELP*.md) with a chapter list, sections, and a language picker (System/en/fr/es/tr, `help.language`). Chapters: workflow, project folder & detection, tools & V-bits, test boards, projects, exporting one program, laser engraving & artwork export, custom layers, editing imported layers, tool library, toolpath engines, generating, parameters, preview (3D, view options), playback, side view, view controls, measuring & undo, G-code/Log/Console, presets & settings, machine zeroing & double-sided work, backlash compensation, machine panel (connecting, DRO, jogging, positions, program, probe, axis calibration, macros, height map, simulator), troubleshooting, keyboard shortcuts.

### 6.18 Rules for UI code (performance)

1. `@Observable` publishes on every assignment, equal values included: hot paths (status reports, acks, interpolator) assign only on change; `MachineController.status` is the one per-report publish and its `didSet` keeps coarse flags (`machineState`, `positionKnown`, `spindleRunning`, `workOffset`) that views read instead. Expensive views (`ContentView`, the sidebar, `PreviewPane`, `ProgramControls`, `JobBar`) must only read coarse properties; anything that changes per ack or per report (`ackedLine`, `elapsedSeconds`, `status`) is read only by a small leaf view of its own.
2. The window root never carries a computed min width (`RootSizeIsolator` + `WindowSizePolicy`).
3. The 3D bit and the cut reveal are placed from the motion interpolator by a display link on the main thread; `PlaybackClock` publishes at most 45 Hz; no `print`/`UserDefaults` in `renderer(_:updateAtTime:)`.
4. Measure, don't guess: `-debugRenderLog 1` (SwiftUI `_printChanges()` per view, count names per 45 s), `-debugDumpViews 1` (body rates, render fps, update-tick gaps — a gap average above 60 ms means the main thread is starved), `sample <pid> 5`.

---

## 7. Editor logic

**Shape editor** (`ShapeEditor`): tool, selection, draft, snapping, handles, align/distribute, undo through `setLayer`; `ShapeGeometry` in design mm; `ProjectFrame` maps to the program frames. `CustomLayerGenerator` plans passes (`ShapeMath.offset` for stroke widths / inside / outside, `pocketRings` for fills, `TextOutlines` for CoreText glyph contours or the single-stroke `StrokeFont`) and emits G-code with the engines' conventions; `PreviewController` and Generate append these programs after the pcb2gcode batch (custom-only projects skip the batch).

**Layer-file editor** (`LayerFileEditor`, `LayerArtwork`, `LayerFileFormats`): parse a Gerber or Excellon file into objects (flash, track, region, hole); select, select similar, move, delete, resize (track width, pad size, hole size), edit the aperture/tool table to change every use at once; each edit writes an edited copy under the working folder with the same file name and points the layer at it (per-file settings keyed by name survive); the Gerber writer emits clean RS-274X in the input's units; macro pads and regions can be moved or deleted but not resized.

---

## 8. Machine control

### 8.1 Protocol layer (pure, `nonisolated`)

Status report parser for `<State|MPos:|WPos:|WCO:|FS:|Ov:|Bf:|Pn:|A:|Ln:>`; response classification (`ok`, `error:n`, `ALARM:n`, `[MSG:…]`, `[PRB:x,y,z:1]`, `[GC:…]`, `[VER:/OPT:]`, FluidNC `$/…` replies); firmware identification from `$I` (Grbl 1.1 vs FluidNC, with version); real-time bytes (`?`, `!`, `~`, `0x18` reset, `0x85` jog cancel, override bytes); line builders (`$J=G91 …`, `G53 G90 G1`, `G10 L20 P0`, `G10 L2 P0`, `G38.2`, `$H`, `$X`, `$C`, `$SLP`); safe move legs (Z first when rising, last when descending); error/alarm code tables merged from Grbl and FluidNC.

### 8.2 Transports (actors)

TCP (`NWConnection`, telnet port 23, `noDelay`), serial (`/dev/cu.*`, 115200, `O_EXLOCK`; `HUPCL` cleared and DTR+RTS set together so an ESP32 is not reset on open/close), simulator (`SimulatorLauncher` runs the bundled `fake-grbl.py` on a free localhost port with `--wco 11,71,-81 --surface -82 --parent-pid` and connects by TCP). All deliver lines through one `LineSplitter`; dead-link detection by status-poll deadlines (one outstanding `?`, re-armed on timeout, ten silent deadlines → unresponsive); optional auto-reconnect.

### 8.3 Controller (main actor, `@Observable`)

Connection lifecycle and phases (disconnected/connecting/connected/unresponsive); identification (axis ranges → `workTravelRect`, home corner); status polling at `pollMs`; a single serialised send queue with one acknowledgement FIFO shared, in order, with the streamer (`[PRB:]` attributed to the FIFO head, `ALARM:` never pops it, a welcome banner always runs the reset path); derived state (`isConnected`, `machineState`, `alarmCode`, `positionTrusted` — false after position-losing alarms until homed, `$X` never sent automatically — `workOffset`, `activeWCS`, `parserState`, `canJog`, `canProbe`, `jobLocksControls`, `manualControlsEnabled`, `positioningEnabled`, `currentDesignOrigin(side:)` from `workOffset`). Commands: jog (FluidNC + homed + soft limits → one long `$J=` and `0x85` on release; otherwise wall-clock-paced 50 ms segments with a stall guard), stop (`!` → `Hold:0` → `0x18` → `G21 G90 G54 M5 M9`), **emergency stop** (`0x85 ! 0x18` written at once; the job fails "Emergency stop"; position distrusted only if the machine was moving), home, unlock, soft reset, sleep, door, check mode, spindle/coolant, overrides, zero axes / set axis (`G10 L20 P0`), go to (machine coords), go to work zero (via the safe work Z), safe Z (just below the top of travel), **probe Z** (`ProbeRoutines`: incremental two-pass `G38.2`, `G10 L20 P0 Z<plate>` at the contact, `$#` read back with the WCO cache reseeded, retract, a fresh status report checked — work Z must read plate + retract, else corrected and checked again; a remaining mismatch is an error with the offsets), probe Z at the work origin (height-mapped tool changes), set work origin to a stored machine point (`G10 L2 P0`, `$#` read back), `recordWorkZero(for:)` at every fresh job start when `autoSaveWorkZero` (named "<layer> – <date time>", `automatic`, capped at 20), macros (`@goto <position>` expands to safe legs; while-running macros through `sendInternal`), FluidNC steps/mm read/write/`$CD=` save, console with history. The last refusal/error is published for the UI. `MotionInterpolator` (lock-protected) turns 5–10 Hz reports into a continuous position (velocity extrapolation capped at 1.5 intervals, continuity offset decayed over 80 ms, snap on jumps > 3 mm); `smoothedWorkPosition` is published ~30 Hz.

### 8.4 Program preparation and streaming

`ProgramPreparer` turns a parsed layer into the exact text sent, line-for-line (line N on disk = line N sent = `sourceLine` N drawn): optional backlash compensation, optional height map warp (bilinear, only moves at or below `applyBelowZ`, arcs chord-split at 1° or 0.1 mm, through the side's design frame), optional Z clamp (`clampZAboveWork` = Z top − WCO.z − 0.5: only Z words above it on motion lines, never G53/G10/G92/G28/G30, never cutting depths), tool-change words (`T`, `M6`, `M0`) turned into comments so the streamer suspends *before* the line; segments per tool; modal-state scan for resume preambles (`resumePreamble`: retract, lead-in for backlash, spindle on + warm-up, rapid over the resume point, plunge, modal motion/feed). Pre-flight (`PreflightResult { message, issues, canClampZ, clampZWork }`) checks every move against the machine's travel and the current work offset and reports the first problem in a full sentence.

`JobStreamer`: character-counting flow control in `StreamWindow` (`$…`/`G10`/`G28.1`/`G30.1` lines drain first on Grbl serial); the window budget is set per job by `applyWindowBudget` — `machine.streamWindowBytes` when > 0, else 128 bytes on serial / 512 over TCP, grown to the largest RX size the controller reported in `Bf:`, lines = bytes ÷ 16 — and logged ("Stream window 512 bytes, 32 lines (automatic)"); states idle/verifying/running/pausedByUser/suspended(toolChange | programPause)/probing/stopping/completed/failed; pause/resume; stateful stop; error prompt (ignore / stop); tool-change suspension before the replaced line (drain, `M5`, park at the machine top, wait Idle, banner; jog/zero/probe allowed); Continue with the preamble (at once unless `machine.confirmContinue`); Send from line with the same preamble shown for confirmation; Verify in check mode (`$C`); height-map probing runs; elapsed (1 Hz `elapsedSeconds` for views) / remaining; **position-matched progress** (ok means planned, not executed; bounded by the acked line) driving the preview clock through `syncLiveClock` on a `FrameTicker` so the canvases, side view, 3D view and G-code tab follow the running job.

### 8.5 Height map

`HeightMap { origin, size, nx, ny (2–15), side, zClear, zMaxDepth, feedFast, feedSlow, values, referenceZ, probedAt, probedDesignOrigin, version 2 }` in design coordinates (older work-coordinate files refused); probing first references Z at work X0/Y0 so maps stay valid after re-zeroing Z there; validity (`HeightMap.Issue`: other side, work offset unknown, origin unknown, origin moved by X/Y, Z re-zeroed, incomplete) checked against `currentDesignOrigin(side:)` before applying; Auto grid from the shown program's cut bounds + 1 mm margin, ~10 mm spacing; JSON load/save; per project path and side in Application Support; drawn as a coloured wireframe in 2D and 3D. The generated files never contain probing; the map is applied only to the streamed copy.

---

## 9. Calibration and export extras

- **Test board**: grid of patches, rows sweep cut depth, columns sweep XY feed; each patch has 0.2/0.3/0.4 mm trace-survival tests between probe pads (closed islands so a multimeter can check them) and a pad with a cleared moat; engraved spreadsheet headers; a legend `.txt`; also a **holes test** (a grid of nominal sizes × clearance variants milled as production-style helices, hole-milling settings as the tool) and a **backlash test** (two half-lines per axis approached from opposite directions, a square and a circle). Each test remembers its own bit (`testboard.toolID[.kind]`). All three apply the two-stage plunge.
- **Backlash compensation** (`BacklashCompensation`): per axis, coordinates reached moving − are shifted by −play, a take-up move of that axis alone is inserted at each reversal, arcs are split at their X/Y extremes, the first rapid gets a 1 mm lead-in from below; a header comment prevents double application; unsupported input (G91, G20, R arcs, G28/G53/G92, canned cycles) leaves the file uncompensated with a WARNING. Applied to Generate's CNC files, `exportProgram`, the test-board dialog, and the streamed copy when enabled; "Compensate a G-code File…" for external programs. Never to the preview.
- **Laser artwork export** (`ArtworkExportService`): the parsed toolpath (cut moves swept at the cutter width when Tool Width is on, else bare centrelines; never rapids) at 1:1 as SVG/PDF/PNG with polarity and frame modes (board / origin / project / layer); Generate's artwork target writes every layer; mask SVGs via gerbv when `maskMode == svg`.
- **Engine comparison** (dev): run both engines, measure swept-area overlap, safety against copper, hole sets, overlay images.

---

## 10. Localization and documentation

**Interface languages**: English (source), French, Spanish, Turkish. `Localizable.xcstrings` is **generated** by `docs/l10n/make_catalog.py` from the translation tables `docs/l10n/{fr,es,tr}.json` (English source string → translation); never edit the catalog by hand. SwiftUI literals (`Text`, `Button`, `Label`, `.help`, `LocalizedStringKey` parameters) are extracted by the compiler; every plain-`String` UI text — enum `title`/`displayName` properties, `-> String` helpers, `?? "fallback"` and `cond ? "a" : "b"` branches, alert/panel messages, undo action names — must be wrapped in `String(localized:)` or it silently stays English (`grep -rn 'return "[A-Z]' Views Models` is the audit). SwiftUI looks interpolated `Text` up by *unnumbered* format keys (`%@ … %lld`) while the exporter writes positional ones (`%1$@ … %2$lld`): the catalog carries both. Workflow for new strings: build → `xcodebuild -exportLocalizations -localizationPath <dir> -exportLanguage en` → add the sources to the three JSON tables → `python3 make_catalog.py <dir>/en.xcloc/Localized\ Contents/en.xliff` (lists untranslated/stale keys, aborts on format-specifier mismatches) → rebuild. Settings → General → Language writes `AppleLanguages` + `app.languageOverride` (effective at relaunch); headless: `-AppleLanguages "(tr)"`. Dates in automatic names use the user's locale. UI labels inside the translated guides stay English (the app's labels differ) — a known inconsistency.

**User guide**: `HELP.md` is the single source; `HELP.fr.md` / `HELP.es.md` / `HELP.tr.md` mirror it with the same chapter/section count and order (asserted). `docs/convert.py` parses the Markdown (tables included) into chapters/sections with slug ids; `docs/build.py` writes `docs/index.html` (Apple-support style page: left contents panel with every section, full-text search, language picker, lightbox on every figure, all four languages embedded, ids assigned to the active language by JS; `docs/artifact.html` is the same without the HTML skeleton for publishing) **and regenerates `Views/HelpView.swift`** (`HelpGuide`: the in-app guide in all four languages). Nav titles, chapter summaries, figure captions and the page's UI strings per language live in build.py.

**Screenshots**: `docs/shoot.sh` renders every figure in `docs/images/` through the offscreen **window snapshot** hook (`Views/DebugWindowSnapshot.swift`, section 13), one app launch per shot, without screen capture or permissions (the macOS 26 glass containers paint white in `cacheDisplay`, so the sidebar's scroll document view, the toolbar's leaf views, the title bar's widgets and the SceneKit view are composited by hand with `.sourceOver`).

**Other documents**: `README.md` (features, install, build), `appconnect.md` (App Store listing text), `CLAUDE.md` (architecture notes, gotchas, dev hooks — kept current with every change), this plan.

---

## 11. Rules learned the hard way (do not relearn)

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
11. Use the `cu.` serial node, not `tty.`; open with `O_EXLOCK`; clear `HUPCL` and set DTR+RTS together or an ESP32 resets on open/close.
12. A sandboxed child process (pcb2gcode) only inherits the app's static sandbox: copy inputs into the app's temp space first; the helper must be signed with sandbox + inherit entitlements, and crashes with SIGTRAP (`_libsecinit_appsandbox`, "failed with exit code 5") if its parent is not sandboxed.
13. **Never run `xcodebuild` while a headless instance launched from the DerivedData bundle is still running**: the build reports success but leaves the app bundle unsigned → not sandboxed → every preview fails as in rule 12. Check `codesign -vvv` when previews suddenly fail.
14. Reading a multi-megabyte process output with `waitUntilExit` + `readDataToEndOfFile` deadlocks at 64 KB; drain the pipe while the process runs.
15. SwiftUI: a `.frame(minWidth:)` on the root re-measures the whole hierarchy every update; answer window sizing from AppKit (`RootSizeIsolator`, `WindowSizePolicy`). `.inspector` grows the window past the screen; lay the panel out yourself. `@AppStorage` inside an `ObservableObject` publishes changes. Text fields must never take focus at launch. Keep edits in the field's own text and only commit parseable values. SwiftUI's `\.undoManager` environment never reaches the model — own the `UndoManager`.
16. `@Observable` publishes on every assignment, equal values included; assign only on change in hot paths and read coarse flags from expensive views (6.18).
17. **Per-ack re-renders starve the sender**: a body that reads `ackedLine`, `elapsedSeconds` or `status` re-lays out everything beneath it (~27 ms with button rows), the acks queue behind the layout, the planner runs dry, and 0.07 mm corner segments crawl — on the simulator as well as the machine. Leaf views for live numbers; coarse flags everywhere else.
18. The 128-byte character-counting window is right for Grbl serial and wrong for Wi‑Fi: one ack per five lines at a 50–100 ms round trip caps the line rate below what corners need. TCP flow-controls the ESP32 itself; use 512+ bytes (or the `Bf:` RX size) there.
19. V-bit diameters must be the **effective** width at depth; all engines receive the effective value.
20. Mask clear width must be at least half the widest opening or the centre stays covered; measure it from the files (inradius via binary search on inward offsets) instead of trusting a typed value.
21. Per-process temp roots named after the pid; startup removes only folders of dead processes so two instances never delete each other's files.
22. Edited layer copies keep the original file name (per-file settings and project packing key on it).
23. EasyEDA names files identically in every export (KiCad after the board); never let per-file settings leak between projects.
24. Probe Z: `G10 L20 P0` at the contact, not `G10 L2` with a computed value (FluidNC answered `ok` and left the origin untouched); read `$#` back and verify a fresh status report.
25. Only `Text("literal")` is localized for free; a `String` computed property returning the same literal is not (rule in section 10). Window titles are localized too: a dev hook that finds a window by title must run with `-AppleLanguages "(en)"`.
26. After changing the layout of `LayerKind` (or other widely-used enums), do a **clean** build — an incremental build once produced a binary that crashed at launch from stale object files.

---

## 12. Implementation phases

Build in this order. Each phase ends with the listed checks passing before the next starts. Keep every phase shippable.

### Phase 0 — Skeleton
- Xcode project, both schemes/configurations, entitlements, bridging header with the Clipper shim, vendored Clipper2, bundle scripts (pcb2gcode, simulator), `Info.plist` with the `.cncproj` package UTI, `container-migration.plist`.
- `AppModel`, `ContentView` three-column split with `RootSizeIsolator` and `WindowSizePolicy`, empty sidebar/preview, Settings and Help windows, menus (6.3).
- Check: both schemes build; the App Store build has no `Helpers` folder and no engine picker; `codesign -vvv` passes.

### Phase 1 — Detection, parameters, pcb2gcode preview
- `DetectedFiles`, `GerberDetector` (EasyEDA/Protel + KiCad), Open Gerber Folder, Import Layers sheet.
- `ParametersStore` with the full key table, snapshot, validation, presets, `ParameterState` undo.
- `Pcb2GcodeService`: jobs, cache, `runBatch` with all post-processing passes, origin normalisation, `ProjectFrame`.
- `GCodeParser`, `PreviewDocument`, `PreviewController` (signature, debounce, manual mode, staleness).
- Sidebar with all groups and tooltips; 2D canvas with fit/zoom/pan, colours, rapids, tool width, drill hits; playback bar and `PlaybackState`; side view; G-code and Log tabs; Generate sheet; single-program export.
- Check: from a sample EasyEDA export and from a KiCad export (`kicad-cli pcb export gerbers [--no-protel-ext]` + `export drill --format excellon --excellon-separate-th`), Generate writes front/back/outline/drill/mask programs; dwells are in seconds; no `G64`; all programs share one origin per side (overlay registers); peck and plunge passes appear in the files; the time estimates match `length ÷ feed`.

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
- SceneKit scene: slab, copper faces with cuts punched out, groove geometry, drill holes, programs, travel, tool model, gizmo, views, travel box.
- Shape editor + custom layers + `CustomLayerGenerator` + `TextOutlines` + `ShapeInspectorPanel`; layer-file editor with artwork overlay and aperture/tool tables; tape measure; guides; origin marker dragging and Set Origin in View; snap to grid.
- Check: a drawn rectangle with "Cut outside" produces a program whose inner edge equals the drawn size; editing a track width in a Gerber regenerates with the new width and the original file is untouched; the tool model's cone matches tip/angle; `-debugSnapshot3D` renders the sample's grooves.

### Phase 5 — Calibration and laser export
- Test board generator and dialog (parameters, holes, backlash tests + legend); backlash compensation service and "Compensate a G-code File"; artwork export (SVG/PDF/PNG, frames, polarity).
- Check: the parameter test board's legend matches the engraved headers; a compensated file carries the header and reversed-direction moves are shifted by the play.

### Phase 6 — Machine control
- Protocol layer with tests; transports (TCP, serial, simulator launcher + `fake-grbl.py`); controller with the motion interpolator; `StreamWindow` with the adaptive budget, `ProgramPreparer`, `JobStreamer`; probing routines; height maps; saved positions (Machine/Work, automatic work zero at Send); macros; machine settings pane; the Machine panel and window with every view in 6.13; the preview following the job; emergency stop; quit/switch-project guards.
- Check with the simulator: connect, home, jog, zero, probe Z (work Z reads the plate thickness), send a program to completion with the canvases following and **elapsed within 2 % of the estimate** (outline ≈ 296 s for 295 s, also with a height map applied), a tool change suspends and continues with one Continue button, Send from line resumes, a height map probes and warps the streamed copy (saved sent program differs from the file), a Work entry appears in Positions at every Send and "Use as zero" re-establishes it, E-STOP marks the position untrusted, `-debugRenderLog 1` shows under 20 re-renders of `JobBar`/`ProgramControls` per 45 s of streaming.

### Phase 7 — Help, localization, documentation, polish
- `.help` on every control (section 15); HELP.md and the three translations; `docs/build.py` → `index.html` + `HelpView.swift`; `docs/shoot.sh` screenshots through the window snapshot hook; the string catalog pipeline with all four languages and the Language setting; README, App Store listing text, CLAUDE.md.
- Window size policy, remembered widths, keyboard shortcuts, imperial display, presets menu.
- Check: `make_catalog.py` reports no untranslated keys beyond untranslatable tokens; a `-AppleLanguages "(tr)"` launch shows no English in the empty-project state, the Program tab and the Positions tab; `build.py` asserts equal chapter counts.

---

## 13. Dev hooks and headless verification

Launch arguments read from `UserDefaults` (every `param.*`, `machine.*`, `export.*`, `ui.*` key can be overridden the same way, e.g. `-machine.inspectorTab positions -machine.positionsKind workZero`). Always pass `-ApplePersistenceIgnoreState YES` (a bare launch may restore no window). Paths must be inside the app container (`~/Library/Containers/com.koraybirand.CNC-G-Coder/Data`; sample Gerbers under `Documents/sample/Cam`).

| Argument | Effect |
|---|---|
| `-debugProjectFolder <dir>` / `-debugOpenProject <x.cncproj>` | open an export folder / a saved project without a panel |
| `-debugDrillSettings "a.drl:k=v,k=v;b.drl:k=v"` | per-drill-file values |
| `-debugSaveProject <path>` | save at once |
| `-debugGenerate 1` / `-debugGenerateLaser 1` / `-debugGenerateLog <file>` / `-debugGenerateDialog 1` | generate beside the project / write the Log and quit / show the sheet |
| `-debugImport a,b`, `-debugRefreshAfter n -debugEdit key=value`, `-debugLayer <name>`, `-debugTab gcode|log`, `-debugScrub 0.6`, `-debugPlay 1`, `-debugFocusLog 1` | imports, edits, selection, tabs, playback |
| `-debugCustomDemo 1`, `-debugSelectShape 1`, `-debugSelectTool <tool>`, `-debugDrawCircleAt x,y`, `-debugUndoTest 1`, `-debugMeasure x1,y1,x2,y2` | shape editor and measuring |
| `-debugEditLayer front|drill0`, `-debugEditSelect …`, `-debugEditTrackWidth …`, `-debugEditHole …`, `-debugEditDoneAfter n` | layer-file editor |
| `-debugCompareEngines <dir>`, `-debugCompareNativeOnly 1` | engine comparison report |
| `-debugTestBoard <out.ngc>`, `-debugTestDialog 1 -testboard.kind holes|backlash|parameters`, `-debugHoleTest <out.ngc>` | test boards |
| `-debugMachineWindow 1|window`, `-debugMachineWindowAfter n`, `-debugMachineConnect host:port|sim`, `-debugMachineSerial /dev/cu.x`, `-debugMachineSend <layer>`, `-debugMachineScript "setx:-10;sety:-70;setz:80;send:outline;wait:done"` (steps: setx/sety/setz, gozero, send, verify, continue, stop, estop, savezero[:name], usezero:name, probez, home, unlock, steps:x, calibrate:x,10,9.85[,file], sleep:n, wait:done|suspended|idle), `-debugMachineAutoContinue 1`, `-debugMachineExitWhenDone 1` (prints `JOB …` and quits), `-debugMachineProbeMap 3x3`, `-debugMachineApplyMap 1` (send with the stored map), `-debugMachineClampZ 1` | machine control; the Simulator transport presets a work zero |
| `-debugSnapshot3D <png>` (+ `-debugSnapshot3DAfter`, `-debugSnapshot3DClose`), `-debugWindowSnapshot <png>` (+ `…After n`, `…Exit 1`, `…Title "General"`, `…SidebarScroll bottom|0…1`, `…Dump 1`, `…Parts <dir>`, `…Method`), `-debugOpenWindow tools|machine|help`, `-debugOpenSettings 1 -debugSettingsTab machine -debugSettingsSnapshot <png> -debugSettingsScroll …` | offscreen renders for verification and the guide's screenshots |
| `-debugWindowSize 1400x900`, `-debugScreenWidth 1200`, `-debugDumpViews 1`, `-debugRenderLog 1`, `-debugMotionLog 1` | layout and performance diagnostics |
| `-AppleLanguages "(tr)"` | run in a language |

Headless recipe: build (never while a headless instance runs — rule 13), launch the binary from `DerivedData/…/CNC G-Coder.app/Contents/MacOS/CNC G-Coder` with hooks, redirect stdout to a file, poll it with an `until` loop (macOS has no `timeout`), inspect outputs with grep or view the snapshot PNGs. Timing runs: wrap the launch in `time` and compare the `[machine] wait:done → … elapsed N s` line with the `est.` in the `loaded` line.

---

## 14. Source layout to reproduce

```
CNC G-Coder/
  CNC_G_CoderApp.swift            scenes, menus, AppDelegate
  ContentView.swift               split view, panel layout, toolbar, presets menu, column widths
  Localizable.xcstrings           GENERATED (docs/l10n/make_catalog.py)
  container-migration.plist       pre-sandbox data → container, first launch
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
           TestBoardDialog, ToolLibraryView, SettingsView, HelpView (GENERATED), LogView,
           GCodeTextView, MonoTextView, ViewUtilities, WindowSizePolicy, DebugWindowSnapshot
  Views/Machine/ MachineInspector, MachineWindow, MachineConnectionBar, MachineDRO,
           MachineControls, JogPad, OverridesView, PositionsSection, GoToSheet,
           ProgramControls, ProgramTab, JobBar, ProbeTab, HeightMapTab, MacrosTab,
           UserButtons, ConsoleTab, EmergencyStopButton, MachineSettingsPane
  ThirdParty/Clipper2, ThirdParty/ClipperShim
Scripts/ bundle-pcb2gcode.sh, pcb2gcode-helper.entitlements, fake-grbl.py
docs/    build.py, convert.py, shoot.sh, index.html, artifact.html, images/, l10n/{make_catalog.py, fr.json, es.json, tr.json}
HELP.md, HELP.fr.md, HELP.es.md, HELP.tr.md, README.md, appconnect.md, CLAUDE.md, plan.md
```

Approximate sizes: ~37 k lines of Swift; the largest files are the machine controller (~1.9 k), the 2D canvas and sidebar (~1.6 k each), the 3D view (~1.6 k), pcb2gcode service (~1.3 k), app model (~1.2 k), job streamer (~1 k).

---

## 15. Writing conventions

- **Tooltips** (`.help`): every button, field, picker, toggle and row label gets one. Say what the control does, what the machine or file will get (the G-code word or flag where it helps: `G10 L20`, `$H`, `--isolation-width`), a typical value, and when it is disabled and why. Full sentences, no jargon without a gloss, no references to other apps.
- **Footers and help text** explain consequences ("deeper widens V-bit cuts and thins traces"), not UI mechanics.
- **Log lines** are terse and factual, one per step, with timings; warnings start with `WARNING:`, failures with `ERROR:`; machine lines with `[machine]`.
- **Code comments** explain *why* (the rule, the firmware quirk, the SwiftUI trap), not what the line does. Every file starts with a doc comment stating its role in the architecture.
- **Translations** keep the English register (plain, concrete), keep G-code words, `$` commands, flags and product names untranslated, keep the same format specifiers, and use the language's own typography (French spacing before `:`/`;`, Turkish dotted/dotless i).
- No external tool names in user-facing text except pcb2gcode, FluidNC, Grbl, EasyEDA, KiCad and FlatCAM, which the user works with directly.
