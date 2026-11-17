import QtQuick

// SidebarView.swift › CategoryChipToggle (#336, #604): „Kategorie in der Buchungszeile anzeigen“
// in an account's menu. The tick reads the stored value (BookingPrefs), so it follows it.
AppMenuItem {
    id: toggle
    property var account: null
    readonly property bool shows: account !== null && BookingPrefs.showsCategoryChip(account.id)
    text: qsTr("Kategorie in der Buchungszeile anzeigen")
    icon.name: SF.icon("tag")
    checkable: true
    checked: shows
    onTriggered: {
        const show = !shows
        checked = Qt.binding(() => toggle.shows)   // the click flipped `checked` itself
        if (account !== null) BookingPrefs.setShowsCategoryChip(show, account.id)
    }
}
