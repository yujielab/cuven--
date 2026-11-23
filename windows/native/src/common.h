// CuvenCore 内部公共头：Windows / D3D / FFmpeg 的头文件、ComPtr、日志、时钟
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <d2d1_3.h>
#include <dwrite_3.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>
#include <cmath>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/pixdesc.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#define CUVEN_CORE_BUILD 1
#include "../include/cuven_core.h"

using Microsoft::WRL::ComPtr;

namespace cv {

// ── 日志：%LOCALAPPDATA%\Cuven\logs\core.log（不写片名和地址） ──
void log(const char* fmt, ...);
void set_log_dir(const std::wstring& dir);

std::wstring widen(const char* s);
std::string narrow(const wchar_t* s);

// ── 时钟：QPC，秒 ──
double now();

// ── 线程：名字 + 能效 ──
void name_thread(const wchar_t* name);
void thread_qos(int mode);   // CV_QOS_*

// 高精度等待（Win10 1803+ 的 CREATE_WAITABLE_TIMER_HIGH_RESOLUTION；不支持就退回普通计时器）
class Waiter {
public:
    Waiter();
    ~Waiter();
    // 最多等 seconds 秒，或者 wake() 被调
    void wait(double seconds);
    void wake();
private:
    HANDLE timer_ = nullptr;
    HANDLE event_ = nullptr;
};

// ── 着色器：D3DCompile（d3dcompiler_47.dll，Win10 起系统自带），字节码缓存到磁盘 ──
ComPtr<ID3DBlob> compile_shader(const char* src, size_t len, const char* name, const char* entry, const char* target);

// ── 共享设备 ──
struct Gpu {
    ComPtr<ID3D11Device1> dev;
    ComPtr<ID3D11DeviceContext1> ctx;
    ComPtr<IDXGIFactory2> factory;
    ComPtr<ID2D1Factory1> d2d;
    ComPtr<ID2D1Device> d2d_dev;
    ComPtr<IDWriteFactory> dwrite;
    ComPtr<IWICImagingFactory> wic;
    std::recursive_mutex lock;          // 立即上下文只能一个线程用：FFmpeg 的 D3D11VA 也用这把锁
    bool warp = false;
    bool video = false;                 // 有 D3D11 视频解码能力
    std::string name;
};
Gpu& gpu();
bool gpu_ok();

struct GpuLock {
    GpuLock() { gpu().lock.lock(); }
    ~GpuLock() { gpu().lock.unlock(); }
    GpuLock(const GpuLock&) = delete;
    GpuLock& operator=(const GpuLock&) = delete;
};

template <class T> inline void safe_release(T*& p) { if (p) { p->Release(); p = nullptr; } }

}  // namespace cv
