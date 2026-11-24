cmake_minimum_required(VERSION 3.5.0)
project(miwen)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${NATIVE_ROOT})

add_library(miwen SHARED
    napi_init.cpp
    decoder.cpp
    fmt_aiff.cpp
)

target_link_libraries(miwen PUBLIC libace_napi.z.so libhilog_ndk.z.so)
