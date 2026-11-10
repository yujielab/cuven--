#!/usr/bin/env bash
# 从源码重建 tx.wasm（仓库里已附带编好的 tx.wasm，正常部署不需要跑这个）
#
# 依赖：emscripten（测试用的是 Ubuntu 24.04 apt 源里的 3.1.6）、FFmpeg 6.1.1 源码
#   sudo apt-get install emscripten
#   apt-get source ffmpeg            # 或从 ffmpeg.org 下载 ffmpeg-6.1.1.tar.xz
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FF="${FFMPEG_SRC:-$HERE/ffmpeg-6.1.1}"
[ -d "$FF" ] || { echo "需要 FFmpeg 6.1.1 源码目录：$FF（可用 FFMPEG_SRC 指定）"; exit 1; }

cd "$FF"
emconfigure ./configure --cc=emcc --cxx=em++ --ar=emar --ranlib=emranlib --nm=llvm-nm-15 \
  --target-os=none --arch=x86_32 --enable-cross-compile \
  --disable-asm --disable-inline-asm --disable-x86asm --disable-stripping \
  --disable-programs --disable-doc --disable-debug --disable-everything --disable-network \
  --disable-autodetect --disable-pthreads --disable-w32threads --disable-os2threads --disable-runtime-cpudetect \
  --disable-avdevice --disable-avformat --disable-swscale --disable-postproc --disable-avfilter \
  --enable-avcodec --enable-avutil --enable-swresample \
  --enable-decoder=dca,truehd,mlp,opus,vorbis,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be,pcm_s24be,pcm_u8,mp2,mp2float,mp3,mp3float \
  --enable-encoder=ac3 --extra-cflags="-O3"
emmake make -j"$(nproc)" libavcodec/libavcodec.a libavutil/libavutil.a libswresample/libswresample.a

EXPORTS='["_tx_alloc","_tx_dealloc","_tx_open","_tx_close","_tx_decode","_tx_skip","_tx_pad","_tx_tail","_tx_pcm_len","_tx_encode","_tx_out","_tx_out_len","_tx_sizes","_tx_nframes","_tx_out_reset","_tx_out_rate","_tx_frame_size","_tx_errors"]'
emcc -O3 "$HERE/tx.c" -I "$FF" \
  "$FF/libavcodec/libavcodec.a" "$FF/libswresample/libswresample.a" "$FF/libavutil/libavutil.a" \
  -s STANDALONE_WASM=1 --no-entry -s EXPORTED_FUNCTIONS="$EXPORTS" \
  -s ALLOW_MEMORY_GROWTH=1 -s INITIAL_MEMORY=33554432 -s TOTAL_STACK=1048576 -s FILESYSTEM=0 \
  -o "$HERE/tx.wasm"
ls -la "$HERE/tx.wasm"
