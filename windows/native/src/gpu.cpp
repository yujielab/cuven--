// 共享设备、日志、时钟、线程能效、高精度等待、着色器编译缓存、显示器信息
#include "common.h"

#include <avrt.h>
#include <d3dcompiler.h>
#include <cstdarg>

namespace cv {

// ── 日志 ────────────────────────────────────────────────────────
static std::mutex g_log_m;
static std::wstring g_log_dir;
static FILE* g_log = nullptr;

void set_log_dir(const std::wstring& dir) {
    std::lock_guard<std::mutex> l(g_log_m);
    g_log_dir = dir;
    if (g_log) { fclose(g_log); g_log = nullptr; }
}

static std::wstring default_root() {
    wchar_t buf[MAX_PATH] = {};
    DWORD n = GetEnvironmentVariableW(L"CUVEN_HOME", buf, MAX_PATH);
    if (n > 0 && n < MAX_PATH) return buf;
    n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    std::wstring r = (n > 0 && n < MAX_PATH) ? std::wstring(buf) + L"\\Cuven" : L".";
    return r;
}

static std::wstring root_dir() {
    std::lock_guard<std::mutex> l(g_log_m);
    if (!g_log_dir.empty()) {
        auto p = g_log_dir.find_last_of(L"\\/");
        return p == std::wstring::npos ? g_log_dir : g_log_dir.substr(0, p);
    }
    return default_root();
}

void log(const char* fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    SYSTEMTIME t;
    GetLocalTime(&t);
    char line[1200];
    snprintf(line, sizeof line, "%02d:%02d:%02d.%03d [%5lu] %s\n", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds,
             (unsigned long)GetCurrentThreadId(), msg);
    OutputDebugStringA(line);
    std::lock_guard<std::mutex> l(g_log_m);
    if (!g_log) {
        std::wstring dir = g_log_dir.empty() ? default_root() + L"\\logs" : g_log_dir;
        CreateDirectoryW(default_root().c_str(), nullptr);
        CreateDirectoryW(dir.c_str(), nullptr);
        std::wstring path = dir + L"\\core.log";
        // 超过 4 MB 就从头写
        WIN32_FILE_ATTRIBUTE_DATA fa{};
        bool big = GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fa) && (fa.nFileSizeHigh > 0 || fa.nFileSizeLow > (4u << 20));
        g_log = _wfopen(path.c_str(), big ? L"w" : L"a");
    }
    if (g_log) { fputs(line, g_log); fflush(g_log); }
}

std::wstring widen(const char* s) {
    if (!s || !*s) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n > 0 ? n - 1 : 0, L'\0');
    if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

std::string narrow(const wchar_t* s) {
    if (!s || !*s) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
    std::string o(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, s, -1, &o[0], n, nullptr, nullptr);
    return o;
}

// ── 时钟 ────────────────────────────────────────────────────────
double now() {
    static LARGE_INTEGER f = [] { LARGE_INTEGER x; QueryPerformanceFrequency(&x); return x; }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (double)c.QuadPart / (double)f.QuadPart;
}

// ── 线程 ────────────────────────────────────────────────────────
void name_thread(const wchar_t* name) {
    typedef HRESULT(WINAPI * Fn)(HANDLE, PCWSTR);
    static Fn fn = (Fn)(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "SetThreadDescription");
    if (fn) fn(GetCurrentThread(), name);
}

void thread_qos(int mode) {
    // Win11 的线程服务质量：EcoQoS 让调度器把线程放到能效核、降频；HighQoS 明确告诉系统别节流
    THREAD_POWER_THROTTLING_STATE s{};
    s.Version = THREAD_POWER_THROTTLING_CURRENT_VERSION;
    if (mode == CV_QOS_ECO) { s.ControlMask = THREAD_POWER_THROTTLING_EXECUTION_SPEED; s.StateMask = THREAD_POWER_THROTTLING_EXECUTION_SPEED; }
    else if (mode == CV_QOS_HIGH) { s.ControlMask = THREAD_POWER_THROTTLING_EXECUTION_SPEED; s.StateMask = 0; }
    SetThreadInformation(GetCurrentThread(), ThreadPowerThrottling, &s, sizeof s);
}

// ── 高精度等待 ──────────────────────────────────────────────────
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

Waiter::Waiter() {
    timer_ = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (!timer_) timer_ = CreateWaitableTimerExW(nullptr, nullptr, 0, TIMER_ALL_ACCESS);
    event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
}

Waiter::~Waiter() {
    if (timer_) CloseHandle(timer_);
    if (event_) CloseHandle(event_);
}

