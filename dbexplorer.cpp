#include "dbexplorer.h"

#include "tablemodel.h"

#include <QDir>
#include <QFileInfo>
#include <QHash>
#include <QSettings>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardItem>
#include <QStringList>
#include <QUrl>

namespace {

enum Role {
    LabelRole = Qt::UserRole + 1,
    NodeTypeRole,
    InfoRole,
    ConnectionRole,
    PathRole,
    TableCountRole,
    RowCountRole,
    ParentPathRole,
    DatabaseNameRole,
};

QString countText(int tables, int views)
{
    QStringList parts;
    if (tables > 0)
        parts << QStringLiteral("%1 表").arg(tables);
    if (views > 0)
        parts << QStringLiteral("%1 视图").arg(views);
    return parts.isEmpty() ? QStringLiteral("空") : parts.join(QStringLiteral(" · "));
}

} // namespace

QString DatabaseEntry::fileName() const
{
    const QString name = QFileInfo(filePath).fileName();
    return name.isEmpty() ? filePath : name;
}

int DatabaseEntry::tableCount() const
{
    int n = 0;
    for (const TableInfo &t : tables)
        if (!t.isView)
            ++n;
    return n;
}

int DatabaseEntry::viewCount() const
{
    int n = 0;
    for (const TableInfo &t : tables)
        if (t.isView)
            ++n;
    return n;
}

DbExplorer::DbExplorer(QObject *parent)
    : QObject(parent)
{
    m_treeModel.setColumnCount(1);
    m_databaseModel.setColumnCount(1);

    QHash<int, QByteArray> roles;
    roles[LabelRole] = "label";
    roles[NodeTypeRole] = "nodeType";
    roles[InfoRole] = "info";
    roles[TableCountRole] = "tableCount";
    roles[RowCountRole] = "rowCount";
    roles[ConnectionRole] = "connectionName";
    roles[PathRole] = "path";
    roles[ParentPathRole] = "parentPath";
    roles[DatabaseNameRole] = "databaseName";
    roles[Qt::DisplayRole] = "display";
    roles[Qt::ToolTipRole] = "tip";
    m_treeModel.setItemRoleNames(roles);
    m_databaseModel.setItemRoleNames(roles);

    m_statusText = QStringLiteral("还没有打开数据库，点「打开数据库」选择一个 .db / .sqlite 文件");
}

DbExplorer::~DbExplorer()
{
    closeTable();
    m_databases.clear();
    for (const QString &name : QSqlDatabase::connectionNames()) {
        if (name.startsWith(QLatin1String("sqlite_ui_")))
            QSqlDatabase::removeDatabase(name);
    }
}

int DbExplorer::tableCount() const
{
    int n = 0;
    for (const DatabaseEntry &db : m_databases)
        n += db.tables.size();
    return n;
}

bool DbExplorer::openDatabase(const QUrl &url)
{
    if (!url.isLocalFile()) {
        m_lastError = QStringLiteral("只支持本地文件：%1").arg(url.toString());
        emit changed();
        return false;
    }
    return openDatabaseFile(url.toLocalFile());
}

