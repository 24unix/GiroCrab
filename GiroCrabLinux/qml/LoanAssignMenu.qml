import QtQuick
import QtQuick.Controls

// ManualLoansUI.swift › LoanAssignMenu: "Darlehen zuordnen" submenu for a booking
// (context menu and Buchung menu). An inline picker "Keinem Darlehen" / the loans,
// then "Neues Darlehen aus dieser Buchung …". The menu bar disables it for loan
// bookings, inflows without a link or without a booking; a context menu leaves it out there (hidesWhenUnavailable).
AppMenu {
    id: menu
    property var booking: null
    // Repayments leave the account: offered for outflows, or to undo an existing link (#429).
    readonly property bool available: AppModel.loanAssignable(booking)
    title: qsTr("Darlehen zuordnen")
    enabled: available

    // The entries depend on the loans and the booking's link: rebuilt when opened.
    property var dynamicItems: []
    onAboutToShow: rebuild()
    function rebuild() {
        for (const it of dynamicItems) { removeItem(it); it.destroy() }
        dynamicItems = []
        if (!available) return
        const loans = AppModel.assignableLoans
        if (!loans.length) {
            // Only loans created in GiroCrab (Neues Darlehen) can take bookings; say so (#429).
            const items = [noteItem.createObject(null), separator.createObject(null)]
            items.forEach((it, i) => insertItem(i, it))
            dynamicItems = items
            return
        }
        const link = AppModel.loanLink(booking)
        const current = link ? link.loan_account_id : null
        const items = [pickItem.createObject(null, { text: qsTr("Keinem Darlehen"), loanId: null, checked: current === null })]
        for (const l of loans)
            items.push(pickItem.createObject(null, { text: l.setup.name, loanId: l.account_id, checked: current === l.account_id }))
        items.push(separator.createObject(null))
        items.forEach((it, i) => insertItem(i, it))
        dynamicItems = items
    }
    Component {
        id: pickItem
        AppMenuItem {
            property var loanId: null
            checkable: true
            onTriggered: AppModel.assignLoan(loanId, menu.booking)
        }
    }
    Component { id: separator; AppMenuSeparator {} }
    Component { id: noteItem; AppMenuItem { text: qsTr("Keine manuellen Darlehen angelegt"); enabled: false } }

    AppMenuItem {
        text: qsTr("Neues Darlehen aus dieser Buchung …")
        onTriggered: AppModel.openLoanEditorFromBooking(menu.booking)
    }
}
