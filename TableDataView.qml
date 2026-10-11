import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Sqlite_UI // 用同模块里的 AppButton

// 数据表格：显示「表名」里的数据，并支持新增 / 修改 / 删除。
//
// 依赖 main.cpp 注入的上下文对象 explorer：表格模型由 explorer.openTable() 创建，
// 通过 explorer.sessionTable 暴露出来（每换一个数据库就换一个模型实例）。
//
// 用 FocusScope 作为根节点（而不是 Item）：里面有可编辑子项（单元格的编辑框），
// 需要焦点能在「pane 自己」和「编辑框」之间来回给。双击进编辑 / 失焦收编辑都靠它。
FocusScope {
    id: pane

    focus: true
    activeFocusOnTab: true

    // 下面三个由 Main.qml 在打开表时赋值，用于标题栏显示
    property string databaseName: ""
    property string tableName: ""
    property bool isView: false

    // 每次点新表都自增，用来强制把表格滚回顶部
    property int loadSerial: 0

    // 当前表的数据模型；未打开表时为 null
    readonly property var dataModel: explorer.sessionTable

    readonly property bool loaded: dataModel !== null && dataModel.loaded
    readonly property bool editable: dataModel !== null && dataModel.canEdit
    readonly property bool dirty: dataModel !== null && dataModel.dirtyCount > 0

    // 当前光标在哪一行。Qt 6.9 的 TableView.currentRow/currentColumn 是只读的，
    // 直接绑 selectionModel.currentIndex 又不会重新求值（currentIndex 变化不发
    // dataChanged），所以干脆在 delegate 点击时自己记一份。
    property int cursorRow: -1
    property int cursorColumn: -1

    // 是否处于「编辑某个单元格」状态（编辑框显示 / 隐藏由它控制）
    property bool editorOpen: false

    // ======================= Toast（操作反馈提示条） =======================
    // 三种色调：info 灰 / success 绿 / error 红
    ListModel { id: toastModel }

    // 由 TableModel 的 error 处理里置位，避免同一条错误弹两次
    property bool suppressExplorerToast: false

    function toast(text, kind) {
        if (!text || String(text).length === 0)
            return
        if (kind === undefined)
            kind = "info"
        // 出错时把之前攒的提示都清掉，避免盖住错误
        if (kind === "error")
            toastModel.clear()
        toastModel.append({ "text": String(text), "kind": kind })
        // 最多同时显示 3 条
        while (toastModel.count > 3)
            toastModel.remove(0)
        toastTimer.restart()
    }

    // explorer 层的错误（打开数据库失败、路径不合法等）→ 红色 toast
    Connections {
        target: explorer

        function onLastErrorChanged() {
            if (pane.suppressExplorerToast)
                return
            if (explorer.lastError.length > 0)
                pane.toast(explorer.lastError, "error")
        }
    }

    Timer {
        id: toastTimer
        interval: 2600
        onTriggered: toastModel.clear()
    }

    // ============ 点表格空白处（没有单元格的地方）→ 刷新表格视图 ============
    // 只做「视图层刷新」：滚动复位 + 清除高亮 + **退出编辑态**；
    // 有未保存改动时不动数据，避免误丢。
    //
    // 退出编辑态的做法：编辑框的 visible 绑在 activeFocus 上，
    // 只要把焦点收回到 TableView 本身（点空白处本来也没有别的控件需要焦点），
    // 编辑框就会自己隐藏，同时 TextField 会发出 editingFinished 把改动写回模型。
    function refreshView() {
        endEditing()
        table.contentX = 0
        table.contentY = 0
        pane.cursorRow = -1
        pane.cursorColumn = -1
        if (table.selectionModel)
            table.selectionModel.clearCurrentIndex()
    }

    // 让当前正在编辑的单元格失焦（编辑框隐藏 + 改动提交到模型）
    function endEditing() {
        if (pane.editorOpen) {
            pane.editorOpen = false
            pane.forceActiveFocus()
        }
    }

    // 换表时把表格视图复位
    onLoadSerialChanged: {
        endEditing()
        table.contentX = 0
        table.contentY = 0
        pane.cursorRow = -1
        pane.cursorColumn = -1
        if (table.selectionModel)
            table.selectionModel.clearCurrentIndex()
        // 换表后强制重排一次：列的几何宽度定了，上面自绘表头才能和列对上
        table.forceLayout()
    }

    // 表格视图自己的报错 → 红色弹窗 + 顶部红条。
    // 用 error 信号而不是 message 属性：message 是表头那句常驻提示
    //（"可以编辑，改完记得点「保存」"），报错时它并不会变，拿它当错误文案会显示错内容。
    Connections {
        target: pane.dataModel

        function onError(message) {
            pane.suppressExplorerToast = true // 下面那次 lastError 变化不再重复弹
            explorer.reportError(message)
            pane.suppressExplorerToast = false
            pane.toast(message, "error")
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------------------ 标题栏
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 38
            color: "#f7f8fa"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 12
                spacing: 8

                Label {
                    text: pane.isView ? "◫" : "▦"
                    color: pane.isView ? "#8b919b" : "#2f6fd0"
                    font.pixelSize: 12
                }

                Label {
                    text: pane.tableName.length > 0 ? pane.tableName : qsTr("(未选择表)")
                    color: "#1f2328"
                    font.pixelSize: 13
                    font.bold: true
                    elide: Text.ElideRight
                }

                Label {
                    text: qsTr("· %1").arg(pane.databaseName)
                    color: "#8b919b"
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }

                Item { Layout.fillWidth: true }

                Label {
                    text: qsTr("%1 行").arg(dataModel ? dataModel.rowCountValue : 0)
                    color: "#7a828c"
                    font.pixelSize: 11
                }

                Rectangle {
                    visible: pane.dirty
                    implicitWidth: dirtyLabel.implicitWidth + 14
                    implicitHeight: 20
                    radius: 10
                    color: "#fff3d6"
                    border.color: "#f0d190"

                    Label {
                        id: dirtyLabel
                        anchors.centerIn: parent
                        text: qsTr("%1 行待保存").arg(dataModel ? dataModel.dirtyCount : 0)
                        color: "#8a5a00"
                        font.pixelSize: 11
                    }
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#e3e6ea"
            }
        }

        // ------------------------------------------------------------ 工具条
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 42
            color: "#ffffff"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 7

                // 新增 = 蓝色（主操作）
                AppButton {
                    text: qsTr("＋ 新增行")
                    tone: "primary"
                    enabled: pane.editable
                    onClicked: {
                        // 失败时模型会发 error 信号，由上面的 Connections 弹红色 toast
                        if (dataModel.addRow())
                            pane.toast("已新增一行（记得点「保存」写回文件）", "info")
                    }
                }

                // 删除 = 红色（危险操作）
                AppButton {
                    text: qsTr("－ 删除选中行")
                    tone: "danger"
                    enabled: pane.editable && pane.cursorRow >= 0
                    onClicked: {
                        if (dataModel.removeRowAt(pane.cursorRow)) {
                            pane.toast(qsTr("已标记删除第 %1 行（保存后生效）").arg(pane.cursorRow + 1),
                                       "info")
                            pane.cursorRow = -1
                            pane.cursorColumn = -1
                        }
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 20
                    Layout.leftMargin: 3
                    Layout.rightMargin: 3
                    color: "#e3e6ea"
                }

                // 保存 = 绿色（确认写入）
                AppButton {
                    text: qsTr("保存")
                    tone: "success"
                    enabled: pane.editable && pane.dirty
                    onClicked: {
                        var changed = dataModel.dirtyCount
                        if (dataModel.save())
                            pane.toast(qsTr("已保存 %1 行改动到数据库文件").arg(changed), "success")
                    }
                }

                AppButton {
                    text: qsTr("放弃修改")
                    tone: "neutral"
                    enabled: pane.editable && pane.dirty
                    onClicked: {
                        dataModel.discardChanges()
                        pane.toast("已放弃未保存的改动", "info")
                    }
                }

                AppButton {
                    text: qsTr("刷新")
                    tone: "neutral"
                    enabled: pane.loaded
                    onClicked: {
                        dataModel.reload()
                        pane.toast("表格已重新读取", "info")
                    }
                }

                Item { Layout.fillWidth: true }

                Label {
                    text: dataModel ? dataModel.message : ""
                    color: pane.editable ? "#7a828c" : "#b06a00"
                    font.pixelSize: 11
                    elide: Text.ElideRight
                    Layout.maximumWidth: 320
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#e3e6ea"
            }
        }

        // ------------------------------------------------------------ 表格
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            // 列头（跟着表格一起横向滚动）
            Row {
                x: 46 - table.contentX
                y: 0
                height: 30
                visible: pane.loaded

                Repeater {
                    model: dataModel && dataModel.loaded ? dataModel.columnCount() : 0

                    Rectangle {
                        required property int index

                        readonly property bool isRequired: dataModel
                                                           && dataModel.columnIsRequired(index)

                        // 宽度跟着 TableView 的真实列宽走 —— 拖动表头改列宽后会自动同步。
                        // 列还没加载完时 columnWidth() 返回 -1，退回到 delegate 的初始宽 150。
                        readonly property real liveWidth: {
                            var w = table ? table.columnWidth(index) : -1
                            return w > 0 ? w : 150
                        }

                        width: liveWidth
                        height: 30
                        color: "#f7f8fa"
                        border.color: "#e3e6ea"

                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            spacing: 4
                            clip: true

                            Text {
                                text: dataModel.columnIsPrimaryKey(index) ? "🔑" : ""
                                font.pixelSize: 10
                            }
                            Text {
                                text: dataModel.columnName(index)
                                color: "#1f2328"
                                font.pixelSize: 12
                                font.bold: true
                                elide: Text.ElideRight
                            }
                            // 必填列（NOT NULL 且无默认值）标个红星
                            Text {
                                visible: isRequired
                                text: "*"
                                color: "#d9363e"
                                font.pixelSize: 13
                                font.bold: true
                            }
                        }

                        ToolTip.visible: headerHover.hovered
                        ToolTip.text: {
                            var t = dataModel.columnName(index) + "  " + dataModel.columnType(index)
                            if (dataModel.columnIsPrimaryKey(index))
                                t += "  [主键]"
                            if (dataModel.columnDefault(index).length > 0)
                                t += "  默认值: " + dataModel.columnDefault(index)
                            if (isRequired)
                                t += "\n必填（NOT NULL 且无默认值），留空会保存失败"
                            return t
                        }
                        ToolTip.delay: 300

                        HoverHandler { id: headerHover }
                    }
                }
            }

            // 行号列（跟着表格一起纵向滚动）
            Column {
                x: 0
                y: 30 - table.contentY
                width: 46
                visible: pane.loaded

                Repeater {
                    model: dataModel && dataModel.loaded ? dataModel.rowCountValue : 0

                    Rectangle {
                        required property int index

                        width: 46
                        height: 30
                        color: index === pane.cursorRow ? "#e8f0fc" : "#fafbfc"
                        border.color: "#e3e6ea"

                        Label {
                            anchors.centerIn: parent
                            text: index + 1
                            color: "#8b919b"
                            font.pixelSize: 11
                        }
                    }
                }
            }

            // 点表格空白处（没有单元格的位置）→ 刷新表格视图。
            //
            // 为什么用 TapHandler 而不是 MouseArea：TableView 的
            // QQuickTableViewPointerHandler 带 setGrabPermissions(CanTakeOverFromAnything)，
            // 会把内容区的指针事件在到达任何子项 / 兄弟 MouseArea 之前抢走
            // （实测装在 TableView 里和它下面的 MouseArea 连 onPressed 都收不到）。
            // TapHandler 同为 pointer handler，用同样的权限就能抢回事件。
            //
            // 为什么不用自己写命中测试：单元格上的点击会被 delegate 的 tap handler
            // 先接走，TapHandler 只在空白处触发（实测点单元格时它完全不触发），
            // 所以只要「触发即空白」。cellAtPosition 的兜底判断留着更稳。
            TapHandler {
                id: blankTap

                parent: table
                gesturePolicy: TapHandler.WithinBounds
                grabPermissions: PointerHandler.CanTakeOverFromAnything

                onTapped: function (eventPoint) {
                    var pos = table.mapFromItem(blankTap.parent, eventPoint.position)
                    var hit = table.cellAtPosition(pos.x, pos.y)
                    if (hit.x >= 0 && hit.y >= 0)
                        return // 兜底：万一落在单元格上就不动，交给 delegate

                    pane.refreshView()
                    if (pane.dirty)
                        pane.toast(qsTr("视图已刷新（还有 %1 行未保存改动）").arg(dataModel.dirtyCount),
                                   "info")
                    else
                        pane.toast("视图已刷新", "info")
                }
            }

            TableView {
                id: table

                anchors.left: parent.left
                anchors.leftMargin: 46
                anchors.top: parent.top
                anchors.topMargin: 30
                anchors.right: parent.right
                anchors.bottom: parent.bottom

                clip: true
                model: pane.dataModel
                boundsBehavior: Flickable.StopAtBounds
                selectionModel: ItemSelectionModel {}

                pointerNavigationEnabled: false

                ScrollBar.vertical: ScrollBar { id: vbar }
                ScrollBar.horizontal: ScrollBar { id: hbar }

                delegate: ItemDelegate {
                    id: cell

                    required property int row
                    required property int column

                    readonly property bool isCurrentCell: pane.cursorRow === row
                                                          && pane.cursorColumn === column
                    readonly property bool rowDirty: model ? model.dirty === true : false

                    readonly property string cellText: model && model.display !== undefined
                                                       && model.display !== null
                                                       ? String(model.display) : ""

                    implicitWidth: 150
                    implicitHeight: 30
                    padding: 0

                    background: Rectangle {
                        color: cell.isCurrentCell ? "#dce9fb"
                               : cell.rowDirty ? "#fff6e0"
                               : cell.hovered ? "#f2f6fd" : "#ffffff"
                        Rectangle {
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            width: 1
                            height: parent.height
                            color: "#eef0f3"
                        }
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 1
                            color: "#eef0f3"
                        }
                    }

                    contentItem: Item {
                        anchors.fill: parent

                        // 普通显示
                        Label {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 6
                            verticalAlignment: Text.AlignVCenter
                            visible: !(editor.visible && editor.activeFocus)
                            text: cell.cellText
                            color: cell.cellText === "(NULL)" ? "#a0a6b0" : "#1f2328"
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }

                        // 编辑中（双击进入）
                        TextField {
                            id: editor

                            anchors.fill: parent
                            anchors.leftMargin: 4
                            anchors.rightMargin: 4
                            visible: pane.editorOpen && cell.isCurrentCell && activeFocus
                            text: cell.cellText
                            font.pixelSize: 12
                            leftPadding: 6
                            rightPadding: 6
                            topPadding: 0
                            bottomPadding: 0
                            verticalAlignment: TextInput.AlignVCenter
                            horizontalAlignment: TextInput.AlignHCenter
                            selectByMouse: true

                            onTextEdited: pane.dataModel.editCell(row, column, text)
                            onEditingFinished: pane.editorOpen = false

                            Keys.onEscapePressed: {
                                text = cell.cellText // 回滚成原值
                                pane.editorOpen = false
                                table.forceActiveFocus()
                            }
                            Keys.onReturnPressed: pane.endEditing()
                            Keys.onEnterPressed: pane.endEditing()
                        }
                    }

                    onClicked: {
                        if (pane.editorOpen && !cell.isCurrentCell)
                            pane.endEditing() // 点到别的格子 = 结束上一个编辑
                        pane.cursorRow = row
                        pane.cursorColumn = column
                    }

                    onDoubleClicked: {
                        pane.cursorRow = row
                        pane.cursorColumn = column
                        if (pane.editable) {
                            pane.editorOpen = true
                            editor.forceActiveFocus()
                            Qt.callLater(function () { editor.selectAll() })
                        }
                    }
                }
            }

            // 空表提示
            Label {
                anchors.centerIn: parent
                visible: pane.loaded && dataModel && dataModel.rowCountValue === 0
                text: pane.editable ? qsTr("这张表还没有数据，点「＋ 新增行」加一行")
                                    : qsTr("这张表还没有数据")
                color: "#8b919b"
                font.pixelSize: 12
            }

            // 没选表时的占位
            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width - 60, 360)
                spacing: 8
                visible: !pane.loaded

                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("在左边点一张表，这里显示数据")
                    color: "#7a828c"
                    font.pixelSize: 13
                }
                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: qsTr("双击单元格修改，改完点「保存」写回数据库文件。\n没有主键的表和视图只能查看。")
                    color: "#8b919b"
                    font.pixelSize: 11
                }
            }
        }
    }

    // ======================= Toast 显示层（右下角堆叠） =======================
    Column {
        id: toastColumn

        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 16
        spacing: 8
        z: 100

        Repeater {
            model: toastModel

            Rectangle {
                id: toastItem

                required property string text
                required property string kind
                required property int index

                readonly property bool isError: kind === "error"
                readonly property bool isSuccess: kind === "success"

                width: Math.min(Math.max(toastLabel.implicitWidth + 34, 180),
                                Math.max(220, pane.width - 80))
                height: Math.max(toastLabel.implicitHeight + 18, 34)
                radius: 7
                // 错误红底 / 成功绿底 / 其余深灰底
                color: isError ? "#d9363e" : (isSuccess ? "#18973f" : "#3b4250")
                opacity: 0
                scale: 0.96

                Component.onCompleted: appear.start()

                ParallelAnimation {
                    id: appear
                    NumberAnimation { target: toastItem; property: "opacity"; to: 0.97; duration: 160 }
                    NumberAnimation { target: toastItem; property: "scale"; to: 1.0; duration: 160;
                                      easing.type: Easing.OutBack }
                }

                Row {
                    id: toastRow

                    anchors.centerIn: parent
                    spacing: 7

                    Label {
                        anchors.verticalCenter: parent.verticalCenter
                        text: toastItem.isError ? "✕" : (toastItem.isSuccess ? "✓" : "ⓘ")
                        color: "#ffffff"
                        font.pixelSize: 13
                        font.bold: true
                    }

                    Label {
                        id: toastLabel

                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, Math.max(180, pane.width - 120))
                        text: toastItem.text
                        color: "#ffffff"
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                }

                // 点一下可以马上关掉
                MouseArea {
                    anchors.fill: parent
                    onClicked: toastModel.remove(toastItem.index)
                }
            }
        }
    }
}
