import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// BugReportUI.swift › BugReportView: Hilfe › Problem melden … (#301). Its own window, so the
// main window stays free to be captured. A screenshot of the main window with personal data
// drawn as opaque boxes (`Sensitive {}`), extra black boxes drawn with the mouse, a scrubbed
// diagnostics block (BugReport.swift → src/bug_report.rs) and a prefilled GitHub issue.
// Nothing leaves the computer until the user pastes the picture and submits the issue in
// the browser.
ApplicationWindow {
    id: win
    // `--dark` / `--light`: the controls follow the forced appearance (Theme.forcedPalette)
    Binding on palette { when: Theme.forced !== ""; value: Theme.forcedPalette }
    font.pointSize: Theme.controlPointSize   // appTextSize (#343)
    title: qsTr("Problem melden")
    width: 760; height: 860
    minimumWidth: 620; minimumHeight: 640
    color: Theme.canvas
    visible: AppModel.showBugReport
    onClosing: {
        token++   // a capture still waiting must not set anything
        AppModel.reportRedaction = 0
        AppModel.showBugReport = false
        AppModel.core("bug_report_clear")
    }
    Shortcut { sequences: [StandardKey.Close]; onActivated: win.close() }

    /// The main window and the item that is captured (toolbar and MainSplitView; sheets and
    /// popups live in the overlay and are never part of the picture, like on the Mac).
    property var mainWindow: null
    property Item captureItem: null

    /// Off only in the demo vault (fictitious data).
    property bool autoRedact: true
    property bool hideLabels: false
    property bool includeLog: true
    /// file:// URL of the captured picture ("" = none).
    property string base: ""
    property size baseSize: Qt.size(0, 0)
    property bool capturing: false
    property int token: 0
    property int shot: 0
    /// Extra black boxes: unit rectangles [x, y, width, height], origin top left.
    property var masks: []
    property var undoStack: []
    property var redoStack: []
    /// { info, log, log_unavailable, text } from `bug_report_prepare`; null while it is prepared.
    property var prepared: null
    property int prepareRun: 0

    readonly property int redaction: (autoRedact || !AppModel.isDemo ? AppModel.redactPersonal : 0)
                                     | (hideLabels ? AppModel.redactLabels : 0)
    readonly property bool canSend: !capturing && prepared !== null
    readonly property string tempDir: AppModel.run(() => AppModel.core("bug_report_temp_dir")) || ""

    onRedactionChanged: capture()
    onIncludeLogChanged: prepareDiagnostics()
    Connections {
        target: AppModel
        function onIsUnlockedChanged() { win.prepareDiagnostics() }
        function onIsDemoChanged() { win.prepareDiagnostics() }
    }
    Component.onCompleted: { capture(); prepareDiagnostics() }

    // MARK: capture (BugReport.captureMainWindow)

    /// Redraws the main window with the redaction, captures it and restores the normal view.
    /// A later call wins: an earlier one that is still waiting does nothing, so it can never
    /// reset the redaction under a newer capture.
    function capture() {
        const t = ++token
        capturing = true
        AppModel.reportRedaction = redaction
        settle.token = t
        settle.restart()
        deadline.token = t
        deadline.restart()
    }
    function finishCapture(t, url, size) {
        if (t !== token) return
        deadline.stop()
        AppModel.reportRedaction = 0
        base = url
        baseSize = size
        // Unit rectangles drawn on the old picture may now cover something else (the list
        // scrolled, the window was resized): start over.
        masks = []; undoStack = []; redoStack = []
        capturing = false
    }
    // Lets the scene graph draw the boxes (lists build delegates lazily).
    Timer {
        id: settle
        property int token: 0
        interval: 180
        onTriggered: {
            const t = token
            if (t !== win.token) return
            const w = win.mainWindow, item = win.captureItem
            // Fail closed: no picture of a closed, minimised or locked main window.
            if (!w || !item || !w.visible || w.visibility === Window.Minimized || !AppModel.isUnlocked
                || (AppModel.reportRedaction & win.redaction) !== win.redaction) {
                win.finishCapture(t, "", Qt.size(0, 0))
                return
            }
            const dpr = w.screen ? w.screen.devicePixelRatio : 1
            const size = Qt.size(Math.round(item.width * dpr), Math.round(item.height * dpr))
            const started = item.grabToImage(result => {
                if (t !== win.token || (AppModel.reportRedaction & win.redaction) !== win.redaction) return
                const path = win.tempDir + "/capture-" + (++win.shot) + ".png"
                win.finishCapture(t, result.saveToFile(path) ? "file://" + path : "", size)
            }, size)
            if (!started) win.finishCapture(t, "", Qt.size(0, 0))
        }
    }
    // BugReport.renderTimeout: no picture rather than a stuck "busy" state.
    Timer {
        id: deadline
        property int token: 0
        interval: 2000
        onTriggered: win.finishCapture(token, "", Qt.size(0, 0))
    }

    // MARK: diagnostics

    /// Log entries and payee names load together, or the log is left out (src/bug_report.rs).
    function prepareDiagnostics() {
        const run = ++prepareRun
        prepared = null
        AppModel.coreAsync("bug_report_prepare", { include_log: includeLog, demo: AppModel.isDemo }, r => {
            if (run === prepareRun) prepared = r
        }, e => { if (run === prepareRun) prepared = { info: null, log: [], log_unavailable: true, text: e } })
    }

    // MARK: masks (undoable: Strg+Z / Strg+Umschalt+Z)

    function replaceMasks(list) {
        undoStack = undoStack.concat([masks])
        redoStack = []
        masks = list
    }
    function undo() {
        if (undoStack.length === 0) return
        redoStack = redoStack.concat([masks])
        masks = undoStack[undoStack.length - 1]
        undoStack = undoStack.slice(0, -1)
    }
    function redo() {
        if (redoStack.length === 0) return
        undoStack = undoStack.concat([masks])
        masks = redoStack[redoStack.length - 1]
        redoStack = redoStack.slice(0, -1)
    }
    Shortcut { sequences: [StandardKey.Undo]; onActivated: win.undo() }
    Shortcut { sequences: [StandardKey.Redo]; onActivated: win.redo() }

    /// The picture with the user's boxes burnt in (BugReport.compose), as a file; "" = none.
    function finalPNG(path) {
        if (base === "") return ""
        const ok = AppModel.run(() => AppModel.core("bug_report_compose",
            { base: AppModel.localPath(base), masks: masks.map(m => [m.x, m.y, m.width, m.height]), path: path }))
        return ok ? path : ""
    }

    function send() {
        if (!canSend || prepared === null || prepared.info === null) return
        const png = finalPNG(tempDir + "/GiroCrab-Fehlerbericht.png")
        const copied = png !== "" && AppModel.run(() => AppModel.core("copy_image", { path: png })) === true
        const url = AppModel.run(() => AppModel.core("bug_report_issue_url",
            { info: prepared.info, log: prepared.log, with_screenshot: copied }))
        if (!url) return
        Qt.openUrlExternally(url)
        // Done: the picture is on the clipboard and the issue body says how to paste it.
        // The clipboard keeps the picture while GiroCrab runs; the window only hides.
        win.close()
    }

    FileDialog {
        id: exportDialog
        title: qsTr("Als PNG sichern …")
        fileMode: FileDialog.SaveFile
        defaultSuffix: "png"
        nameFilters: [qsTr("PNG-Bild (*.png)")]
        currentFolder: StandardPaths.writableLocation(StandardPaths.PicturesLocation)
        selectedFile: currentFolder + "/" + qsTr("GiroCrab-Fehlerbericht") + ".png"
        onAccepted: win.finalPNG(AppModel.localPath(selectedFile))
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        ScrollView {
            id: scroll
            Layout.fillWidth: true; Layout.fillHeight: true
            contentWidth: availableWidth
            ColumnLayout {
                width: scroll.availableWidth - 40
                x: 20
                spacing: 18
                Item { implicitHeight: 2 }

                SettingsFormSection {
                    title: qsTr("Screenshot")
                    footer: qsTr("Eine neue Aufnahme verwirft die Markierungen, weil sich der Inhalt verschoben haben kann.")
                    Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout; color: Theme.secondary
                           text: qsTr("Ziehe mit der Maus Rechtecke über Stellen, die zusätzlich schwarz übermalt werden sollen.") }
                    // MaskCanvas
                    Item {
                        id: canvas
                        visible: win.base !== ""
                        Layout.fillWidth: true
                        implicitHeight: win.baseSize.width > 0 ? width * win.baseSize.height / win.baseSize.width : 0
                        opacity: win.capturing ? 0.5 : 1
                        Image {
                            anchors.fill: parent
                            source: win.base
                            cache: false
                            fillMode: Image.PreserveAspectFit
                            smooth: true; mipmap: true
                            Accessible.name: qsTr("Vorschau des Screenshots")
                            Accessible.description: win.masks.length === 0 ? qsTr("Persönliche Daten sind abgedeckt.")
                                : qsTr("Persönliche Daten sind abgedeckt, dazu %1 eigene Markierungen.").arg(win.masks.length)
                        }
                        Repeater {
                            model: win.masks.concat(drag.draft ? [drag.draft] : [])
                            Rectangle {
                                required property var modelData
                                color: "black"
                                x: modelData.x * canvas.width; y: modelData.y * canvas.height
                                width: modelData.width * canvas.width; height: modelData.height * canvas.height
                            }
                        }
                        Rectangle { anchors.fill: parent; color: "transparent"; radius: 4; border.color: Theme.withAlpha(Theme.secondary, 0.4) }
                        MouseArea {
                            id: drag
                            anchors.fill: parent
                            enabled: !win.capturing
                            // HIG: show that the picture takes a drag (crosshair over it).
                            cursorShape: Qt.CrossCursor
                            preventStealing: true
                            property point start
                            property var draft: null
                            function unitRect(a, b) {
                                const cl = v => Math.min(Math.max(v, 0), 1)
                                const x0 = cl(Math.min(a.x, b.x) / width), x1 = cl(Math.max(a.x, b.x) / width)
                                const y0 = cl(Math.min(a.y, b.y) / height), y1 = cl(Math.max(a.y, b.y) / height)
                                return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }
                            }
                            onPressed: mouse => { start = Qt.point(mouse.x, mouse.y); draft = null }
                            onPositionChanged: mouse => { draft = unitRect(start, Qt.point(mouse.x, mouse.y)) }
                            onReleased: mouse => {
                                const r = unitRect(start, Qt.point(mouse.x, mouse.y))
                                draft = null
                                if (r.width > 0.004 && r.height > 0.004) win.replaceMasks(win.masks.concat([r]))
                            }
                        }
                    }
                    RowLayout {
                        visible: win.base === ""
                        Layout.fillWidth: true; Layout.minimumHeight: 160
                        Item { Layout.fillWidth: true }
                        BusyIndicator { visible: win.capturing; running: visible; implicitWidth: 28; implicitHeight: 28 }
                        Text { visible: win.capturing; text: qsTr("Screenshot wird erstellt …"); color: Theme.secondary; font.pixelSize: Theme.body }
                        Text {
                            visible: !win.capturing
                            Layout.fillWidth: true; Layout.maximumWidth: 520
                            wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                            color: Theme.secondary; font.pixelSize: Theme.body
                            text: qsTr("Kein Screenshot: Das Hauptfenster ist geschlossen, minimiert, gesperrt oder wurde nicht rechtzeitig geschwärzt. „Neu aufnehmen“ versucht es erneut; sonst wird das Issue ohne Screenshot erstellt.")
                        }
                        Item { Layout.fillWidth: true }
                    }
                    // maskControls
                    RowLayout {
                        Layout.fillWidth: true
                        Button { text: qsTr("Rückgängig"); icon.name: "edit-undo"; flat: true
                                 enabled: win.undoStack.length > 0; onClicked: win.undo() }
                        Button { text: qsTr("Alle Markierungen entfernen"); flat: true
                                 enabled: win.masks.length > 0; onClicked: win.replaceMasks([]) }
                        Item { Layout.fillWidth: true }
                        Button { text: qsTr("Neu aufnehmen"); icon.name: "camera-photo"; flat: true
                                 enabled: !win.capturing; onClicked: win.capture() }
                    }
                }

                SettingsFormSection {
                    footer: AppModel.isDemo
                        ? qsTr("Beträge, IBANs, Namen, Kontonamen, Verwendungszwecke und Belege werden abgedeckt; „Kategorien ausblenden“ deckt auch Kategorien, Gruppen und Wertpapiernamen ab. Im Demo-Tresor sind alle Daten erfunden, deshalb lässt sich die Schwärzung hier abschalten.")
                        : qsTr("Beträge, IBANs, Namen, Kontonamen, Verwendungszwecke und Belege werden abgedeckt; „Kategorien ausblenden“ deckt auch Kategorien, Gruppen und Wertpapiernamen ab. Prüfe das Bild trotzdem, bevor du es teilst.")
                    CheckBox {
                        visible: AppModel.isDemo
                        text: qsTr("Persönliche Daten schwärzen")
                        checked: win.autoRedact
                        onToggled: win.autoRedact = checked
                    }
                    RowLayout {
                        visible: !AppModel.isDemo
                        spacing: 7
                        SFIcon { symbol: "eye.slash"; size: 14; color: Theme.secondary }
                        Text { text: qsTr("Persönliche Daten werden geschwärzt"); color: Theme.text; font.pixelSize: Theme.body }
                    }
                    CheckBox {
                        text: qsTr("Kategorien ausblenden")
                        checked: win.hideLabels
                        onToggled: win.hideLabels = checked
                    }
                }

                SettingsFormSection {
                    title: qsTr("Diagnose")
                    footer: qsTr("Beim Öffnen des Issues liegt der geschwärzte Screenshot in der Zwischenablage. Es wird nichts automatisch gesendet: Der Browser zeigt ein vorausgefülltes Issue, das du vor dem Absenden noch bearbeiten kannst.")
                    CheckBox {
                        text: qsTr("Abruf-Protokoll anhängen")
                        checked: win.includeLog
                        onToggled: win.includeLog = checked
                    }
                    TextEdit {
                        visible: win.prepared !== null
                        Layout.fillWidth: true
                        text: win.prepared ? win.prepared.text : ""
                        readOnly: true; selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        font.family: "monospace"; font.pixelSize: Theme.caption
                        color: Theme.text
                    }
                    RowLayout {
                        visible: win.prepared !== null && win.prepared.log_unavailable === true
                        Layout.fillWidth: true
                        spacing: 6
                        SFIcon { symbol: "exclamationmark.triangle"; size: 13; color: Theme.secondary; Layout.alignment: Qt.AlignTop }
                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.caption; color: Theme.secondary
                               text: qsTr("Das Abruf-Protokoll wird nicht angehängt: Es konnte nicht vollständig geladen und bereinigt werden.") }
                    }
                    RowLayout {
                        visible: win.prepared === null
                        spacing: 8
                        BusyIndicator { running: visible; implicitWidth: 22; implicitHeight: 22 }
                        Text { text: qsTr("Diagnose wird bereinigt …"); color: Theme.secondary; font.pixelSize: Theme.body }
                    }
                }
                Item { implicitHeight: 4 }
            }
        }

        // actionBar: the primary action stays in view, bottom trailing, bound to Return.
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: actions.implicitHeight + 24
            color: Theme.canvas
            RowLayout {
                id: actions
                anchors.fill: parent; anchors.leftMargin: 20; anchors.rightMargin: 20
                Button { text: qsTr("Als PNG sichern …"); enabled: win.base !== "" && !win.capturing; onClicked: exportDialog.open() }
                Item { Layout.fillWidth: true }
                Button {
                    text: qsTr("Issue auf GitHub öffnen")
                    icon.name: "document-open-remote"
                    highlighted: true
                    enabled: win.canSend
                    onClicked: win.send()
                }
            }
        }
    }
    Shortcut { sequences: ["Return", "Enter"]; enabled: win.canSend; onActivated: win.send() }
}