bool DbExplorer::openDatabaseFile(const QString &rawPath, bool readOnly)
{
    QString path = rawPath.trimmed();

    if (path.startsWith(QLatin1String("file:"), Qt::CaseInsensitive)) {
        const QUrl url(path);
        const QString local = url.toLocalFile();
        if (local.isEmpty()) {
            m_lastError = QStringLiteral("这不是本地文件路径：%1").arg(path);
            emit changed();
            return false;
        }
        path = local;
    }

    if (path.isEmpty()) {
        m_lastError = QStringLiteral("路径为空");
        emit changed();
        return false;
    }

    const QFileInfo info(path);
    if (!info.exists() || !info.isFile()) {
        m_lastError = QStringLiteral("文件不存在：%1").arg(QDir::toNativeSeparators(path));
        emit changed();
        return false;
    }

    const QString canonical =
        info.canonicalFilePath().isEmpty() ? info.absoluteFilePath() : info.canonicalFilePath();

    for (const DatabaseEntry &db : std::as_const(m_databases)) {
        const QFileInfo opened(db.filePath);
        const QString openedPath =
            opened.canonicalFilePath().isEmpty() ? opened.absoluteFilePath() : opened.canonicalFilePath();
        if (openedPath == canonical) {
            m_lastError.clear();
            m_statusText = QStringLiteral("%1 已经打开了").arg(db.fileName());
            refresh();
            emit databaseOpened(canonical);
            return true;
        }
    }

    if (!QSqlDatabase::isDriverAvailable(QStringLiteral("QSQLITE"))) {
        m_lastError = QStringLiteral("找不到 QSQLITE 驱动，请确认 Qt 的 sqldrivers 插件可用。");
        emit changed();
        return false;
    }

    DatabaseEntry entry;
    entry.filePath = canonical;
    entry.readOnly = readOnly;
    entry.connectionName = QStringLiteral("sqlite_ui_%1").arg(++m_connectionSeq);

    bool usable = false;
    {
        QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), entry.connectionName);
        db.setDatabaseName(canonical);
        if (readOnly)
            db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        if (db.open()) {
            usable = readTables(entry);
            if (!usable)
                entry.error = entry.error.isEmpty() ? QStringLiteral("未知错误") : entry.error;
            // 连接故意不关：后面编辑表要一直用它
        } else {
            entry.error = db.lastError().text().trimmed();
        }
    }

    if (!usable && !readOnly && !entry.error.isEmpty()
        && entry.error.contains(QLatin1String("readonly"), Qt::CaseInsensitive)) {
        // 少见情况：文件权限不让写，退回只读再试一次
        entry.readOnly = true;
        QSqlDatabase db = QSqlDatabase::database(entry.connectionName, false);
        db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        if (db.open()) {
            entry.error.clear();
            usable = readTables(entry);
        }
    }

    if (!usable) {
        // 打不开（或者不是 SQLite 文件）就不放进列表，只在提示条里报错
        QSqlDatabase::removeDatabase(entry.connectionName);
        m_lastError = QStringLiteral("打不开 %1：%2")
                          .arg(info.fileName(),
                               entry.error.isEmpty() ? QStringLiteral("不是有效的 SQLite 数据库")
                                                     : entry.error);
        emit changed();
        return false;
    }

    if (entry.readOnly)
        m_lastError = QStringLiteral("%1 只能以只读方式打开（其他程序占用或没有写权限）")
                          .arg(info.fileName());
    else
        m_lastError.clear();

    m_databases.append(entry);
    rebuildModels();
    emit databaseOpened(canonical);
    return true;
}

QString DbExplorer::connectionNameForPath(const QString &rawPath) const
{
    QString path = rawPath.trimmed();
    if (path.startsWith(QLatin1String("file:"), Qt::CaseInsensitive)) {
        const QString local = QUrl(path).toLocalFile();
        if (!local.isEmpty())
            path = local;
    }
    const QFileInfo wanted(path);
    const QString canonical = wanted.canonicalFilePath().isEmpty() ? wanted.absoluteFilePath()
                                                                  : wanted.canonicalFilePath();
    for (const DatabaseEntry &entry : std::as_const(m_databases)) {
        const QFileInfo info(entry.filePath);
        const QString entryPath =
            info.canonicalFilePath().isEmpty() ? info.absoluteFilePath() : info.canonicalFilePath();
        if (entryPath.compare(canonical, Qt::CaseInsensitive) == 0)
            return entry.connectionName;
    }
    return QString();
}

QString DbExplorer::displayNameForConnection(const QString &connectionName) const
{
    for (const DatabaseEntry &entry : std::as_const(m_databases)) {
        if (entry.connectionName == connectionName)
            return entry.fileName();
    }
    return QString();
}

void DbExplorer::reportError(const QString &message)
{
    m_lastError = message;
    emit changed();
}

const DatabaseEntry *DbExplorer::entryForConnection(const QString &connectionName) const
{
    for (const DatabaseEntry &entry : m_databases) {
        if (entry.connectionName == connectionName)
            return &entry;
    }
    return nullptr;
}

