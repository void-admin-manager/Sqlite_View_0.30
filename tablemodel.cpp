#include "tablemodel.h"

#include <QSqlDatabase>
#include <QSqlError>
#include <QSqlQuery>
#include <QSqlRecord>

TableModel::TableModel(const QString &connectionName, QObject *parent)
    : QSqlTableModel(parent, QSqlDatabase::database(connectionName, false))
    , m_connectionName(connectionName)
{
    // OnManualSubmit：增删改都先在内存里攒着，点「保存」才写文件
    setEditStrategy(QSqlTableModel::OnManualSubmit);
}

TableModel::~TableModel()
{
    close();
}

QHash<int, QByteArray> TableModel::roleNames() const
{
    QHash<int, QByteArray> roles = QSqlTableModel::roleNames();
    roles[DirtyRole] = "dirty";
    return roles;
}

QVariant TableModel::data(const QModelIndex &index, int role) const
{
    if (role == DirtyRole)
        return rowIsDirty(index.row());
    return QSqlTableModel::data(index, role);
}

bool TableModel::setData(const QModelIndex &index, const QVariant &value, int role)
{
    return QSqlTableModel::setData(index, value, role);
}

bool TableModel::canEdit() const
{
    return m_loaded && !m_fileReadOnly && !m_isView && !m_tableReadOnly;
}

void TableModel::setFileReadOnly(bool readOnly)
{
    if (m_fileReadOnly == readOnly)
        return;
    m_fileReadOnly = readOnly;
    emit tableChanged();
}

void TableModel::setMessage(const QString &message)
{
    if (m_message == message)
        return;
    m_message = message;
    emit tableChanged();
}

QVector<ColumnInfo> TableModel::readSchema(const QString &tableName) const
{
    QVector<ColumnInfo> columns;
    QSqlDatabase db = database();
    if (!db.isValid())
        return columns;

    QSqlQuery query(db);
    // PRAGMA 不支持绑定参数，表名自己转义
    const QString quoted = QString(tableName).replace(QLatin1Char('"'), QLatin1String("\"\""));
    if (!query.exec(QStringLiteral("PRAGMA table_info(\"%1\")").arg(quoted)))
        return columns;

    while (query.next()) {
        ColumnInfo info;
        info.name = query.value(1).toString();
        info.type = query.value(2).toString();
        info.notNull = query.value(3).toInt() != 0;
        // 第 5 列是 dflt_value：SQLite 里没有默认值就是 NULL，
        // toString() 会把 NULL 变成空串，正好当「没有默认值」判断
        info.defaultValue = query.value(4).toString();
        info.primaryKey = query.value(5).toInt() > 0;
        columns.append(info);
    }
    return columns;
}

bool TableModel::open(const QString &tableName, bool isView)
{
    close();

    if (tableName.isEmpty()) {
        emit error(QStringLiteral("没有指定表名"));
        return false;
    }

    QSqlDatabase db = database();
    if (!db.isValid() || !db.isOpen()) {
        setMessage(QStringLiteral("数据库连接不可用"));
        emit error(m_message);
        return false;
    }

    m_tableName = tableName;
    m_isView = isView;

    m_columns = readSchema(tableName);
    m_primaryKey.clear();
    for (const ColumnInfo &column : std::as_const(m_columns)) {
        if (column.primaryKey)
            m_primaryKey << column.name;
    }

    setTable(tableName);
    if (!select()) {
        const QString detail = lastError().text().trimmed();
        setMessage(QStringLiteral("读取失败：%1")
                       .arg(detail.isEmpty() ? QStringLiteral("未知错误") : detail));
        emit error(m_message);
        clear();
        m_tableName.clear();
        m_loaded = false;
        emit tableChanged();
        return false;
    }

    m_loaded = true;

    m_tableReadOnly = m_isView || m_primaryKey.isEmpty();

    if (m_isView)
        setMessage(QStringLiteral("视图，只读"));
    else if (m_fileReadOnly)
        setMessage(QStringLiteral("数据库是只读打开的，不能编辑"));
    else if (m_tableReadOnly)
        setMessage(QStringLiteral("这张表没有主键，只能查看"));
    else
        setMessage(QStringLiteral("可以编辑，改完记得点「保存」"));

    refreshDirtyCount();
    emit rowCountChanged();
    emit tableChanged();
    emit loadedChanged();
    return true;
}

void TableModel::close()
{
    if (m_loaded) {
        revertAll();
        clear();
    }
    setTable(QString());
    m_loaded = false;
    m_isView = false;
    m_tableReadOnly = false;
    m_columns.clear();
    m_primaryKey.clear();
    m_tableName.clear();
    m_dirtyCount = 0;
    m_message.clear();
    emit tableChanged();
    emit rowCountChanged();
    emit dirtyCountChanged();
    emit loadedChanged();
}

void TableModel::reload()
{
    if (!m_loaded)
        return;
    revertAll();
    if (!select()) {
        setMessage(QStringLiteral("刷新失败：%1").arg(lastError().text().trimmed()));
        emit error(m_message);
        return;
    }
    refreshDirtyCount();
    emit tableChanged();
}

