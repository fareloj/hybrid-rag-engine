cmake_minimum_required(VERSION 3.20)
project(dense_index LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)
FetchContent_Declare(
    hnswlib
    GIT_REPOSITORY https://github.com/nmslib/hnswlib.git
    GIT_TAG v0.9.0
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(hnswlib)

add_executable(dense-index src/main.cpp)
target_include_directories(dense-index PRIVATE ${hnswlib_SOURCE_DIR})
