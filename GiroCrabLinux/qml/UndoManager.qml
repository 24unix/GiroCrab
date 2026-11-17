pragma Singleton
import QtQuick

// ManualLoansUI.swift › windowUndoManager: the one undo manager of the main window, also
// for edits saved from its sheets. Tags (AppModel+Tags.swift), loans (ManualLoansUI.swift)
// and the Startsaldo (OpeningBalanceUI.swift) register on it, so Bearbeiten › Rückgängig
// undoes the last action of any kind first.
//
// Works like NSUndoManager.registerUndo + setActionName: `register(name, fn)` records `fn`
// as the inverse of what was just done. While `undo()` runs `fn`, the inverse that `fn`
// registers in turn lands on the redo stack; while `redo()` runs, it lands on the undo
// stack again without clearing the redo stack. A step whose core call fails registers
// nothing and is gone, as on the Mac.
QtObject {
    id: um

    property var undoStack: []
    property var redoStack: []
    /// 0 = normal action, 1 = undoing, 2 = redoing.
    property int phase: 0
    readonly property string undoName: undoStack.length ? undoStack[undoStack.length - 1].name : ""
    readonly property string redoName: redoStack.length ? redoStack[redoStack.length - 1].name : ""
    readonly property bool canUndo: undoStack.length > 0
    readonly property bool canRedo: redoStack.length > 0

    /// Records `fn` (no arguments) as the undo of the action just done, shown as `name`.
    function register(name, fn) {
        const entry = { name: name, fn: fn }
        if (phase === 1) redoStack = redoStack.concat([entry])
        else {
            undoStack = undoStack.concat([entry])
            if (phase === 0) redoStack = []
        }
    }
    function undo() {
        if (!undoStack.length || phase !== 0) return
        const e = undoStack[undoStack.length - 1]
        undoStack = undoStack.slice(0, -1)
        perform(e, 1)
    }
    function redo() {
        if (!redoStack.length || phase !== 0) return
        const e = redoStack[redoStack.length - 1]
        redoStack = redoStack.slice(0, -1)
        perform(e, 2)
    }
    function perform(e, p) {
        phase = p
        try { e.fn() } catch (err) { AppModel.errorMessage = err.message } finally { phase = 0 }
    }
    function clear() { undoStack = []; redoStack = [] }

    /// Another vault (demo / own, lock, reset) or a restored backup: the recorded ids
    /// point at other data, nothing to undo.
    property Connections vaultWatch: Connections {
        target: AppModel
        function onVaultStateChanged() { um.clear() }
        function onDemoActiveChanged() { um.clear() }
        function onVaultReplaced() { um.clear() }
    }
}
