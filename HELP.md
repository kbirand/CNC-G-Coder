# CNC G-Coder — User Guide

*(This guide is also available inside the app: ⌘? or the toolbar Help button.)*

## Workflow overview

1. Export Gerber + drill files from EasyEDA into a folder.
2. **Choose Folder** (toolbar) — layers are auto-detected by filename.
3. Set your tools, depths and feeds (or load a **Preset**). The sidebar shows the settings for the selected program only — the layer menu at its top switches both the preview and the settings; pick **Machine setup** there for the parameters shared by every program.
4. Inspect the preview: select each program, play it back, check depths in the side view and the total time estimate.
5. **Generate** — pick (or create with New Folder) the destination folder; all `.ngc` programs are written there.
6. Machine in order: front copper isolation → drills (one program per drill file; change bits at the M0 pauses) → flip the board → back copper → outline cutout (bridges hold the board) → snap/file the bridge tabs.
7. Solder mask: paint the milled board with UV solder mask, cure it, then run `mask_top.ngc` / `mask_bottom.ngc` to mill the pad openings clear.

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

## Parameters

### Copper isolation
- **Tool diameter** — the *effective* diameter at cutting depth (see "Tools & V-bits" above).
- **Isolation width** — total copper cleared around each trace; passes overlap 50%, so machining time grows almost linearly with it. 2–3× tool diameter is a good start.
- **Cut depth** — copper foil is ~0.035 mm; −0.05…−0.08 mm cuts through with margin. Deeper widens V-bit cuts and thins traces.
- Traces are never cut into: the first pass is offset outward, isolation eats surrounding waste copper only.

### Drilling & cutout
- Depths = board thickness + ~0.2 mm into the spoilboard (1.6 mm stock → −1.8).
- The cutout runs laps of **Pass depth**; time = laps × perimeter ÷ feed.
- **Bridges**: on passes deeper than Bridge Z the cutter lifts and leaves holding tabs (white in the preview) so the board can't break loose on the final lap. Tab thickness = board bottom − Bridge Z. Snap and file after machining.

### Safety heights & plunge clearance
- **Safe Z** — travel height between cuts; must clear clamps and board warp.
- **Plunge clearance** — vertical moves are rapid through the air and feed only below this height: descents rapid down to it then plunge at the Z feed; retracts feed up to it then rapid. This often halves program time (pcb2gcode alone feeds the whole descent — and drill retracts too). 0.2–0.5 mm typical; must clear board warp; 0 disables. The bit always enters and leaves the material at the programmed feed.

### Solder mask etch
The `.GTS`/`.GBS` layers describe the *openings* (pads/vias that stay exposed). CNC etch mode inverts the layer and pockets each opening with 40% overlapping passes → `mask_top.ngc` / `mask_bottom.ngc`.
- Mask tool must be no larger than the smallest opening (smaller ones are skipped — watch the Log).
- **Clear width** ≥ half the widest opening; larger values slow generation dramatically.
- Etch depth only needs to remove cured paint, not copper.

## Preview

- One program is shown at a time (layer menu at the top of the sidebar). All programs share one origin per side, so the "All Layers Overlay" registers copper, drills and masks exactly; enable "Flip Back View" to overlay the mirrored back side aligned with the front.
- **Colors**: per-layer colors for cuts; **yellow dashed = head travel** (no cutting); **white = holding bridges**; the translucent band under cuts is the real cutter width ("Tool Width" in the View Options menu).
- **Flip Back View** (View Options menu) un-mirrors back-side programs for visual alignment checks — display only; the G-code stays mirrored and CNC-ready.

## Playback & estimates

Feed-rate-accurate simulation via the floating player bar: each move takes `length ÷ programmed feed`. **1× real = 100% machining speed**; the tool marker glides along every move including rapids. The G-code tab highlights the current source line. Per-program times are in the sidebar layer menu; **Σ est.** below it is the total. Rapids are assumed at 2000 mm/min (G-code carries no rapid feed).

## Side view

X–Z / Y–Z projections or a Z-vs-distance **Profile**, with labeled reference lines (Z0, zwork, zdrill, zcut, zbridge, zsafe). Z is exaggerated (the ×N note shows how much); travel above zsafe is compressed into a thin top band so retracts stay visible.

## View controls

Scroll wheel / pinch = zoom (anchored at cursor) · drag = pan · double-click / fit button = reset. Zoom and pan survive layer switches; panel divider positions and all parameters persist across launches.

## Presets & settings

**Presets** (toolbar) save/recall complete parameter sets. **Settings (⌘,)**: preview refresh mode — Automatic (debounced after edits, delay adjustable) or Manual (Refresh button); the "Out of date" badge marks a stale preview.

## Machine zeroing & double-sided work

With "Zero project at X0/Y0" on, every program shares one origin per side: zero X/Y once at the project corner for the front-side programs (copper, drills, outline, top mask), then once more after flipping for the back-side programs — everything stays registered. Zero Z on the board surface. Choose the flip direction with **Mirror around Y axis** and verify with Flip Back View. The app generates no probing G-code — use your sender's autolevel (e.g. UGS AutoLeveler) for isolation passes.

## Troubleshooting

- **pcb2gcode not found** → `brew install pcb2gcode` (and `gerbv` for laser SVGs).
- **Preview failed** → the Log tab has the full output with per-step timings; the error is at the bottom.
- **Uncut gaps between close traces** → tool too wide to fit; pcb2gcode warns in the Log. Reduce effective tool diameter or increase design clearance.
- **Mask opening not cleared** → opening smaller than the mask tool, or Clear width < half the opening.
- **Slow generation** → mask Clear width too large, or very wide isolation width.
