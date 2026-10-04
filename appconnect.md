APP STORE CONNECT — CNC G-CODER

Everything to enter for the Mac App Store listing, in the order App Store Connect asks for it. Text to paste sits between the ----- lines. Fill in the items marked TODO.

Build to upload: scheme "CNC G-Coder (App Store)", then Product > Archive > Distribute App > App Store Connect (native engine only, no pcb2gcode).


1. NEW APP (My Apps > +)

Platform: macOS
Name (max 30): CNC G-Coder
Primary language: English (U.S.)
Bundle ID: com.koraybirand.CNC-G-Coder
SKU: cnc-gcoder-mac-001 (any unique text, never shown)
User access: Full access


2. APP INFORMATION

Subtitle (max 30):
-----
PCB milling for desktop CNC
-----

Primary category: Developer Tools
Secondary category: Utilities
Content rights: Does not contain, show or access third-party content
Age rating: answer None / No to every question, result 4+
Copyright: 2026 Koray Birand (also fill "Copyright (human-readable)" in Xcode > target > Info, it is empty now)

Category note: Graphics & Design or Productivity also fit. Developer Tools puts it next to other maker and engineering tools.


3. PRICING AND AVAILABILITY

Price: TODO (Free, or a price tier)
Availability: all countries, or TODO
Requires: macOS 26.5, Apple silicon


4. VERSION PAGE (1.0)

Promotional text (max 170, can be changed any time without review):
-----
From Gerber files to ready-to-run G-code: isolation, drilling, cutout and solder-mask programs, with a live toolpath simulator that shows every move before you cut.
-----

Description (max 4000):
-----
CNC G-Coder turns your PCB design into G-code for a desktop CNC mill — and lets you watch every program run before a single bit touches copper.

Open the Gerber and drill files exported from your PCB editor and the layers are detected automatically. Set your tools, depths and feeds, and the preview updates as you type.

COMPLETE PCB WORKFLOW
• Isolation milling for front and back copper, with the back side mirrored for the flip
• Drilling, one program per drill file, with tool-change pauses — or only the bits you own, each covering a range of hole sizes
• Mill large holes in circles with an end mill when no drill is big enough
• Hole tolerance, so pins and screws still fit after drilling
• Board cutout with holding bridges and multiple depth passes
• Solder-mask and silkscreen programs, or 1:1 artwork for laser ablation
• One Generate writes every program into the folder you choose

SEE IT BEFORE YOU CUT
• A 2D toolpath view with the real cutter width, drill hits and bridge tabs
• A 3D view of the board and tool
• Playback at real machining speed (or faster), with the current G-code line highlighted
• A side view to check every depth: surface, cut, drill, bridge and safe heights
• Machining-time estimates per program and for the whole board
• Plunge optimisation: rapids through the air, feed only near the board — often half the time

DRAW AND EDIT
• Custom layers: draw lines, rectangles, circles, holes and text, and machine them as milling, engraving, silkscreen or drill programs
• Edit imported layers: change track widths, pad and hole sizes, move, delete or add holes
• Guides through the centre of any selection, and mirroring across them — find the middle of the board and make symmetric mounting holes in seconds
• Undo for everything

BUILT FOR THE WORKSHOP
• A tool library for your bits, with V-bit width worked out at cut depth
• A calibration test board that sweeps depth and feed so you can read the best settings straight off a milled board
• Projects that keep their Gerber files inside, so nothing goes missing
• Shared origin per side: zero once for the front, once after flipping
• Metric or inch display; the programs stay metric
• Programs for GRBL, LinuxCNC and similar controllers (.ngc)

Toolpaths are computed on your Mac. No account, no internet connection, no subscription.
-----

