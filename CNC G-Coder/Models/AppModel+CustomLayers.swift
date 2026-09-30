import Foundation

/// Custom (hand-drawn) layers: adding, removing, duplicating and selecting
/// them. Edits inside a layer go through ShapeEditor, which owns the undo
/// registration; these list operations register their own.
extension AppModel {

    /// Adds an empty layer and shows it in the editor.
    @discardableResult
    func addCustomLayer(select: Bool = true) -> CustomLayer {
        var n = customLayers.count + 1
        var name = "Custom \(n)"
        while customLayers.contains(where: { $0.name == name }) {
            n += 1
            name = "Custom \(n)"
        }
        var layer = CustomLayer(name: name)
        // A new layer goes on the side being looked at.
        if let selected = player.selectedLayer, selected.isBackSide { layer.back = true }
        insertCustomLayer(layer, at: customLayers.count)
        if select { selectCustomLayer(layer.id) }
        appendLog("\nAdded custom layer \"\(name)\" — draw on it with the tools above the preview.\n")
        return layer
    }

    func insertCustomLayer(_ layer: CustomLayer, at index: Int) {
        let i = min(max(index, 0), customLayers.count)
        customLayers.insert(layer, at: i)
        editor.undoManager?.registerUndo(withTarget: self) { model in model.removeCustomLayer(id: layer.id) }
        editor.undoManager?.setActionName("Add Layer")
    }

    func removeCustomLayer(id: UUID) {
        guard let i = customLayers.firstIndex(where: { $0.id == id }) else { return }
        let layer = customLayers.remove(at: i)
        editor.undoManager?.registerUndo(withTarget: self) { model in model.insertCustomLayer(layer, at: i) }
        editor.undoManager?.setActionName("Delete Layer")
        if player.selectedLayer?.customRef?.id == id {
            player.selectedLayer = preview.document?.layers.first { $0.id.customRef?.id != id }?.id
                ?? customLayers.first.map { .custom($0.ref(index: 0)) }
            editor.layerDidChange()
        }
        appendLog("\nRemoved custom layer \"\(layer.name)\".\n")
    }

    func duplicateCustomLayer(id: UUID) {
        guard let i = customLayers.firstIndex(where: { $0.id == id }) else { return }
        var copy = customLayers[i]
        copy.id = UUID()
        copy.name += " copy"
        for k in copy.shapes.indices { copy.shapes[k].id = UUID() }
        insertCustomLayer(copy, at: i + 1)
        selectCustomLayer(copy.id)
    }

    /// Shows a drawn layer in the preview and its settings in the sidebar.
    func selectCustomLayer(_ id: UUID) {
        guard let ref = customLayers.ref(id: id) else { return }
        if player.selectedLayer != .custom(ref) {
            player.selectedLayer = .custom(ref)
            editor.layerDidChange()
        }
        UserDefaults.standard.set("", forKey: "ui.sectionOverride")
    }

    /// Copies a library tool's cutting data into a drawn layer.
    func applyTool(_ tool: MachineTool, toCustomLayer id: UUID) {
        guard var layer = customLayers.first(where: { $0.id == id }) else { return }
        layer.toolID = tool.id.uuidString
        layer.toolDiameter = tool.shape == .vBit ? tool.effectiveDiameter(atDepth: tool.cutDepth) : tool.diameter
        layer.cutDepth = tool.cutDepth
        layer.depthPerPass = tool.depthPerPass
        if tool.feedXY > 0 { layer.feedXY = tool.feedXY }
        if tool.feedZ > 0 { layer.feedZ = tool.feedZ }
        if tool.spindle > 0 { layer.spindle = tool.spindle }
        if tool.overlap > 0 { layer.overlap = tool.overlap }
        if tool.dwell > 0 { layer.dwell = tool.dwell }
        layer.travelZ = max(0, tool.travelZ)
        layer.endZ = max(0, tool.toolChangeZ)
        layer.extraCut = max(0, tool.extraCut)
        layer.spindleCCW = tool.spindleCCW
        editor.setLayer(layer, actionName: "Change Tool")
    }
}
