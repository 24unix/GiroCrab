import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

// PlanningUI.swift › BudgetProgressCard. Folds to its title row with the total spent / budget
// and one bar (GitHub #603).
Card {
    id: card
    // ViewLayout.cardPadding / cardVerticalPadding(collapsed:)
    padding: 12
    verticalPadding: collapsed ? 4 : 12
    /// `@AppStorage(ViewLayout.budgetsCollapsedKey)`
    readonly property bool collapsed: layout.budgetsCollapsed
    property Settings layout: Settings { property bool budgetsCollapsed: false }
    readonly property real totalSpent: AppModel.budgets.reduce((t, s) => t + s.spent_cents, 0)
    readonly property real totalBudget: AppModel.budgets.reduce((t, s) => t + s.budget_cents, 0)
    readonly property real totalPercent: totalBudget > 0 ? totalSpent / totalBudget * 100 : 0
    /// BudgetTone.color: green < 80 %, yellow 80–100 %, red > 100 %.
    function tone(p) { return p > 100 ? Theme.negative : (p >= 80 ? Theme.warning : Theme.inflow) }
    ColumnLayout {
        width: parent.width
        spacing: 8   // ViewLayout.cardSpacing
        RowLayout {
            Layout.fillWidth: true
            CardChevron { collapsed: card.collapsed; onToggled: card.layout.budgetsCollapsed = !card.collapsed }
            Text { text: qsTr("Monatsbudgets"); font.pixelSize: Theme.subheadline + 1; font.weight: Font.DemiBold; color: Theme.text; Layout.fillWidth: true }
            // folded: all budgets together
            Text {
                visible: card.collapsed && AppModel.budgets.length > 0
                text: Fmt.money(card.totalSpent) + " / " + Fmt.money(card.totalBudget)
                font.pixelSize: Theme.subheadline + 1; font.weight: Font.DemiBold; font.features: { "tnum": 1 }
                color: card.tone(card.totalPercent)
                Sensitive { amounts: true }
            }
            BudgetBar { visible: card.collapsed && AppModel.budgets.length > 0; percent: card.totalPercent; Layout.preferredWidth: 60 }
            IconButton {
                visible: !card.collapsed
                text: qsTr("Budget hinzufügen"); symbol: "plus.circle"; symbolSize: 14
                display: AbstractButton.TextBesideIcon; flat: true
                onClicked: addMenu.popup()
                AppMenu {
                    id: addMenu
                    Repeater { model: addMenu.visible ? AppModel.categories.filter(c => c.budget_cents === null) : []; AppMenuItem { required property var modelData; text: modelData.path; onTriggered: AppModel.budgetCategoryID = modelData.id } }
                }
            }
        }
        Text {
            visible: !card.collapsed && AppModel.budgets.length === 0
            text: qsTr("Noch keine Budgets. Legen Sie über das Kontextmenü einer Kategorie ein Monatsbudget fest.")
            font.pixelSize: Theme.caption; color: Theme.secondary; wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Repeater {
            model: card.collapsed ? [] : AppModel.budgets
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 4
                // Button { editing = IDBox(id: s.categoryId) }
                TapHandler { onTapped: AppModel.budgetCategoryID = modelData.category_id }
                TapHandler { acceptedButtons: Qt.RightButton; onTapped: budgetMenu.popup() }
                HoverHandler { id: rowHover }
                ToolTip.visible: rowHover.hovered; ToolTip.delay: 600; ToolTip.text: qsTr("Budget bearbeiten …")
                // the Mac row is a Button that merges its children and keeps the bar's value (#571)
                Accessible.role: Accessible.Button
                Accessible.name: AppModel.masking(modelData.name, AppModel.redactLabels) + ", "
                    + AppModel.masking(Fmt.money(modelData.spent_cents) + " / " + Fmt.money(modelData.budget_cents), AppModel.redactAmounts)
                Accessible.description: card.spokenValue(modelData.percent)
                Accessible.onPressAction: AppModel.budgetCategoryID = modelData.category_id
                AppMenu { id: budgetMenu
                    AppMenuItem { text: qsTr("Budget bearbeiten …"); icon.name: SF.icon("pencil"); onTriggered: AppModel.budgetCategoryID = modelData.category_id }
                    AppMenuItem { text: qsTr("Budget entfernen"); icon.name: SF.icon("trash"); onTriggered: AppModel.setBudget(null, modelData.category_id) } }
                RowLayout {
                    Text { text: modelData.name; font.pixelSize: Theme.callout + 1; color: Theme.text; Layout.fillWidth: true; Sensitive { labels: true } }
                    Text { text: Fmt.money(modelData.spent_cents) + " / " + Fmt.money(modelData.budget_cents); font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: card.tone(modelData.percent); Sensitive { amounts: true } }
                    // shows the row opens the editor (it looked read-only)
                    SFIcon { symbol: "pencil"; size: Theme.caption; opacity: rowHover.hovered ? 1 : 0 }
                }
                BudgetBar { Layout.fillWidth: true; percent: modelData.percent }
            }
        }
    }

    /// BudgetBar.spokenValue: "85 % des Budgets verbraucht"; over budget (red bar) is never spoken as 100 %.
    function spokenValue(percent) {
        const rounded = Math.round(percent)
        return percent > 100 ? qsTr("%1 % des Budgets verbraucht, überschritten").arg(Math.max(rounded, 101))
                             : qsTr("%1 % des Budgets verbraucht").arg(Math.min(rounded, 100))
    }

    // PlanningUI.swift › BudgetBar: capsule in the tone of the share spent.
    component BudgetBar: Rectangle {
        property real percent: 0
        Accessible.role: Accessible.ProgressBar
        Accessible.name: qsTr("Budgetverbrauch")
        Accessible.description: card.spokenValue(percent)
        implicitHeight: 6; radius: 3; color: Theme.border
        Rectangle { height: 6; radius: 3; color: card.tone(parent.percent); width: parent.width * Math.min(Math.max(parent.percent, 0), 100) / 100 }
    }
}
