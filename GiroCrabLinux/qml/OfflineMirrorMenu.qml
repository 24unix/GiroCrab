import QtQuick
import QtQuick.Controls

// OfflineAccountsUI.swift › OfflineBookingMenu: "In Offline-Konto spiegeln" – one entry per offline
// account other than the booking's own (#679). A one-time copy with the amount reversed, no category.
AppMenu {
    id: menu
    property var booking: null
    /// The offline accounts the booking can go to; the context menu leaves the submenu out without any.
    readonly property var targets: booking ? OfflineAccounts.offlineAccounts.filter(a => a.id !== booking.account_id) : []
    title: qsTr("In Offline-Konto spiegeln")
    icon.name: SF.icon("arrow.left.arrow.right")

    property var dynamicItems: []
    onAboutToShow: rebuild()
    function rebuild() {
        for (const it of dynamicItems) { removeItem(it); it.destroy() }
        const items = targets.map(a => entry.createObject(null, { text: AppModel.menuText(AppModel.masking(a.name)), account: a }))
        items.forEach((it, i) => insertItem(i, it))
        dynamicItems = items
    }
    Component {
        id: entry
        AppMenuItem {
            property var account: null
            onTriggered: OfflineAccounts.mirror(menu.booking, account)
        }
    }
}
