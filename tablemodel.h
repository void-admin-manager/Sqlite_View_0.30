#pragma once

#include <QSqlTableModel>
#include <QString>
#include <QStringList>
#include <QVector>

struct ColumnInfo
{
    QString name;
    QString type;
    bool notNull = false;
    bool primaryKey = false;
    QString defaultValue;
};

class TableModel : public QSqlTableModel
{
    Q_OBJECT
    Q_PROPERTY(bool loaded READ isLoaded NOTIFY loadedChanged)
    Q_PROPERTY(QString tableName READ tableName NOTIFY tableChanged)
    Q_PROPERTY(QString connectionName READ connectionName NOTIFY tableChanged)
    Q_PROPERTY(bool fileReadOnly READ isFileReadOnly NOTIFY tableChanged)
    Q_PROPERTY(bool canEdit READ canEdit NOTIFY tableChanged)
    Q_PROPERTY(int rowCountValue READ rowCount NOTIFY rowCountChanged)
    Q_PROPERTY(int dirtyCount READ dirtyCount NOTIFY dirtyCountChanged)
    Q_PROPERTY(QString primaryKey READ primaryKey NOTIFY tableChanged)
    Q_PROPERTY(QString message READ message NOTIFY tableChanged)

public:
    enum ExtraRole {
        DirtyRole = Qt::UserRole + 100,
    };

    explicit TableModel(const QString &connectionName, QObject *parent = nullptr);
    ~TableModel() override;

    QVariant data(const QModelIndex &index, int role = Qt::DisplayRole) const override;
    bool setData(const QModelIndex &index, const QVariant &value,
                 int role = Qt::EditRole) override;
    QHash<int, QByteArray> roleNames() const override;

    bool isLoaded() const { return m_loaded; }
    QString tableName() const { return m_tableName; }
    QString connectionName() const { return m_connectionName; }
    bool isFileReadOnly() const { return m_fileReadOnly; }
    bool canEdit() const;
    int dirtyCount() const { return m_dirtyCount; }
    QString primaryKey() const { return m_primaryKey.join(QStringLiteral(", ")); }
    QString message() const { return m_message; }

    void setFileReadOnly(bool readOnly);
    bool open(const QString &tableName, bool isView);
    Q_INVOKABLE void close();
    Q_INVOKABLE void reload();

    Q_INVOKABLE bool addRow();
    Q_INVOKABLE bool removeRowAt(int row);
    Q_INVOKABLE bool save();
    Q_INVOKABLE bool discardChanges();

    Q_INVOKABLE QString columnName(int column) const;
    Q_INVOKABLE QString columnType(int column) const;
    Q_INVOKABLE bool columnIsPrimaryKey(int column) const;
    Q_INVOKABLE bool columnIsRequired(int column) const;
    Q_INVOKABLE QString columnDefault(int column) const;
    Q_INVOKABLE bool columnIsAutoIncrement(int column) const;
    Q_INVOKABLE int primaryKeyColumnIndex() const;
    Q_INVOKABLE QString valueAt(int row, int column) const;
    Q_INVOKABLE bool editCell(int row, int column, const QVariant &value);
    Q_INVOKABLE QStringList columnNames() const;
    Q_INVOKABLE bool rowIsDirty(int row) const;
    Q_INVOKABLE int columnCount() const;

signals:
    void loadedChanged();
    void tableChanged();
    void rowCountChanged();
    void dirtyCountChanged();
    void saved();
    void error(const QString &message);

private:
    void refreshDirtyCount();
    void setMessage(const QString &message);
    QVector<ColumnInfo> readSchema(const QString &tableName) const;

    QVector<ColumnInfo> m_columns;
    QStringList m_primaryKey;
    QString m_tableName;
    QString m_connectionName;
    QString m_message;
    bool m_loaded = false;
    bool m_isView = false;
    bool m_fileReadOnly = false;
    bool m_tableReadOnly = false;
    int m_dirtyCount = 0;
};