bool DbExplorer::runSql(const QString &connectionName, const QString &sql)
{
    const DatabaseEntry *entry = entryForConnection(connectionName);
    if (!entry) {
        const QString message = QStringLiteral("找不到要执行 SQL 的数据库（可能已经关掉了）");
        m_sqlResult.setError(message);
        reportError(message);
        return false;
    }

    const QString fileName = entry->fileName();
    const bool readOnly = entry->readOnly;

    if (m_sessionTable && m_sessionTable->dirtyCount() > 0
        && m_sessionTable->connectionName() == connectionName) {
        const QString message =
            QStringLiteral("表「%1」还有 %2 行改动没保存，请先「保存」或「放弃修改」再执行 SQL")
                .arg(m_sessionTable->tableName())
                .arg(m_sessionTable->dirtyCount());
        m_sqlResult.setError(message);
        reportError(message);
        return false;
    }

    if (readOnly) {
        const QStringList statements = SqlResultModel::splitStatements(sql);
        for (int i = 0; i < statements.size(); ++i) {
            if (!SqlResultModel::isWriteStatement(statements.at(i)))
                continue;
            const QString message =
                QStringLiteral("%1 是以只读方式打开的，不能执行写语句（第 %2 条）")
                    .arg(fileName)
                    .arg(i + 1);
            m_sqlResult.setError(message);
            reportError(message);
            return false;
        }
    }

    const bool ok = m_sqlResult.execute(QSqlDatabase::database(connectionName, false), sql);

    if (!ok) {
        reportError(m_sqlResult.errorText());
        return false;
    }

    m_lastError.clear();

    if (m_sqlResult.wroteData()) {
        if (m_sessionTable && m_sessionTable->connectionName() == connectionName)
            m_sessionTable->reload();
        refreshAfterWrite();
    }

    emit changed();
    return true;
}

bool DbExplorer::isConnectionReadOnly(const QString &connectionName) const
{
    for (const DatabaseEntry &entry : std::as_const(m_databases)) {
        if (entry.connectionName == connectionName)
            return entry.readOnly;
    }
    return false;
}


namespace {
constexpr auto kWidthKey = "window/width";
constexpr auto kHeightKey = "window/height";

constexpr int kMinWidth = 900;
constexpr int kMinHeight = 560;
} // namespace

void DbExplorer::saveWindowSize(int width, int height)
{
    if (width <= 0 || height <= 0)
        return;
    QSettings settings;
    settings.setValue(QLatin1String(kWidthKey), width);
    settings.setValue(QLatin1String(kHeightKey), height);
}

int DbExplorer::savedWindowWidth() const
{
    const int value = QSettings().value(QLatin1String(kWidthKey), 0).toInt();
    return value >= kMinWidth ? value : 0;
}

int DbExplorer::savedWindowHeight() const
{
    const int value = QSettings().value(QLatin1String(kHeightKey), 0).toInt();
    return value >= kMinHeight ? value : 0;
}

bool DbExplorer::openTable(const QString &connectionName, const QString &tableName, bool isView)
{
    if (m_sessionTable && m_sessionTable->connectionName() != connectionName)
        closeTable();

    if (!m_sessionTable) {
        const auto it = std::find_if(m_databases.cbegin(), m_databases.cend(),
                                     [&connectionName](const DatabaseEntry &entry) {
                                         return entry.connectionName == connectionName;
                                     });
        if (it == m_databases.cend()) {
            reportError(QStringLiteral("找不到对应的数据库连接"));
            return false;
        }
        m_sessionTable = new TableModel(connectionName, this);
        m_sessionTable->setFileReadOnly(it->readOnly);
        emit sessionTableChanged();
    }

    const bool ok = m_sessionTable->open(tableName, isView);
    if (!ok) {
        closeTable();
        return false;
    }
    return true;
}

void DbExplorer::closeTable()
{
    if (!m_sessionTable)
        return;

    TableModel *model = m_sessionTable;
    m_sessionTable = nullptr;
    model->close();

    delete model;

    emit sessionTableChanged();
}

bool DbExplorer::hasPendingChanges() const
{
    return m_sessionTable && m_sessionTable->dirtyCount() > 0;
}

