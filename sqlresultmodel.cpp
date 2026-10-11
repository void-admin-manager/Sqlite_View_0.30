#include "sqlresultmodel.h"

#include <QElapsedTimer>
#include <QMetaType>
#include <QSqlError>
#include <QSqlQuery>
#include <QSqlRecord>
#include <QStringList>

namespace {

// 一次最多往网格里装多少行。
constexpr int kMaxRows = 5000;

// 跳过开头的空白和注释，返回第一条真正的代码的位置；返回 size 说明整段只有注释 / 空白
int firstCodeIndex(const QString &sql)
{
    int i = 0;
    const int n = sql.size();
    while (i < n) {
        const QChar c = sql.at(i);
        if (c.isSpace()) {
            ++i;
            continue;
        }
        // -- 行注释
        if (c == QLatin1Char('-') && i + 1 < n && sql.at(i + 1) == QLatin1Char('-')) {
            while (i < n && sql.at(i) != QLatin1Char('\n'))
                ++i;
            continue;
        }
        // /* 块注释 */
        if (c == QLatin1Char('/') && i + 1 < n && sql.at(i + 1) == QLatin1Char('*')) {
            i += 2;
            while (i + 1 < n
                   && !(sql.at(i) == QLatin1Char('*') && sql.at(i + 1) == QLatin1Char('/')))
                ++i;
            i = qMin(i + 2, n);
            continue;
        }
        break;
    }
    return i;
}

} // namespace

SqlResultModel::SqlResultModel(QObject *parent)
    : QAbstractTableModel(parent)
{
}

QHash<int, QByteArray> SqlResultModel::roleNames() const
{
    QHash<int, QByteArray> roles;
    roles[Qt::DisplayRole] = "display";
    roles[NullValueRole] = "nullValue";
    return roles;
}

int SqlResultModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_rows.size());
}

int SqlResultModel::columnCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_columns.size());
}

QString SqlResultModel::displayText(const QVariant &value)
{
    if (value.isNull())
        return QStringLiteral("(NULL)");
    if (value.typeId() == QMetaType::QByteArray) {
        // BLOB 直接 toString() 会出来一堆乱码，显示个长度就够了
        return QStringLiteral("<BLOB %1 字节>").arg(value.toByteArray().size());
    }
    if (value.typeId() == QMetaType::Double || value.typeId() == QMetaType::Float)
        return QString::number(value.toDouble(), 'g', 15); // 免得 1.0 显示成 1.000000
    return value.toString();
}

QVariant SqlResultModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= m_rows.size())
        return QVariant();
    const QVector<QVariant> &row = m_rows.at(index.row());
    if (index.column() < 0 || index.column() >= row.size())
        return QVariant();

    const QVariant &value = row.at(index.column());
    if (role == NullValueRole)
        return value.isNull();
    if (role == Qt::DisplayRole)
        return displayText(value);
    return QVariant();
}

QVariant SqlResultModel::headerData(int section, Qt::Orientation orientation, int role) const
{
    if (role != Qt::DisplayRole)
        return QVariant();
    if (orientation == Qt::Horizontal)
        return columnName(section);
    return section + 1; // 纵向就是行号
}

QString SqlResultModel::columnName(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return QString();
    return m_columns.at(column);
}

qreal SqlResultModel::columnWidthHint(int column) const
{
    if (column < 0 || column >= m_columns.size())
        return 150.0;

    int maxChars = m_columns.at(column).size();
    const int sample = qMin(int(m_rows.size()), 200);
    for (int i = 0; i < sample; ++i) {
        const QVector<QVariant> &row = m_rows.at(i);
        if (column < row.size())
            maxChars = qMax(maxChars, displayText(row.at(column)).size());
    }
    return qBound(96.0, maxChars * 7.4 + 26.0, 340.0);
}