bool TableModel::addRow()
{
    if (!canEdit()) {
        emit error(QStringLiteral("这张表不能新增数据"));
        return false;
    }

    const int row = rowCount();
    // QSqlTableModel 只有基类的 insertRows/removeRows，没有单行版本
    if (!insertRows(row, 1)) {
        emit error(QStringLiteral("新增失败：%1").arg(lastError().text().trimmed()));
        return false;
    }

    // 主键是整数的话，自动填一个下一个可用值，省得用户自己算
    if (m_primaryKey.size() == 1) {
        const int pkIndex = primaryKeyColumnIndex();
        if (pkIndex >= 0
            && m_columns.at(pkIndex).type.contains(QLatin1String("INT"), Qt::CaseInsensitive)
            && data(index(row, pkIndex)).isNull()) {
            QSqlQuery query(database());
            const QString quoted = QString(m_tableName).replace(QLatin1Char('"'), QLatin1String("\"\""));
            const QString pkQuoted = QString(m_primaryKey.first())
                                         .replace(QLatin1Char('"'), QLatin1String("\"\""));
            if (query.exec(QStringLiteral("SELECT IFNULL(MAX(\"%1\"), 0) + 1 FROM \"%2\"")
                               .arg(pkQuoted, quoted))
                && query.next()) {
                setData(index(row, pkIndex), query.value(0));
            }
        }
    }

    refreshDirtyCount();
    emit rowCountChanged();
    return true;
}

bool TableModel::removeRowAt(int row)
{
    if (!canEdit()) {
        emit error(QStringLiteral("这张表不能删除数据"));
        return false;
    }
    if (row < 0 || row >= rowCount()) {
        emit error(QStringLiteral("行号超出范围：%1").arg(row));
        return false;
    }

    if (!removeRows(row, 1)) {
        emit error(QStringLiteral("删除失败：%1").arg(lastError().text().trimmed()));
        return false;
    }

    refreshDirtyCount();
    emit rowCountChanged();
    return true;
}

bool TableModel::save()
{
    if (!canEdit()) {
        emit error(QStringLiteral("这张表不能保存改动"));
        return false;
    }

    if (!submitAll()) {
        const QString detail = lastError().text().trimmed();
        emit error(QStringLiteral("保存失败：%1")
                       .arg(detail.isEmpty() ? QStringLiteral("未知错误") : detail));
        return false;
    }

    refreshDirtyCount();
    emit rowCountChanged();
    setMessage(QStringLiteral("已保存到数据库文件"));
    emit saved();
    return true;
}

bool TableModel::discardChanges()
{
    revertAll();
    refreshDirtyCount();
    emit rowCountChanged();
    setMessage(QStringLiteral("已放弃未保存的改动"));
    return true;
}

void TableModel::refreshDirtyCount()
{
    int dirty = 0;
    if (m_loaded) {
        // 基类那版 isDirty() 是空实现，必须用 QSqlTableModel::isDirty(index)
        for (int row = 0; row < rowCount(); ++row) {
            if (rowIsDirty(row))
                ++dirty;
        }
    }

    if (m_dirtyCount != dirty) {
        m_dirtyCount = dirty;
        emit dirtyCountChanged();
    }
    // dirty 角色可能变了，让 delegate 重画
    if (m_loaded && rowCount() > 0 && columnCount() > 0)
        emit dataChanged(index(0, 0), index(rowCount() - 1, columnCount() - 1), {DirtyRole});
}

QString TableModel::columnName(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return QString();
    return m_columns.at(column).name;
}

QString TableModel::columnType(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return QString();
    const ColumnInfo &info = m_columns.at(column);
    return info.type.isEmpty() ? QStringLiteral("(无类型)") : info.type;
}

bool TableModel::columnIsPrimaryKey(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return false;
    return m_columns.at(column).primaryKey;
}

// 必填 = NOT NULL 且没有默认值。
// 主键里的 INTEGER PRIMARY KEY 是 SQLite 的 rowid 别名，不填会自动生成，不算必填。
bool TableModel::columnIsRequired(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return false;
    const ColumnInfo &info = m_columns.at(column);
    if (!info.notNull)
        return false;
    if (!info.defaultValue.isEmpty())
        return false; // 有默认值，不填也能插入
    if (columnIsAutoIncrement(column))
        return false; // 自增主键，自动生成
    return true;
}

QString TableModel::columnDefault(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return QString();
    return m_columns.at(column).defaultValue;
}

bool TableModel::columnIsAutoIncrement(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return false;
    const ColumnInfo &info = m_columns.at(column);
    return info.primaryKey
           && info.type.contains(QLatin1String("INT"), Qt::CaseInsensitive);
}

int TableModel::primaryKeyColumnIndex() const
{
    for (int i = 0; i < m_columns.size(); ++i) {
        if (m_columns.at(i).primaryKey)
            return i;
    }
    return -1;
}

QString TableModel::valueAt(int row, int column) const
{
    const QModelIndex idx = index(row, column);
    if (!idx.isValid())
        return QString();
    const QVariant value = data(idx);
    return value.isNull() ? QStringLiteral("(NULL)") : value.toString();
}

QStringList TableModel::columnNames() const
{
    QStringList names;
    for (const ColumnInfo &column : m_columns)
        names << column.name;
    return names;
}

bool TableModel::editCell(int row, int column, const QVariant &value)
{
    if (!canEdit()) {
        emit error(QStringLiteral("这张表不能修改数据"));
        return false;
    }
    const QModelIndex idx = index(row, column);
    if (!idx.isValid()) {
        emit error(QStringLiteral("单元格不存在：第 %1 行第 %2 列").arg(row + 1).arg(column + 1));
        return false;
    }
    const bool ok = setData(idx, value, Qt::EditRole);
    if (!ok)
        emit error(QStringLiteral("这个单元格写不进去（可能是只读列或类型不允许）"));
    refreshDirtyCount();
    return ok;
}

int TableModel::columnCount() const
{
    return QSqlTableModel::columnCount();
}

bool TableModel::rowIsDirty(int row) const
{
    if (!m_loaded || row < 0 || row >= rowCount())
        return false;
    for (int column = 0; column < columnCount(); ++column) {
        if (QSqlTableModel::isDirty(index(row, column)))
            return true;
    }
    return false;
}
