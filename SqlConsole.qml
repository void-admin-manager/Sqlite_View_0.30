import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Sqlite_UI // 用同模块里的 AppButton

FocusScope {
    id: pane

    focus: true
    activeFocusOnTab: true
    visible: false

    // Main.qml 打开控制台时给的「优先操作哪个库」（连接名）
    property string preferredConnection: ""
    // 当前真正执行到哪个库上
    property string targetConnection: ""

    readonly property var result: explorer.sqlResult
    readonly property bool hasResult: pane.result ? pane.result.hasResult === true : false
    readonly property string errorText: pane.result && pane.result.errorText
                                        ? pane.result.errorText : ""
    readonly property string infoText: pane.result && pane.result.infoText
                                       ? pane.result.infoText : ""
    readonly property bool failed: pane.errorText.length > 0
    readonly property int resultRowCount: pane.hasResult ? pane.result.rowCountValue : 0
    readonly property bool targetReadOnly: pane.targetConnection.length > 0
                                           && explorer.isConnectionReadOnly(pane.targetConnection)

    property int resultSerial: 0

    readonly property int columnCount: pane.resultSerial >= 0 && pane.hasResult
                                        ? pane.result.columns() : 0
    readonly property int rowCount: pane.resultSerial >= 0 && pane.hasResult
                                    ? pane.result.rows() : 0

    property var history: []
    property int historyIndex: -1
    property string historyDraft: ""

    readonly property int highlightLimit: 20000

    signal closed()

    function showConsole() {
        if (!visible) {
            pane.targetConnection = pane.pickConnection()
            visible = true
        }
        Qt.callLater(function () { sqlEditor.forceActiveFocus() })
    }

    function hideConsole() {
        if (!visible)
            return
        visible = false
        pane.closed()
    }

    function pickConnection() {
        if (pane.isOpenConnection(pane.preferredConnection))
            return pane.preferredConnection
        if (pane.isOpenConnection(pane.targetConnection))
            return pane.targetConnection

        var session = explorer.sessionTable
        if (session && session.connectionName && session.connectionName.length > 0
                && pane.isOpenConnection(session.connectionName))
            return session.connectionName

        return explorer.databaseCount > 0 ? explorer.connectionNameAt(0) : ""
    }

    function isOpenConnection(name) {
        if (!name || name.length === 0)
            return false
        for (var i = 0; i < explorer.databaseCount; ++i) {
            if (explorer.connectionNameAt(i) === name)
                return true
        }
        return false
    }

    function targetLabel() {
        if (pane.targetConnection.length === 0)
            return qsTr("没有打开的数据库")
        var name = explorer.displayNameForConnection(pane.targetConnection)
        if (name.length === 0)
            return qsTr("数据库已关闭")
        return explorer.isConnectionReadOnly(pane.targetConnection) ? name + " 🔒" : name
    }

    // ============================================================ 执行
    function runSql() {
        pane.runText(sqlEditor.text)
    }

    function runSelection() {
        if (sqlEditor.selectedText.length === 0)
            return
        pane.runText(sqlEditor.selectedText)
    }

    function runText(sql) {
        if (!sql || String(sql).trim().length === 0) {
            sqlEditor.forceActiveFocus()
            return
        }
        if (!pane.isOpenConnection(pane.targetConnection))
            pane.targetConnection = pane.pickConnection()
        if (pane.targetConnection.length === 0) {
            sqlEditor.forceActiveFocus()
            return
        }

        if (explorer.runSql(pane.targetConnection, String(sql)))
            pane.pushHistory(sql)

        sqlEditor.forceActiveFocus()
    }

    function clearEditor() {
        if (sqlEditor.length > 0) {
            sqlEditor.select(0, sqlEditor.length)
            sqlEditor.remove(0, sqlEditor.length)
        }
        sqlEditor.deselect()
        sqlEditor.cursorPosition = 0
        sqlEditor.forceActiveFocus()
    }

    function ensureCursorVisible() {
        if (!pane.visible)
            return
        var y = sqlEditor.y + sqlEditor.cursorRectangle.y
        var h = Math.max(sqlEditor.cursorRectangle.height, 14)
        var top = editorFlick.contentY
        var bottom = top + editorFlick.height
        if (y < top + 4) {
            editorFlick.contentY = Math.max(0, y - 4)
        } else if (y + h > bottom - 4) {
            var limit = Math.max(0, editorFlick.contentHeight - editorFlick.height)
            editorFlick.contentY = Math.min(limit, y + h - editorFlick.height + 4)
        }
    }

    function pushHistory(sql) {
        var text = String(sql).trim()
        if (text.length === 0)
            return
        var list = pane.history.slice()
        if (list.length > 0 && list[0] === text) {
            pane.historyIndex = -1
            return
        }
        list.unshift(text)
        if (list.length > 50)
            list = list.slice(0, 50)
        pane.history = list
        pane.historyIndex = -1
    }

    function recallHistory(text) {
        sqlEditor.text = text
        sqlEditor.cursorPosition = sqlEditor.text.length
        sqlEditor.forceActiveFocus()
    }

    function historyPrev() {
        if (pane.history.length === 0)
            return
        if (pane.historyIndex === -1)
            pane.historyDraft = sqlEditor.text
        pane.historyIndex = Math.min(pane.historyIndex + 1, pane.history.length - 1)
        pane.recallHistory(pane.history[pane.historyIndex])
    }

    function historyNext() {
        if (pane.historyIndex < 0)
            return
        pane.historyIndex -= 1
        if (pane.historyIndex < 0)
            pane.recallHistory(pane.historyDraft)
        else
            pane.recallHistory(pane.history[pane.historyIndex])
    }

    readonly property var sqlKeywords: ({
            "ABORT": true, "ACTION": true, "ADD": true, "AFTER": true, "ALL": true, "ALTER": true,
            "ANALYZE": true, "AND": true, "AS": true, "ASC": true, "ATTACH": true, "AUTOINCREMENT": true,
            "BEFORE": true, "BEGIN": true, "BETWEEN": true, "BY": true, "CASCADE": true, "CASE": true,
            "CAST": true, "CHECK": true, "COLLATE": true, "COLUMN": true, "COMMIT": true,
            "CONFLICT": true, "CONSTRAINT": true, "CREATE": true, "CROSS": true, "CURRENT_DATE": true,
            "CURRENT_TIME": true, "CURRENT_TIMESTAMP": true, "DATABASE": true, "DEFAULT": true,
            "DEFERRABLE": true, "DEFERRED": true, "DELETE": true, "DESC": true, "DETACH": true,
            "DISTINCT": true, "DO": true, "DROP": true, "EACH": true, "ELSE": true, "END": true,
            "ESCAPE": true, "EXCEPT": true, "EXCLUDE": true, "EXCLUSIVE": true, "EXISTS": true,
            "EXPLAIN": true, "FAIL": true, "FILTER": true, "FIRST": true, "FOLLOWING": true,
            "FOR": true, "FOREIGN": true, "FROM": true, "FULL": true, "GENERATED": true, "GLOB": true,
            "GROUP": true, "GROUPS": true, "HAVING": true, "IF": true, "IGNORE": true, "IMMEDIATE": true,
            "IN": true, "INDEX": true, "INDEXED": true, "INITIALLY": true, "INNER": true, "INSERT": true,
            "INSTEAD": true, "INTERSECT": true, "INTO": true, "IS": true, "ISNULL": true, "JOIN": true,
            "KEY": true, "LAST": true, "LEFT": true, "LIKE": true, "LIMIT": true, "MATCH": true,
            "MATERIALIZED": true, "NATURAL": true, "NO": true, "NOT": true, "NOTHING": true,
            "NOTNULL": true, "NULL": true, "OF": true, "OFFSET": true, "ON": true, "OR": true,
            "ORDER": true, "OTHERS": true, "OUTER": true, "OVER": true, "PARTITION": true, "PLAN": true,
            "PRAGMA": true, "PRECEDING": true, "PRIMARY": true, "QUERY": true, "RAISE": true,
            "RANGE": true, "RECURSIVE": true, "REFERENCES": true, "REGEXP": true, "REINDEX": true,
            "RELEASE": true, "RENAME": true, "REPLACE": true, "RESTRICT": true, "RETURNING": true,
            "RIGHT": true, "ROLLBACK": true, "ROW": true, "ROWS": true, "SAVEPOINT": true, "SELECT": true,
            "SET": true, "TABLE": true, "TEMP": true, "TEMPORARY": true, "THEN": true, "TIES": true,
            "TO": true, "TRANSACTION": true, "TRIGGER": true, "UNBOUNDED": true, "UNION": true,
            "UNIQUE": true, "UPDATE": true, "USING": true, "VACUUM": true, "VALUES": true, "VIEW": true,
            "VIRTUAL": true, "WHEN": true, "WHERE": true, "WINDOW": true, "WITH": true, "WITHOUT": true
        })

    function escapeSql(text) {
        var out = String(text)
        out = out.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        out = out.replace(/ +/g, function (run) {
            return run.length < 2 ? " " : new Array(run.length).join("&nbsp;") + " "
        })
        return out.replace(/\n/g, "<br/>")
    }

    function colorOf(kind) {
        switch (kind) {
        case "kw": return "color:#0033b3;font-weight:bold"  // 关键字：蓝 + 粗
        case "st": return "color:#067d17"                   // 字符串：绿
        case "nm": return "color:#1750eb"                   // 数字：蓝
        case "cm": return "color:#8c8c8c;font-style:italic" // 注释：灰斜体
        case "fn": return "color:#7a3e9d"                   // 函数名：紫
        default: return "color:#5a6b7a"                     // 运算符 / 标点
        }
    }

    // 一段 SQL → 一段带颜色的富文本
    function highlightSql(source) {
        var text = String(source)
        if (text.length === 0)
            return ""
        if (text.length > pane.highlightLimit)
            return pane.escapeSql(text) // 太长就不着色，至少保证字还看得见

        //                ①注释                    ②字符串 / 标识符                ③数字        ④标识符 / 关键字        ⑤运算符
        var tokenRe = /(--[^\n]*|\/\*[\s\S]*?\*\/)|('(?:[^']|'')*'?|"(?:[^"]|"")*"?|`[^`]*`|\[[^\]]*\])|(\b\d+\.?\d*(?:[eE][+-]?\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)|([(),;.]+|[-+*\/%=<>!|&~^]+)/g

        var out = []
        var last = 0
        var m
        while ((m = tokenRe.exec(text)) !== null) {
            if (m.index > last)
                out.push(pane.escapeSql(text.slice(last, m.index)))
            last = tokenRe.lastIndex

            var token = m[0]
            var kind = "op"
            if (m[1] !== undefined) {
                kind = "cm"
            } else if (m[2] !== undefined) {
                kind = "st"
            } else if (m[3] !== undefined) {
                kind = "nm"
            } else if (m[4] !== undefined) {
                if (pane.sqlKeywords[token.toUpperCase()] === true)
                    kind = "kw"
                else if (/^\s*\(/.test(text.slice(tokenRe.lastIndex)))
                    kind = "fn" // 后面紧跟左括号的标识符 = 函数名
            }

            out.push('<span style="' + pane.colorOf(kind) + '">' + pane.escapeSql(token) + '</span>')
        }
        if (last < text.length)
            out.push(pane.escapeSql(text.slice(last)))
        return out.join("")
    }

    // ============================================================ 跟着后端刷新
    Connections {
        target: pane.result

        function onResultChanged() {
            pane.resultSerial++
            resultTable.contentX = 0
            resultTable.contentY = 0
            resultTable.forceLayout()
        }
    }

    Connections {
        target: explorer

        function onChanged() {
            // 目标库被关掉了就换一个；一个库都不剩就自己收起来
            if (!pane.isOpenConnection(pane.targetConnection)) {
                if (explorer.databaseCount === 0) {
                    if (pane.visible)
                        pane.hideConsole()
                    pane.targetConnection = ""
                } else {
                    pane.targetConnection = pane.pickConnection()
                }
            }
        }
    }

    // ============================================================ 快捷键
    // 全部挂在「控制台可见」上：盖着的时候才生效，收起来之后不会去抢数据表格的键。
    Shortcut { sequence: "F5"; enabled: pane.visible; onActivated: pane.runSql() }
    Shortcut { sequence: "Ctrl+Return"; enabled: pane.visible; onActivated: pane.runSql() }
    Shortcut { sequence: "Ctrl+Enter"; enabled: pane.visible; onActivated: pane.runSql() }
    Shortcut { sequence: "Ctrl+L"; enabled: pane.visible; onActivated: pane.clearEditor() }
    // 回退 / 重做（TextEdit 自带撤销栈，这里只是给它配快捷键 + 按钮）
    Shortcut { sequence: "Ctrl+Z"; enabled: pane.visible; onActivated: sqlEditor.undo() }
    Shortcut { sequence: "Ctrl+Y"; enabled: pane.visible; onActivated: sqlEditor.redo() }
    Shortcut { sequence: "Ctrl+Shift+Z"; enabled: pane.visible; onActivated: sqlEditor.redo() }
    Shortcut { sequence: "Ctrl+C"; enabled: pane.visible; onActivated: sqlEditor.copy() }
    Shortcut { sequence: "Ctrl+X"; enabled: pane.visible; onActivated: sqlEditor.cut() }
    Shortcut { sequence: "Ctrl+V"; enabled: pane.visible; onActivated: sqlEditor.paste() }
    Shortcut { sequence: "Ctrl+A"; enabled: pane.visible; onActivated: sqlEditor.selectAll() }
    Shortcut { sequence: "Ctrl+Up"; enabled: pane.visible; onActivated: pane.historyPrev() }
    Shortcut { sequence: "Ctrl+Down"; enabled: pane.visible; onActivated: pane.historyNext() }
    Shortcut {
        sequence: "Escape"
        enabled: pane.visible && !targetPopup.opened && !historyPopup.opened
        onActivated: pane.hideConsole()
    }

    // ============================================================ 背景
    Rectangle {
        anchors.fill: parent
        color: "#fbfcfd"
    }

    // 铺一层「什么都不做」的 MouseArea：挡住下面数据表格的点击 / 悬停，
    // 顺带把焦点送回编辑框。声明在其它子项之前，所以不会挡住它们。
    MouseArea {
        anchors.fill: parent
        onClicked: sqlEditor.forceActiveFocus()
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
                anchors.rightMargin: 10
                spacing: 8

                Label {
                    text: "⌨"
                    color: "#2f6fd0"
                    font.pixelSize: 12
                }

                Label {
                    text: qsTr("SQL 控制台")
                    color: "#1f2328"
                    font.pixelSize: 13
                    font.bold: true
                }

                // 目标数据库：点开一个自绘的小下拉
                Rectangle {
                    id: targetChip

                    implicitWidth: targetChipRow.implicitWidth + 20
                    implicitHeight: 24
                    radius: 12
                    color: targetHover.hovered || targetPopup.opened ? "#e8f0fc" : "#eef2f7"
                    border.width: 1
                    border.color: targetHover.hovered || targetPopup.opened ? "#2f6fd0" : "#d7dade"

                    Row {
                        id: targetChipRow

                        anchors.centerIn: parent
                        spacing: 6

                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "🗄"
                            font.pixelSize: 10
                        }

                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("目标：%1").arg(pane.targetLabel())
                            color: "#3b4250"
                            font.pixelSize: 11
                        }

                        Label {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "▾"
                            color: "#7a828c"
                            font.pixelSize: 10
                        }
                    }

                    HoverHandler { id: targetHover }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: targetPopup.opened ? targetPopup.close() : targetPopup.open()
                    }

                    ToolTip.visible: targetHover.hovered
                    ToolTip.delay: 500
                    ToolTip.text: qsTr("SQL 在哪个数据库上执行（点一下换一个）")
                }

                Label {
                    visible: pane.targetReadOnly
                    text: qsTr("只读，只能查询")
                    color: "#b06a00"
                    font.pixelSize: 11
                }

                Item { Layout.fillWidth: true }

                Label {
                    text: qsTr("Ctrl+Enter 运行 · Ctrl+Z 回退 · Esc 关闭")
                    color: "#7a828c"
                    font.pixelSize: 11
                }

                AppButton {
                    text: qsTr("✕ 关闭")
                    tone: "outline"
                    onClicked: pane.hideConsole()
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
            // 用 Flow 而不是 Row：窗口窄的时候按钮会自己换行，不会被挤成一条缝
            implicitHeight: toolFlow.implicitHeight + 16
            color: "#ffffff"

            Flow {
                id: toolFlow

                x: 12
                y: 8
                width: parent.width - 24
                spacing: 7

                AppButton {
                    text: qsTr("▶ 运行")
                    tone: "primary"
                    enabled: sqlEditor.text.trim().length > 0
                             && pane.targetConnection.length > 0
                    onClicked: pane.runSql()

                    ToolTip.visible: runHover.hovered
                    ToolTip.text: qsTr("执行编辑框里的全部 SQL（Ctrl+Enter / F5）")
                    HoverHandler { id: runHover }
                }

                AppButton {
                    text: qsTr("▶ 运行选中")
                    tone: "outline"
                    enabled: sqlEditor.selectedText.length > 0
                             && pane.targetConnection.length > 0
                    onClicked: pane.runSelection()

                    ToolTip.visible: runSelHover.hovered
                    ToolTip.text: qsTr("只执行选中的那段 SQL")
                    HoverHandler { id: runSelHover }
                }

                Rectangle { width: 1; height: 30; color: "#e3e6ea" }

                AppButton {
                    text: qsTr("回退")
                    tone: "neutral"
                    enabled: sqlEditor.canUndo
                    onClicked: sqlEditor.undo()

                    ToolTip.visible: undoHover.hovered
                    ToolTip.text: qsTr("撤销上一次编辑（Ctrl+Z）")
                    HoverHandler { id: undoHover }
                }

                AppButton {
                    text: qsTr("重做")
                    tone: "neutral"
                    enabled: sqlEditor.canRedo
                    onClicked: sqlEditor.redo()

                    ToolTip.visible: redoHover.hovered
                    ToolTip.text: qsTr("重做（Ctrl+Y / Ctrl+Shift+Z）")
                    HoverHandler { id: redoHover }
                }

                Rectangle { width: 1; height: 30; color: "#e3e6ea" }

                AppButton {
                    text: qsTr("复制")
                    tone: "neutral"
                    enabled: sqlEditor.selectedText.length > 0
                    onClicked: sqlEditor.copy()

                    ToolTip.visible: copyHover.hovered
                    ToolTip.text: qsTr("复制选中的 SQL（Ctrl+C）")
                    HoverHandler { id: copyHover }
                }

                AppButton {
                    text: qsTr("粘贴")
                    tone: "neutral"
                    enabled: sqlEditor.canPaste
                    onClicked: {
                        sqlEditor.paste()
                        sqlEditor.forceActiveFocus()
                    }

                    ToolTip.visible: pasteHover.hovered
                    ToolTip.text: qsTr("粘贴（Ctrl+V）")
                    HoverHandler { id: pasteHover }
                }

                AppButton {
                    text: qsTr("全选")
                    tone: "neutral"
                    enabled: sqlEditor.text.length > 0
                    onClicked: {
                        sqlEditor.selectAll()
                        sqlEditor.forceActiveFocus()
                    }

                    ToolTip.visible: selectAllHover.hovered
                    ToolTip.text: qsTr("全选（Ctrl+A）")
                    HoverHandler { id: selectAllHover }
                }

                AppButton {
                    text: qsTr("清空")
                    tone: "outline"
                    danger: true
                    enabled: sqlEditor.text.length > 0
                    onClicked: pane.clearEditor()

                    ToolTip.visible: clearHover.hovered
                    ToolTip.text: qsTr("清空编辑框（Ctrl+L），结果网格保留")
                    HoverHandler { id: clearHover }
                }

                Rectangle { width: 1; height: 30; color: "#e3e6ea" }

                AppButton {
                    text: qsTr("历史")
                    tone: "neutral"
                    enabled: pane.history.length > 0
                    onClicked: historyPopup.opened ? historyPopup.close() : historyPopup.open()

                    ToolTip.visible: historyHover.hovered
                    ToolTip.text: qsTr("执行过的语句（Ctrl+↑ / Ctrl+↓ 也能翻）")
                    HoverHandler { id: historyHover }
                }

                Label {
                    // 注意：Flow 里的子项不能写 anchors，这里靠 height + 垂直对齐来居中
                    height: 30
                    verticalAlignment: Text.AlignVCenter
                    visible: pane.targetConnection.length === 0
                    text: qsTr("先在主界面打开一个数据库")
                    color: "#b06a00"
                    font.pixelSize: 11
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: "#e3e6ea"
            }
        }

        // ------------------------------------------------------ 编辑区 / 结果区
        SplitView {
            id: split

            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: Qt.Vertical

            handle: Rectangle {
                implicitHeight: 5
                color: SplitHandle.pressed || SplitHandle.hovered ? "#2f6fd0" : "#e3e6ea"
            }

            // =============================================== 上：SQL 编辑框
            Rectangle {
                SplitView.fillWidth: true
                SplitView.preferredHeight: 230
                SplitView.minimumHeight: 90
                color: "#ffffff"

                Flickable {
                    id: editorFlick

                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    contentWidth: width
                    contentHeight: Math.max(height, sqlEditor.y + sqlEditor.height + 12)
                    // 不用鼠标拖动滚动（拖拽留给编辑框选文字），滚轮照常
                    interactive: false
                    ScrollBar.vertical: ScrollBar {}

                    Item {
                        id: editorContent

                        width: editorFlick.width
                        height: editorFlick.contentHeight

                        // 高亮层：只读、只负责好看
                        Text {
                            id: highlightLayer

                            x: sqlEditor.x + sqlEditor.leftPadding + sqlEditor.textMargin
                            y: sqlEditor.y + sqlEditor.topPadding + sqlEditor.textMargin
                            width: sqlEditor.width - sqlEditor.leftPadding - sqlEditor.rightPadding
                            textFormat: Text.RichText
                            text: pane.highlightSql(sqlEditor.text)
                            wrapMode: Text.Wrap
                            color: "#1f2328"
                            font.family: sqlEditor.font.family
                            font.pixelSize: sqlEditor.font.pixelSize
                            font.weight: sqlEditor.font.weight
                        }

                        // 输入层：字体全透明，只留下光标、选区和高亮层透过来的字
                        TextEdit {
                            id: sqlEditor

                            x: 12
                            y: 10
                            width: editorContent.width - 24
                            // 高度撑到内容那么高，让外面的 Flickable 负责滚动
                            height: Math.max(contentHeight, 18)
                            clip: false

                            wrapMode: TextEdit.Wrap
                            textFormat: TextEdit.PlainText
                            selectByMouse: true
                            persistentSelection: true
                            activeFocusOnPress: true

                            font.family: "Consolas"
                            font.pixelSize: 13
                            leftPadding: 0
                            rightPadding: 0
                            topPadding: 0
                            bottomPadding: 0

                            // 字是透明的不然会盖住高亮层；光标得自己画，否则也是透明的
                            color: "transparent"
                            selectedTextColor: "transparent"
                            // 选中底色必须是**半透明**的：
                            // 这一层盖在高亮层上面，不透明的底色会把下面的彩色字糊掉
                            //（选中时整段变成一块实心蓝，什么字都看不见）。
                            // 等价写法：selectionColor: "#597aa7e8"（#AARRGGBB，前两位是 alpha）
                            selectionColor: Qt.rgba(0.478, 0.655, 0.910, 0.35)

                            cursorDelegate: Rectangle {
                                width: 2
                                height: sqlEditor.cursorRectangle.height
                                color: "#2f6fd0"
                                visible: sqlEditor.cursorVisible && sqlEditor.activeFocus
                            }

                            // Tab 插四个空格（默认会去切焦点，写 SQL 时很难受）
                            Keys.onTabPressed: function (event) {
                                sqlEditor.insert(sqlEditor.cursorPosition, "    ")
                                event.accepted = true
                            }

                            // 光标跑到看不见的地方就滚一下，不然在最后一行打字看不到自己
                            onCursorPositionChanged: pane.ensureCursorVisible()
                            onActiveFocusChanged: {
                                if (activeFocus)
                                    pane.ensureCursorVisible()
                            }
                        }

                        // 空的时候给个提示（Label 不吃鼠标事件，底下照样能点）
                        Label {
                            visible: sqlEditor.text.length === 0
                            x: sqlEditor.x
                            y: sqlEditor.y
                            text: qsTr("在这里写 SQL，例如：\nSELECT * FROM 表名 WHERE id > 10;\n\nCtrl+Enter / F5 运行 · Ctrl+↑ 翻历史 · Esc 关闭")
                            color: "#a8aeb8"
                            font.family: sqlEditor.font.family
                            font.pixelSize: sqlEditor.font.pixelSize
                            lineHeight: 1.3
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

            // =============================================== 下：结果网格
            Rectangle {
                SplitView.fillWidth: true
                SplitView.fillHeight: true
                SplitView.minimumHeight: 110
                color: "#fbfcfd"

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    // 状态行：成功给绿勾 + 摘要，失败给红叉 + 错误原文
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 30
                        color: "#f7f8fa"

                        Rectangle {
                            anchors.top: parent.top
                            width: parent.width
                            height: 1
                            color: "#e3e6ea"
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            spacing: 8

                            Label {
                                text: pane.failed ? "✕" : (pane.hasResult ? "✓" : "ⓘ")
                                color: pane.failed ? "#d9363e"
                                                      : (pane.hasResult ? "#18973f" : "#7a828c")
                                font.pixelSize: 12
                                font.bold: true
                            }

                            Label {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: pane.failed ? pane.errorText
                                                     : (pane.infoText.length > 0
                                                        ? pane.infoText
                                                        : qsTr("还没有执行 SQL"))
                                color: pane.failed ? "#b4232b" : "#7a828c"
                                font.pixelSize: 11
                            }

                            Label {
                                visible: pane.targetConnection.length > 0
                                text: pane.targetLabel()
                                color: "#a8aeb8"
                                font.pixelSize: 11
                            }
                        }
                    }

                    // 结果表：表头 + 行号列 + TableView，样式照着 TableDataView 来
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true

                        // 表头（跟着横向滚动）
                        Row {
                            x: 46 - resultTable.contentX
                            y: 0
                            height: 30
                            visible: pane.hasResult

                            Repeater {
                                model: pane.columnCount

                                Rectangle {
                                    required property int index

                                    // 宽度和单元格用同一个估算值，保证表头跟列对得上
                                    width: pane.result.columnWidthHint(index)
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
                                            text: index + 1
                                            color: "#a8aeb8"
                                            font.pixelSize: 10
                                        }

                                        Text {
                                            text: pane.result.columnName(index)
                                            color: "#1f2328"
                                            font.pixelSize: 12
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }
                                    }

                                    ToolTip.visible: headerHover.hovered
                                    ToolTip.delay: 300
                                    ToolTip.text: pane.result.columnName(index)
                                    HoverHandler { id: headerHover }
                                }
                            }
                        }

                        // 行号列（跟着纵向滚动）
                        Column {
                            x: 0
                            y: 30 - resultTable.contentY
                            width: 46
                            visible: pane.hasResult

                            Repeater {
                                model: pane.rowCount

                                Rectangle {
                                    required property int index

                                    width: 46
                                    height: 30
                                    color: "#fafbfc"
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

                        TableView {
                            id: resultTable

                            anchors.left: parent.left
                            anchors.leftMargin: 46
                            anchors.top: parent.top
                            anchors.topMargin: 30
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom

                            clip: true
                            model: pane.result
                            boundsBehavior: Flickable.StopAtBounds
                            pointerNavigationEnabled: false

                            ScrollBar.vertical: ScrollBar {}
                            ScrollBar.horizontal: ScrollBar {}

                            // 只读网格：不需要 ItemDelegate，Rectangle + Label 就够了
                            delegate: Rectangle {
                                id: resultCell

                                required property int row
                                required property int column

                                readonly property bool nullCell: model.nullValue === true
                                readonly property string cellText: model.display === undefined
                                                                  || model.display === null
                                                                  ? "" : String(model.display)

                                implicitWidth: pane.result.columnWidthHint(column)
                                implicitHeight: 30

                                color: cellHover.hovered ? "#f2f6fd" : (row % 2 === 1 ? "#fcfcfd" : "#ffffff")

                                Rectangle {
                                    anchors.right: parent.right
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

                                Label {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 6
                                    verticalAlignment: Text.AlignVCenter
                                    text: resultCell.cellText
                                    color: resultCell.nullCell ? "#a0a6b0" : "#1f2328"
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }

                                HoverHandler { id: cellHover }

                                // ToolTip 是附加属性，作用域在 delegate 自己身上，不能用 parent
                                ToolTip.visible: cellHover.hovered && resultCell.cellText.length > 0
                                ToolTip.delay: 700
                                ToolTip.text: resultCell.cellText
                            }
                        }

                        // 空状态 / 报错：没结果的时候在网格位置给一句话
                        ColumnLayout {
                            anchors.centerIn: parent
                            width: Math.min(parent.width - 60, 460)
                            spacing: 6
                            visible: !pane.hasResult

                            Label {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: {
                                    if (pane.failed)
                                        return pane.errorText
                                    if (pane.result && pane.result.truncated)
                                        return pane.infoText
                                    if (pane.infoText.length > 0)
                                        return pane.infoText
                                    return qsTr("还没有结果。上面写一条 SQL，按 Ctrl+Enter 或点「运行」。")
                                }
                                color: pane.failed ? "#b4232b" : "#8b919b"
                                font.pixelSize: 12
                            }

                            Label {
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                visible: pane.failed
                                text: qsTr("先把上面的 SQL 改对再运行")
                                color: "#a8aeb8"
                                font.pixelSize: 11
                            }
                        }

                        // 有结果集但一行都没有
                        Label {
                            anchors.centerIn: parent
                            visible: pane.hasResult && pane.resultRowCount === 0
                            text: qsTr("这条语句没有返回任何行")
                            color: "#8b919b"
                            font.pixelSize: 12
                        }
                    }
                }
            }
        }
    }

    // ============================================================ 目标库下拉
    Popup {
        id: targetPopup

        parent: pane
        width: 300
        padding: 4
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        onAboutToShow: {
            var p = targetChip.mapToItem(pane, 0, targetChip.height + 4)
            x = Math.max(8, Math.min(p.x, pane.width - width - 8))
            y = Math.max(8, Math.min(p.y, pane.height - height - 8))
        }

        background: Rectangle {
            color: "#ffffff"
            border.color: "#c9ced6"
            radius: 6
        }

        contentItem: Flickable {
            implicitHeight: Math.min(targetColumn.implicitHeight + 8, 260)
            contentHeight: targetColumn.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            Column {
                id: targetColumn

                width: parent.width
                y: 4

                Repeater {
                    model: explorer.databaseCount

                    Rectangle {
                        id: targetRow

                        required property int index

                        readonly property string connection: explorer.connectionNameAt(index)
                        readonly property bool current: connection === pane.targetConnection

                        width: targetColumn.width
                        height: 30
                        radius: 5
                        color: current ? "#e8f0fc" : (targetRowHover.hovered ? "#f2f5f9" : "transparent")
                        border.width: current ? 1 : 0
                        border.color: "#2f6fd0"

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            spacing: 6

                            Label {
                                anchors.verticalCenter: parent.verticalCenter
                                text: explorer.isConnectionReadOnly(targetRow.connection) ? "🔒" : "🗄"
                                font.pixelSize: 10
                            }

                            Label {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 40
                                text: explorer.displayNameForConnection(targetRow.connection)
                                color: "#1f2328"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }

                        HoverHandler { id: targetRowHover }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pane.targetConnection = targetRow.connection
                                targetPopup.close()
                                sqlEditor.forceActiveFocus()
                            }
                        }
                    }
                }
            }
        }
    }

    // ============================================================ 历史记录
    Popup {
        id: historyPopup

        parent: pane
        width: Math.min(560, Math.max(280, pane.width - 80))
        padding: 4
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

        onAboutToShow: {
            x = Math.max(8, (pane.width - width) / 2)
            y = 90
        }

        background: Rectangle {
            color: "#ffffff"
            border.color: "#c9ced6"
            radius: 6
        }

        contentItem: Flickable {
            implicitHeight: Math.min(historyColumn.implicitHeight + 8, 300)
            contentHeight: historyColumn.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            Column {
                id: historyColumn

                width: parent.width
                y: 4

                Repeater {
                    model: pane.history

                    Rectangle {
                        id: historyRow

                        required property string modelData
                        required property int index

                        width: historyColumn.width
                        height: 28
                        radius: 5
                        color: historyRowHover.hovered ? "#f2f5f9" : "transparent"

                        Label {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 8
                            verticalAlignment: Text.AlignVCenter
                            // 多行语句压成一行显示
                            text: historyRow.modelData.replace(/\s*\n\s*/g, " ⏎ ")
                            color: "#1f2328"
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }

                        HoverHandler { id: historyRowHover }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                pane.recallHistory(historyRow.modelData)
                                historyPopup.close()
                            }
                        }
                    }
                }
            }
        }
    }
}
