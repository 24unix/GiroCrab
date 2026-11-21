pragma Singleton
import QtQuick

// AppModel.swift › scrollFocusDay / chartHoverDay / streamHighlightDay (#593): the balance
// chart follows the booking list. BookingStreamView reports the day at the top edge of the
// scrolled list (and the day of a selected booking), BalanceChart puts its marker there and
// reports the day under the pointer; the list highlights the day header both point to.
QtObject {
    /// Day (`yyyy-MM-dd`) at the top edge of the booking stream while scrolling; "" = the
    /// stream is at the top or not scrolled yet.
    property string scrollFocusDay: ""
    /// Day under the mouse pointer in the balance chart; "" = none.
    property string chartHoverDay: ""
    /// AppModel+Loading.swift › updateStreamHighlight: the hovered chart day (or the nearest
    /// earlier day with bookings), else the day at the top of the scrolled list.
    readonly property string highlightDay: {
        const day = chartHoverDay || scrollFocusDay
        if (!day) return ""
        const g = AppModel.dayGroups.find(g => g.date <= day)   // newest first
        return g ? g.date : ""
    }
}
