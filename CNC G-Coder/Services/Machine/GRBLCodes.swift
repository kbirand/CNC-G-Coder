import Foundation

// Human-readable text for the numeric `error:n` and `ALARM:n` lines. The
// tables merge Grbl 1.1's doc/csv files with FluidNC's Error.h / Alarm.h:
// the numbers agree where both define them (1–38, alarms 1–9), FluidNC adds
// codes 18, 19, 39, 40 and everything ≥ 60. Where the two firmwares give a
// code different meanings (alarm 10) both readings are shown.

/// `error:n` descriptions.
nonisolated enum GRBLError {
    static func description(for code: Int) -> String {
        switch code {
        // Grbl 1.1 + FluidNC common table
        case 1: "Expected command letter: a G-code word has a letter and a value; the letter was not found."
        case 2: "Bad number format: missing value or invalid numeric format."
        case 3: "Unrecognised or unsupported $ system command."
        case 4: "Negative value received where a positive value is expected."
        case 5: "Setting disabled (Grbl: homing is not enabled in the settings)."
        case 6: "Step pulse time must be greater than 3 µs."
        case 7: "Settings read failed; defaults restored."
        case 8: "Command only valid when Idle."
        case 9: "Locked out: G-code is not accepted in alarm or jog state. Unlock or home first."
        case 10: "Soft limits cannot be enabled without homing."
        case 11: "Line too long: maximum characters per line exceeded; the line was not executed."
        case 12: "Setting would make the step rate exceed the supported maximum."
        case 13: "Safety door detected open; door state initiated."
        case 14: "Build info or startup line exceeds the storage line length; not stored."
        case 15: "Jog target exceeds machine travel; the jog was ignored."
        case 16: "Invalid jog command: no '=' or prohibited G-code in a $J= line."
        case 17: "Laser mode requires a PWM output."
        case 18: "No homing cycles are defined in the configuration (FluidNC)."
        case 19: "Single-axis homing is not allowed (FluidNC)."
        case 20: "Unsupported or invalid G-code command in the block."
        case 21: "More than one G-code command from the same modal group in the block."
        case 22: "Feed rate has not been set or is undefined."
        case 23: "G-code command requires an integer value."
        case 24: "More than one G-code command that requires axis words in the block."
        case 25: "Repeated G-code word in the block."
        case 26: "No axis words in the block for a command or modal state that requires them."
        case 27: "Line number value is invalid."
        case 28: "G-code command is missing a required value word."
        case 29: "G59.x work coordinate systems are not supported."
        case 30: "G53 is only allowed with G0 and G1 motion modes."
        case 31: "Axis words in the block, but no command or modal state uses them."
        case 32: "G2/G3 arcs require at least one in-plane axis word."
        case 33: "Motion command target is invalid."
        case 34: "Arc radius value is invalid."
        case 35: "G2/G3 arcs require at least one in-plane offset word."
        case 36: "Unused value words in the block."
        case 37: "G43.1 dynamic tool length offset is not assigned to the configured tool length axis."
        case 38: "Tool number greater than the maximum supported value."
        // FluidNC
        case 39: "P parameter exceeds its maximum."
        case 40: "Check startup pins: a control or limit input is active at boot."
        case 60: "Failed to mount the filesystem / SD card."
        case 61: "File read failed."
        case 62: "Failed to open the directory."
        case 63: "Directory not found."
        case 64: "File is empty."
        case 65: "File not found."
        case 66: "Failed to open the file."
        case 67: "Filesystem / SD card is busy."
        case 68: "Failed to delete the directory."
        case 69: "Failed to delete the file."
        case 70: "Failed to rename the file."
        case 80: "Setting value is out of range."
        case 81: "Invalid value for the setting."
        case 82: "Failed to create the file."
        case 83: "Failed to format the filesystem."
        case 90: "Failed to send the message."
        case 100: "Failed to store the setting (NVS)."
        case 101: "Failed to read the setting status (NVS)."
        case 110: "Authentication failed."
        case 111: "End of line."
        case 112: "End of file."
        case 113: "System reset."
        case 114: "No data."
        case 115: "Deferred: the command was queued and will be acknowledged later."
        case 120: "Another interface is busy (a job is running from another channel)."
        case 130: "Jog cancelled."
        case 150: "Bad pin specification in the configuration."
        case 151: "Bad runtime config setting."
        case 152: "Configuration is invalid; check the boot messages for ERR lines."
        case 160: "File upload failed."
        case 161: "File download failed."
        case 162: "Read-only setting."
        case 170: "Expression: divide by zero."
        case 171: "Expression: invalid argument."
        case 172: "Expression: invalid result."
        case 173: "Expression: unknown operator."
        case 174: "Expression: argument out of range."
        case 175: "Expression: syntax error."
        case 176: "Flow control: syntax error."
        case 177: "Flow control: not executing a macro."
        case 178: "Flow control: out of memory."
        case 179: "Flow control: stack overflow."
        case 180: "Parameter assignment failed."
        case 181: "Invalid G-code word value."
        default: "Error \(code)."
        }
    }
}

/// `ALARM:n` descriptions and what each alarm means for the machine position.
nonisolated enum GRBLAlarm {
    static func description(for code: Int) -> String {
        switch code {
        case 1: "Hard limit triggered. Machine position is probably lost from the sudden halt; re-homing is strongly recommended."
        case 2: "Soft limit: the motion target exceeds machine travel. Position retained; the alarm can be unlocked safely."
        case 3: "Reset while in motion. Machine position is probably lost; re-homing is strongly recommended."
        case 4: "Probe fail: the probe is not in the expected initial state before the probe cycle."
        case 5: "Probe fail: the probe did not contact the workpiece within the programmed travel."
        case 6: "Homing fail: the homing cycle was reset."
        case 7: "Homing fail: the safety door opened during homing."
        case 8: "Homing fail: pull-off travel failed to clear the limit switch. Increase pull-off or check wiring."
        case 9: "Homing fail: no limit switch found within the search distance. Increase max travel, decrease pull-off, or check wiring."
        case 10: "Spindle control failure (FluidNC); on Grbl: the second dual-axis limit switch did not trigger within the search distance."
        case 11: "A control or limit input pin was active at startup (FluidNC)."
        case 12: "Homing: ambiguous switch, more than one limit switch is active (FluidNC)."
        case 13: "Hard stop (FluidNC). The machine was halted; reset required."
        case 14: "Unhomed: the machine must be homed before motion (FluidNC)."
        case 15: "Initialisation alarm (FluidNC)."
        case 16: "I/O expander reset (FluidNC)."
        case 17: "G-code error during a job (FluidNC)."
        case 18: "Hard limit hit while probing (FluidNC)."
        default: "Alarm \(code)."
        }
    }

    /// Alarms after which the reported machine position can no longer be trusted:
    /// sudden halts (1, 3), soft-limit stops, homing failures and FluidNC's
    /// explicit "unhomed". The controller clears `positionTrusted` on these and
    /// recommends homing instead of unlocking.
    static func losesPosition(_ code: Int) -> Bool {
        switch code {
        case 1, 2, 3, 6, 7, 8, 9, 14: true
        default: false
        }
    }

    /// Alarms that `$X` cannot clear: the firmware demands a soft reset (0x18).
    static func isCritical(_ code: Int) -> Bool {
        switch code {
        case 1, 2, 3, 13: true
        default: false
        }
    }
}
