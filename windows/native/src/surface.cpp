#include "surface.h"

using namespace cv;

// WinUI 3 的 ISwapChainPanelNative（microsoft.ui.xaml.media.dxinterop.h；IID 和 UWP 那个一样）
MIDL_INTERFACE("63aad0b8-7c24-40ff-85a8-640d944cc325")
ISwapChainPanelNative : public IUnknown {
public:
    virtual HRESULT STDMETHODCALLTYPE SetSwapChain(IDXGISwapChain* swapChain) = 0;
};
// 63aad0b8-7c24-40ff-85a8-640d944cc325（和 microsoft.ui.xaml.media.dxinterop.h 一致）
static const GUID IID_SwapChainPanelNative = {0x63aad0b8, 0x7c24, 0x40ff, {0x85, 0xa8, 0x64, 0x0d, 0x94, 0x4c, 0xc3, 0x25}};

static const UINT kFlags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;

bool cv_surface::create(int width, int height, int fl) {
    flags = fl;
    w = want_w = std::max(1, width);
    h = want_h = std::max(1, height);
    DXGI_SWAP_CHAIN_DESC1 d{};
    d.Width = (UINT)w;
    d.Height = (UINT)h;
    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    d.SampleDesc.Count = 1;
    d.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    d.BufferCount = (fl & CV_SURFACE_VIDEO) ? 3 : 2;
    d.Scaling = DXGI_SCALING_STRETCH;
    d.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    d.AlphaMode = (fl & CV_SURFACE_TRANSPARENT) ? DXGI_ALPHA_MODE_PREMULTIPLIED : DXGI_ALPHA_MODE_IGNORE;
    d.Flags = kFlags;
    auto& G = gpu();
    HRESULT hr = G.factory->CreateSwapChainForComposition(G.dev.Get(), &d, nullptr, &sc);
    if (FAILED(hr)) { log("交换链失败 0x%08lx", (unsigned long)hr); return false; }
    ComPtr<IDXGISwapChain2> sc2;
    if (SUCCEEDED(sc.As(&sc2))) {
        sc2->SetMaximumFrameLatency(1);
        waitable = sc2->GetFrameLatencyWaitableObject();
    }
    dirty = true;
    return true;
}

bool cv_surface::prepare() {
    std::lock_guard<std::mutex> l(m);
    if (!sc) return false;
    if (ss_min > 0) {
        float base = std::max(0.5f, std::max(sx, sy));
        extra = std::min(ss_max, std::max(ss_min, base)) / base;
    }
    int nw = std::max(1, (int)std::lround(want_w * extra)), nh = std::max(1, (int)std::lround(want_h * extra));
    if (dirty || nw != w || nh != h || want_hdr != hdr || !rtv) {
        GpuLock gl;
        rtv.Reset();
        back.Reset();
        gpu().ctx->OMSetRenderTargets(0, nullptr, nullptr);
        gpu().ctx->Flush();
        bool fmt_change = want_hdr != hdr;
        hdr = want_hdr;
        if (nw != w || nh != h || fmt_change || dirty) {
            HRESULT hr = sc->ResizeBuffers(0, (UINT)nw, (UINT)nh, format(), kFlags);
            if (FAILED(hr)) { log("ResizeBuffers 失败 0x%08lx", (unsigned long)hr); return false; }
            w = nw; h = nh;
        }
        ComPtr<IDXGISwapChain3> sc3;
        if (SUCCEEDED(sc.As(&sc3)))
            sc3->SetColorSpace1(hdr ? DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709 : DXGI_COLOR_SPACE_RGB_FULL_G22_NONE_P709);
        // 缓冲区按物理像素（再乘超采样）：缩回面板的逻辑尺寸
        ComPtr<IDXGISwapChain2> sc2;
        if (SUCCEEDED(sc.As(&sc2))) {
            DXGI_MATRIX_3X2_F mt{};
            mt._11 = 1.0f / (sx * extra);
            mt._22 = 1.0f / (sy * extra);
            sc2->SetMatrixTransform(&mt);
        }
        if (FAILED(sc->GetBuffer(0, IID_PPV_ARGS(&back)))) return false;
        if (FAILED(gpu().dev->CreateRenderTargetView(back.Get(), nullptr, &rtv))) return false;
        dirty = false;
    }
    return true;
}

void cv_surface::present(UINT interval) {
    HRESULT hr;
    {
        GpuLock gl;
        hr = sc->Present(interval, 0);
    }
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET)
        log("设备丢了 0x%08lx（原因 0x%08lx）", (unsigned long)hr, (unsigned long)gpu().dev->GetDeviceRemovedReason());
}

void cv_surface::wait_ready(DWORD ms) {
    if (waitable) WaitForSingleObjectEx(waitable, ms, TRUE);
}

extern "C" {

CV_API cv_surface* CV_CALL cv_surface_create(int width, int height, int flags) {
    if (!gpu_ok() && cv_init(0) != 0) return nullptr;
    auto s = new cv_surface();
    if (!s->create(width, height, flags)) { delete s; return nullptr; }
    return s;
}

CV_API int CV_CALL cv_surface_attach(cv_surface* s, void* panel) {
    if (!s || !panel) return -1;
    ComPtr<ISwapChainPanelNative> native;
    HRESULT hr = ((IUnknown*)panel)->QueryInterface(IID_SwapChainPanelNative, (void**)native.GetAddressOf());
    if (FAILED(hr)) { log("面板没有 ISwapChainPanelNative 0x%08lx", (unsigned long)hr); return -2; }
    hr = native->SetSwapChain(s->sc.Get());
    if (FAILED(hr)) { log("SetSwapChain 失败 0x%08lx", (unsigned long)hr); return -3; }
    return 0;
}

CV_API void CV_CALL cv_surface_resize(cv_surface* s, int width, int height, float sx, float sy) {
    if (!s) return;
    std::lock_guard<std::mutex> l(s->m);
    s->want_w = std::max(1, width);
    s->want_h = std::max(1, height);
    if (sx > 0) s->sx = sx;
    if (sy > 0) s->sy = sy;
    s->dirty = true;
    s->gen++;
    if (s->on_change) s->on_change();
}

CV_API void CV_CALL cv_surface_destroy(cv_surface* s) {
    if (!s) return;
    {
        GpuLock gl;
        s->rtv.Reset();
        s->back.Reset();
        s->sc.Reset();
    }
    if (s->waitable) CloseHandle(s->waitable);
    delete s;
}

}  // extern "C"
