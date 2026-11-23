#pragma once
#include "common.h"
#include "surface.h"

namespace cv {

// 杜比视界 5 的 RPU 摊平成常量缓冲（和 video.hlsl 的 cbuffer Dovi 一一对应）
struct alignas(16) DoviConsts {
    float nonlinear[3][4];
    float offset[4];
    float linear[3][4];
    int pivots[4];
    float piv[9][4];
    float info[24][4];
    float poly[24][4];
    float mmr[144][4];
};

// 一帧的颜色信息（解码线程填，渲染线程用）
struct ColorInfo {
    int matrix = AVCOL_SPC_UNSPECIFIED;
    int range = AVCOL_RANGE_UNSPECIFIED;
    int primaries = AVCOL_PRI_UNSPECIFIED;
    int trc = AVCOL_TRC_UNSPECIFIED;
    int chroma_loc = AVCHROMA_LOC_UNSPECIFIED;
    int bits = 8;
    float peak = 1000;          // HDR 片的峰值（尼特）：母版元数据 / MaxCLL / RPU
    bool dovi = false;          // 用 RPU 重塑（杜比视界 5）
};

// 排队等着上屏的一帧
struct VideoFrame {
    int slot = -1;
    double pts = 0, dur = 0;
    int serial = 0;
    int w = 0, h = 0;           // 显示区域（裁过）
    int tex_w = 0, tex_h = 0;   // 纹理尺寸
    int crop_l = 0, crop_t = 0;
    double sar = 1;
    ColorInfo color;
    std::shared_ptr<DoviConsts> dovi;
};

struct OutputConfig {
    bool hdr = false;           // 交换链在 scRGB
    float display_peak = 1000;  // HDR 屏峰值
    float sdr_white = 203;      // HDR 屏上 SDR 白（尼特）
    float sdr_target = 203;     // SDR 屏：HDR 片的参考白映射到多亮（相对 1.0）
};

class SubLayer;

class VideoRenderer {
public:
    static constexpr int kSlots = 8;

    bool init();
    // 解码线程：把一帧放进第 slot 个纹理。硬解帧在 GPU 上拷，软解帧上传
    bool upload(AVFrame* f, int slot);
    // 渲染线程：新帧 → 中间纹理
    bool convert(const VideoFrame& vf, const OutputConfig& out);
    // 中间纹理 + 字幕 → 交换链（不 Present）
    void present(cv_surface* s, const OutputConfig& out, SubLayer* subs, double sar_override = 0);
    bool has_frame() const { return has_frame_; }
    int frame_w() const { return conv_w_; }
    int frame_h() const { return conv_h_; }
    double frame_sar() const { return sar_; }
    // 自检：中间纹理读回成 8 位 RGBA（SDR 编码）
    bool readback(std::vector<uint8_t>& rgba, int& w, int& h);
    void reset() { has_frame_ = false; }

private:
    struct Slot {
        ComPtr<ID3D11Texture2D> tex;            // 硬解：NV12 / P010 拷贝目标
        ComPtr<ID3D11Texture2D> ytex, uvtex;    // 软解：两个平面
        ComPtr<ID3D11ShaderResourceView> y, uv;
        int w = 0, h = 0;
        DXGI_FORMAT fmt = DXGI_FORMAT_UNKNOWN;
        bool sw = false;
    };
    bool ensure_hw(Slot& s, ID3D11Texture2D* src);
    bool ensure_sw(Slot& s, int w, int h, bool high);
    bool ensure_target(int w, int h);

    Slot slots_[kSlots];
    ComPtr<ID3D11VertexShader> vs_;
    ComPtr<ID3D11PixelShader> ps_convert_, ps_present_;
    ComPtr<ID3D11Buffer> cb_convert_, cb_dovi_, cb_present_;
    ComPtr<ID3D11SamplerState> linear_, point_;
    ComPtr<ID3D11RasterizerState> raster_;
    ComPtr<ID3D11Texture2D> target_;
    ComPtr<ID3D11RenderTargetView> target_rtv_;
    ComPtr<ID3D11ShaderResourceView> target_srv_;
    int target_w_ = 0, target_h_ = 0;
    int conv_w_ = 0, conv_h_ = 0;
    double sar_ = 1;
    bool has_frame_ = false;

    SwsContext* sws_ = nullptr;
    std::vector<uint8_t> sw_buf_;
};

// 画面按显示宽高比放进 W×H，居中：x y w h
void fit_rect(int W, int H, int vw, int vh, double sar, float r[4]);

// AVDOVIMetadata → 常量（杜比视界 5）；同时给出母版峰值（尼特）
std::shared_ptr<DoviConsts> make_dovi(const AVFrameSideData* sd, float* peak_nits);

}  // namespace cv
