#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QStringList>

#include "dbexplorer.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Sqlite_UI"));
    app.setOrganizationName(QStringLiteral("Sqlite_UI"));

    // 命令行：第一个非选项参数当成要打开的数据库文件。
    // 例：appSqlite_UI.exe "D:\data\demo.db"
    QString initialDatabase;
    const QStringList args = app.arguments();
    for (int i = 1; i < args.size(); ++i) {
        const QString arg = args.at(i);
        if (!arg.startsWith(QLatin1Char('-')) && initialDatabase.isEmpty())
            initialDatabase = arg;
    }

    DbExplorer explorer;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("explorer"), &explorer);
    // 窗口创建完成后再打开命令行指定的数据库（这样能顺便自动展开）
    engine.rootContext()->setContextProperty(QStringLiteral("initialDatabasePath"), initialDatabase);
    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("Sqlite_UI", "Main");

    return app.exec();
}
