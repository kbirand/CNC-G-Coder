#!/bin/zsh
# Renders the documentation screenshots offscreen through the app's launch
# hooks (no screen capture). One app launch per shot; the app window appears
# briefly on screen while it renders. Output: docs/images/*.png (copied out
# of the app container, where the sandboxed app must write them).
#
#   docs/shoot.sh            all shots
#   docs/shoot.sh playback   only the shots whose name contains "playback"
set -u
APP=${APP:-$(ls -d ~/Library/Developer/Xcode/DerivedData/CNC_G-Coder-*/Build/Products/Debug/"CNC G-Coder.app" | head -1)}
BIN="$APP/Contents/MacOS/CNC G-Coder"
C="$HOME/Library/Containers/com.koraybirand.CNC-G-Coder/Data"
CAM="$C/Documents/sample/Cam"
KICAD="$C/Documents/sample/KiCad_ProMini_gbr"
TMP="$C/tmp/docshots"; mkdir -p "$TMP"
OUT="$(cd "$(dirname "$0")" && pwd)/images"; mkdir -p "$OUT"
FILTER=${1:-}
SIZE=${SIZE:-1440x900}

shot() {   # shot <name> [extra launch args...]
  local name=$1; shift
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return
  local png="$TMP/$name.png"; rm -f "$png" "$TMP/$name.settings.png"
  echo "— $name"
  "$BIN" -ApplePersistenceIgnoreState YES -debugWindowSize "$SIZE" -ui.sidebarVisible 1 -ui.machineInspector 0 \
    -debugWindowSnapshot "$png" -debugWindowSnapshotExit 1 "$@" 2>&1 \
    | grep -E "^\[debug\] (window|settings|3D) snapshot" || true
  # Shots of the Settings window write <name>.settings.png through the
  # Settings snapshot hook; that one is the deliverable then.
  [[ -f "$TMP/$name.settings.png" ]] && png="$TMP/$name.settings.png"
  [[ -f "$png" ]] && cp "$png" "$OUT/$name.png" || echo "   MISSING $name"
}

P=(-debugProjectFolder "$CAM")

# Getting started
shot workflow-overview            "${P[@]}"
shot project-folder-detection     -debugProjectFolder "$KICAD" -debugTab log -debugWindowSnapshotAfter 6
shot tools-v-bits                 "${P[@]}" -debugTestDialog 1 -testboard.kind parameters
# Projects & layers
shot projects-import              "${P[@]}" -debugImport "$CAM/Gerber_TopLayer.GTL,$CAM/Drill_PTH_Through.DRL"
shot exporting-one-program        "${P[@]}" -debugLayer outline
shot custom-layers                "${P[@]}" -debugCustomDemo 1 -debugSelectShape 1 -debugWindowSnapshotAfter 10
shot editing-imported-layers      "${P[@]}" -debugEditLayer front -debugEditSelect tracks -debugWindowSnapshotAfter 10
shot tool-library                 "${P[@]}" -debugOpenWindow tools -debugWindowSnapshotTitle "Tool Library" -debugSelectTool "VBIT-30deg-0.1-Izolasyon"
shot toolpath-engines             "${P[@]}" -ui.sectionOverride setup
# Parameters
shot parameters-isolation         "${P[@]}" -ui.sectionOverride isolation
shot parameters-drilling          "${P[@]}" -debugLayer "PTH_Through"
shot parameters-cutout            "${P[@]}" -debugLayer outline -ui.sectionOverride cutout
shot parameters-mask              "${P[@]}" -debugLayer mask
# Preview
shot preview-2d                   "${P[@]}" -debugScrub 0.45
shot preview-3d                   "${P[@]}" -preview3D 1 -debugLayer "Front copper" -debugScrub 0.5 -debugWindowSnapshotAfter 12
shot playback                     "${P[@]}" -debugScrub 0.6 -debugPlay 1 -debugWindowSnapshotAfter 10
shot measuring                    "${P[@]}" -debugMeasure 2,2,22,14
# Settings
shot presets-settings             "${P[@]}" -debugOpenSettings 1 -debugSettingsTab general -debugWindowSnapshotTitle "General"
# Machine (the panel needs a wider window)
SIZE=1680x1000
shot machine-zeroing              "${P[@]}" -ui.sectionOverride setup
shot machine-panel-control        "${P[@]}" -debugMachineWindow 1 -debugMachineConnect sim -machine.inspectorTab control -debugWindowSnapshotAfter 10
shot machine-panel-positions      "${P[@]}" -debugMachineWindow 1 -debugMachineConnect sim -machine.inspectorTab positions -debugWindowSnapshotAfter 10
shot machine-panel-program        "${P[@]}" -debugMachineWindow 1 -debugMachineConnect sim -machine.inspectorTab program -debugMachineSend front -debugWindowSnapshotAfter 16
shot machine-panel-probe          "${P[@]}" -debugMachineWindow 1 -debugMachineConnect sim -machine.inspectorTab probe -debugWindowSnapshotAfter 10
shot machine-panel-heightmap      "${P[@]}" -debugMachineWindow 1 -debugMachineConnect sim -machine.inspectorTab heightMap -debugMachineProbeMap 3x3 -debugWindowSnapshotAfter 18
shot machine-panel-macros         "${P[@]}" -debugMachineWindow 1 -debugMachineConnect sim -machine.inspectorTab macros -debugWindowSnapshotAfter 10
shot machine-axis-calibration     "${P[@]}" -debugMachineConnect sim -debugOpenSettings 1 -debugSettingsTab machine -debugSettingsSnapshot "$TMP/scroll-trigger.png" -debugSettingsScroll bottom -debugWindowSnapshotTitle "Machine" -debugWindowSnapshotAfter 10
# New chapters
SIZE=1440x900
shot generate-dialog              "${P[@]}" -debugGenerateDialog 1 -generate.target laser
shot laser-export                 "${P[@]}" -debugLayer outline -debugWindowSnapshotSidebarScroll bottom
shot test-board-backlash          "${P[@]}" -debugTestDialog 1 -testboard.kind backlash
shot test-board-holes             "${P[@]}" -debugTestDialog 1 -testboard.kind holes
shot backlash-compensation        "${P[@]}" -ui.sectionOverride setup -debugWindowSnapshotSidebarScroll bottom
shot parameters-silkscreen        "${P[@]}" -debugLayer silkscreen
shot gcode-tab                    "${P[@]}" -debugTab gcode -debugScrub 0.3
shot console-tab                  "${P[@]}" -debugTab console -debugMachineWindow 1 -debugMachineConnect sim -debugWindowSnapshotAfter 10
shot machine-settings             "${P[@]}" -debugOpenSettings 1 -debugSettingsTab machine -debugWindowSnapshotTitle "Machine"
# Help
shot troubleshooting              "${P[@]}" -debugTab log
echo "done → $OUT"
