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
                7. Solder mask: paint the milled board with UV solder mask, cure it, then run mask_top.ngc / mask_bottom.ngc to mill the pad openings clear.
                """)

                section("Project folder & detection", """
                The app expects an EasyEDA export: Gerber_TopLayer.GTL, Gerber_BottomLayer.GBL, Gerber_BoardOutlineLayer.GKO, solder masks .GTS/.GBS, and .DRL drill files. EasyEDA splits drills into PTH / PTH-via / NPTH files; each becomes a separate program because pcb2gcode accepts one drill file per run.

                Generate asks where to write the programs each project (the dialog's New Folder button creates a fresh destination); the choice is remembered until you switch projects. The live preview uses a temporary folder and never touches your files until you press Generate.
                """)

                section("Tools & V-bits — read this first", """
                Every diameter you enter must be the EFFECTIVE cutting diameter at depth, with the exact bit you machine with.

                Straight/end-mill bits: the effective diameter is the printed one — enter it as-is (cutout end mill, mask end mill, straight micro end mills).

                V-bits (the usual choice for isolation — 0.1 mm straight bits snap easily): the tip is narrow but the cone widens with depth. Effective ≈ tip + 2 × |cut depth| × tan(half-angle). Examples for a 0.1 mm tip at −0.06 mm: 30° V ≈ 0.13 mm · 60° V ≈ 0.17 mm · 90° V ≈ 0.22 mm. Entering the tip size instead makes every trace thinner than designed and the isolation narrower than requested — silently.

                Verification: mill a test board (File → Generate Test Board…) and measure the 0.2 mm test trace. If it comes out ~0.13 mm with a 60° V-bit entered as 0.1, your effective diameter is ~0.07 mm larger than entered — fix the parameter, not the design.
                """)

                section("Parameters — copper isolation", """
                Isolation width is the total copper cleared around each trace; passes overlap 50%, so time grows almost linearly with it. Cut depth only needs to pass the ~0.035 mm copper foil (−0.05…−0.08 mm typical); deeper cutting widens V-bit kerf and thins traces.

                Important: traces are never cut into — the first pass is offset outward so the cutter just grazes the trace edge. Isolation eats surrounding waste copper only.
                """)

                section("Parameters — drilling & cutout", """
                Depths for drills and cutout are board thickness + ~0.2 mm into the spoilboard (1.6 mm stock → −1.8). The cutout runs multiple laps of Pass depth each; machining time = laps × perimeter ÷ feed.

                Bridges: on passes deeper than Bridge Z, the cutter lifts and leaves tabs of material (white in the preview) so the board can't break loose on the final lap. Tab thickness = board bottom − Bridge Z. After machining, snap the board out and file the tabs flush.
                """)

                section("Parameters — safety heights & plunge clearance", """
                Safe Z is the travel height between cuts — it must clear clamps and board warp. Plunge clearance makes vertical moves cross the air at rapid speed: descents rapid down to it and plunge at the Z feed only from there; retracts feed up to it and rapid the rest. This often halves a program's time — pcb2gcode alone feeds the entire descent from Safe Z, and drill retracts come up at feed too. 0.2–0.5 mm is typical; it must clear board warp; 0 disables. The bit always enters and leaves the material at the programmed feed.
                """)

                section("Parameters — solder mask etch", """
                The .GTS/.GBS layers describe the OPENINGS — pads and vias that must stay exposed. In CNC etch mode the app inverts the layer and pockets each opening with 40% overlapping passes: mask_top.ngc and mask_bottom.ngc.

                The mask tool must be no larger than your smallest opening (smaller openings are skipped — watch the Log). Clear width must be at least half the widest opening; larger values slow G-code generation dramatically. Etch depth only needs to remove cured paint, not copper.
                """)

                section("Preview — layers & colors", """
                One program is shown at a time — select it with the layer menu at the top of the sidebar. All programs share one origin per side, so the optional \"All Layers Overlay\" registers copper, drills and masks exactly; back-side programs are mirrored, so enable \"Flip Back View\" to overlay them aligned with the front.

                Colors: each layer has its own color; YELLOW dashed lines are head travel (rapids, no cutting); WHITE segments on the outline are the holding bridges; the translucent band under cut lines is the real cutter width (\"Tool Width\" in the View Options menu). Drill hits are dots.

                \"Flip Back View\" (View Options menu, eye icon) un-mirrors back-side programs on screen so you can check they align with the front — display only, the G-code stays mirrored and CNC-ready.
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
                With \"Zero project at X0/Y0\" on, every program shares one origin per side: zero X/Y once at the project corner for all front-side programs (copper, drills, outline, top mask), then once more after flipping the board for the back-side programs — copper, drills and masks stay registered. Zero Z on the board surface.

                Choose the flip direction with \"Mirror around Y axis\" to match how you physically turn the board, and verify with \"Flip Back View\": flipped back copper must sit exactly over the front. The app intentionally generates no probing/height-map G-code — use your sender's autolevel (e.g. UGS AutoLeveler) on the isolation programs.
                """)

                section("Troubleshooting", """
                • \"pcb2gcode not found\": install Homebrew, then `brew install pcb2gcode` (and `gerbv` for laser SVG export).
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
