cmake_minimum_required(VERSION 3.20)
project(WingMultitrackRenamerWin32 LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_executable(WingMultitrackRenamer WIN32
  src/main.cpp
)

target_include_directories(WingMultitrackRenamer PRIVATE include)

target_compile_definitions(WingMultitrackRenamer PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)

target_link_libraries(WingMultitrackRenamer PRIVATE comctl32 shell32 ole32 shlwapi)

if(MSVC)
  target_compile_options(WingMultitrackRenamer PRIVATE /W4 /permissive- /utf-8)
  set_property(TARGET WingMultitrackRenamer PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
else()
  target_compile_options(WingMultitrackRenamer PRIVATE -Wall -Wextra -Wpedantic)
  target_link_options(WingMultitrackRenamer PRIVATE -static -static-libgcc -static-libstdc++ -municode)
endif()

install(TARGETS WingMultitrackRenamer RUNTIME DESTINATION .)

set(CPACK_PACKAGE_NAME "Wing Multitrack Renamer")
set(CPACK_PACKAGE_VENDOR "Lev Aranovich")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Rename WING multitrack WAV files from a .snap file")
set(CPACK_PACKAGE_INSTALL_DIRECTORY "Wing Multitrack Renamer")
set(CPACK_PACKAGE_FILE_NAME "Wing-Multitrack-Renamer-Windows")
set(CPACK_GENERATOR "NSIS")
set(CPACK_NSIS_DISPLAY_NAME "Wing Multitrack Renamer")
set(CPACK_NSIS_PACKAGE_NAME "Wing Multitrack Renamer")
set(CPACK_NSIS_ENABLE_UNINSTALL_BEFORE_INSTALL ON)
set(CPACK_NSIS_MUI_ICON "${CMAKE_SOURCE_DIR}/resources/app.ico")
set(CPACK_NSIS_MUI_UNIICON "${CMAKE_SOURCE_DIR}/resources/app.ico")
set(CPACK_NSIS_INSTALLED_ICON_NAME "WingMultitrackRenamer.exe")
set(CPACK_NSIS_CREATE_ICONS_EXTRA "CreateShortCut '$SMPROGRAMS\\\\$STARTMENU_FOLDER\\\\Wing Multitrack Renamer.lnk' '$INSTDIR\\\\WingMultitrackRenamer.exe'")
set(CPACK_NSIS_DELETE_ICONS_EXTRA "Delete '$SMPROGRAMS\\\\$STARTMENU_FOLDER\\\\Wing Multitrack Renamer.lnk'")
include(CPack)
