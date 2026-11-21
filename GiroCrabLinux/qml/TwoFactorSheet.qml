import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// TwoFactorSheet.swift: push approval (polled), TAN / photoTAN code, PSD2 redirect.
Sheet {
    id: sheet
    readonly property var active: AppModel.activeChallenge
    readonly property var c: active ? active.challenge : null
    property bool showManualRedirect: false
    visible: active !== null
    sheetWidth: c && c.kind === "Redirect" && consentLoader.active ? 928 : 420
    // a new challenge never inherits the previous one's consent page or pasted address
    onAboutToShow: { code.text = ""; showManualRedirect = false; consentLoader.active = false; redirectField.text = "" }
    onRejected: AppModel.skipCurrentSync()
    function submit() {
        const value = code.text.trim()
        if (value === "" || (active && active.busy)) return
        if (c.kind !== "Redirect") code.text = ""
        AppModel.submitCode(value)
    }
    ColumnLayout {
        width: sheet.availableWidth
        spacing: 18
        RowLayout {
            spacing: 10
            SymbolTile { symbol: sheet.active ? sheet.active.connection.sf_symbol : ""; size: 30; tint: Theme.accent }
            ColumnLayout { spacing: 0; Layout.fillWidth: true
                Text { text: sheet.active ? sheet.active.connection.display_name : ""; font.pixelSize: Theme.body + 1; font.weight: Font.DemiBold; color: Theme.text; Sensitive {} }
                Text { text: sheet.c ? sheet.c.method_name : ""; font.pixelSize: Theme.caption; color: Theme.secondary } }
            SyncBatchProgressLabel {}
        }
        DemoHintBanner {
            visible: sheet.active !== null && (AppModel.isDemo || AppModel.isMagicDemoLogin(sheet.active.connection.login_name))
            Layout.fillWidth: true
            credentials: false
            buttonTitle: sheet.c && (sheet.c.kind === "DecoupledPush" || sheet.c.kind === "Progress") ? "" : qsTr("TAN 123456 einfügen")
            onFill: code.text = "123456"
        }
        // .decoupledPush
        ColumnLayout {
            visible: sheet.c !== null && sheet.c.kind === "DecoupledPush"
            Layout.fillWidth: true; spacing: 12
            SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "iphone.radiowaves.left.and.right"; size: 56; color: Theme.accent
                     SequentialAnimation on opacity { loops: Animation.Infinite; running: sheet.visible
                         NumberAnimation { to: 0.45; duration: 700 } NumberAnimation { to: 1; duration: 700 } } }
            ChallengeTexts {}
            Button { visible: sheet.c && !!sheet.c.redirect_url; Layout.alignment: Qt.AlignHCenter
                     text: qsTr("Im Browser anmelden"); highlighted: true; onClicked: Qt.openUrlExternally(sheet.c.redirect_url) }
            RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 8
                BusyIndicator { implicitWidth: 18; implicitHeight: 18; running: parent.visible }
                Text { text: sheet.active && sheet.active.waiting ? qsTr("Warte auf Freigabe …") : qsTr("Push-Nachricht gesendet"); color: Theme.secondary; font.pixelSize: Theme.callout + 1 } }
        }
        // .progress: approval given, a longer download runs (comdirect PostBox, #838)
        ColumnLayout {
            visible: sheet.c !== null && sheet.c.kind === "Progress"
            Layout.fillWidth: true; spacing: 12
            SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: "tray"; size: 56; color: Theme.accent }
            ChallengeTexts {}
            BusyIndicator { Layout.alignment: Qt.AlignHCenter; implicitWidth: 18; implicitHeight: 18; running: parent.visible }
        }
        // .code, .imageCode
        ColumnLayout {
            visible: sheet.c !== null && (sheet.c.kind === "Code" || sheet.c.kind === "ImageCode")
            Layout.fillWidth: true; spacing: 12
            SFIcon { Layout.alignment: Qt.AlignHCenter; symbol: sheet.c && sheet.c.kind === "ImageCode" ? "qrcode.viewfinder" : "lock.rotation"; size: 44; color: Theme.accent }
            Text { Layout.alignment: Qt.AlignHCenter; text: sheet.c ? sheet.c.title : ""; font.pixelSize: Theme.title3 + 2; font.weight: Font.Bold; color: Theme.text }
            Rectangle {
                visible: sheet.c && !!sheet.c.image_url
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: Math.min(220, img.implicitWidth + 8); implicitHeight: Math.min(220, img.implicitHeight + 8)
                color: "white"; radius: 8
                Image { id: img; anchors.fill: parent; anchors.margins: 4; source: sheet.c && sheet.c.image_url ? sheet.c.image_url : ""
                        fillMode: Image.PreserveAspectFit; smooth: false }
                Sensitive {}   // photoTAN/QR codes encode the order
            }
            Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; text: sheet.c ? sheet.c.message : ""; color: Theme.secondary; font.pixelSize: Theme.body; Sensitive {} }   // a transfer TAN names payee and amount
            TextField {
                id: code
                Layout.alignment: Qt.AlignHCenter; Layout.preferredWidth: 220
                placeholderText: qsTr("TAN / Code"); horizontalAlignment: Text.AlignHCenter
                font.family: "monospace"; font.pixelSize: Theme.title2 + 2
                onAccepted: sheet.submit()
            }
            Button { visible: sheet.active && sheet.active.connection.connector === "TradeRepublic" && sheet.c.kind === "Code"
                     Layout.alignment: Qt.AlignHCenter; flat: true; text: qsTr("Code per SMS anfordern"); onClicked: AppModel.submitCode("SMS") }
        }
        // .redirect (PSD2 consent page)
        ColumnLayout {
            visible: sheet.c !== null && sheet.c.kind === "Redirect"
            Layout.fillWidth: true; spacing: 12
            Loader {
                id: consentLoader
                active: false
                visible: active
                Layout.fillWidth: true; Layout.preferredHeight: 560
                source: "ConsentBrowser.qml"
                onLoaded: { item.url = sheet.c.redirect_url; item.redirect = AppModel.consentRedirectURL() }
                Connections { target: consentLoader.item; ignoreUnknownSignals: true
                    function onFinished(result) { consentLoader.active = false; AppModel.submitCode(result) } }
            }
            Text { visible: consentLoader.active; text: qsTr("Bei der Bank anmelden und den Zugriff erlauben – das Fenster schließt sich danach von selbst."); color: Theme.secondary; font.pixelSize: Theme.callout + 1 }
            SFIcon { visible: !consentLoader.active; Layout.alignment: Qt.AlignHCenter; symbol: "building.columns"; size: 44; color: Theme.accent }
            Text { visible: !consentLoader.active; Layout.alignment: Qt.AlignHCenter; text: sheet.c ? sheet.c.title : ""; font.pixelSize: Theme.title3 + 2; font.weight: Font.Bold; color: Theme.text }
            Text { visible: !consentLoader.active; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; color: Theme.secondary
                   text: qsTr("Sie melden sich direkt bei Ihrer Bank an und erlauben den Zugriff. GiroCrab übernimmt das Ergebnis automatisch.") }
            Button { visible: !consentLoader.active && sheet.c && !!sheet.c.redirect_url; Layout.alignment: Qt.AlignHCenter
                     text: qsTr("Bei der Bank anmelden"); highlighted: true; onClicked: consentLoader.active = true }
            CheckBox { id: manual; text: qsTr("Stattdessen im eigenen Browser anmelden"); checked: sheet.showManualRedirect; onToggled: sheet.showManualRedirect = checked }
            ColumnLayout {
                visible: sheet.showManualRedirect
                Layout.fillWidth: true; spacing: 8
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: sheet.c ? sheet.c.message : ""; font.pixelSize: Theme.caption; color: Theme.secondary; Sensitive {} }   // a transfer TAN names payee and amount
                Button { visible: sheet.c && !!sheet.c.redirect_url; text: qsTr("Zustimmungsseite öffnen"); onClicked: Qt.openUrlExternally(sheet.c.redirect_url) }
                TextField { id: redirectField; Layout.fillWidth: true; placeholderText: qsTr("Weitergeleitete Adresse hier einfügen")
                            onTextChanged: code.text = text; onAccepted: sheet.submit() }
            }
        }
        RowLayout {
            visible: sheet.active && sheet.active.busy && sheet.c.kind === "Redirect"
            spacing: 8
            BusyIndicator { implicitWidth: 18; implicitHeight: 18; running: parent.visible }
            Text { text: qsTr("Freigabe wird übernommen …"); color: Theme.secondary; font.pixelSize: Theme.callout + 1 }
        }
        Text { visible: sheet.active && sheet.active.error !== ""; text: sheet.active ? sheet.active.error : ""; color: Theme.negative; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        Text { visible: sheet.c && sheet.c.expires_in_seconds !== null; text: sheet.c && sheet.c.expires_in_seconds ? qsTr("Gültig noch etwa %1 Min.").arg(Math.floor(sheet.c.expires_in_seconds / 60)) : ""
               font.pixelSize: Theme.caption; color: Theme.tertiary }
        SyncPromptButtons {
            Layout.fillWidth: true
            defaultVisible: sheet.c !== null && (sheet.c.kind === "Code" || sheet.c.kind === "ImageCode" || (sheet.c.kind === "Redirect" && sheet.showManualRedirect))
            defaultEnabled: code.text.trim() !== "" && !(sheet.active && sheet.active.busy)
            onCancel: AppModel.skipCurrentSync()
            onAccept: sheet.submit()
        }
    }
    component ChallengeTexts: ColumnLayout {
        Layout.fillWidth: true; spacing: 8
        Text { Layout.alignment: Qt.AlignHCenter; text: sheet.c ? sheet.c.title : ""; font.pixelSize: Theme.title3 + 2; font.weight: Font.Bold; color: Theme.text }
        Text { Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; text: sheet.c ? sheet.c.message : ""; color: Theme.secondary; font.pixelSize: Theme.body; Sensitive {} }   // a transfer TAN names payee and amount
    }
}