bool DbExplorer::readTables(DatabaseEntry &entry)
{
    entry.tables.clear();

    QSqlDatabase db = QSqlDatabase::database(entry.connectionName, false);
    if (!db.isValid() || !db.isOpen()) {
        entry.error = QStringLiteral("数据库连接不可用");
        return false;
    }

    QSqlQuery query(db);
    if (!query.exec(QStringLiteral("SELECT name, type FROM sqlite_master "
                                   "WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' "
                                   "ORDER BY type DESC, name COLLATE NOCASE"))) {
        entry.error = query.lastError().text().trimmed();
        return false;
    }

    while (query.next()) {
        TableInfo table;
        table.name = query.value(0).toString();
        table.isView = (query.value(1).toString() == QLatin1String("view"));

        const QString quoted = QString(table.name).replace(QLatin1Char('"'), QLatin1String("\"\""));
        QSqlQuery countQuery(db);
        if (countQuery.exec(QStringLiteral("SELECT COUNT(*) FROM \"%1\"").arg(quoted)) && countQuery.next())
            table.rowCount = countQuery.value(0).toLongLong();
        else
            table.rowCount = -1;

        entry.tables.append(table);
    }
    return true;
}

QStandardItem *DbExplorer::makeDatabaseItem(const DatabaseEntry &entry) const
{
    auto *item = new QStandardItem(entry.fileName());
    item->setEditable(false);
    item->setData(entry.fileName(), LabelRole);
    item->setData(QStringLiteral("database"), NodeTypeRole);
    item->setData(countText(entry.tableCount(), entry.viewCount()), InfoRole);
    item->setData(entry.connectionName, ConnectionRole);
    item->setData(QDir::toNativeSeparators(entry.filePath), PathRole);
    item->setData(entry.tables.size(), TableCountRole);
    item->setData(QDir::toNativeSeparators(entry.filePath), Qt::ToolTipRole);
    if (entry.readOnly) {
        item->setData(QStringLiteral("%1（只读）").arg(countText(entry.tableCount(), entry.viewCount())),
                      InfoRole);
    }
    if (!entry.error.isEmpty())
        item->setData(QStringLiteral("%1（读取失败）").arg(entry.fileName()), LabelRole);
    return item;
}

void DbExplorer::appendTableItems(QStandardItem *parent, const DatabaseEntry &entry) const
{
    for (const TableInfo &table : entry.tables) {
        auto *item = new QStandardItem(table.name);
        item->setEditable(false);
        item->setData(table.name, LabelRole);
        item->setData(table.isView ? QStringLiteral("view") : QStringLiteral("table"), NodeTypeRole);
        item->setData(table.rowCount, RowCountRole);
        item->setData(entry.connectionName, ConnectionRole);
        item->setData(entry.filePath, ParentPathRole);
        item->setData(entry.fileName(), DatabaseNameRole);
        const QString rowText = table.rowCount >= 0 ? QStringLiteral("%1 行").arg(table.rowCount)
                                                   : QStringLiteral("行数未知");
        item->setData(rowText, InfoRole);
        item->setData(rowText, Qt::ToolTipRole);
        parent->appendRow(item);
    }
}

void DbExplorer::rebuildModels()
{
    m_treeModel.removeRows(0, m_treeModel.rowCount());
    m_databaseModel.removeRows(0, m_databaseModel.rowCount());

    for (const DatabaseEntry &entry : std::as_const(m_databases)) {
        QStandardItem *treeItem = makeDatabaseItem(entry);
        appendTableItems(treeItem, entry);
        m_treeModel.appendRow(treeItem);

        QStandardItem *flatItem = makeDatabaseItem(entry);
        appendTableItems(flatItem, entry);
        m_databaseModel.appendRow(flatItem);
    }

    updateStatus();
    emit changed();
    emit tablesChanged();
}

void DbExplorer::updateStatus()
{
    if (m_databases.isEmpty()) {
        m_statusText = QStringLiteral("还没有打开数据库，点「打开数据库」选择一个 .db / .sqlite 文件");
        return;
    }

    int tables = 0;
    int views = 0;
    for (const DatabaseEntry &entry : std::as_const(m_databases)) {
        tables += entry.tableCount();
        views += entry.viewCount();
    }
    m_statusText = QStringLiteral("已打开 %1 个数据库 · %2 张表 · %3 个视图")
                       .arg(m_databases.size())
                       .arg(tables)
                       .arg(views);
}

QString DbExplorer::databasePathAt(int index) const
{
    if (index < 0 || index >= m_databases.size())
        return QString();
    return m_databases.at(index).filePath;
}

