#pragma once

#include <QAbstractTableModel>
#include <QHash>
#include <QSqlDatabase>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVector>

class SqlResultModel : public QAbstractTableModel
{
    Q_OBJECT
    Q_PROPERTY(QString errorText READ errorText NOTIFY resultChanged)
    Q_PROPERTY(QString infoText READ infoText NOTIFY resultChanged)
    Q_PROPERTY(QString executedSql READ executedSql NOTIFY resultChanged)
    Q_PROPERTY(bool hasResult READ hasResult NOTIFY resultChanged)
    Q_PROPERTY(bool truncated READ isTruncated NOTIFY resultChanged)
    Q_PROPERTY(bool wroteData READ wroteData NOTIFY resultChanged)
    Q_PROPERTY(int affectedRows READ affectedRows NOTIFY resultChanged)
    Q_PROPERTY(int elapsedMs READ elapsedMs NOTIFY resultChanged)
    Q_PROPERTY(int statementCount READ statementCount NOTIFY resultChanged)
    Q_PROPERTY(int failedIndex READ failedIndex NOTIFY resultChanged)
    Q_PROPERTY(int rowCountValue READ rowCount NOTIFY resultChanged)

public:
    enum ExtraRole {
        NullValueRole = Qt::UserRole + 1,
    };

    explicit SqlResultModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    int columnCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    QVariant headerData(int section, Qt::Orientation orientation,
                        int role = Qt::DisplayRole) const override;
    QHash<int, QByteArray> roleNames() const override;

    QString errorText() const { return m_error; }
    QString infoText() const { return m_info; }
    QString executedSql() const { return m_executedSql; }
    bool hasResult() const { return !m_columns.isEmpty(); }
    bool isTruncated() const { return m_truncated; }
    bool wroteData() const { return m_wroteData; }
    int affectedRows() const { return m_affectedRows; }
    int elapsedMs() const { return m_elapsedMs; }
    int statementCount() const { return m_statementCount; }
    int failedIndex() const { return m_failedIndex; }

    Q_INVOKABLE QString columnName(int column) const;
    Q_INVOKABLE int columns() const { return int(m_columns.size()); }
    Q_INVOKABLE int rows() const { return int(m_rows.size()); }
    Q_INVOKABLE qreal columnWidthHint(int column) const;
    Q_INVOKABLE void clear();

    bool execute(const QSqlDatabase &db, const QString &sql);
    void setError(const QString &message);

    static QStringList splitStatements(const QString &sql);
    static bool isWriteStatement(const QString &statement);

signals:
    void resultChanged();

private:
    static QString displayText(const QVariant &value);

    QStringList m_columns;
    QVector<QVector<QVariant>> m_rows;
    QString m_error;
    QString m_info;
    QString m_executedSql;
    int m_affectedRows = 0;
    int m_elapsedMs = 0;
    int m_statementCount = 0;
    int m_failedIndex = -1;
    bool m_truncated = false;
    bool m_wroteData = false;
};
