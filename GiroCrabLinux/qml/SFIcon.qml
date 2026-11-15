import QtQuick
import org.kde.kirigami as Kirigami

// Image(systemName:) – an SF Symbol name drawn with the matching Breeze icon,
// tinted like a template image.
Kirigami.Icon {
    property string symbol: ""
    property int size: 14
    source: SF.icon(symbol)
    // older Breeze versions without the "-symbolic" variant
    fallback: source.toString().endsWith("-symbolic") ? source.toString().replace(/-symbolic$/, "") : "tag"
    implicitWidth: size
    implicitHeight: size
    isMask: true
    color: Theme.secondary
}
