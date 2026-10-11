cmake_minimum_required(VERSION 3.16)

project(Sqlite_UI VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick Gui Qml Sql)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(appSqlite_UI
    main.cpp
    dbexplorer.h
    dbexplorer.cpp
    tablemodel.h
    tablemodel.cpp
    sqlresultmodel.h
    sqlresultmodel.cpp
)

qt_add_qml_module(appSqlite_UI
    URI Sqlite_UI
    VERSION 1.0
    QML_FILES
        Main.qml
        TableDataView.qml
        AppButton.qml
        SqlConsole.qml
)

set_target_properties(appSqlite_UI PROPERTIES
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
    OUTPUT_NAME Sqlite_UI
)

target_link_libraries(appSqlite_UI
    PRIVATE Qt6::Quick Qt6::Gui Qt6::Qml Qt6::Sql
)

include(GNUInstallDirs)
install(TARGETS appSqlite_UI
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)
