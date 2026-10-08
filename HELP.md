# CNC G-Coder — User Guide

*(This guide is also available inside the app: ⌘? or the toolbar Help button.)*

## Workflow overview

1. Export Gerber + drill files from EasyEDA into a folder.
2. **Choose Folder** (toolbar) — layers are auto-detected by filename.
3. Set your tools, depths and feeds (or load a **Preset**). The sidebar shows the settings for the selected program only — the layer menu at its top switches both the preview and the settings; pick **Machine setup** there for the parameters shared by every program.
4. Inspect the preview: select each program, play it back, check depths in the side view and the total time estimate.
5. **Generate** — pick (or create with New Folder) the destination folder; all `.ngc` programs are written there.
6. Machine in order: front copper isolation → drills (one program per drill file; change bits at the M0 pauses) → flip the board → back copper → outline cutout (bridges hold the board) → snap/file the bridge tabs.
7. Solder mask: paint the milled board with UV solder mask, cure it, then run `top-mask-etch.ngc` / `bottom-mask-etch.ngc` to mill the pad openings clear.

## Project folder & detection

The app expects an EasyEDA export: `Gerber_TopLayer.GTL`, `Gerber_BottomLayer.GBL`, `Gerber_BoardOutlineLayer.GKO`, solder masks `.GTS`/`.GBS`, and `.DRL` drill files. EasyEDA splits drills into PTH / PTH-via / NPTH files; each becomes a separate program because pcb2gcode accepts one drill file per run.

