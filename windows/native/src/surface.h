#pragma once
#include "common.h"

// SwapChainPanel 用的交换链：翻转模型 + 可等待对象（最多排 1 帧，延迟最低、不白画）
struct cv_surface {
    int flags = 0;
    std::mutex m;
    ComPtr<IDXGISwapChain1> sc;
    HANDLE waitable = nullptr;
    int w = 1, h = 1;               // 缓冲区（像素）
    int want_w = 1, want_h = 1;     // 面板（物理像素）
    float sx = 1, sy = 1;           // CompositionScale
    float extra = 1;                // 额外超采样（由 ss_min / ss_max 算）
    float ss_min = 0, ss_max = 0;   // 粒子云：和网页版一样按 1.5–2.5 倍像素画（0 = 不超采样）
    bool hdr = false;               // FP16 scRGB
    bool want_hdr = false;
    bool dirty = true;
    std::atomic<int> gen{0};            // 每次改大小 +1（渲染线程据此重画）
    std::function<void()> on_change;    // 改了大小：叫醒用这个表面的渲染线程
    ComPtr<ID3D11RenderTargetView> rtv;
    ComPtr<ID3D11Texture2D> back;

    bool create(int width, int height, int flags);
    // 渲染线程：每帧开头调，按需改大小 / 格式。返回 false = 交换链坏了
    bool prepare();
    void present(UINT interval);
    // 等可以画下一帧（最多 ms 毫秒）
    void wait_ready(DWORD ms);
    DXGI_FORMAT format() const { return hdr ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_B8G8R8A8_UNORM; }
};
