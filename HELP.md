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

## Tool library

**File → Tool Library…** (⇧⌘L) holds every bit you own with the cutting data that goes with it: shape (straight / ball / V-bit), what it is used for, diameter or tip + angle, depth, depth per pass (drills: peck depth), feeds, spindle, pass overlap, and for drills the range of hole sizes it may drill.

- **Import FlatCAM…** reads a FlatCAM Tools Database export (Tools Database → Export, the JSON `.TXT`). Tool Target maps to *Used for* (Isolation, Drilling, Milling/Cutout → Cutout, others → General); V shape keeps tip and angle; FlatCAM's drill tolerance becomes the hole range. Re-importing updates tools with the same name instead of duplicating them.
- Each settings group has a **Tool** menu at its top. Picking a tool **copies** its values into the group — as FlatCAM copies database data into an object — so you can still tune the layer. **Edited** appears when the fields no longer match the tool; click it to restore the tool's values. **Custom** means values entered by hand.
- Feeds or spindle of 0 (FlatCAM's "not set") leave the layer's own value unchanged.

## Parameters

### Copper isolation
- **Tool diameter** — the *effective* diameter at cutting depth (see "Tools & V-bits" above), or pick **V-bit** and enter tip + angle.
- **Isolation width** — total copper cleared around each trace; machining time grows almost linearly with it. 2–3× tool diameter is a good start.
- **Cut depth** — copper foil is ~0.035 mm; −0.05…−0.08 mm cuts through with margin. Deeper widens V-bit cuts and thins traces.
- **Depth per pass** — reach the cut depth in several equal passes of at most this depth. 0 = one pass.
- **Pass overlap** — overlap between neighbouring isolation passes (default 50%).
- Traces are never cut into: the first pass is offset outward, isolation eats surrounding waste copper only.

### Drilling & cutout
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
- **Spindle dwell** (every layer, next to its spindle speed; also stored per tool in the library and imported from FlatCAM's dwell) — pause after the spindle starts, so it is at speed before cutting, and after it stops, before a tool change. 0 = no pause. pcb2gcode writes dwells in milliseconds (`G04 P2000`), but GRBL and LinuxCNC read seconds, so the app writes each program's dwell in seconds (`G04 P2.000`). Machines configured for millisecond dwells (some Mach3 setups) need the value ×1000.

### Solder mask etch
The `.GTS`/`.GBS` layers describe the *openings* (pads/vias that stay exposed). CNC etch mode inverts the layer and pockets each opening with 40% overlapping passes → `top-mask-etch.ngc` / `bottom-mask-etch.ngc`.
- Mask tool must be no larger than the smallest opening (smaller ones are skipped — watch the Log).
- **Clear width** ≥ half the widest opening; larger values slow generation dramatically.
- Etch depth only needs to remove cured paint, not copper.

## Preview

- One program is shown at a time (layer menu at the top of the sidebar). All programs share one origin per side, so the "All Layers Overlay" registers copper, drills and masks exactly; enable "Un-mirror Back Side" to overlay the mirrored back side aligned with the front.
- **Colors**: per-layer colors for cuts; **yellow dashed = head travel** (no cutting); **white = holding bridges**; the translucent band under cuts is the real cutter width ("Tool Width" in the View Options menu).
- **Un-mirror Back Side** (View Options menu) un-mirrors back-side programs for visual alignment checks — display only; the G-code stays mirrored and CNC-ready. Off, the back correctly sits mirrored against the front.

## Playback & estimates

Feed-rate-accurate simulation via the floating player bar: each move takes `length ÷ programmed feed`. **1× real = 100% machining speed**; the tool marker glides along every move including rapids. The G-code tab highlights the current source line. Per-program times are in the sidebar layer menu; **Σ est.** below it is the total. Rapids are assumed at 2000 mm/min (G-code carries no rapid feed).

## Side view

X–Z / Y–Z projections or a Z-vs-distance **Profile**, with labeled reference lines (Z0, zwork, zdrill, zcut, zbridge, zsafe). Z is exaggerated (the ×N note shows how much); travel above zsafe is compressed into a thin top band so retracts stay visible.

## View controls

Scroll wheel / pinch = zoom (anchored at cursor) · drag = pan · double-click / fit button = reset. Zoom and pan survive layer switches; panel divider positions and all parameters persist across launches.

## Presets & settings

**Presets** (toolbar) save/recall complete parameter sets. **Settings (⌘,)**: preview refresh mode — Automatic (debounced after edits, delay adjustable) or Manual (Refresh button); the "Out of date" badge marks a stale preview.

## Machine zeroing & double-sided work

**Machine setup → Origin → "X0 Y0 at"** decides where the machine origin is on the board; every program shares it, one origin per side. The view marks it with a ringed crosshair and red X / green Y arrows (always framed by Fit).

- **Corners / Centre** — of the whole project (all programs' extent) as the machine sees each side: after flipping you touch off at the same corner of the fixture.
- **Custom point** — a point in design (Gerber/EasyEDA) coordinates, so tool sizes never move it. It is the same physical spot on both sides, e.g. a registration hole. Type Origin X / Y, or set it in the view (below).
- **Moving it in the view** — drag the origin marker to where X0 Y0 should be, or click **Set Origin in View** (Machine setup) / the scope button and click the spot. Both snap to the project's corners and centre (which set that corner mode) and to drill holes (a custom point). With **Snap to Grid** on (View Options, or View → Snap to Grid, ⌘'), any other drop lands on the grid shown in the view, so the origin moves in whole grid steps; zoom in for a finer grid.
- **Design origin** — no zeroing; coordinates exactly as exported.

Zero X/Y at the origin for the front-side programs (copper, drills, outline, top mask), then once more after flipping for the back-side programs — everything stays registered. Zero Z on the board surface. Choose the flip direction with **Mirror around Y axis** and verify with Flip Back View. The app generates no probing G-code — use your sender's autolevel (e.g. UGS AutoLeveler) for isolation passes.

## Troubleshooting

- **pcb2gcode not found** → `brew install pcb2gcode` (and `gerbv` for laser SVGs).
- **Preview failed** → the Log tab has the full output with per-step timings; the error is at the bottom.
- **Uncut gaps between close traces** → tool too wide to fit; pcb2gcode warns in the Log. Reduce effective tool diameter or increase design clearance.
- **Mask opening not cleared** → opening smaller than the mask tool, or Clear width < half the opening.
- **Slow generation** → mask Clear width too large, or very wide isolation width.
