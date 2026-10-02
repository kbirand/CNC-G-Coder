import SwiftUI

/// The in-app user guide (opened via ⌘?, the Help menu, or the ? button).
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("CNC G-Coder — User Guide")
                    .font(.title.bold())

                section("Workflow overview", """
                1. Export Gerber + drill files from EasyEDA into a folder.
                2. Choose Folder (toolbar) — layers are auto-detected by filename.
                3. Set your tools, depths and feeds (or load a Preset). The sidebar shows the settings for the selected program only — the layer menu at its top switches both the preview and the settings; pick Machine setup there for the parameters shared by every program (mirror axis, safe heights).
                4. Inspect the preview: select each program, play it back, check depths in the side view and the total time estimate.
                5. Generate — pick (or create with New Folder) the destination folder; all .ngc programs are written there.
                6. Machine in order: front copper isolation → drills (one program per drill file, change bits at the M0 pauses) → flip the board → back copper → outline cutout (bridges hold the board) → snap/file the bridge tabs.
                7. Solder mask: paint the milled board with UV solder mask, cure it, then run top-mask-etch.ngc / bottom-mask-etch.ngc to mill the pad openings clear.
                """)

                section("Project folder & detection", """
                The app expects an EasyEDA export: Gerber_TopLayer.GTL, Gerber_BottomLayer.GBL, Gerber_BoardOutlineLayer.GKO, solder masks .GTS/.GBS, and .DRL drill files. EasyEDA splits drills into PTH / PTH-via / NPTH files; each becomes a separate program because pcb2gcode accepts one drill file per run.

                Generate asks where to write the programs each project (the dialog's New Folder button creates a fresh destination); the choice is remembered until you switch projects. The live preview uses a temporary folder and never touches your files until you press Generate.
                """)

                section("Tools & V-bits — read this first", """
                Every diameter you enter must be the EFFECTIVE cutting diameter at depth, with the exact bit you machine with.

                Straight/end-mill bits: the effective diameter is the printed one — enter it as-is (cutout end mill, mask end mill, straight micro end mills).

                V-bits (the usual choice for isolation — 0.1 mm straight bits snap easily): the tip is narrow but the cone widens with depth. Effective ≈ tip + 2 × |cut depth| × tan(half-angle). Examples for a 0.1 mm tip at −0.06 mm: 30° V ≈ 0.13 mm · 60° V ≈ 0.17 mm · 90° V ≈ 0.22 mm. Entering the tip size instead makes every trace thinner than designed and the isolation narrower than requested — silently.

                Verification: mill a test board (File → Generate Test Board… → Parameter test board, cut with the bit you pick) and measure the 0.2 mm test trace. Every test trace runs between two probe pads inside a closed moat, so a multimeter in continuity mode checks it: pad to pad must beep (the trace survived), a pad to the surrounding copper or to the next trace must not (the isolation is complete). If it comes out ~0.13 mm with a 60° V-bit entered as 0.1, your effective diameter is ~0.07 mm larger than entered — fix the parameter, not the design.
                """)

                section("Custom layers — drawing your own shapes", """
                File → New Custom Layer (⇧⌘N, also in the sidebar's layer menu) adds a layer you draw on: lines and polygons, rectangles (with corner radius and rotation), circles, and text — in the built-in single-stroke engraving font or any installed font, engraved along its outlines. Every non-empty layer becomes one program, written by Generate and the CNC export like any other, and shown in the preview as it regenerates after each edit.

                Drawing: with the layer selected, a bar appears over the preview with the tools — Select (V), Line (L), Rectangle (R), Circle (C), Text (T). Click or drag to draw; double-click or Return finishes a line, clicking its first point closes it into a polygon; Shift constrains to 45° and makes squares. Points snap to the grid (Snap to Grid), to guides, and to other shapes' corners, vertices, centres and quadrants (Snap to Objects); a green ring shows the snap. Right- or middle-drag pans (Option-drag too), scroll zooms as usual. The other programs show behind the drawing only with All Layers Overlay on (View Options).

                Editing: click to select, shift-click to add, drag a box (rightwards: enclosed shapes, leftwards: touched shapes). Drag shapes to move them — they snap to each other — or drag the handles to resize rectangles and circles and to move a line's vertices. Arrow keys nudge by 0.1 mm (Shift: 1 mm), ⌘D duplicates, Delete deletes, ⌘Z undoes everything. The sidebar lists the shapes; selecting one opens a floating Properties panel at the right of the drawing with its numbers — position, size, corner radius, rotation, text, font, stroke width — for exact values; with several selected, Align (edges and centres) and Distribute (equal gaps) line them up.

                Machining: each layer has one tool (from the library or typed in), a depth, depth per pass, feeds and spindle, and an operation. Engrave runs the tool centre along the drawn line; Cut outside / Cut inside offset closed shapes by half the tool so what you drew is the size that comes out (outside for a part you keep, inside for a hole). A shape's stroke width wider than the tool is cleared with overlapping passes; Filled pockets a closed shape inside-out. Shapes are drawn in design coordinates on the board, so they keep their place whatever origin you choose, and a Back-side layer is mirrored like back copper.
                """)

                section("Measuring & undo", """
                Measure: the ruler button at the top right of the 2D view (or M while the view has focus) turns on the tape measure, on any layer. Click two points — or drag between them — to read the distance, ΔX, ΔY and angle. It snaps to toolpath corners, drill holes, drawn shapes, the origin, guides and (with Snap to Grid) the grid; Shift keeps the line horizontal, vertical or at 45°. Esc clears the measurement, then leaves the tool.

                Undo: Edit → Undo / Redo (⌘Z / ⇧⌘Z) step through one history for the whole app — parameter edits, tools and presets being applied, the origin being moved, layer files imported, replaced or removed, and every drawing edit. Opening another project starts a new history.
                """)

                section("Tool library", """
                File → Tool Library… (⇧⌘L) holds every bit you own with its cutting data: shape (straight, ball, V-bit), what it is used for, diameter or tip + angle, depth, depth per pass (drills: peck), feeds, spindle, overlap, and for drills the range of hole sizes it may drill. Import FlatCAM… reads a FlatCAM Tools Database export; re-importing updates tools with the same name.

                The Tool menu at the top of each settings group copies a tool's values into that layer — the fields stay editable. "Edited" means they no longer match the tool (click to restore); "Custom" means values entered by hand. V-bits: choose Bit → V-bit and enter tip and angle; the width at depth is worked out and follows the cut depth.
                """)

                section("Parameters — copper isolation", """
                Isolation width is the total copper cleared around each trace; passes overlap by Pass overlap (default 50%), so time grows almost linearly with it. Depth per pass splits the cut into several shallower passes (0 = one pass). Cut depth only needs to pass the ~0.035 mm copper foil (−0.05…−0.08 mm typical); deeper cutting widens V-bit kerf and thins traces.

                Important: traces are never cut into — the first pass is offset outward so the cutter just grazes the trace edge. Isolation eats surrounding waste copper only.
                """)

                section("Parameters — drilling & cutout", """
                Depths for drills and cutout are board thickness + ~0.2 mm into the spoilboard (1.6 mm stock → −1.8). The cutout runs multiple laps of Pass depth each; machining time = laps × perimeter ÷ feed.

                Bridges: on passes deeper than Bridge Z, the cutter lifts and leaves tabs of material (white in the preview) so the board can't break loose on the final lap. Tab thickness = board bottom − Bridge Z. After machining, snap the board out and file the tabs flush.

                Peck depth drills in pecks, clearing chips between them (0 = one stroke). Bits on hand: every hole inside a checked bit's range is drilled with that bit, so a job needs only the bits you own; holes no bit covers keep their designed size and the Log names them. Hole milling: turn on Mill large holes and holes from the given size up are cut in circles, spiralling down, with their own end mill (e.g. a 2 mm corn bit — its own tool, depth, pass depth, feeds, spindle and dwell) into a separate "… milled" program. The bit must be smaller than the holes it mills.
                """)

                section("Parameters — safety heights & plunge clearance", """
                Safe Z is the travel height between cuts — it must clear clamps and board warp. Plunge clearance makes vertical moves cross the air at rapid speed: descents rapid down to it and plunge at the Z feed only from there; retracts feed up to it and rapid the rest. This often halves a program's time — pcb2gcode alone feeds the entire descent from Safe Z, and drill retracts come up at feed too. 0.2–0.5 mm is typical; it must clear board warp; 0 disables. The bit always enters and leaves the material at the programmed feed.

                Machine setup also holds Milling direction (Any / Climb / Conventional, for every milling program). Spindle dwell is set per layer, next to its spindle speed: the pause after the spindle starts and stops, written as G4 P in seconds as GRBL and LinuxCNC expect (pcb2gcode itself writes milliseconds; the app converts). 0 = no pause.
                """)

                section("Hole fit test", """
                File → Generate Test Board… → Hole fit test mills holes to find the size that fits a pin. List the nominal sizes (rows, e.g. 2 3 4) and the variants added to each (columns, e.g. -0.05 0 0.05 0.10 0.15 0.20); every hole is milled like production — a spiral down in the bit's pass depth, then a clean-up circle — with the hole-milling settings or a flat bit from the Tool Library (each test remembers its own bit). A legend .txt lists every hole's diameter; the single hole at the top-left marks the orientation. Push the pin into each hole of its row, keep the variant that fits the way you want, and design the hole at nominal + variant.
                """)

                section("Machine setup — backlash compensation", """
                For an axis that loses travel every time it reverses (a screw bearing with end play, a worn nut): squares come out short in one direction, milled holes oval, diagonal traces thinned. File → Generate Test Board… → Backlash test (or Backlash Test… in Machine setup) writes a 75 × 75 mm test with the bit you pick — per axis one line cut in two halves reached from opposite directions; the step between the halves is that axis's play. Enter it as X / Y backlash and cut the test again: straight lines mean the value is right.

                With a value set, every program the app writes (Generate, Export, test boards) gets a short take-up move of that axis wherever it reverses, and the coordinates reached moving − are shifted by the play; arcs are split where they reverse. The program's first rapid comes in from 1 mm below so the play starts in a known state. The preview and the G-code tab show the uncompensated program. The values belong to the machine, not the project. Compensate a G-code File… writes a compensated copy of a program made elsewhere. Heavy cuts can still push an axis through its play — repairing the machine is always better; set 0 when it is fixed.
                """)

                section("Parameters — solder mask etch", """
                The .GTS/.GBS layers describe the OPENINGS — pads and vias that must stay exposed. In CNC etch mode the app inverts the layer and pockets each opening with 40% overlapping passes: top-mask-etch.ngc and bottom-mask-etch.ngc.

                The mask tool must be no larger than your smallest opening (smaller openings are skipped — watch the Log). Clear width must be at least half the widest opening; larger values slow G-code generation dramatically. Etch depth only needs to remove cured paint, not copper.
                """)

                section("Preview — layers & colors", """
                One program is shown at a time — select it with the layer menu at the top of the sidebar. All programs share one origin per side, so the optional \"All Layers Overlay\" registers copper, drills and masks exactly; back-side programs are mirrored, so enable \"Un-mirror Back Side\" to overlay them aligned with the front.

                Colors: each layer has its own color; YELLOW dashed lines are head travel (rapids, no cutting); WHITE segments on the outline are the holding bridges; the translucent band under cut lines is the real cutter width (\"Tool Width\" in the View Options menu). Drill hits are dots.

                \"Un-mirror Back Side\" (View Options menu, eye icon) un-mirrors back-side programs on screen so you can check they align with the front — display only, the G-code stays mirrored and CNC-ready.
                """)

                section("Playback & time estimates", """
                Playback is a feed-rate-accurate simulation: each move takes length ÷ its programmed feed (XY feed for cuts, Z feed for plunges). 1× real is 100% machining speed; 2×–200× skim faster. The tool marker glides along every move, including rapids.

                Scrub with the slider in the floating player bar; the G-code tab highlights and scrolls to the current source line for the same program. Per-program times show in the sidebar layer menu; Σ est. below it is the total for all programs. Rapids are assumed at 2000 mm/min (G-code carries no rapid feed), so totals are accurate to within your machine's real rapid speed.
                """)

                section("Side view", """
                X–Z / Y–Z project the selected program onto a vertical plane; Profile plots Z against distance traveled — ideal for verifying drill depths and etch depths against the labeled reference lines (Z0 board top, zwork, zdrill, zcut, zbridge, zsafe).

                Z is exaggerated relative to X (the ×N note shows the ratio). Travel above zsafe (tool-change retracts) is compressed into a thin band at the top so it stays visible without flattening the cutting depths.
                """)

                section("View controls", """
                Scroll wheel or pinch: zoom (anchored at the cursor). Drag: pan. Double-click or the fit button: reset framing. Zoom and pan survive layer switches and window resizes; the +/− buttons step zoom. Panel divider positions and all parameters persist across launches.
                """)

                section("Presets & settings", """
                The Presets menu (toolbar) saves and recalls complete parameter sets — one per material or machine. All settings persist automatically.

                Settings (⌘,) controls preview refresh: Automatic regenerates ~1 s after you stop editing (delay adjustable); Manual only regenerates on the Refresh button. The \"Out of date\" badge appears when parameters changed since the last preview.
                """)

                section("Machine zeroing & double-sided work", """
                Machine setup → Origin → \"X0 Y0 at\" decides where the machine origin is: a corner or the centre of the project (as the machine sees each side, so after flipping you touch off at the same fixture corner), a custom point in design coordinates (the same physical spot on both sides — e.g. a registration hole), or the design's own origin (no zeroing). The view marks X0 Y0 with a ringed crosshair and red X / green Y arrows. To move it, drag the marker, or use Set Origin in View (Machine setup) or the scope button and click the spot — both snap to the project's corners, centre and drill holes, and with Snap to Grid on (View Options, or View → Snap to Grid, ⌘') to the grid shown in the view.

                To save a single program, select its layer and use CNC export → Export <name>.ngc… in the sidebar: it writes exactly the previewed G-code.

                Zero X/Y at the origin once for all front-side programs (copper, drills, outline, top mask), then once more after flipping the board for the back-side programs — copper, drills and masks stay registered. Zero Z on the board surface.

                Choose the flip direction with \"Board flips\" to match how you physically turn the board, and verify with \"Un-mirror Back Side\": flipped back copper must sit exactly over the front. The app intentionally generates no probing/height-map G-code — use your sender's autolevel (e.g. UGS AutoLeveler) on the isolation programs.
                """)

                section("Troubleshooting", """
                • pcb2gcode is built into the app — nothing to install. The native engine (Machine setup → Toolpath engine) does not need it at all.
                • Preview failed: the Log tab holds the full pcb2gcode output with per-step timings — the error is at the bottom.
                • Uncut gaps between close traces: the tool is too wide to fit between them; pcb2gcode warns in the Log. Use a smaller effective tool diameter or increase design clearance.
                • Mask openings not cleared: opening smaller than the mask tool, or Clear width less than half the opening.
                • Long generation times: mask Clear width too large, or very wide isolation width.
                """)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 500, idealHeight: 760)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