QString DbExplorer::databaseInfoAt(int index) const
{
    if (index < 0 || index >= m_databases.size())
        return QString();
    const DatabaseEntry &entry = m_databases.at(index);
    return countText(entry.tableCount(), entry.viewCount());
}

QString DbExplorer::connectionNameAt(int index) const
{
    if (index < 0 || index >= m_databases.size())
        return QString();
    return m_databases.at(index).connectionName;
}

void DbExplorer::closeDatabase(const QString &connectionName)
{
    for (int i = 0; i < m_databases.size(); ++i) {
        if (m_databases.at(i).connectionName != connectionName)
            continue;
        if (m_sessionTable && m_sessionTable->connectionName() == connectionName)
            closeTable();

        const QString fileName = m_databases.at(i).fileName();
        const QString connection = m_databases.at(i).connectionName;
        m_databases.remove(i);
        QSqlDatabase::removeDatabase(connection);
        m_lastError.clear();
        m_statusText = QStringLiteral("已关闭 %1").arg(fileName);
        rebuildModels();
        return;
    }
}

void DbExplorer::closeAll()
{
    closeTable();
    m_databases.clear();
    for (const QString &name : QSqlDatabase::connectionNames()) {
        if (name.startsWith(QLatin1String("sqlite_ui_")))
            QSqlDatabase::removeDatabase(name);
    }
    m_lastError.clear();
    rebuildModels();
}

void DbExplorer::refresh()
{
    // 连接是常开的（编辑表要用），这里只要重新扫一遍 sqlite_master
    for (DatabaseEntry &entry : m_databases) {
        entry.error.clear();
        QSqlDatabase db = QSqlDatabase::database(entry.connectionName, false);
        if (!db.isValid() || !db.isOpen()) {
            // 连接没了就重建一个，保持原来的读 / 写属性
            db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), entry.connectionName);
            db.setDatabaseName(entry.filePath);
            if (entry.readOnly)
                db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        }
        if (db.isOpen() || db.open())
            readTables(entry);
        else
            entry.error = db.lastError().text().trimmed();
    }
    rebuildModels();
}

namespace {

bool tableSetChanged(const QVector<TableInfo> &before, const QVector<TableInfo> &after)
{
    if (before.size() != after.size())
        return true;
    for (int i = 0; i < before.size(); ++i) {
        if (before.at(i).name != after.at(i).name || before.at(i).isView != after.at(i).isView)
            return true;
    }
    return false;
}

void applyCounts(QStandardItem *dbItem, const DatabaseEntry &entry)
{
    if (!dbItem)
        return;
    for (int j = 0; j < entry.tables.size() && j < dbItem->rowCount(); ++j) {
        QStandardItem *item = dbItem->child(j);
        if (!item)
            continue;
        const TableInfo &table = entry.tables.at(j);
        const QString rowText = table.rowCount >= 0 ? QStringLiteral("%1 行").arg(table.rowCount)
                                                   : QStringLiteral("行数未知");
        item->setData(table.rowCount, RowCountRole);
        item->setData(rowText, InfoRole);
        item->setData(rowText, Qt::ToolTipRole);
    }
}

} // namespace

void DbExplorer::updateItemCounts()
{
    for (int i = 0; i < m_databases.size(); ++i) {
        const DatabaseEntry &entry = m_databases.at(i);
        applyCounts(m_treeModel.item(i), entry);
        applyCounts(m_databaseModel.item(i), entry);
    }
}

void DbExplorer::refreshAfterWrite()
{
    bool structureChanged = false;

    for (DatabaseEntry &entry : m_databases) {
        const QVector<TableInfo> before = entry.tables;
        entry.error.clear();

        QSqlDatabase db = QSqlDatabase::database(entry.connectionName, false);
        if (!db.isValid() || !db.isOpen()) {
            db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), entry.connectionName);
            db.setDatabaseName(entry.filePath);
            if (entry.readOnly)
                db.setConnectOptions(QStringLiteral("QSQLITE_OPEN_READONLY"));
        }

        if (db.isOpen() || db.open())
            readTables(entry);
        else
            entry.error = db.lastError().text().trimmed();

        if (tableSetChanged(before, entry.tables))
            structureChanged = true;
    }

    if (structureChanged) {
        rebuildModels(); // 内部会 emit tablesChanged()
        return;
    }

    updateItemCounts();
    updateStatus();
    emit changed();
}
