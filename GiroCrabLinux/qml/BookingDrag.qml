pragma Singleton
import QtQuick

// BookingCategoryMenu.swift › BookingDrag (#366): bookings dragged from the list onto a sidebar
// category. The drag image (BookingStreamView) carries the key below; only BookingDropTarget
// (category rows) accepts it, the sidebar's account and group drop zones use other keys.
QtObject {
    readonly property string key: "girocrab-bookings"
    /// Ids of the dragged bookings (the multiple selection when the row is part of it); [] = none.
    property var ids: []
    readonly property bool active: ids.length > 0
    property string label: ""
    property point scenePos: Qt.point(0, 0)

    function start(booking) {
        const list = BookingDetails.categorizeTargets(booking)
        label = list.length > 1 ? qsTr("%1 Buchungen").arg(list.length) : (booking.merchant.name || booking.booking_text)
        ids = list.map(b => b.id)
    }
    function end() { ids = [] }

    /// AppModel+Editing.swift › dropBookings(_:onCategory:): false when no loaded booking is dragged.
    function dropOnCategory(categoryID) {
        const dropped = ids.map(id => AppModel.bookingByID(id)).filter(b => b !== null)
        if (!dropped.length) return false
        AppModel.setCategoryFor(dropped, categoryID)
        return true
    }
}
