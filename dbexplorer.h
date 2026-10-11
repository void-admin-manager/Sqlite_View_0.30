#pragma once

#include <QObject>
#include <QSqlDatabase>
#include <QStandardItemModel>
#include <QString>
#include <QVector>

#include "sqlresultmodel.h"
#include "tablemodel.h"

class QStandardItem;

struct TableInfo
{
    QString name;
    bool isView = false;
    qint64 rowCount = -1;
};

struct DatabaseEntry
{
    QString connectionName;
    QString filePath;
    QVector<TableInfo> tables;
    QString error;
    bool readOnly = false;

    QString fileName() const;
    int tableCount() const;
    int viewCount() const;
};

class DbExplorer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(QStandardItemModel *treeModel READ treeModel CONSTANT)
    Q_PROPERTY(QStandardItemModel *databaseModel READ databaseModel CONSTANT)
    Q_PROPERTY(int databaseCount READ databaseCount NOTIFY changed)
    Q_PROPERTY(int tableCount READ tableCount NOTIFY changed)
    Q_PROPERTY(QString statusText READ statusText NOTIFY changed)
    Q_PROPERTY(QString lastError READ lastError NOTIFY changed)
    Q_PROPERTY(TableModel *sessionTable READ sessionTable NOTIFY sessionTableChanged)
    Q_PROPERTY(SqlResultModel *sqlResult READ sqlResult CONSTANT)

public:
    explicit DbExplorer(QObject *parent = nullptr);
    ~DbExplorer() override;

    QStandardItemModel *treeModel() { return &m_treeModel; }
    QStandardItemModel *databaseModel() { return &m_databaseModel; }

    int databaseCount() const { return int(m_databases.size()); }
    int tableCount() const;
    QString statusText() const { return m_statusText; }
    QString lastError() const { return m_lastError; }
    TableModel *sessionTable() const { return m_sessionTable; }
    SqlResultModel *sqlResult() { return &m_sqlResult; }

    Q_INVOKABLE bool openTable(const QString &connectionName, const QString &tableName, bool isView);
    Q_INVOKABLE void closeTable();
    Q_INVOKABLE bool hasPendingChanges() const;

    Q_INVOKABLE bool openDatabase(const QUrl &url);
    Q_INVOKABLE bool openDatabaseFile(const QString &path, bool readOnly = false);
    Q_INVOKABLE void closeDatabase(const QString &connectionName);
    Q_INVOKABLE void closeAll();
    Q_INVOKABLE void refresh();
    Q_INVOKABLE QString databasePathAt(int index) const;
    Q_INVOKABLE QString databaseInfoAt(int index) const;
    Q_INVOKABLE QString connectionNameAt(int index) const;
    Q_INVOKABLE QString connectionNameForPath(const QString &path) const;
    Q_INVOKABLE QString displayNameForConnection(const QString &connectionName) const;
    Q_INVOKABLE bool isConnectionReadOnly(const QString &connectionName) const;
    Q_INVOKABLE void reportError(const QString &message);
    Q_INVOKABLE bool runSql(const QString &connectionName, const QString &sql);
    Q_INVOKABLE void saveWindowSize(int width, int height);
    Q_INVOKABLE int savedWindowWidth() const;
    Q_INVOKABLE int savedWindowHeight() const;

signals:
    void changed();
    void databaseOpened(const QString &path);
    void tablesChanged();
    void sessionTableChanged();
    void pendingChangesRequired(const QString &reason);

private:
    const DatabaseEntry *entryForConnection(const QString &connectionName) const;
    bool readTables(DatabaseEntry &entry);
    void refreshAfterWrite();
    void updateItemCounts();
    void appendTableItems(QStandardItem *parent, const DatabaseEntry &entry) const;
    QStandardItem *makeDatabaseItem(const DatabaseEntry &entry) const;
    void rebuildModels();
    void updateStatus();

    QVector<DatabaseEntry> m_databases;
    QStandardItemModel m_treeModel;
    QStandardItemModel m_databaseModel;
    TableModel *m_sessionTable = nullptr;
    SqlResultModel m_sqlResult;
    QString m_statusText;
    QString m_lastError;
    int m_connectionSeq = 0;
};
