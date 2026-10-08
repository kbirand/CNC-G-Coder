import SwiftUI
import Combine
import AppKit

/// X/Y cross with diagonals and a Z column, Stop in the middle, step and
/// feed presets, and keyboard jogging. A click steps by the selected
/// increment; holding a button for 250 ms (or any press in Continuous mode)
/// jogs until release. The keyboard works the same way on a focusable
/// container: arrows for X/Y, Page Up/Down for Z, ⇧ multiplies the step by
/// ten, Esc stops. Every path that can leave a jog running — key-up lost to
/// another window, an alarm, the view disappearing — stops it.
struct JogPad: View {
    @Bindable var machine: MachineController

    @AppStorage(MachineSettings.Keys.jogStep) private var step = MachineSettings.Defaults.jogStep
    @AppStorage(MachineSettings.Keys.jogFeed) private var feed = MachineSettings.Defaults.jogFeed

    @State private var keyboardJog = false
    @FocusState private var padFocused: Bool
    @State private var keyboard = KeyboardJogTracker()

    private let buttonSize: CGFloat = 44
    private let spacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionLabel(title: "Jog", detail: detail)
            pad
            stepPicker
            feedPicker
            keyboardToggle
        }
        .machinePanel()
        .onChange(of: keyboardJog) { _, on in
            if on { padFocused = true } else { stopKeyboardJog() }
        }
        .onChange(of: padFocused) { _, focused in
            if !focused { stopKeyboardJog() }
        }
        .onChange(of: machine.alarmCode) { _, code in
            if code != nil { stopKeyboardJog() }
        }
        .onChange(of: machine.isConnected) { _, connected in
            if !connected { stopKeyboardJog() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            stopKeyboardJog()
        }
        .onDisappear { stopKeyboardJog() }
    }

    private var detail: String {
        let stepText = step <= 0 ? "continuous" : "\(formatMM(step)) mm"
        return "\(stepText) · F\(Int(feed))"
    }

    // MARK: Pad

    private var pad: some View {
        HStack(alignment: .center, spacing: 18) {
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                GridRow {
                    jogButton([.x: .negative, .y: .positive], "arrow.up.left")
                    jogButton([.y: .positive], "arrow.up")
                    jogButton([.x: .positive, .y: .positive], "arrow.up.right")
                }
                GridRow {
                    jogButton([.x: .negative], "arrow.left")
                    stopButton
                    jogButton([.x: .positive], "arrow.right")
                }
                GridRow {
                    jogButton([.x: .negative, .y: .negative], "arrow.down.left")
                    jogButton([.y: .negative], "arrow.down")
                    jogButton([.x: .positive, .y: .negative], "arrow.down.right")
                }
            }
            VStack(spacing: spacing) {
                jogButton([.z: .positive], "arrow.up.to.line")
                Text("Z")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(axisTint(.z))
                    .frame(width: buttonSize, height: buttonSize)
                jogButton([.z: .negative], "arrow.down.to.line")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .focusable(keyboardJog)
        .focused($padFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .up, .repeat]) { press in handleKey(press) }
        .overlay {
            if keyboardJog, padFocused {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if keyboardJog { padFocused = true } }
    }

    private func jogButton(_ directions: [Axis: JogDirection], _ symbol: String) -> some View {
        JogButton(machine: machine, directions: directions, symbol: symbol, size: buttonSize, step: step, feed: feed)
    }

    private var stopButton: some View {
        Button {
            stopKeyboardJog()
            Task { await machine.stop() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: buttonSize, height: buttonSize)
                .background(Color.red.gradient, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!machine.isConnected)
        .opacity(machine.isConnected ? 1 : 0.4)
        .help("Stop all motion (⌘.)")
    }

    // MARK: Pickers

    private var stepPicker: some View {
        HStack(spacing: 8) {
            Text("Step").frame(width: 36, alignment: .leading)
            Picker("", selection: $step) {
                ForEach(MachineSettings.jogStepPresets, id: \.self) { value in
                    Text(formatMM(value)).tag(value)
                }
                Text("Cont.").tag(0.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Distance of one click on a jog button (mm). Cont.: the axis moves for as long as the button or key is held. Holding a button for a quarter second jogs continuously in any mode.")
        }
        .font(.callout)
        .controlSize(.small)
    }

    private var feedPicker: some View {
        HStack(spacing: 8) {
            Text("Feed").frame(width: 36, alignment: .leading)
            Picker("", selection: $feed) {
                ForEach(MachineSettings.jogFeedPresets, id: \.self) { value in
                    Text(formatMM(value, decimals: 0)).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Jog speed in mm/min (the $J= F word). Also the speed of Go to and saved positions. Use a low feed near the board or clamps.")
        }
        .font(.callout)
        .controlSize(.small)
    }

    private var keyboardToggle: some View {
        HStack {
            Toggle("Keyboard jog", isOn: $keyboardJog)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!machine.isConnected)
                .help("Jog from the keyboard while the pad has focus (it gets a blue outline): arrows move X and Y, Page Up/Down move Z, ⇧ multiplies the step by ten, holding a key jogs continuously, Esc stops. Switches off by itself when the window loses focus or an alarm comes in.")
            Text("← → X · ↑ ↓ Y · Page ↑ ↓ Z · ⇧ ×10 · hold = continuous · Esc stops")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard keyboardJog, padFocused else { return .ignored }
        if press.key == .escape {
            stopKeyboardJog()
            Task { await machine.stop() }
            return .handled
        }
        guard let directions = Self.directions(for: press.key) else { return .ignored }
        switch press.phase {
        case .down:
            guard keyboard.heldKey == nil, machine.canJog, machine.positionTrusted, !machine.jobLocksControls else { return .handled }
            keyboard.heldKey = press.key
            let multiplier: Double = press.modifiers.contains(.shift) ? 10 : 1
            keyboard.step = step * multiplier
            keyboard.directions = directions
            if step <= 0 {
                beginContinuous()
            } else {
                let key = press.key
                keyboard.holdTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, keyboard.heldKey == key else { return }
                    beginContinuous()
                }
            }
            return .handled
        case .up:
            guard keyboard.heldKey == press.key else { return .handled }
            endKeyboardPress()
            return .handled
        default:
            return .handled   // auto-repeat: the press is already being tracked
        }
    }

    private static func directions(for key: KeyEquivalent) -> [Axis: JogDirection]? {
        switch key {
        case .leftArrow: [.x: .negative]
        case .rightArrow: [.x: .positive]
        case .upArrow: [.y: .positive]
        case .downArrow: [.y: .negative]
        case .pageUp: [.z: .positive]
        case .pageDown: [.z: .negative]
        default: nil
        }
    }

    private func beginContinuous() {
        guard !keyboard.isContinuous else { return }
        keyboard.isContinuous = true
        machine.startContinuousJog(directions: keyboard.directions, feed: feed)
    }

    /// Key released: a hold becomes a stop, a short press becomes one step.
    private func endKeyboardPress() {
        keyboard.holdTask?.cancel()
        keyboard.holdTask = nil
        keyboard.heldKey = nil
        if keyboard.isContinuous {
            keyboard.isContinuous = false
            machine.stopContinuousJog()
        } else if keyboard.step > 0 {
            var vector: [Axis: Double] = [:]
            for (axis, direction) in keyboard.directions { vector[axis] = keyboard.step * direction.sign }
            let feed = self.feed
            Task { await machine.jog(vector: vector, feed: feed) }
        }
    }

    /// Unconditional stop, for every path that may have lost the key-up.
    private func stopKeyboardJog() {
        keyboard.holdTask?.cancel()
        keyboard.holdTask = nil
        keyboard.heldKey = nil
        if keyboard.isContinuous {
            keyboard.isContinuous = false
            machine.stopContinuousJog()
        }
    }
}

/// The key currently held for jogging and whether it has turned continuous.
private struct KeyboardJogTracker {
    var heldKey: KeyEquivalent?
    var directions: [Axis: JogDirection] = [:]
    var step: Double = 0
    var isContinuous = false
    var holdTask: Task<Void, Never>?
}

/// One jog direction (or a diagonal pair): click to step, hold to move
/// continuously until released. Press tracking uses the button style's
/// `isPressed`, which the system clears when the press is cancelled, so a
/// drag off the button ends the jog too.
struct JogButton: View {
    @Bindable var machine: MachineController
    var directions: [Axis: JogDirection]
    var symbol: String
    var size: CGFloat
    var step: Double
    var feed: Double

    @State private var isPressed = false
    @State private var isHolding = false
    @State private var holdTimer: Task<Void, Never>?

    private let holdThreshold: Duration = .milliseconds(250)

    private var enabled: Bool {
        machine.canJog && machine.positionTrusted && !machine.jobLocksControls
    }

    var body: some View {
        Button {
            // Tap vs. hold is decided when the press ends.
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(isPressed ? Color.white : tint)
                .frame(width: size, height: size)
                .background(isPressed ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.16)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressTrackingButtonStyle(isPressed: $isPressed))
        .scaleEffect(isHolding ? 1.08 : 1)
        .animation(.snappy(duration: 0.15), value: isHolding)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(helpText)
        .onChange(of: isPressed) { _, pressed in
            if pressed { pressBegan() } else { pressEnded() }
        }
        .onDisappear {
            holdTimer?.cancel()
            if isHolding { machine.stopContinuousJog() }
        }
    }

    private var tint: Color {
        if directions.count == 1, let axis = directions.keys.first { return axisTint(axis) }
        return .secondary
    }

    private var helpText: String {
        let axes = Axis.allCases.compactMap { axis in directions[axis].map { "\(axis.gcodeLetter)\($0 == .positive ? "+" : "−")" } }
        return axes.joined(separator: " ") + " — click to step, hold to jog continuously"
    }

    private func pressBegan() {
        holdTimer?.cancel()
        if step <= 0 {
            isHolding = true
            machine.startContinuousJog(directions: directions, feed: feed)
            return
        }
        holdTimer = Task {
            try? await Task.sleep(for: holdThreshold)
            guard !Task.isCancelled, isPressed else { return }
            isHolding = true
            machine.startContinuousJog(directions: directions, feed: feed)
        }
    }

    private func pressEnded() {
        holdTimer?.cancel()
        holdTimer = nil
        if isHolding {
            isHolding = false
            machine.stopContinuousJog()
        } else if step > 0 {
            let step = self.step
            let feed = self.feed
            let directions = self.directions
            Task {
                if directions.count == 1, let single = directions.first {
                    await machine.jog(axis: single.key, direction: single.value, distance: step, feed: feed)
                } else {
                    var vector: [Axis: Double] = [:]
                    for (axis, direction) in directions { vector[axis] = step * direction.sign }
                    await machine.jog(vector: vector, feed: feed)
                }
            }
        }
    }
}

/// Mirrors the button's pressed state into a binding (the system clears
/// `isPressed` when the press is cancelled, which a drag gesture would not report).
struct PressTrackingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed = pressed
            }
    }
}