void Waiter::wait(double seconds) {
    if (seconds <= 0) return;
    if (seconds > 3600) seconds = 3600;
    LARGE_INTEGER due;
    due.QuadPart = -(LONGLONG)(seconds * 1e7);   // 相对时间，100 ns
    HANDLE hs[2] = {event_, timer_};
    if (timer_ && SetWaitableTimer(timer_, &due, 0, nullptr, nullptr, FALSE))
        WaitForMultipleObjects(2, hs, FALSE, INFINITE);
    else
        WaitForSingleObject(event_, (DWORD)(seconds * 1000));
}

void Waiter::wake() { SetEvent(event_); }

// ── 着色器 ──────────────────────────────────────────────────────
static uint64_t fnv(const void* p, size_t n, uint64_t h = 1469598103934665603ull) {
    auto b = (const uint8_t*)p;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ull; }
    return h;
}

ComPtr<ID3DBlob> compile_shader(const char* src, size_t len, const char* name, const char* entry, const char* target) {
    uint64_t h = fnv(src, len);
    h = fnv(entry, strlen(entry), h);
    h = fnv(target, strlen(target), h);
    std::wstring dir = root_dir() + L"\\shaders";
    wchar_t file[64];
    swprintf(file, 64, L"\\%016llx.cso", (unsigned long long)h);
    std::wstring path = dir + file;

    ComPtr<ID3DBlob> blob;
    if (SUCCEEDED(D3DReadFileToBlob(path.c_str(), &blob)) && blob && blob->GetBufferSize() > 0) return blob;

    ComPtr<ID3DBlob> err;
    blob.Reset();
    HRESULT hr = D3DCompile(src, len, name, nullptr, nullptr, entry, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &blob, &err);
    if (FAILED(hr)) {
        log("着色器 %s/%s 编译失败 0x%08lx: %s", name, entry, (unsigned long)hr,
            err ? (const char*)err->GetBufferPointer() : "(无信息)");
        return nullptr;
    }
    CreateDirectoryW(root_dir().c_str(), nullptr);
    CreateDirectoryW(dir.c_str(), nullptr);
    D3DWriteBlobToFile(blob.Get(), path.c_str(), TRUE);
    return blob;
}

// ── 共享设备 ────────────────────────────────────────────────────
static Gpu g_gpu;
static bool g_ok = false;
static std::mutex g_init_m;

Gpu& gpu() { return g_gpu; }
bool gpu_ok() { return g_ok; }

static int init_gpu(int flags) {
    std::lock_guard<std::mutex> l(g_init_m);
    if (g_ok) return 0;
    HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    (void)co;
    bool warp = (flags & CV_INIT_WARP) != 0;
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> ctx;
    D3D_FEATURE_LEVEL got{};
    UINT base = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    bool video = true;
    HRESULT hr = E_FAIL;
    for (int attempt = 0; attempt < 4 && FAILED(hr); attempt++) {
        UINT f = base | (video ? D3D11_CREATE_DEVICE_VIDEO_SUPPORT : 0);
        int skip = attempt % 2;   // 老系统不认 11_1：去掉再试
        hr = D3D11CreateDevice(nullptr, warp ? D3D_DRIVER_TYPE_WARP : D3D_DRIVER_TYPE_HARDWARE, nullptr, f, levels + skip,
                               (UINT)(sizeof levels / sizeof levels[0]) - skip, D3D11_SDK_VERSION, &dev, &got, &ctx);
        if (FAILED(hr) && attempt == 1) video = false;
    }
    if (FAILED(hr) && !warp) {
        log("硬件设备建不起来（0x%08lx），退回 WARP", (unsigned long)hr);
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, base, levels + 1, 3, D3D11_SDK_VERSION, &dev, &got, &ctx);
        warp = true;
        video = false;
    }
    if (FAILED(hr)) { log("D3D11 设备失败 0x%08lx", (unsigned long)hr); return -1; }

    Gpu& G = g_gpu;
    dev.As(&G.dev);
    ctx.As(&G.ctx);
    if (!G.dev || !G.ctx) { log("没有 D3D11.1"); return -2; }
    ComPtr<ID3D10Multithread> mt;
    if (SUCCEEDED(ctx.As(&mt))) mt->SetMultithreadProtected(TRUE);
    ComPtr<ID3D11VideoDevice> vd;
    G.video = video && SUCCEEDED(dev.As(&vd));
    G.warp = warp;

    ComPtr<IDXGIDevice> dxgi;
    dev.As(&dxgi);
    ComPtr<IDXGIAdapter> ad;
    if (dxgi && SUCCEEDED(dxgi->GetAdapter(&ad))) {
        DXGI_ADAPTER_DESC d{};
        ad->GetDesc(&d);
        G.name = narrow(d.Description);
        ad->GetParent(__uuidof(IDXGIFactory2), (void**)G.factory.GetAddressOf());
    }
    if (!G.factory) CreateDXGIFactory1(__uuidof(IDXGIFactory2), (void**)G.factory.GetAddressOf());

    D2D1_FACTORY_OPTIONS fo{};
    if (SUCCEEDED(D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, __uuidof(ID2D1Factory1), &fo, (void**)G.d2d.GetAddressOf())) && dxgi)
        G.d2d->CreateDevice(dxgi.Get(), &G.d2d_dev);
    DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), (IUnknown**)G.dwrite.GetAddressOf());
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&G.wic));

    log("设备：%s，特性级别 %x，%s，视频解码 %s", G.name.c_str(), (unsigned)got, warp ? "WARP" : "硬件", G.video ? "有" : "无");
    g_ok = true;
    return 0;
}

}  // namespace cv

