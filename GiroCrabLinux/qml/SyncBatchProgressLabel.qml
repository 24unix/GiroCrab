import QtQuick

// "Bankzugang 2 von 5" while "Alle abrufen" runs.
Text {
    visible: AppModel.syncBatchProgress !== null
    text: AppModel.syncBatchProgress ? qsTr("Bankzugang %1 von %2").arg(AppModel.syncBatchProgress.current).arg(AppModel.syncBatchProgress.total) : ""
    font.pixelSize: Theme.caption; font.features: { "tnum": 1 }; color: Theme.secondary
}
