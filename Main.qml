import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Sqlite_UI

ApplicationWindow {
    id: root

    // ============================ 窗口尺寸 ============================
    // ↓↓↓ 想改默认大小就改这两行 ↓↓↓
    // 启动时如果 QSettings 里存过尺寸，会用存的值覆盖这里（见下面的 onCompleted）
    width: 1420
    height: 860

    Component.onCompleted: {
        // 恢复上次的窗口尺寸
        var w = explorer.savedWindowWidth()
        var h = explorer.savedWindowHeight()
        if (w > 0)
            root.width = w
        if (h > 0)
            root.height = h

        // 打开命令行指定的数据库
        if (root.initialDatabase.length > 0)
            root.openPath(root.initialDatabase)
    }
    // 最小尺寸（拖拽不能小于这个）
    minimumWidth: 900
    minimumHeight: 560
    visible: true
    title: qsTr("SQLite View")

    // ------------------------------------------------------------ 配色
    readonly property color cAccent: "#2f6fd0"
    readonly property color cAccentSoft: "#e8f0fc"
    readonly property color cLine: "#e3e6ea"
    readonly property color cText: "#1f2328"
    readonly property color cTextDim: "#7a828c"
    readonly property color cPanel: "#ffffff"

    // ------------------------------------------------------ 当前选中的节点
    property string selectedLabel: ""
    property string selectedKind: "" // "" | "database" | "table" | "view"
    property string selectedPath: ""
    property string selectedInfo: ""
    // 选中的表节点所属的库文件名（左侧选中高亮要区分同名表）
    property string selectedDatabaseName: ""

    // 记住哪些数据库被展开过（key = 文件绝对路径），模型重建后自动恢复
    property var expandedKeys: ({})

    // 勾上以后打开数据库时用文件级只读（这时候表不能编辑）
    property bool openReadOnly: false

    // 当前表格里打开的是哪张表（切换表 / 放弃修改时用来复位）
    property string openTablePath: ""
    property string openDatabaseName: ""
    property string openTableName: ""
    property bool openTableIsView: false

    // 用户在确认框里点了「放弃修改」之后要执行的动作
    property var pendingPicker: null

    // main.cpp 用命令行参数指定要自动打开的库，这里读一次
    property string initialDatabase: (typeof initialDatabasePath !== "undefined")
                                     ? initialDatabasePath : ""

    function markExpanded(key) {
        if (!key || key.length === 0)
            return
        var copy = {}
        for (var k in root.expandedKeys)
            copy[k] = true
        copy[key] = true
        root.expandedKeys = copy
    }

    function isExpandedNode(key) {
        return root.expandedKeys[key] === true
    }

    function selectNode(label, kind, path, info, dbName) {
        root.selectedLabel = label
        root.selectedKind = kind
        root.selectedPath = path
        root.selectedInfo = info
        root.selectedDatabaseName = dbName === undefined ? "" : dbName
    }

    function clearSelection() {
        root.selectNode("", "", "", "", "")
    }

    // SQL 控制台默认操作哪个库：
    // 优先「当前打开的表」所在的库，其次是左侧选中的库，最后是第一个打开的库。
    function sqlTargetConnection() {
        var session = explorer.sessionTable
        if (session && session.connectionName && session.connectionName.length > 0)
            return session.connectionName
        if (root.selectedKind === "database" && root.selectedPath.length > 0) {
            var conn = explorer.connectionNameForPath(root.selectedPath)
            if (conn.length > 0)
                return conn
        }
        return explorer.databaseCount > 0 ? explorer.connectionNameAt(0) : ""
    }

    function openSqlConsole() {
        if (explorer.databaseCount === 0)
            return
        sqlConsole.preferredConnection = root.sqlTargetConnection()
        sqlConsole.showConsole()
    }

    function baseName(path) {
        var parts = String(path).replace(/\\/g, "/").split("/")
        return parts[parts.length - 1]
    }

    // 展开所有已打开的数据库节点，并记住它们
    function expandAll() {
        for (var i = 0; i < explorer.databaseCount; ++i) {
            var path = explorer.databasePathAt(i)
            root.markExpanded(path)
            var idx = explorer.treeModel.index(i, 0)
            if (idx.valid)
                tree.expand(idx)
        }
    }

    // 传进来的可能是本地路径，也可能是 "file:///..." 形式的 url
    // （FileDialog.selectedFile / DropArea 的 urls 都是 url），统一成路径
    function toLocalPath(value) {
        var s = String(value === undefined || value === null ? "" : value)
        if (s.length === 0)
            return ""
        if (s.substr(0, 5).toLowerCase() !== "file:")
            return s // 已经是普通路径
        var p = s.substr(7) // 去掉 "file://"
        while (p.length > 0 && p.charAt(0) === "/")
            p = p.substr(1) // 去掉多余的前导 "/"（Windows 上 /D:/x -> D:/x）
        p = p.replace(/\//g, "\\")
        try {
            return decodeURIComponent(p)
        } catch (e) {
            return p // 路径里出现单独的 % 时 decodeURIComponent 会抛异常，原样返回
        }
    }

    // 打开一个数据库文件（拖放、命令行参数、文件对话框都用它）
    function openPath(path) {
        if (!path || path.length === 0)
            return
        if (explorer.openDatabaseFile(path, root.openReadOnly))
            return true
        return false
    }

    function openTableIn(path, dbName, label, kind, connection) {
        var conn = (connection && connection.length > 0)
                ? connection : explorer.connectionNameForPath(path)
        if (conn.length === 0) {
            explorer.reportError(qsTr("找不到 %1 对应的连接").arg(path))
            return true
        }

        var view = (kind === "view")
        var sameTable = explorer.sessionTable && explorer.sessionTable.loaded && explorer.sessionTable.tableName === label
                && explorer.sessionTable.connectionName === conn
        if (!sameTable && explorer.sessionTable && explorer.sessionTable.dirtyCount > 0) {
            pendingPicker = function () {
                root.switchTable(path, dbName, label, view, conn)
            }
            discardDialog.open()
            return false
        }

        root.switchTable(path, dbName, label, view, conn)
        return true
    }

    function switchTable(path, dbName, label, view, connection) {
        tableView.tableName = label
        tableView.databaseName = dbName
        tableView.isView = view
        if (explorer.openTable(connection, label, view)) {
            tableView.loadSerial++
            root.rememberOpenTable(path, dbName, label, view)
        }
    }

    function rememberOpenTable(path, dbName, label, view) {
        root.openTablePath = path
        root.openDatabaseName = dbName
        root.openTableName = label
        root.openTableIsView = view
    }

    // 用户在确认框里选了「放弃修改」→ 关掉当前表，再打开他点的那张
    function discardAndContinue() {
        if (explorer.sessionTable)
            explorer.sessionTable.close()
        if (pendingPicker) {
            pendingPicker()
            pendingPicker = null
        }
    }

    // 选了「取消」→ 回到原来那张表（重新读一遍，改动丢弃）
    function keepCurrentTable() {
        pendingPicker = null
        if (root.openTablePath.length === 0)
            return
        root.openTableIn(root.openTablePath, root.openDatabaseName,
                         root.openTableName, root.openTableIsView ? "view" : "table")
    }

    // 后端成功打开数据库后：记住它、展开它、选中它
    Connections {
        target: explorer

        function onDatabaseOpened(path) {
            root.markExpanded(path)
            root.expandAll()
            root.selectNode(root.baseName(path), "database", path,
                            explorer.databaseInfoAt(explorer.databaseCount - 1),
                            root.baseName(path))
        }

        // 左树模型被重建了（刷新 / 关库 / 控制台里建表删表）。
        // 重建之后 TreeView 不会自己把展开过的库重新排出来，肉眼看到的是
        // 「箭头是展开的、下面一行都没有」，所以要再推一下：强制重排 + 重新展开。
        function onTablesChanged() {
            Qt.callLater(function () {
                tree.forceLayout()
                root.expandAll()
            })
        }
    }

    onClosing: {
        explorer.saveWindowSize(root.width, root.height) // 记住这次的窗口尺寸
        explorer.closeAll()
    }

    FileDialog {
        id: openDialog

        title: qsTr("选择 SQLite 数据库文件")
        nameFilters: [
            qsTr("SQLite 数据库 (*.db *.sqlite *.sqlite3 *.db3)"),
            qsTr("所有文件 (*)")
        ]
        onAccepted: root.openPath(root.toLocalPath(selectedFile))
    }

    // 从资源管理器把文件拖进来
    DropArea {
        anchors.fill: parent
        onDropped: function (drop) {
            if (drop.hasUrls && drop.urls.length > 0)
                root.openPath(root.toLocalPath(drop.urls[0]))
        }
    }

    // Ctrl+E：打开 SQL 控制台（和工具条上那个按钮一样）
    Shortcut {
        sequence: "Ctrl+E"
        enabled: explorer.databaseCount > 0 && !sqlConsole.visible
        onActivated: root.openSqlConsole()
    }

    // 切表前发现当前表有未保存的改动
    Dialog {
        id: discardDialog

        anchors.centerIn: parent
        width: 380
        modal: true
        title: qsTr("有未保存的改动")
        standardButtons: Dialog.Discard | Dialog.Cancel

        Label {
            width: parent.width
            wrapMode: Text.WordWrap
            text: qsTr("表「%1」还有 %2 行改动没有保存。\n继续切过去会丢掉这些改动。")
                    .arg(root.openTableName)
                    .arg(explorer.sessionTable ? explorer.sessionTable.dirtyCount : 0)
        }

        onDiscarded: root.discardAndContinue()
        onRejected: root.keepCurrentTable()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ------------------------------------------------------------ 工具条
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 54
            color: root.cPanel

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                spacing: 9

                Label {
                    text: "SQLite"
                    color: root.cText
                    font.pixelSize: 16
                    font.bold: true
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 20
                    Layout.leftMargin: 4
                    Layout.rightMargin: 4
                    color: root.cLine
                }

                // 打开数据库 = 蓝色主操作
                AppButton {
                    text: qsTr("打开数据库")
                    tone: "primary"
                    onClicked: {
                        explorer.closeAll()
                        root.clearSelection()
                        openDialog.open()
                    }
                }

                // 执行 SQL = 打开右侧的 SQL 控制台（盖在数据表格上）
                AppButton {
                    text: qsTr("执行 SQL")
                    tone: "outline"
                    enabled: explorer.databaseCount > 0
                    onClicked: root.openSqlConsole()

                    ToolTip.visible: sqlButtonHover.hovered
                    ToolTip.text: qsTr("打开 SQL 控制台，直接写 SQL 执行（Ctrl+E）")
                    HoverHandler { id: sqlButtonHover }
                }

                // 次级操作 = 描边轻量风格
                AppButton {
                    text: qsTr("刷新")
                    tone: "outline"
                    enabled: explorer.databaseCount > 0
                    onClicked: explorer.refresh()
                }

                AppButton {
                    text: qsTr("全部展开")
                    tone: "outline"
                    enabled: explorer.databaseCount > 0
                    onClicked: root.expandAll()
                }

                // 危险操作 = 红色描边
                AppButton {
                    text: qsTr("关闭全部")
                    tone: "outline"
                    danger: true
                    enabled: explorer.databaseCount > 0
                    onClicked: {
                        // closeAll() 内部会把表会话一起关掉
                        explorer.closeAll()
                        root.clearSelection()
                    }

                    ToolTip.visible: closeAllHover.hovered
                    ToolTip.text: qsTr("关闭所有已打开的数据库（未保存的改动会丢失）")
                    HoverHandler { id: closeAllHover }
                }

                CheckBox {

                    text: qsTr("只读打开")
                    font.pixelSize: 12
                    checked: root.openReadOnly
                    onToggled: root.openReadOnly = checked

                    ToolTip.visible: readOnlyHover.hovered
                    ToolTip.text: qsTr("勾上以后打开数据库时加只读标记，不能改数据（防手滑）")
                    HoverHandler { id: readOnlyHover }
                }

                Item { Layout.fillWidth: true }

                Label {
                    text: qsTr("%1 个数据库 / %2 个对象")
                            .arg(explorer.databaseCount).arg(explorer.tableCount)
                    color: root.cTextDim
                    font.pixelSize: 12
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: root.cLine
            }
        }

        // 出错时的提示条
        Rectangle {
            Layout.fillWidth: true
            visible: explorer.lastError.length > 0
            implicitHeight: visible ? 34 : 0
            color: "#fdecec"

            Label {

                anchors.fill: parent
                anchors.leftMargin: 14
                anchors.rightMargin: 14
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                text: explorer.lastError
                color: "#b4232b"
                font.pixelSize: 12

                HoverHandler { id: errorHover }
                ToolTip.visible: errorHover.hovered
                ToolTip.text: explorer.lastError
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#f2c2c2"
            }
        }

        // ---------------------------------------------------------- 主体分栏
        SplitView {
            id: split

            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: Qt.Horizontal

            handle: Rectangle {
                implicitWidth: 5
                color: SplitHandle.pressed || SplitHandle.hovered ? root.cAccent : root.cLine
            }

            // ============================================= 左：数据库 + 表
            Rectangle {
                // ↓↓↓ 左侧列表宽度：preferredWidth 是初始宽度，minimumWidth 是拖拽下限 ↓↓↓
                SplitView.preferredWidth: 230
                SplitView.minimumWidth: 200
                SplitView.maximumWidth: 300
                color: root.cPanel

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    // 标题栏
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
                                text: qsTr("数据库")
                                color: root.cText
                                font.pixelSize: 13
                                font.bold: true
                            }

                            Item { Layout.fillWidth: true }

                            Label {
                                visible: explorer.databaseCount > 0
                                text: qsTr("单击选中 · 点 ▸ 展开")
                                color: root.cTextDim
                                font.pixelSize: 11
                            }
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 1
                            color: root.cLine
                        }
                    }

                    // 空状态
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: explorer.databaseCount === 0

                        ColumnLayout {
                            anchors.centerIn: parent
                            width: Math.min(parent.width - 48, 300)
                            spacing: 9

                            Label {
                                Layout.alignment: Qt.AlignHCenter
                                text: "🗄"
                                font.pixelSize: 40
                                color: "#9aa1ab"
                            }

                            Label {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: qsTr("还没有打开数据库")
                                color: root.cText
                                font.pixelSize: 14
                                font.bold: true
                            }

                            Label {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: qsTr("点上面的「打开数据库」选择 .db / .sqlite 文件，\n也可以把文件直接拖进这个窗口。")
                                color: root.cTextDim
                                font.pixelSize: 11
                            }

                            Button {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.topMargin: 4
                                text: qsTr("打开数据库")
                                onClicked: openDialog.open()
                            }
                        }
                    }

                    // 树：第一层 = 数据库文件，第二层 = 表 / 视图
                    TreeView {
                        id: tree

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: explorer.databaseCount > 0
                        clip: true
                        model: explorer.databaseModel
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar {}

                        delegate: ItemDelegate {
                            id: row

                            required property string label
                            required property string nodeType
                            required property string info
                            required property string connectionName
                            required property string path
                            required property string parentPath
                            required property string databaseName
                            // TreeView 注入，用来拿层级和展开状态
                            required property TreeView treeView

                            readonly property bool isDatabase: nodeType === "database"
                            readonly property bool isView: nodeType === "view"
                            readonly property bool expanded: treeView.isExpanded(treeView.index)
                            readonly property int level: treeView.depth(treeView.index)

                            // 是不是当前选中的节点（左侧选中高亮）
                            readonly property bool isCurrent: root.selectedKind === nodeType
                                    && root.selectedLabel === row.label
                                    && (nodeType === "database" ? root.selectedPath === row.path
                                                                : root.selectedDatabaseName === row.databaseName)
                            // 这个库是不是只读打开的
                            readonly property bool readOnlyDb: row.isDatabase
                                    && explorer.isConnectionReadOnly(row.connectionName)

                            implicitWidth: tree.width
                            implicitHeight: row.isDatabase ? 34 : 30
                            leftPadding: 6 + row.level * 20
                            rightPadding: 10

                            background: Rectangle {
                                radius: 6
                                // 选中：蓝色描边 + 淡蓝底；悬停：淡灰；数据库行：淡蓝灰底
                                color: row.isCurrent ? root.cAccentSoft
                                       : row.hovered ? "#eef2f7"
                                       : row.isDatabase ? "#f6f8fb" : "transparent"
                                border.width: row.isCurrent ? 1 : 0
                                border.color: root.cAccent

                                Rectangle {
                                    visible: row.isDatabase
                                    anchors.bottom: parent.bottom
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    height: 1
                                    color: root.cLine
                                }
                            }

                            contentItem: RowLayout {
                                spacing: 7

                                // 展开 / 收起箭头
                                Item {
                                    Layout.preferredWidth: 14
                                    Layout.preferredHeight: 14
                                    visible: row.isDatabase

                                    Text {
                                        anchors.centerIn: parent
                                        text: row.expanded ? "▾" : "▸"
                                        color: row.isCurrent ? root.cAccent : root.cTextDim
                                        font.pixelSize: 12
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        onClicked: row.treeView.toggleExpanded(row.treeView.index)
                                    }
                                }

                                Label {
                                    text: row.isDatabase ? "🗄" : (row.isView ? "◫" : "▦")
                                    color: row.isDatabase ? root.cAccent : "#8b919b"
                                    font.pixelSize: 12
                                }

                                Label {
                                    Layout.fillWidth: true
                                    text: row.label
                                    color: row.isCurrent ? root.cAccent : root.cText
                                    font.pixelSize: 13
                                    font.bold: row.isDatabase
                                    elide: Text.ElideRight
                                }

                                // 只读打开的库标个锁
                                Label {
                                    visible: row.readOnlyDb
                                    text: "🔒"
                                    font.pixelSize: 10
                                }

                                Label {
                                    text: row.info
                                    color: root.cTextDim
                                    font.pixelSize: 11
                                }

                                // 关闭这个数据库
                                Item {
                                    Layout.preferredWidth: 16
                                    Layout.preferredHeight: 16
                                    visible: row.isDatabase && (row.hovered || row.checked)

                                    Text {
                                        anchors.centerIn: parent
                                        text: "✕"
                                        color: root.cTextDim
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        onClicked: explorer.closeDatabase(row.connectionName)
                                    }
                                }
                            }

                            onClicked: {
                                root.selectNode(row.label, row.nodeType,
                                                row.isDatabase ? row.path : "", row.info,
                                                row.databaseName)
                                if (row.isDatabase) {
                                    if (!row.expanded)
                                        row.treeView.expand(row.treeView.index)
                                } else {
                                    // 表 / 视图 → 右边显示数据
                                    root.openTableIn(row.parentPath, row.databaseName,
                                                     row.label, row.nodeType, row.connectionName)
                                }
                            }

                            onDoubleClicked: {
                                if (row.isDatabase)
                                    row.treeView.toggleExpanded(row.treeView.index)
                            }

                            // 模型重建之后（以及 delegate 第一次建立时），把之前展开过的库恢复成展开。
                            // changed 信号在模型重建时发出；首次建立时补一次，避免开机自动打开时错过信号。
                            Component.onCompleted: Qt.callLater(row.restoreExpanded)

                            function restoreExpanded() {
                                if (row.isDatabase && root.isExpandedNode(row.path)
                                        && !row.treeView.isExpanded(row.treeView.index))
                                    row.treeView.expand(row.treeView.index)
                            }

                            Connections {
                                target: explorer

                                function onChanged() {
                                    row.restoreExpanded()
                                }
                            }
                        }
                    }
                }
            }

            // =========================================== 右：数据表格（可编辑）
            Rectangle {
                id: rightPanel

                SplitView.fillWidth: true
                SplitView.minimumWidth: 300
                color: "#fbfcfd"

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    TableDataView {
                        id: tableView

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }

                    // 状态栏
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30
                        color: "#f7f8fa"

                        Rectangle {
                            anchors.top: parent.top
                            width: parent.width
                            height: 1
                            color: root.cLine
                        }

                        Label {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideLeft
                            text: explorer.statusText
                            color: root.cTextDim
                            font.pixelSize: 11
                        }
                    }
                }

                // SQL 控制台：铺满整个右侧面板（连状态栏一起盖住，地方大一点好写 SQL）。
                // 它是一个独立的 QML 组件，默认 visible: false，点「执行 SQL」才出来。
                SqlConsole {
                    id: sqlConsole

                    anchors.fill: parent
                    z: 200

                    // 收起来以后把焦点还给数据表格，不然键盘事件没人接
                    onClosed: tableView.forceActiveFocus()
                }
            }
        }
    }
}