void SqlResultModel::clear()
{
    beginResetModel();
    m_columns.clear();
    m_rows.clear();
    endResetModel();

    m_error.clear();
    m_info.clear();
    m_executedSql.clear();
    m_affectedRows = 0;
    m_elapsedMs = 0;
    m_statementCount = 0;
    m_failedIndex = -1;
    m_truncated = false;
    m_wroteData = false;
    emit resultChanged();
}

void SqlResultModel::setError(const QString &message)
{
    m_error = message;
    emit resultChanged();
}

QStringList SqlResultModel::splitStatements(const QString &sql)
{
    // 一个很小的状态机：只有「代码状态」下的分号才算语句结束，
    // 单引号 / 双引号 / 反引号 / 方括号 / -- 注释 / /* */ 注释里的分号都是普通字符。
    enum State { Code, SingleQuote, DoubleQuote, Backtick, Bracket, LineComment, BlockComment };

    QStringList statements;
    QString current;
    State state = Code;
    const int n = sql.size();

    for (int i = 0; i < n; ++i) {
        const QChar c = sql.at(i);
        const QChar next = (i + 1 < n) ? sql.at(i + 1) : QChar();
        bool handled = false; // true = 这个字符已经在下面自己塞进 current 了

        switch (state) {
        case Code:
            if (c == QLatin1Char('\'')) {
                state = SingleQuote;
            } else if (c == QLatin1Char('"')) {
                state = DoubleQuote;
            } else if (c == QLatin1Char('`')) {
                state = Backtick;
            } else if (c == QLatin1Char('[')) {
                state = Bracket;
            } else if (c == QLatin1Char('-') && next == QLatin1Char('-')) {
                state = LineComment;
                current += c;
                current += next;
                ++i;
                handled = true;
            } else if (c == QLatin1Char('/') && next == QLatin1Char('*')) {
                state = BlockComment;
                current += c;
                current += next;
                ++i;
                handled = true;
            } else if (c == QLatin1Char(';')) {
                const QString statement = current.trimmed();
                // 纯注释 / 纯空白的片段直接丢掉：SQLite 对空语句会报 "not an error"，很难懂
                if (firstCodeIndex(statement) < statement.size())
                    statements.append(statement);
                current.clear();
                handled = true;
            }
            break;

        case SingleQuote:
            if (c == QLatin1Char('\'')) {
                // SQL 里 '' 表示一个单引号，不是字符串结束
                if (next == QLatin1Char('\'')) {
                    current += c;
                    current += next;
                    ++i;
                    handled = true;
                } else {
                    state = Code;
                }
            }
            break;

        case DoubleQuote:
            if (c == QLatin1Char('"')) {
                if (next == QLatin1Char('"')) {
                    current += c;
                    current += next;
                    ++i;
                    handled = true;
                } else {
                    state = Code;
                }
            }
            break;

        case Backtick:
            if (c == QLatin1Char('`'))
                state = Code;
            break;

        case Bracket:
            if (c == QLatin1Char(']'))
                state = Code;
            break;

        case LineComment:
            if (c == QLatin1Char('\n'))
                state = Code;
            break;

        case BlockComment:
            if (c == QLatin1Char('*') && next == QLatin1Char('/')) {
                current += c;
                current += next;
                ++i;
                state = Code;
                handled = true;
            }
            break;
        }

        if (!handled)
            current += c;
    }

    const QString tail = current.trimmed();
    if (firstCodeIndex(tail) < tail.size())
        statements.append(tail);
    return statements;
}

bool SqlResultModel::isWriteStatement(const QString &statement)
{
    const int start = firstCodeIndex(statement);
    if (start >= statement.size())
        return false;

    int end = start;
    while (end < statement.size()
           && (statement.at(end).isLetterOrNumber() || statement.at(end) == QLatin1Char('_')))
        ++end;
    const QString word = statement.mid(start, end - start).toUpper();

    // 认得出是「只读」的才放行，其余一律当成写操作：
    // 只读库的拦截宁可严一点（真放过去了 SQLite 也会自己报错）。
    static const QStringList kReadOnlyWords = {
        QStringLiteral("SELECT"), QStringLiteral("WITH"), QStringLiteral("EXPLAIN"),
        QStringLiteral("VALUES"), QStringLiteral("PRAGMA"),
    };
    return !kReadOnlyWords.contains(word);
}

