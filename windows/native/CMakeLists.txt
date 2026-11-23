# CuvenCore.dll —— Cuven for Windows 的原生核心（D3D11 + FFmpeg + WASAPI）
#   cmake -S windows/native -B build -A x64 -DFFMPEG_DIR=<FFmpeg 共享库：include/ lib/ bin/>
#   cmake --build build --config Release
cmake_minimum_required(VERSION 3.20)
project(CuvenCore LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# 静态 C 运行库：不用另装 VC++ 运行库
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(FFMPEG_DIR "" CACHE PATH "FFmpeg 共享库（include/ lib/ bin/）")
if(NOT FFMPEG_DIR)
  message(FATAL_ERROR "请用 -DFFMPEG_DIR=... 指定 FFmpeg")
endif()

file(GLOB CUVEN_SRC CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp)
file(GLOB CUVEN_HLSL CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/shaders/*.hlsl)
set(GEN ${CMAKE_CURRENT_BINARY_DIR}/gen)
# 列表里的分号到了 shell 里会把命令截断：换成 | 传进去
string(REPLACE ";" "|" CUVEN_HLSL_ARG "${CUVEN_HLSL}")
add_custom_command(
  OUTPUT ${GEN}/shaders_gen.cpp ${GEN}/shaders_gen.h
  COMMAND ${CMAKE_COMMAND} -DOUT=${GEN} "-DIN=${CUVEN_HLSL_ARG}" -P ${CMAKE_CURRENT_SOURCE_DIR}/embed.cmake
  DEPENDS ${CUVEN_HLSL} ${CMAKE_CURRENT_SOURCE_DIR}/embed.cmake
  COMMENT "嵌入着色器"
  VERBATIM)

add_library(CuvenCore SHARED ${CUVEN_SRC} ${GEN}/shaders_gen.cpp)
target_include_directories(CuvenCore PRIVATE ${FFMPEG_DIR}/include ${GEN} ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(CuvenCore PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)

foreach(L avformat avcodec avutil swresample swscale)
  find_library(FF_${L} NAMES ${L} lib${L} PATHS ${FFMPEG_DIR}/lib NO_DEFAULT_PATH REQUIRED)
  target_link_libraries(CuvenCore PRIVATE ${FF_${L}})
endforeach()
target_link_libraries(CuvenCore PRIVATE d3d11 dxgi d2d1 dwrite windowscodecs d3dcompiler winhttp avrt ole32 uuid)

if(MSVC)
  target_compile_options(CuvenCore PRIVATE /utf-8 /W3 /EHsc /permissive- /Zc:__cplusplus /MP /O2 /GL)
  target_link_options(CuvenCore PRIVATE /LTCG /OPT:REF /OPT:ICF)
  set_property(TARGET CuvenCore PROPERTY INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)
else()
  target_compile_options(CuvenCore PRIVATE -Wall -Wno-unknown-pragmas -Wno-missing-field-initializers -O2)
  target_link_options(CuvenCore PRIVATE -static -Wl,--kill-at)
endif()

# CI 上的原生自检（WARP）
add_executable(CuvenSelfTest tools/selftest_main.cpp)
target_link_libraries(CuvenSelfTest PRIVATE CuvenCore)
if(MSVC)
  target_compile_options(CuvenSelfTest PRIVATE /utf-8)
else()
  target_link_options(CuvenSelfTest PRIVATE -static)
endif()

install(TARGETS CuvenCore RUNTIME DESTINATION .)
