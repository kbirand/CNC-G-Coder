APP STORE CONNECT — CNC G-CODER 2.0

Everything to enter for the Mac App Store listing, in the order App Store Connect asks for it. Text to paste sits between the ----- lines. Fill in the items marked TODO.

Build to upload: scheme "CNC G-Coder (App Store)", then Product > Archive > Distribute App > App Store Connect (native engine only, no pcb2gcode). The app icon is MyIconV2 (ASSETCATALOG_COMPILER_APPICON_NAME) — the 1024 px icon App Store Connect shows comes from that .icon file, nothing to upload separately.


1. NEW APP (My Apps > +) — already created for 1.0; skip for 2.0

Platform: macOS
Name (max 30): CNC G-Coder
Primary language: English (U.S.)
Bundle ID: com.koraybirand.CNC-G-Coder
SKU: cnc-gcoder-mac-001 (any unique text, never shown)
User access: Full access


2. APP INFORMATION (unchanged unless noted)

Subtitle (max 30):
-----
PCB milling for desktop CNC
-----

Primary category: Developer Tools (the bundle's LSApplicationCategoryType now says the same)
Secondary category: Utilities
Content rights: Does not contain, show or access third-party content
Age rating: answer None / No to every question, result 4+
Copyright: © 2026 Koray Birand (filled in the target's Info settings too)

Category note: Graphics & Design or Productivity also fit. Developer Tools puts it next to other maker and engineering tools.

Localizations: the app and its guide are in English, French, Spanish and Turkish. App Store Connect lets you add a localized listing per language; the English text below is the source, translate it if you want the store page in those languages too (optional, the app itself is localized regardless).


3. PRICING AND AVAILABILITY

Price: TODO (Free, or a price tier)
Availability: all countries, or TODO
Requires: macOS 26.5, Apple silicon


4. VERSION PAGE (2.0)

Promotional text (max 170, can be changed any time without review):
-----
Gerber in, ready-to-run programs out — for GRBL, FluidNC and the Makera Carvera's tool changer. Simulate every move, then send it to the machine from the app, Carvera included.
-----

Description (max 4000):
-----
CNC G-Coder turns your PCB design into G-code for a desktop CNC mill — and lets you watch every program run before a single bit touches copper. Then it drives the machine.

Open the Gerber and drill files exported from your PCB editor and the layers are detected automatically. Set your tools, depths and feeds, and the preview updates as you type.

COMPLETE PCB WORKFLOW
• Isolation milling for front and back copper, with the back side mirrored for the flip
• Drilling, one program per drill file — or only the bits you own, each covering a range of hole sizes
• Mill large holes in circles with an end mill when no drill is big enough
• Board cutout with holding bridges and multiple depth passes
• Solder-mask and silkscreen programs, or 1:1 artwork for laser ablation
• One Generate writes every program into the folder you choose

MADE FOR THE MAKERA CARVERA
• Pick the Carvera, Carvera Air or Z1 as your machine and Generate writes one .cnc file per machine session — front isolation, then mask etch, drilling and cutout after the mask is cured, the same two for the back
• Tool changes become T<n> M6 for the automatic tool changer, with the rack list at the top of every file and a Rack table in the app to renumber the slots
• Makera's own bits are built in: every Carvera drill, corn bit, engraving bit and mask-removal tool with Makera's cutting data for fifteen materials, and one click re-imports Makera Studio's library

SEE IT BEFORE YOU CUT
• A 2D toolpath view with the real cutter width, drill hits and bridge tabs
• A 3D view of the board and tool
• Playback at real machining speed (or faster), with the current G-code line highlighted
• A side view to check every depth: surface, cut, drill, bridge and safe heights
• Machining-time estimates per program and for the whole board
• Plunge optimisation: rapids through the air, feed only near the board — often half the time

RUN THE MACHINE
• A built-in sender for GRBL and FluidNC controllers over Wi‑Fi or USB: jog, zero, probe Z, stream a program and follow it live in the preview
• Tool changes suspend the job so you can swap the bit and re-probe, then continue where it stopped
• Probe a height map over the board and warp the program to the real surface
• Backlash compensation written into every program
• A built-in simulator to learn the panel without a machine

TOOLS AND MATERIALS
• A tool library with search, groups and a material setting: pick the stock and each bit's feeds, plunge, spindle and depth per pass follow, the way Makera's library fills them in
• Add your own materials and bits, import Fusion 360 and FlatCAM libraries
• V-bit cutting width worked out at depth

DRAW AND EDIT
• Custom layers: draw lines, rectangles, circles, holes and text, and machine them as milling, engraving, silkscreen or drill programs
• Edit imported layers: change track widths, pad and hole sizes, move, delete or add holes
• Guides and mirroring for symmetric mounting holes
• Undo for everything

BUILT FOR THE WORKSHOP
• A calibration test board that sweeps depth and feed so you can read the best settings straight off a milled board
• Projects that keep their Gerber files inside, so nothing goes missing
• Shared origin per side: zero once for the front, once after flipping
• Metric or inch display; the programs stay metric
• English, French, Spanish and Turkish, guide included

Toolpaths are computed on your Mac. The only network connection is the one you open to your own CNC controller. No account, no subscription.
-----

Keywords (max 100 characters, comma separated, no spaces; exactly 100 here; don't repeat the app name or category):
-----
pcb,cnc,gcode,gerber,isolation,milling,drill,carvera,makera,grbl,fluidnc,cam,circuit,toolpath,router
-----

What's New (version 2.0):
-----
Makera Carvera support: choose the Carvera, Carvera Air or Z1 under Machine setup and Generate writes one .cnc file per machine session, with T<n> M6 tool changes for the tool changer and the rack list in every file.

Makera's bits built in: 121 Carvera bits with Makera's cutting data for fifteen materials, in Makera Studio's groups. Pick the material of the job and the feeds follow. Import Makera Studio's library, Fusion 360 libraries (.tools, .csv) or FlatCAM databases.

Tool Library: search, group filter, material presets per bit, Add Material, multi-select deletion.

Machine panel: send programs to GRBL and FluidNC controllers — and to the Carvera itself, over Wi‑Fi or USB, with the tool changer doing the changes mid-program — probe Z, height maps, backlash compensation, a built-in simulator.

New app icon. French, Spanish and Turkish.
-----

Support URL (required): TODO, e.g. the GitHub repository's Issues page, or a page with a contact e-mail
Marketing URL (optional): TODO
Privacy Policy URL (required): TODO, host the text in section 6 (e.g. a GitHub Pages page or a PRIVACY file in the repository)

Screenshots: 16:10, one of 1280 x 800, 1440 x 900, 2560 x 1600 or 2880 x 1800 pixels, 1 to 10 of them. Suggested set, using a real board:
1. 2D toolpath of the front copper with the sidebar showing isolation settings
2. Machine setup with the Makera Carvera profile: the Rack table and the stage list
3. Playback mid-program, with the G-code tab and the side view visible
4. 3D view of the finished board
5. The Tool Library: Makera groups, the material pull-down and a bit's material presets
6. The Machine panel streaming a program, the preview following the job
7. Drill program with milled large holes and the "Bits on hand" list
8. A custom layer being drawn: guides, the Hole tool and a mirrored copy
9. The Generate sheet listing the Carvera stage files
10. The calibration test board

Tip: set the window to exactly 1440 x 900 points on a Retina display, then press Shift-Command-4, then Space, and click the window to capture it at 2880 x 1800. The docs/shoot.sh script renders most of these offscreen.


5. APP PRIVACY (data collection)

Answer: No, we do not collect data from this app. Result: Data Not Collected.

That is accurate: the app has no analytics, crash-reporting SDKs or accounts, and only touches files the user opens or saves. The only network traffic is the connection the user opens to their own CNC controller on the local network (the local-network usage description in the bundle says so).


6. PRIVACY POLICY TEXT (to host at the Privacy Policy URL)

-----
CNC G-Coder — Privacy Policy

CNC G-Coder does not collect, store or share any personal data.

The app works entirely on your Mac. It reads only the files you choose to open (Gerber, drill, tool-library and project files) and writes only where you choose to save. Its only network connection is the one you open to your own CNC controller on your local network; nothing is sent anywhere else. It contains no analytics or advertising and requires no account.

Settings, your tool library, saved machine positions and height maps are stored locally on your Mac and are removed when you delete the app.

Questions: TODO (contact e-mail)

Last updated: TODO (date)
-----


7. APP REVIEW INFORMATION

Sign-in required: No
Contact: TODO (first name, last name, phone, e-mail)
Attachment: a zipped sample project (.cncproj), see below

Notes for the reviewer:
-----
CNC G-Coder creates G-code programs for milling printed circuit boards on a desktop CNC machine and can send them to the machine. It needs no account. The only network use is a connection the user opens to a CNC controller on the local network (hence the local-network, serial and USB entitlements); nothing is required to review the app.

Quick ways to try it without your own files or a machine:
1. File > Generate Test Board… > Generate: a calibration board appears in the preview. Press Play to watch the toolpath run.
2. File > New Custom Layer, then draw with the Rectangle, Circle, Hole or Text tool in the bar above the preview. The toolpaths regenerate as you draw.
3. The attached sample project (File > Open Project…) contains a real two-layer board: select layers in the sidebar's layer menu, play them back, and press Generate to write the programs into a folder of your choice. Switch Machine setup > Machine to "Makera Carvera" to see the tool rack and the stage files.
4. File > Tool Library… shows the built-in Makera bits; the Material pull-down changes the feeds each bit offers.
5. The Machine panel (toolbar > Machine) connects to real controllers; Settings > Machine > "Show the Simulator" adds a built-in simulator to the connection picker (it needs python3 on the Mac).

The app is sandboxed and only reads and writes files and folders the user picks in Open and Save panels; security-scoped bookmarks let it reopen recent projects and the chosen output folder after a relaunch.
-----

Sample project to attach: save the cam board as a project, compress it (right-click > Compress), and attach the .zip in App Review Information. Make sure it opens in the App Store build first.


8. BUILD AND COMPLIANCE

Export compliance (encryption): No, the app uses no encryption of its own; ITSAppUsesNonExemptEncryption = NO is in Info.plist, so App Store Connect does not ask on upload.
Sandbox entitlements (CNC G-Coder.entitlements): App Sandbox; User Selected File (read/write); App-scope bookmarks; Outgoing network connections (client) and Incoming (server) — the controller link over Wi‑Fi and the local simulator; Serial devices and USB — the controller link over USB. If App Review asks about network server: the app listens only on localhost for its own simulator process.
Usage descriptions: NSLocalNetworkUsageDescription is set (controller over the local network).
Third-party code: Clipper2 (Boost Software License), included in the app. The bundled Makera tool data (MakeraTools.json) is Makera's published cutting data for Makera's own bits, credited in the guide. pcb2gcode is not in the App Store build.
Version / build: MARKETING_VERSION 2.0, CURRENT_PROJECT_VERSION 2; raise the build number for every upload of the same version.
Minimum system: macOS 26.5, Apple silicon only (the project builds arm64).


9. BEFORE SUBMITTING: CHECKLIST

[ ] Archive with the "CNC G-Coder (App Store)" scheme
[ ] Run the App Store build once: open a project, preview, Generate into a chosen folder (GRBL and Carvera profiles), quit, reopen from Open Recent
[ ] Open the Tool Library in the App Store build: the Makera bits are there, Makera Studio… import works (it falls back to a file picker in the sandbox)
[ ] Support and Privacy Policy URLs live
[ ] Screenshots uploaded (new ones for the Carvera rack, the Tool Library and the Machine panel)
[ ] What's New pasted
[ ] Price and availability set
[ ] Sample project attached for review