bool SqlResultModel::execute(const QSqlDatabase &db, const QString &sql)
{
    clear();
    m_executedSql = sql;

    if (!db.isValid() || !db.isOpen()) {
        setError(QStringLiteral("数据库连接不可用"));
        return false;
    }

    const QStringList statements = splitStatements(sql);
    m_statementCount = int(statements.size());
    if (statements.isEmpty()) {
        setError(QStringLiteral("没有可执行的 SQL 语句"));
        return false;
    }

    QElapsedTimer timer;
    timer.start();

    QStringList columns;
    QVector<QVector<QVariant>> rows;
    QString error;
    int affected = 0;
    int failedIndex = -1;
    int done = 0;
    bool truncated = false;
    bool wrote = false;

    for (int i = 0; i < statements.size(); ++i) {
        const QString &statement = statements.at(i);

        // 每条语句用一个新的 QSqlQuery：省得纠结「上一条结果集读完没有」。
        QSqlQuery query(db);
        if (!query.exec(statement)) {
            // databaseText() 是驱动原本的报错（"no such table: xxx"）；
            // text() 会在后面再拼一句 Qt 自己的话（"无法执行语句"），读起来很别扭
            const QSqlError sqlError = query.lastError();
            QString detail = sqlError.databaseText().trimmed();
            if (detail.isEmpty())
                detail = sqlError.text().trimmed();
            error = QStringLiteral("第 %1 条语句出错：%2")
                        .arg(i + 1)
                        .arg(detail.isEmpty() ? QStringLiteral("未知错误") : detail);
            failedIndex = i;
            break;
        }
        ++done;

        const int touched = query.numRowsAffected();
        if (isWriteStatement(statement) || touched > 0)
            wrote = true;

        const QSqlRecord record = query.record();
        // isSelect() 覆盖 SELECT；record().count() > 0 兜住 PRAGMA / RETURNING 这类也有输出列的语句
        if (query.isSelect() || record.count() > 0) {
            columns.clear();
            rows.clear();
            for (int c = 0; c < record.count(); ++c)
                columns.append(record.fieldName(c));

            while (query.next()) {
                if (rows.size() >= kMaxRows) {
                    truncated = true;
                    break;
                }
                QVector<QVariant> row;
                row.reserve(columns.size());
                for (int c = 0; c < columns.size(); ++c)
                    row.append(query.value(c));
                rows.append(row);
            }
            query.finish();
        } else if (touched > 0) {
            affected += touched;
        }
    }

    m_elapsedMs = int(timer.elapsed());

    beginResetModel();
    m_columns = columns;
    m_rows = rows;
    m_affectedRows = affected;
    m_truncated = truncated;
    m_wroteData = wrote;
    m_failedIndex = failedIndex;
    m_error = error;
    m_info = QString();
    endResetModel();

    if (failedIndex >= 0) {
        m_info = QStringLiteral("已执行 %1 / %2 条语句").arg(done).arg(m_statementCount);
    } else {
        QStringList parts;
        if (m_statementCount > 1)
            parts << QStringLiteral("%1 条语句").arg(m_statementCount);
        if (!m_columns.isEmpty()) {
            parts << QStringLiteral("%1 列 / %2 行").arg(m_columns.size()).arg(m_rows.size());
            if (m_truncated) {
                parts << QStringLiteral("结果超过 %1 行，只载入了前 %2 行")
                             .arg(kMaxRows).arg(kMaxRows);
            }
        }
        if (m_affectedRows > 0)
            parts << QStringLiteral("影响 %1 行").arg(m_affectedRows);
        if (parts.isEmpty())
            parts << QStringLiteral("执行成功，没有返回数据");
        parts << QStringLiteral("耗时 %1 ms").arg(m_elapsedMs);
        m_info = parts.join(QStringLiteral(" · "));
    }

    emit resultChanged();
    return failedIndex < 0;
}
