cmake_minimum_required(VERSION 3.16)
project(qnnt-2 VERSION 1.0 LANGUAGES C CXX)

set(CMAKE_INCLUDE_CURRENT_DIR ON)

find_package(Qt6 REQUIRED COMPONENTS Gui)

qt_standard_project_setup()

)
target_link_libraries(qnnt-2 PRIVATE
    Qt::Core
    Qt::Gui
)

install(TARGETS qnnt-2
    BUNDLE DESTINATION .
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

qt_generate_deploy_app_script(
    TARGET qnnt-2
    FILENAME_VARIABLE deploy_script
    NO_UNSUPPORTED_PLATFORM_ERROR
)
install(SCRIPT ${deploy_script})
