import Foundation

/// App-wide undo/redo. Everything goes on one UndoManager (`history`), which
/// Edit → Undo / Redo drive, so parameter edits, layer-file changes and
/// drawing edits share a single history, in the order they were made.
extension AppModel {

    var undoManager: UndoManager? { history }

    // MARK: - Parameters

    /// Called (one runloop turn late) after anything in ParametersStore
    /// changed — a typed field, a picker, a tool or preset being applied, the
    /// origin being dragged. Records the step from the last known values.
    ///
    /// Typing "0.25" changes a field four times; consecutive edits of the
    /// same single parameter within a short while are one undo step.
    func noteParameterChange() {
        let current = parameters.exportState()
        let previous = lastParameterValues
        guard current != previous else { return }
        lastParameterValues = current

        let changed = current.changedKeys(from: previous)
        let now = Date()
        if changed.count == 1, let key = changed.first, let last = lastParameterEdit,
           last.key == key, now.timeIntervalSince(last.date) < 1.5,
           undoManager?.canUndo == true, undoManager?.undoActionName == String(localized: String.LocalizationValue(Self.parameterActionName)) {
            lastParameterEdit = (key, now)
            return   // still the same edit: the step already on the stack covers it
        }
        lastParameterEdit = changed.count == 1 ? (changed[0], now) : nil
        undoManager?.registerUndo(withTarget: self) { model in model.restoreParameters(previous) }
        undoManager?.setActionName(changed.count == 1 ? String(localized: String.LocalizationValue(Self.parameterActionName)) : String(localized: "Change Parameters"))
    }

    private static let parameterActionName = "Change Parameter"

    /// Puts a whole set of parameter values back (undo / redo).
    func restoreParameters(_ state: ParameterState) {
        let current = parameters.exportState()
        undoManager?.registerUndo(withTarget: self) { model in model.restoreParameters(current) }
        resignTextFieldFocus()   // a focused field would keep showing what was typed
        lastParameterEdit = nil
        lastParameterValues = state   // so the change observer does not record this as a new edit
        parameters.restoreState(state)
    }

    // MARK: - Layer files

    /// Changes the project's input files as one undoable step.
    func setDetectedFiles(_ files: DetectedFiles, actionName: String) {
        let old = detectedFiles
        guard old != files else { return }
        detectedFiles = files
        undoManager?.registerUndo(withTarget: self) { model in
            model.setDetectedFiles(old, actionName: actionName)
        }
        undoManager?.setActionName(String(localized: String.LocalizationValue(actionName)))
        if undoManager?.isUndoing == true || undoManager?.isRedoing == true {
            if projectURL == nil { manualLayerEdits = true }
            if files.hasAnyToolpathInput || customLayers.hasShapes { preview.parametersDidChange() } else { preview.clear() }
        }
    }

    /// A different project: what was done to the previous one cannot be
    /// undone into this one.
    func clearUndoHistory() {
        undoManager?.removeAllActions()
        lastParameterValues = parameters.exportState()
        lastParameterEdit = nil
    }
}