using namespace cv;

extern "C" {

CV_API int CV_CALL cv_init(int flags) { return init_gpu(flags); }

CV_API const char* CV_CALL cv_version(void) {
    static std::string v = std::string("CuvenCore 1.0 · FFmpeg ") + av_version_info();
    return v.c_str();
}

CV_API const char* CV_CALL cv_gpu_name(void) { return gpu().name.c_str(); }

CV_API void CV_CALL cv_set_log_dir(const char* dir) { set_log_dir(widen(dir)); }

CV_API void CV_CALL cv_thread_qos(int mode) { thread_qos(mode); }

CV_API void CV_CALL cv_process_eco(int on) {
    PROCESS_POWER_THROTTLING_STATE s{};
    s.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
    s.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
    s.StateMask = on ? PROCESS_POWER_THROTTLING_EXECUTION_SPEED : 0;
    SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &s, sizeof s);
}

CV_API int CV_CALL cv_display_query(void* hmonitor, cv_display* out) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    out->max_nits = 270;
    out->min_nits = 0.5f;
    out->max_full_frame_nits = 270;
    out->sdr_white_nits = 80;
    out->bits = 8;
    // 每次新开一个工厂：HDR 开关以后旧工厂看到的还是旧状态
    ComPtr<IDXGIFactory2> f;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory2), (void**)f.GetAddressOf()))) return -2;
    ComPtr<IDXGIAdapter1> ad;
    for (UINT i = 0; f->EnumAdapters1(i, &ad) != DXGI_ERROR_NOT_FOUND; i++, ad.Reset()) {
        ComPtr<IDXGIOutput> o;
        for (UINT j = 0; ad->EnumOutputs(j, &o) != DXGI_ERROR_NOT_FOUND; j++, o.Reset()) {
            DXGI_OUTPUT_DESC d{};
            o->GetDesc(&d);
            if (hmonitor && d.Monitor != (HMONITOR)hmonitor) continue;
            ComPtr<IDXGIOutput6> o6;
            if (SUCCEEDED(o.As(&o6))) {
                DXGI_OUTPUT_DESC1 d1{};
                if (SUCCEEDED(o6->GetDesc1(&d1))) {
                    out->hdr = d1.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
                    out->bits = (int)d1.BitsPerColor;
                    if (d1.MaxLuminance > 0) out->max_nits = d1.MaxLuminance;
                    out->min_nits = d1.MinLuminance;
                    if (d1.MaxFullFrameLuminance > 0) out->max_full_frame_nits = d1.MaxFullFrameLuminance;
                }
            }
            // 「SDR 内容亮度」：DisplayConfig 的 SDR 白电平（1000 = 80 尼特）
            UINT32 np = 0, nm = 0;
            if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) == ERROR_SUCCESS && np > 0) {
                std::vector<DISPLAYCONFIG_PATH_INFO> paths(np);
                std::vector<DISPLAYCONFIG_MODE_INFO> modes(nm);
                if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths.data(), &nm, modes.data(), nullptr) == ERROR_SUCCESS) {
                    for (UINT32 k = 0; k < np; k++) {
                        DISPLAYCONFIG_SOURCE_DEVICE_NAME src{};
                        src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                        src.header.size = sizeof src;
                        src.header.adapterId = paths[k].sourceInfo.adapterId;
                        src.header.id = paths[k].sourceInfo.id;
                        if (DisplayConfigGetDeviceInfo(&src.header) != ERROR_SUCCESS) continue;
                        if (wcscmp(src.viewGdiDeviceName, d.DeviceName) != 0) continue;
                        DISPLAYCONFIG_SDR_WHITE_LEVEL wl{};
                        wl.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
                        wl.header.size = sizeof wl;
                        wl.header.adapterId = paths[k].targetInfo.adapterId;
                        wl.header.id = paths[k].targetInfo.id;
                        if (DisplayConfigGetDeviceInfo(&wl.header) == ERROR_SUCCESS && wl.SDRWhiteLevel > 0)
                            out->sdr_white_nits = wl.SDRWhiteLevel / 1000.0f * 80.0f;
                        break;
                    }
                }
            }
            return 0;
        }
    }
    return hmonitor ? -3 : 0;
}

}  // extern "C"
