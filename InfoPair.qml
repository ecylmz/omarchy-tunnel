import QtQuick
import QtQuick.Layouts
import qs.Commons

RowLayout {
  id: root

  property string label: ""
  property string value: ""

  width: parent ? parent.width : implicitWidth
  spacing: Style.space(10)

  Text {
    Layout.preferredWidth: Style.space(92)
    text: root.label
    color: Qt.darker(Color.foreground, 1.55)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }

  Text {
    Layout.fillWidth: true
    text: root.value
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideMiddle
  }
}