Keywords (max 100, comma separated; exactly 100 characters, don't repeat the app name or category):
-----
pcb,cnc,gcode,gerber,isolation,milling,drill,excellon,engrave,router,grbl,cam,circuit,board,toolpath
-----

What's New (version 1.0):
-----
First release.
-----

Support URL (required): TODO, e.g. the GitHub repository's Issues page, or a page with a contact e-mail
Marketing URL (optional): TODO
Privacy Policy URL (required): TODO, host the text in section 6 (e.g. a GitHub Pages page or a PRIVACY file in the repository)

Screenshots: 16:10, one of 1280 x 800, 1440 x 900, 2560 x 1600 or 2880 x 1800 pixels, 1 to 10 of them. Suggested set, using a real board:
1. 2D toolpath of the front copper with the sidebar showing isolation settings
2. Playback mid-program, with the G-code tab and the side view visible
3. 3D view of the finished board
4. Drill program with milled large holes and the "Bits on hand" list
5. A custom layer being drawn: guides, the Hole tool and a mirrored copy
6. The Generate sheet listing the programs written
7. The calibration test board

Tip: set the window to exactly 1440 x 900 points on a Retina display, then press Shift-Command-4, then Space, and click the window to capture it at 2880 x 1800.


5. APP PRIVACY (data collection)

Answer: No, we do not collect data from this app. Result: Data Not Collected.

That is accurate: the app makes no network connections, has no analytics, crash-reporting SDKs or accounts, and only touches files the user opens or saves.


6. PRIVACY POLICY TEXT (to host at the Privacy Policy URL)

-----
CNC G-Coder — Privacy Policy

CNC G-Coder does not collect, store or share any personal data.

The app works entirely on your Mac. It reads only the files you choose to open (Gerber, drill and project files) and writes only where you choose to save. It makes no network connections, contains no analytics or advertising, and requires no account.

Settings and your tool library are stored locally on your Mac and are removed when you delete the app.

Questions: TODO (contact e-mail)

Last updated: TODO (date)
-----


7. APP REVIEW INFORMATION

Sign-in required: No
Contact: TODO (first name, last name, phone, e-mail)
Attachment: a zipped sample project (.cncproj), see below

Notes for the reviewer:
-----
CNC G-Coder creates G-code programs for milling printed circuit boards on a desktop CNC machine. It needs no account and no network.

Quick ways to try it without your own files:
1. File > Generate Test Board… > Generate: a calibration board appears in the preview. Press Play to watch the toolpath run.
2. File > New Custom Layer, then draw with the Rectangle, Circle, Hole or Text tool in the bar above the preview. The toolpaths regenerate as you draw.
3. The attached sample project (Open > Open Project…) contains a real two-layer board: select layers in the sidebar's layer menu, play them back, and press Generate to write the programs into a folder of your choice.

The app is sandboxed and only reads and writes files and folders the user picks in Open and Save panels; security-scoped bookmarks let it reopen recent projects and the chosen output folder after a relaunch.
-----

Sample project to attach: save the cam board as a project, compress it (right-click > Compress), and attach the .zip in App Review Information. Make sure it opens in the App Store build first.


8. BUILD AND COMPLIANCE

Export compliance (encryption): No, the app uses no encryption. Add ITSAppUsesNonExemptEncryption = NO to the Info.plist (or Xcode > target > Info) so App Store Connect doesn't ask on every upload.
Sandbox entitlements: App Sandbox, User Selected File (read/write), App-scope bookmarks. No others.
Third-party code: Clipper2 (Boost Software License), included in the app. pcb2gcode is not in the App Store build.
Version / build: MARKETING_VERSION 1.0, CURRENT_PROJECT_VERSION 1; raise the build number for every upload.


9. BEFORE SUBMITTING: CHECKLIST

[ ] Archive with the "CNC G-Coder (App Store)" scheme
[ ] Run the App Store build once: open a project, preview, Generate into a chosen folder, quit, reopen from Open Recent
[ ] Copyright filled in Xcode
[ ] ITSAppUsesNonExemptEncryption = NO added
[ ] Support and Privacy Policy URLs live
[ ] Screenshots uploaded
[ ] Price and availability set
[ ] Sample project attached for review