Generate asks where to write the programs (the dialog's New Folder button creates a fresh destination); the choice is remembered until you switch projects. The live preview uses a temporary folder and never touches your files until you press Generate.

## Tools & V-bits — read this first

Every diameter you enter must be the **effective cutting diameter at depth**, with the exact bit you machine with.

- **Straight/end-mill bits**: effective = printed diameter, enter as-is.
- **V-bits** (the usual isolation choice — 0.1 mm straight bits snap easily): the cone widens with depth:
  `effective ≈ tip + 2 × |cut depth| × tan(half-angle)`
  For a 0.1 mm tip at −0.06 mm: 30° V ≈ **0.13 mm** · 60° V ≈ **0.17 mm** · 90° V ≈ **0.22 mm**.
  Entering the tip size instead makes every trace thinner than designed and the isolation narrower than requested — silently.
- **Verification**: mill a test board (File → Generate Test Board…) and measure the 0.2 mm test trace. If it measures ~0.13 mm with a 60° V-bit entered as 0.1, your effective diameter is ~0.07 mm larger than entered — fix the parameter, not the design.

- **V-bit mode**: set **Bit → V-bit** on isolation, mask or silkscreen and enter tip and angle instead; the width at depth is worked out (and follows the cut depth) for you.

## Projects

A project (`.cncproj`) is a self-contained **package**: Finder shows it as one file, but right-click → **Show Package Contents** reveals

```
Board.cncproj/
  project.json   parameters (tools, depths, feeds, origin…), layer roles, guides, where each file came from
  Layers/        the Gerber and drill files themselves, unchanged
```

Move or copy the project on its own — it never loses its layers. (To email one, compress it first; Mail does this automatically.) When a project is opened its files are copied into a private working folder, so the originals are not needed and are never modified.

- **File → New Project** (⌘N), **Open Project…** (⌘O), **Open Recent**, **Save Project** (⌘S), **Save Project As…** (⇧⌘S). The same actions are in the sidebar's **Open** menu. The window title shows the project and "Edited" when it has unsaved changes; New, Open and Quit ask before discarding them.
- **Open Gerber Folder…** (⇧⌘O) starts an untitled project from an EasyEDA export folder, detecting the layers by filename, as before.
- The packed copies are what the project uses. If you re-export the Gerbers from EasyEDA, bring them in with **Import Layer…** or **Replace…** (or open the new export folder), then save. **Show Original in Finder** on a layer points at the file it was packed from, if it still exists.
- Projects saved by earlier versions (a single file with the layers embedded, or with links to them) still open, and become a package on their next save.
- Finder shows the package as one file once the app has been run (that registers the project type); before that it appears as a folder named `….cncproj`.
- Opening a project replaces the current parameters with the project's.

### Importing single layers

**File → Import Layer…** (⌘I), or **Import Layer…** under Layer files in the sidebar, adds Gerber or Excellon files from anywhere. Each file's role is guessed from its name (and drill files from their M48 header, whatever they are called) and can be changed in the import sheet before importing: a drill file is added as another drill program; any other role replaces the file in that slot. Right-click a layer file in the sidebar to **Replace…**, **Remove** or **Show in Finder**.

## Exporting one program

With a layer selected, **CNC export → Export <name>.ngc…** in the sidebar saves just that program — exactly the previewed G-code, with the same post-processing and origin Generate would write. It is available once the preview is up to date. The "X0 Y0 at" link beside it jumps to the origin setting.

## Custom layers — drawing your own shapes

**File → New Custom Layer** (⇧⌘N, also in the sidebar's layer menu) adds a layer you draw on: lines and polygons, rectangles (with corner radius and rotation), circles, and text — in the built-in single-stroke engraving font or any installed font, engraved along its outlines. Every non-empty layer becomes one program, written by Generate and the CNC export like any other, and shown in the preview as it regenerates after each edit.

**Drawing.** With the layer selected, a bar appears over the preview with the tools — Select (V), Line (L), Rectangle (R), Circle (C), Text (T). Click or drag to draw; double-click or Return finishes a line, clicking its first point closes it into a polygon; Shift constrains to 45° and makes squares. Points snap to the grid (Snap to Grid), to guides, and to other shapes' corners, vertices, centres and quadrants (Snap to Objects); a green ring shows the snap. Right- or middle-drag pans (Option-drag too), scroll zooms as usual. The other programs show behind the drawing only with All Layers Overlay on (View Options).

**Editing.** Click to select, shift-click to add, drag a box (rightwards: enclosed shapes, leftwards: touched shapes). Drag shapes to move them — they snap to each other — or drag the handles to resize rectangles and circles and to move a line's vertices. Arrow keys nudge by 0.1 mm (Shift: 1 mm), ⌘D duplicates, Delete deletes, ⌘Z undoes everything. The sidebar lists the shapes; selecting one opens a floating Properties panel at the right of the drawing with its numbers — position, size, corner radius, rotation, text, font, stroke width — for exact values; with several selected, **Align** (edges and centres) and **Distribute** (equal gaps) line them up.

**Machining.** Each layer has one tool (from the library or typed in), a depth, depth per pass, feeds and spindle, and an operation. *Engrave* runs the tool centre along the drawn line; *Cut outside* / *Cut inside* offset closed shapes by half the tool so what you drew is the size that comes out (outside for a part you keep, inside for a hole). A shape's stroke width wider than the tool is cleared with overlapping passes; *Filled* pockets a closed shape inside-out. Shapes are drawn in design coordinates on the board, so they keep their place whatever origin you choose, and a Back-side layer is mirrored like back copper. Custom layers are saved in the project.

## Editing imported layers

Any imported Gerber or drill file can be edited in place: select a program made from one and click **Edit** at the top of its settings, or right-click the file under **Layer files** → **Edit…**. The file's artwork (pads, tracks, filled areas or holes) is drawn over its program in the 2D view.

- **Select**: click, ⇧-click to add, drag a box (left-to-right encloses, right-to-left touches). ⌘A selects all; **Select Similar** (the wand) adds every track of the same width, pad of the same aperture or hole of the same size.
- **Change sizes of the selection** in the Properties panel: track width, pad diameter or width × height, hole diameter. Only the selected objects change.
- **Change a size everywhere**: while editing, the sidebar lists the file's apertures (Gerber) or drill tools (Excellon). Editing a row resizes everything that uses it, e.g. all 0.25 mm tracks at once. The target icon selects them.
- **Move** by dragging or with the arrow keys (0.1 mm, ⇧ 1 mm); **Delete** with ⌫. Values commit on Return.

Every edit writes an edited copy of the file; the original file is never modified. While editing, the sidebar shows only the file's sizes and pcb2gcode does not run — the toolpaths drawn under the artwork are the ones from before editing. Press **Done** (or Esc with nothing selected) and the preview regenerates once from the edited file. Edits are on the normal undo history (⌘Z), edited files are marked with an orange pencil, and saving the project packs the edited file. Custom-shaped (macro) pads and filled areas can be moved or deleted but not resized.

## Tool library

**File → Tool Library…** (⇧⌘L) holds every bit you own with the cutting data that goes with it: shape (straight / ball / V-bit), what it is used for, diameter or tip + angle, depth, depth per pass (drills: peck depth), feeds, spindle, pass overlap, and for drills the range of hole sizes it may drill.

- **Import FlatCAM…** reads a FlatCAM Tools Database export (Tools Database → Export, the JSON `.TXT`). Tool Target maps to *Used for* (Isolation, Drilling, Milling/Cutout → Cutout, others → General); V shape keeps tip and angle; FlatCAM's drill tolerance becomes the hole range. Re-importing updates tools with the same name instead of duplicating them.
- Every tool is drawn at its real proportions: a profile icon in the list, and a slowly turning 3D model (drag to turn it) with its key dimensions at the top of the editor — the same model the 3D preview uses.
- **Import…** / **Export…** move the library between computers: Export writes the whole library as a `.json` file; Import reads either such a file or a FlatCAM Tools Database. Tools already in the library (same tool, or same name) are updated, the rest added — so a project's "bits on hand" still match on the other machine.
- Each settings group has a **Tool** menu at its top. Picking a tool **copies** its values into the group — as FlatCAM copies database data into an object — so you can still tune the layer. **Edited** appears when the fields no longer match the tool; click it to restore the tool's values. **Custom** means values entered by hand.
- Feeds or spindle of 0 (FlatCAM's "not set") leave the layer's own value unchanged.

## Toolpath engines

Machine setup → **Toolpath engine** picks what turns the Gerber and drill files into programs:

- **pcb2gcode** — the established open-source generator. It is built into the app (Contents/Helpers), so nothing has to be installed.
- **Native** — the app's own engine: it reads the files itself and computes isolation, board outline with tabs, drilling (with bits on hand), hole milling, solder-mask etch and silkscreen with the Clipper2 polygon library. It runs in the app, which makes it faster, and follows the same rules as pcb2gcode — passes spread evenly across the isolation width, the outline's centre line as the board edge, tabs on the longest edges.

Both write their programs the same way, so every setting (dwells, pecks, plunge clearance, extra cut, heights, origins) applies to either. Differences you may notice: the native engine splits depths exactly (1.8 mm in 0.6 mm passes is 3 passes; pcb2gcode makes it 4 of 0.45 mm) and orders paths by nearest neighbour.

## Parameters

### Copper isolation
- **Tool diameter** — the *effective* diameter at cutting depth (see "Tools & V-bits" above), or pick **V-bit** and enter tip + angle.
- **Isolation width** — total copper cleared around each trace; machining time grows almost linearly with it. 2–3× tool diameter is a good start.
- **Cut depth** — copper foil is ~0.035 mm; −0.05…−0.08 mm cuts through with margin. Deeper widens V-bit cuts and thins traces.
- **Depth per pass** — reach the cut depth in several equal passes of at most this depth. 0 = one pass.
- **Pass overlap** — overlap between neighbouring isolation passes (default 50%).
- Traces are never cut into: the first pass is offset outward, isolation eats surrounding waste copper only.

### Drilling & cutout
- **Every drill file has its own settings.** Select a drill program (or its `… milled` program) and the Drilling, Bits on hand, Hole milling and Heights & direction groups show that file's values — the header names the file. Turning on Mill large holes for the NPTH file, or giving the via file a shallower depth, changes nothing for the other drill files. A file added to the project starts from the drilling defaults (shown when no drill program is selected) and keeps its own values from then on; they are saved in the project with the file. Applying a preset puts every drill file on the preset's values.
- Depths = board thickness + ~0.2 mm into the spoilboard (1.6 mm stock → −1.8).
- **Peck depth** — drill in pecks: after each one the bit rapids out to clear chips, returns to just above the previous bottom and feeds on. 0 = one stroke.
- **Bits on hand** — check the library drills you own. Every hole inside a checked bit's range is drilled with that bit, so a job needs only those bits (a 0.915 mm hole goes to the 1.0 mm bit). Bits without a range of their own use **Bit tolerance** (± around the bit). Holes no bit covers keep their designed size and the Log names them — ranges are always passed, because without them pcb2gcode would round *every* hole to the nearest bit (a 3 mm mounting hole silently drilled at 1 mm).
- **Hole milling** — for holes bigger than any drill you own (e.g. 3–4 mm mounting holes with a 2 mm 2-flute corn bit). Turn on **Mill large holes**; holes from **Mill holes from** up are not drilled but cut in circles, spiralling down (helical G2 moves), into a separate `… milled` program run right after its drill program. The hole-milling bit has its own Tool menu (cutout and general tools from the library), diameter, depth, pass depth (per turn of the spiral), feeds, spindle and dwell. The circle is offset inward by half the bit, so holes come out at their designed size; the bit must be smaller than the smallest milled hole.
- The cutout runs laps of **Pass depth**; time = laps × perimeter ÷ feed.
- **Bridges**: on passes deeper than Bridge Z the cutter lifts and leaves holding tabs (white in the preview) so the board can't break loose on the final lap. Tab thickness = board bottom − Bridge Z. Snap and file after machining.

### Safety heights & plunge clearance
- **Safe Z** — travel height between cuts; must clear clamps and board warp.
- **Plunge clearance** — vertical moves are rapid through the air and feed only below this height: descents rapid down to it then plunge at the Z feed; retracts feed up to it then rapid. This often halves program time (pcb2gcode alone feeds the whole descent — and drill retracts too). 0.2–0.5 mm typical; must clear board warp; 0 disables. The bit always enters and leaves the material at the programmed feed.
- **Milling direction** (Machine setup) — Any lets pcb2gcode choose the shortest path; Climb or Conventional fixes it for every milling program (this turns off 2-opt path shortening, so programs get slightly longer).
- **Rapid feed** (Machine setup) — your machine's G0 speed, used only for the time estimates (FlatCAM's FR Rapids).
- **Heights & direction** (every layer; also stored per tool and imported from FlatCAM) — the layer's own **Travel Z** and **Tool-change Z** (the height for the tool-change pause and the end of the program; FlatCAM's Tool-change Z / End Z), left empty to use Machine setup's values, which show greyed in the field; **Extra cut** (isolation, mask, silkscreen and custom layers) — every closed contour runs on past its start by this length so no sliver is left where the loop closes; where pcb2gcode chains passes into one cut, the tool then retraces back along the groove, so only already-cut copper is cut again; **Milling direction** — Machine default or this layer's own; **Spindle** — clockwise (M3) or counter-clockwise (M4). Hole milling uses the drilling heights (it runs in the same pass).
- **Spindle dwell** (every layer, next to its spindle speed; also stored per tool in the library and imported from FlatCAM's dwell) — pause after the spindle starts, so it is at speed before cutting, and after it stops, before a tool change. 0 = no pause. pcb2gcode writes dwells in milliseconds (`G04 P2000`), but GRBL and LinuxCNC read seconds, so the app writes each program's dwell in seconds (`G04 P2.000`). Machines configured for millisecond dwells (some Mach3 setups) need the value ×1000.

### Solder mask etch
The `.GTS`/`.GBS` layers describe the *openings* (pads/vias that stay exposed). CNC etch mode inverts the layer and pockets each opening with 40% overlapping passes → `top-mask-etch.ngc` / `bottom-mask-etch.ngc`.
- Mask tool must be no larger than the smallest opening (smaller ones are skipped — watch the Log).
- **Clear width** — how far inward each opening is pocketed. By default (**Clear width from the mask layers** on) the app measures the widest opening in the mask files and clears by half of it plus a little, so every opening is cleared to its centre and no wider; the footer shows the widest opening. Switched off, enter it yourself: it must be ≥ half the widest opening or the middle of large openings stays covered, and larger values slow generation dramatically.
- Etch depth only needs to remove cured paint, not copper.

## Preview

### 3D view

The **2D / 3D** switch above the preview shows the programs in 3D: cuts as lines in each layer's colour, head travel in faint yellow above the board, and a translucent 1.6 mm FR4 slab sized from the cutout. Drag to orbit, right-drag or middle-drag (mouse wheel button) to pan, and scroll (mouse wheel or two-finger trackpad scroll) or pinch to zoom.

- **Gizmo** (top right): the X/Y/Z balls turn with the view; click one to look along that axis — Z = top, −Z = bottom, −Y = front, Y = back, X = right, −X = left. Below it: a menu of all standard views, **Iso**, **Fit**, perspective/orthographic, and travel moves on/off.
- With **All Layers Overlay** on, every program sits on the physical board: back-side programs appear un-mirrored on the underside, so you can orbit round to inspect the back. A single program is shown as it is machined.
- Playback works as in 2D: the finished part of the program is highlighted, and the **bit that cuts the program** follows the tool at real size — the V-bit's cone at its angle and tip, the end mill's or hole mill's diameter, a drill with its 118° point, all on a 1/8″ (3.175 mm), 38 mm shank with the coloured depth ring PCB bits carry (yellow V-bit, blue end mill, red drill, purple ball nose). It spins clockwise while the program plays.

- One program is shown at a time (layer menu at the top of the sidebar). All programs share one origin per side, so the "All Layers Overlay" registers copper, drills and masks exactly; enable "Un-mirror Back Side" to overlay the mirrored back side aligned with the front.
- **Colors**: per-layer colors for cuts; **yellow dashed = head travel** (no cutting); **white = holding bridges**; the translucent band under cuts is the real cutter width ("Tool Width" in the View Options menu).
- **Un-mirror Back Side** (View Options menu) un-mirrors back-side programs for visual alignment checks — display only; the G-code stays mirrored and CNC-ready. Off, the back correctly sits mirrored against the front.

## Playback & estimates

Feed-rate-accurate simulation via the floating player bar: each move takes `length ÷ programmed feed`. **1× real = 100% machining speed**; the tool marker glides along every move including rapids. The G-code tab highlights the current source line. Per-program times are in the sidebar layer menu; **Σ est.** below it is the total. Rapids are assumed at 2000 mm/min (G-code carries no rapid feed).

## Side view

X–Z / Y–Z projections or a Z-vs-distance **Profile**, with labeled reference lines (Z0, zwork, zdrill, zcut, zbridge, zsafe). Z is exaggerated (the ×N note shows how much); travel above zsafe is compressed into a thin top band so retracts stay visible.

## View controls

Scroll wheel / pinch = zoom (anchored at cursor) · drag = pan · double-click / fit button = reset. Zoom and pan survive layer switches; panel divider positions and all parameters persist across launches.

## Measuring & undo

**Measure.** the ruler button at the top right of the 2D view (or M while the view has focus) turns on the tape measure, on any layer. Click two points — or drag between them — to read the distance, ΔX, ΔY and angle. It snaps to toolpath corners, drill holes, drawn shapes, the origin, guides and (with Snap to Grid) the grid; Shift keeps the line horizontal, vertical or at 45°. Esc clears the measurement, then leaves the tool.

**Undo.** Edit → Undo / Redo (⌘Z / ⇧⌘Z) step through one history for the whole app — parameter edits, tools and presets being applied, the origin being moved, layer files imported, replaced or removed, and every drawing edit. Opening another project starts a new history.

## Presets & settings

**Presets** (toolbar) save/recall complete parameter sets. **Settings (⌘,)**: preview refresh mode — Automatic (debounced after edits, delay adjustable) or Manual (Refresh button); the "Out of date" badge marks a stale preview.

## Machine zeroing & double-sided work

**Machine setup → Origin → "X0 Y0 at"** decides where the machine origin is on the board; every program shares it, one origin per side. The view marks it with a ringed crosshair and red X / green Y arrows (always framed by Fit).

- **Corners / Centre** — of the whole project (all programs' extent) as the machine sees each side: after flipping you touch off at the same corner of the fixture.
- **Custom point** — a point in design (Gerber/EasyEDA) coordinates, so tool sizes never move it. It is the same physical spot on both sides, e.g. a registration hole. Type Origin X / Y, or set it in the view (below).
- **Moving it in the view** — drag the origin marker to where X0 Y0 should be, or click **Set Origin in View** (Machine setup) / the scope button and click the spot. Both snap to the project's corners and centre (which set that corner mode) and to drill holes (a custom point). With **Snap to Grid** on (View Options, or View → Snap to Grid, ⌘'), any other drop lands on the grid shown in the view, so the origin moves in whole grid steps; zoom in for a finer grid.
- **Design origin** — no zeroing; coordinates exactly as exported.

Zero X/Y at the origin for the front-side programs (copper, drills, outline, top mask), then once more after flipping for the back-side programs — everything stays registered. Zero Z on the board surface. Choose the flip direction with **Mirror around Y axis** and verify with Flip Back View. Probing and height maps are done live from the Machine panel (below); the programs themselves stay plain G-code.

## Machine panel

The **Machine** button in the toolbar (View → Machine Panel, ⇧⌘M) opens a panel on the right of the main window: a native sender for GRBL 1.1 and FluidNC controllers. The connection strip and the position read-out stay at the top; the tabs below (Control, Positions, Program, Probe, Height Map, Macros) scroll on their own; a red **E-STOP** under the read-out stays in view on every tab; the console is the main window's Console tab, and "Open in a window" at the top of the panel gives the same controls a window of their own with the program text.

### Connecting
Pick **Wi‑Fi** (the controller's IP and telnet port, 23 by default) or **USB** (a `/dev/cu.*` port at 115200) and press Connect. The state pill shows Idle / Run / Jog / Hold / Alarm…, the badge the firmware the app identified (`$I`), and alarms appear decoded with Unlock / Home / Reset. Alarms that lose position (limits, a reset while moving) mark the position untrusted: Home, or press Unlock to keep the position as it is. The connection runs alongside other clients (a pendant on the same controller keeps working).

### DRO, zeroing, positions
Work and machine coordinates, live feed and spindle, the planner buffer and triggered pins (P = probe input closed). Click an axis value to set or zero that axis; the button grid under it has **Zero XY / Zero Z / Zero All** (`G10 L20 P0`, persistent) and **Probe Z** (the two-pass touch-off of the Probe tab) on the first row, **Work Zero** (retracts to the safe work Z first), **Safe Z** (just below the top of Z travel), **Home** and **Unlock** on the second. The **Positions** tab keeps named machine positions; **Go to coordinates…** moves to a typed machine target (Z first when rising, last when descending). **Save work zero** stores where work X0 Y0 Z0 is in machine coordinates, and **Use as zero** on any entry re-establishes the work origin at that point (`G10 L2 P0`, no motion) — restore a zero after a reset or re-homing. **User buttons** on the Control tab run the macros of the Macros tab (one button per macro, optional SF Symbol icon; "allow while running" keeps a button enabled during a job, for short commands such as coolant). **E-STOP** (also at the end of the job bar, and ⇧⌘.) sends jog cancel, feed hold and soft reset at once without waiting for anything; the position is marked untrusted if the machine was moving. ⌘. stays the controlled stop.

### Jogging and overrides
Tap a jog button for one step; press and hold for continuous motion that stops on release (on a homed FluidNC with soft limits the jog runs to the limit and is cancelled on release; otherwise short segments are streamed). Diagonal buttons move two axes. **Keyboard jog**: arrows = X/Y, Page Up/Down = Z, Shift = step ×10, Esc or ⌘. = stop. Overrides adjust feed (10–200 %), rapid (25/50/100 %) and spindle speed in real time. Spindle on/off with RPM, coolant, Hold/Resume, Check mode, Sleep and Door are under Machine controls.

### Program tab — sending
Pick a generated layer (or use CNC export → **Send … to Machine…** in the sidebar), or **Open .ngc file…** for an external program (a test board, for example). **Backlash** and **Apply height map** transform the copy that is sent, never the files on disk; **Save sent program…** keeps that copy. **Verify** streams the program in check mode without motion. If the machine's travel cannot hold the program the job bar says so in full — for example that line 12 rises to a Z above the top of travel because work Z0 is near the top; when that is the only problem, **Clamp Z to top** re-prepares the program with those retract heights lowered to just below the top (cutting depths are untouched; an orange "Z clamped" badge shows while it is on) so an air test can run. **Send** streams it with character counting; the main window's canvases, side view, 3D view and G-code tab follow the job, a blue crosshair marks the machine's real position, and the job bar shows the line, elapsed and remaining time. Hold/Resume and the overrides stay live. **Stop** holds, resets once the machine is at a standstill, and turns the spindle off.

Tool changes (extra drill sizes) suspend the job before the change: spindle off, Z parked at the top, and a banner names the bit. Jog, Zero and **Probe Z** are enabled while suspended so you can touch off the new bit, then **Continue**, which resumes at once — the banner lists the preamble lines it will send (Settings → Machine → *Confirm before continuing after a tool change* brings back the confirmation sheet). **Send from line…** resumes mid-program with a safe preamble (retract, spindle, rapid over the point, plunge), always shown for confirmation. The app asks before switching projects, disconnecting or quitting while a job runs.

### Probe tab
A two-pass Z touch-off: fast down to find contact, back off 1 mm, slow down for the exact point; the active work origin is then set on the contact point (`G10 L20`; the slow pass stops within a micron of the trigger) and read back from the controller — the DRO then reads the retract height, with Z0 on the surface. Plate thickness 0 = clip on the copper and the bit as probe; enter the thickness for a touch plate. Settings → Machine holds the feeds, maximum travel and retract.

### Axis calibration (steps/mm)

If a 10 mm jog moves the spindle 9.85 mm, the controller's steps/mm is off. Settings → Machine → **Axis calibration** (FluidNC, while connected) reads `axes/x|y/steps_per_mm` and the config filename from the controller. Measure with a dial indicator or a ruler: jog a little in the measuring direction first (takes up the backlash), zero the indicator, jog a known distance — the longer the better — and enter commanded and measured; new steps/mm = current × commanded ÷ measured. **Apply** writes the running config at once (`$/axes/x/steps_per_mm=…`) and, with the save toggle on, `$CD=<config file>` rewrites that file (e.g. `raptorex.yaml`) from the running config so the value survives a reboot. Re-measure afterwards; measurements that disagree by more than a few hundredths point at backlash or a loose pulley, not at steps/mm.

### Height Map tab
Define a grid over the board (**Auto** fits the selected program), **Probe** it and read the deviation. Maps are per side and stored relative to the Z probed at the work origin, so re-probing Z there after a tool change keeps them valid. With **Apply height map** on, every cut and low plunge of the streamed copy is warped to the measured surface (bilinear interpolation); rapids at safe height are untouched. If the work origin moved since probing, the app warns before applying. Maps are kept per project under Application Support and can be saved/loaded as JSON; View Options → Height Map shows the points on the toolpath.

### Trying it without a machine
Turn on **Show the Simulator in the connection picker** in Settings → Machine, pick **Simulator** in the connection bar and press Connect: the app starts a built-in FluidNC simulator (`fake-grbl.py`, bundled; needs python3 from Xcode's command line tools) on a private port and talks to it like a real controller — real-time motion, alarms, tool-change suspensions, Z probing against a synthetic surface 1 mm below work zero, height maps. Its work zero is preset so the sample programs fit the travel. The state pill carries a **SIM** tag and the badge reads Simulator; Disconnect or quitting stops it. (Dev: `-debugMachineWindow 1 -debugMachineConnect sim`.)

## Troubleshooting

- **pcb2gcode missing** → only in builds made without it; the native engine takes over (Machine setup → Toolpath engine). Normal builds carry pcb2gcode inside the app — nothing to install.
- **Preview failed** → the Log tab has the full output with per-step timings; the error is at the bottom.
- **Uncut gaps between close traces** → tool too wide to fit; pcb2gcode warns in the Log. Reduce effective tool diameter or increase design clearance.
- **Mask opening not cleared** → opening smaller than the mask tool, or a hand-entered Clear width < half the opening (turn "Clear width from the mask layers" back on).
- **Slow generation** → mask Clear width too large, or very wide isolation width.
