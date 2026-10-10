cmake_minimum_required(VERSION 3.25)

project(LibtorrentNative VERSION 0.2.2 LANGUAGES CXX)

if(NOT DEFINED LIBTORRENT_SOURCE_DIR)
    message(FATAL_ERROR "LIBTORRENT_SOURCE_DIR must point to a libtorrent source checkout.")
endif()
if(NOT DEFINED LIBTORRENT_CA_BUNDLE OR NOT EXISTS "${LIBTORRENT_CA_BUNDLE}")
    message(FATAL_ERROR "LIBTORRENT_CA_BUNDLE must point to a verified PEM CA bundle.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(build_tests OFF CACHE BOOL "" FORCE)
set(build_examples OFF CACHE BOOL "" FORCE)
set(build_tools OFF CACHE BOOL "" FORCE)
set(build_python_binding OFF CACHE BOOL "" FORCE)

add_subdirectory("${LIBTORRENT_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/libtorrent")

if(TARGET LibtorrentRasterbar::torrent-rasterbar)
    set(LIBTORRENT_CMAKE_TARGET LibtorrentRasterbar::torrent-rasterbar)
elseif(TARGET torrent-rasterbar)
    set(LIBTORRENT_CMAKE_TARGET torrent-rasterbar)
else()
    message(FATAL_ERROR "The libtorrent CMake target was not found after add_subdirectory().")
endif()

# The pinned openssl-apple binary intentionally hides OpenSSL 3's deprecated
# low-level digest contexts. Use Apple's CommonCrypto for piece hashing while
# retaining OpenSSL for TLS, certificate validation, and secure randomness.
target_compile_definitions(${LIBTORRENT_CMAKE_TARGET}
    PUBLIC
        TORRENT_USE_COMMONCRYPTO
)

add_library(LibtorrentNative SHARED
    src/LibtorrentNative.cpp
    "${LIBTORRENT_CA_BUNDLE}"
)

set_source_files_properties("${LIBTORRENT_CA_BUNDLE}" PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources
)

target_include_directories(LibtorrentNative
    PUBLIC
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
        "$<INSTALL_INTERFACE:include>"
)

target_link_libraries(LibtorrentNative
    PRIVATE
        ${LIBTORRENT_CMAKE_TARGET}
        "-framework CoreFoundation"
)

set_target_properties(LibtorrentNative PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    MACOSX_FRAMEWORK_IDENTIFIER io.github.tryagi.libtorrent-native
    PUBLIC_HEADER include/LibtorrentNative.h
    XCODE_ATTRIBUTE_BUILD_LIBRARY_FOR_DISTRIBUTION YES
    XCODE_ATTRIBUTE_DEFINES_MODULE YES
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER io.github.tryagi.libtorrent-native
    XCODE_ATTRIBUTE_SKIP_INSTALL NO
)
