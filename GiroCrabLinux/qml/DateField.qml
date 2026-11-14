import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// DatePicker(…, displayedComponents: .date) in the compact style: day / month / year
// steppers, clamped to the allowed range (CustomPeriodForm, LoanEditorSheet, OpeningBalanceSheet).
RowLayout {
    id: df
    property date date
    property var minimum: null
    property var maximum: null
    signal picked(date d)
    spacing: 4
    function clamp(d) {
        if (minimum && d < minimum) return new Date(minimum)
        if (maximum && d > maximum) return new Date(maximum)
        return d
    }
    function setParts(y, m, day) {
        const last = new Date(y, m + 1, 0).getDate()
        picked(clamp(new Date(y, m, Math.min(day, last))))
    }
    SpinBox {
        from: 1; to: new Date(df.date.getFullYear(), df.date.getMonth() + 1, 0).getDate(); editable: true
        value: df.date.getDate(); implicitWidth: 110
        onValueModified: df.setParts(df.date.getFullYear(), df.date.getMonth(), value)
    }
    AppComboBox {
        implicitWidth: 120
        model: [...Array(12).keys()].map(m => Fmt.locale.standaloneMonthName(m, Locale.LongFormat))
        currentIndex: df.date.getMonth()
        onActivated: i => df.setParts(df.date.getFullYear(), i, df.date.getDate())
    }
    SpinBox {
        from: 1990; to: 2100; editable: true
        value: df.date.getFullYear(); implicitWidth: 130
        textFromValue: v => String(v); valueFromText: t => Number(t)
        onValueModified: df.setParts(value, df.date.getMonth(), df.date.getDate())
    }
}
