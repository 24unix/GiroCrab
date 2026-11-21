import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore

// BugReportUI.swift › BugReportView: Hilfe › Problem melden … (#301). Its own window, so the
// main window stays free to be captured. A screenshot of the main window, with the sheet or
// popover over it and the Settings window drawn at their place (#384), personal data
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

    /// The main window and the item that is captured (toolbar and MainSplitView). The sheets
    /// and popovers over it live in the window's overlay and are drawn at their place
    /// (ReportDialogs.qml, #384), like the Settings window while it is open (`settingsWindow`).
    property var mainWindow: null
    property Item captureItem: null
    property var settingsWindow: null
    /// The capture left out a dialog over the main window (an alert).
    property bool dialogOmitted: false

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
    Component.onCompleted: { ReportDialogs.dismissPopovers(); capture(); prepareDiagnostics() }

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
    function finishCapture(t, url, size, omitted) {
        if (t !== token) return
        deadline.stop()
        AppModel.reportRedaction = 0
        base = url
        baseSize = size
        dialogOmitted = url !== "" && omitted === true
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
            win.snapshot(t, w, item)
        }
    }

    // MARK: dialogs (ReportDialogs.swift, BugReport.dialogLayers / snapshot, #384)

    /// `#aarrggbb` of a QML colour (the compositor takes it with alpha).
    function argb(c) {
        const h = v => ("0" + Math.round(v * 255).toString(16)).slice(-2)
        return "#" + h(c.a) + h(c.r) + h(c.g) + h(c.b)
    }
    /// `item`'s rect in `ref`'s coordinates, moved by `offset`.
    function rectIn(item, ref, offset) {
        const r = item.mapToItem(ref, 0, 0, item.width, item.height)
        return Qt.rect(r.x + offset.x, r.y + offset.y, r.width, r.height)
    }
    function intersect(a, b) {
        const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y)
        return Qt.rect(x, y, Math.max(0, Math.min(a.x + a.width, b.x + b.width) - x),
                       Math.max(0, Math.min(a.y + a.height, b.y + b.height) - y))
    }
    /// The same rectangles in the same order: the geometry did not change between two looks.
    function sameRects(a, b) {
        if (a.length !== b.length) return false
        for (let i = 0; i < a.length; ++i)
            if (a[i].x !== b[i].x || a[i].y !== b[i].y || a[i].width !== b[i].width || a[i].height !== b[i].height)
                return false
        return true
    }
    function unite(a, b) {
        const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y)
        return Qt.rect(x, y, Math.max(a.x + a.width, b.x + b.width) - x, Math.max(a.y + a.height, b.y + b.height) - y)
    }
    /// A text field or text editor that takes input, a pop-up menu (ComboBox) or a web page
    /// (a bank or portal login): what the user typed or picked there is personal more often
    /// than not, so the capture covers it (BugReport.inputRects).
    function isInput(d) {
        return (d.cursorPosition !== undefined && d.readOnly === false)
            || (d.displayText !== undefined && d.popup !== undefined && d.currentIndex !== undefined)
            || typeof d.runJavaScript === "function"
    }
    /// The visible inputs inside `root`, each clipped to the clipping items it sits in (a
    /// field scrolled out of its list must not cover what lies outside the list).
    function inputRects(root, ref, offset) {
        const out = []
        const visit = (d, clip) => {
            if (!d.visible || d.opacity <= 0) return
            const r = rectIn(d, ref, offset)
            if (isInput(d)) {
                const c = clip ? intersect(r, clip) : r
                if (c.width > 0 && c.height > 0) out.push(c)
                return
            }
            const inner = d.clip ? (clip ? intersect(r, clip) : r) : clip
            for (let i = 0; i < d.children.length; ++i) visit(d.children[i], inner)
        }
        visit(root, null)
        return out
    }
    /// The layers over `window` in its overlay, bottom up: a registered dialog (sheet or
    /// popover) with its inputs, the dim under a modal one, or `omitted` for a popup that is
    /// not capturable (an alert, a menu, a non-native file dialog). The shared tool tip is no
    /// dialog and stays out.
    function overlayLayers(window, ref, offset) {
        const overlay = window && window.contentItem ? window.contentItem.Overlay.overlay : null
        if (!overlay) return []
        const shared = scroll.ToolTip.toolTip
        const tip = shared ? ReportDialogs.itemOf(shared) : null
        const items = []
        for (let i = 0; i < overlay.children.length; ++i) {
            const c = overlay.children[i]
            if (c.visible && c.opacity > 0 && c !== tip) items.push({ item: c, index: i })
        }
        // the overlay paints by z, then in child order
        items.sort((a, b) => a.item.z - b.item.z || a.index - b.index)
        return items.map(e => {
            const c = e.item
            const popup = ReportDialogs.popupFor(c)
            if (popup) {
                // the card's rounded corners (the grab has no alpha outside them)
                const bg = popup.background
                return { kind: "dialog", item: c, rect: rectIn(c, ref, offset), inputs: inputRects(c, ref, offset),
                         measure: () => [rectIn(c, ref, offset)].concat(inputRects(c, ref, offset)),
                         radius: bg && bg.radius !== undefined ? bg.radius : 0 }
            }
            // the overlay's dimmer under a modal popup: a plain coloured rectangle over all of it
            if (c.color !== undefined && c.width >= overlay.width && c.height >= overlay.height)
                return { kind: "dim", color: argb(Qt.rgba(c.color.r, c.color.g, c.color.b, c.color.a * c.opacity)),
                         rect: rectIn(c, ref, offset) }
            return { kind: "omitted" }
        })
    }
    /// The Settings window, while it is open (the Mac draws its tracked window in front of the
    /// main one). Its place relative to the main window is known on X11; Wayland does not tell
    /// window positions (nor do windows that report the same place), so there it is drawn
    /// centred over the main window.
    function settingsLayers(main, item) {
        const s = settingsWindow
        // `captureItem`: the window's own content (its contentItem has no QML engine to grab with)
        const content = s ? s.captureItem : null
        if (!s || !s.visible || s.visibility === Window.Minimized || !content) return []
        const origin = item.mapToItem(null, 0, 0)
        const offset = Qt.platform.pluginName.startsWith("wayland") || (s.x === main.x && s.y === main.y)
            ? Qt.point((item.width - s.width) / 2, (item.height - s.height) / 2)
            : Qt.point(s.x - main.x - origin.x, s.y - main.y - origin.y)
        return [{ kind: "window", item: content, rect: rectIn(content, content, offset), radius: 0,
                  inputs: inputRects(content, content, offset),
                  measure: () => [rectIn(content, content, offset)].concat(inputRects(content, content, offset)) }]
            .concat(overlayLayers(s, content, offset))
    }

    /// Captures the main window and, bottom up, the dialogs over it; the first one that cannot
    /// be drawn ends the stack (anything above it would sit on top of it), and the report then
    /// says a dialog was left out. Fail closed: no picture at all when a picture fails.
    function snapshot(t, w, item) {
        const dpr = w.screen ? w.screen.devicePixelRatio : 1
        const all = overlayLayers(w, item, Qt.point(0, 0)).concat(settingsLayers(w, item))
        let layers = []
        let pendingDims = []
        let omitted = false
        for (const l of all) {
            if (l.kind === "omitted") { omitted = true; break }
            if (l.kind === "dim") { pendingDims.push(l); continue }
            layers = layers.concat(pendingDims, [l])
            pendingDims = []
        }
        const coverInputs = redaction !== 0
        const grabs = [{ kind: "base", item: item, rect: Qt.rect(0, 0, item.width, item.height) }]
            .concat(layers.filter(l => l.kind !== "dim"))
        let pending = grabs.length
        let failed = false
        const done = () => {
            if (--pending > 0) return
            if (failed || t !== token || (AppModel.reportRedaction & redaction) !== redaction) {
                if (t === token && failed) finishCapture(t, "", Qt.size(0, 0))
                return
            }
            const area = layers.reduce((a, l) => unite(a, l.rect), grabs[0].rect)
            const px = r => ({ x: (r.x - area.x) * dpr, y: (r.y - area.y) * dpr, width: r.width * dpr, height: r.height * dpr })
            const spec = { width: Math.ceil(area.width * dpr), height: Math.ceil(area.height * dpr),
                           background: "#00000000", layers: [] }
            spec.layers.push(Object.assign({ fill: argb(Theme.canvas), radius: 0 }, px(grabs[0].rect)))
            spec.layers.push(Object.assign({ image: grabs[0].path }, px(grabs[0].rect)))
            for (const l of layers) {
                if (l.kind === "dim") {
                    spec.layers.push(Object.assign({ fill: l.color, radius: 0 }, px(l.rect)))
                    continue
                }
                spec.layers.push(Object.assign({ image: l.path, radius: l.radius * dpr }, px(l.rect)))
                if (coverInputs)
                    for (const r of l.inputs)
                        spec.layers.push(Object.assign({ fill: argb(Theme.redactionFill), radius: 3 * dpr }, px(r)))
            }
            const path = tempDir + "/capture-" + (++shot) + ".png"
            const ok = AppModel.run(() => AppModel.core("bug_report_compose_capture", { spec: spec, path: path })) === true
            finishCapture(t, ok ? "file://" + path : "", Qt.size(spec.width, spec.height), omitted)
        }
        for (const g of grabs) {
            const target = Qt.size(Math.max(1, Math.round(g.item.width * dpr)), Math.max(1, Math.round(g.item.height * dpr)))
            // The covers are measured before the grab, which renders later: a field that moved in
            // between (a list scrolled) could leave its cover. Measured again once the layer is
            // rendered, any change drops the picture (fail closed) instead of showing it uncovered.
            const before = g.measure ? [g.rect].concat(g.inputs) : []
            const started = g.item.grabToImage(result => {
                const path = tempDir + "/layer-" + (++shot) + ".png"
                if (g.measure && !sameRects(before, g.measure())) failed = true
                else if (result.saveToFile(path)) g.path = path
                else failed = true
                done()
            }, target)
            if (!started) { failed = true; done() }
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
            ScrollBar.vertical: ScrollViewBar {}
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
                    // #384: the main window stays usable next to this one
                    footer: qsTr("Aufgenommen wird das Hauptfenster samt geöffnetem Dialog. Liegt das Problem woanders, wechsle dort zur betroffenen Ansicht oder öffne den Dialog und wähle dann „Neu aufnehmen“. Eine neue Aufnahme verwirft die Markierungen, weil sich der Inhalt verschoben haben kann.")
                    Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout; color: Theme.secondary
                           text: qsTr("Ziehe mit der Maus Rechtecke über Stellen, die zusätzlich schwarz übermalt werden sollen.") }
                    // the capture left out a dialog over the main window (an alert)
                    RowLayout {
                        visible: win.base !== "" && win.dialogOmitted && !win.capturing
                        Layout.fillWidth: true
                        spacing: 6
                        SFIcon { symbol: "info.circle"; size: 14; color: Theme.secondary; Layout.alignment: Qt.AlignTop }
                        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: Theme.callout; color: Theme.secondary
                               text: qsTr("Ein geöffneter Hinweis oder Bestätigungsdialog wird nicht aufgenommen; das Bild zeigt, was darunter liegt.") }
                    }
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
