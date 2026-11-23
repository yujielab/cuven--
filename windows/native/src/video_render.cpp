// 视频渲染：纹理环、硬解拷贝 / 软解上传、颜色矩阵、杜比视界 RPU、两遍着色器
#include "video_render.h"
#include "subs.h"
#include "shaders_gen.h"

namespace cv {

namespace {

struct alignas(16) ConvertConsts {
    float m[3][4];
    float uvScale[2], uvOffset[2];
    float chromaShift[2];
    float bitScale;
    int mode;
    int outHdr, gamut, tonemap;
    float srcPeak;
    float dstPeak, sdrWhite, srcPQ, dstPQ;
};
static_assert(sizeof(ConvertConsts) == 112, "cbuffer Convert");

struct alignas(16) PresentConsts {
    float dst[4];
    float srcSize[2], targetSize[2];
    int outHdr, bicubic, hasSubs;
    float subGain;
};
static_assert(sizeof(PresentConsts) == 48, "cbuffer Present");
static_assert(sizeof(DoviConsts) == 3344, "cbuffer Dovi");

double pq_oetf(double y) {   // y：0..1（10000 尼特）
    const double m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    double p = std::pow(std::max(y, 0.0), m1);
    return std::pow((c1 + c2 * p) / (1 + c3 * p), m2);
}

double pq_eotf(double e) {
    const double m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    double p = std::pow(std::max(e, 0.0), 1 / m2);
    return std::pow(std::max(p - c1, 0.0) / (c2 - c3 * p), 1 / m1);
}

// YCbCr（按位深归一的取样值）→ R'G'B' 的仿射矩阵
void ycbcr_matrix(const ColorInfo& c, int height, float m[3][4]) {
    int mat = c.matrix;
    if (mat == AVCOL_SPC_UNSPECIFIED || mat == AVCOL_SPC_RESERVED || mat == AVCOL_SPC_RGB) {
        if (c.primaries == AVCOL_PRI_BT2020 || c.trc == AVCOL_TRC_SMPTE2084 || c.trc == AVCOL_TRC_ARIB_STD_B67) mat = AVCOL_SPC_BT2020_NCL;
        else mat = height >= 720 ? AVCOL_SPC_BT709 : AVCOL_SPC_SMPTE170M;
    }
    double kr = 0.299, kb = 0.114;
    switch (mat) {
    case AVCOL_SPC_BT709: kr = 0.2126; kb = 0.0722; break;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL: kr = 0.2627; kb = 0.0593; break;
    case AVCOL_SPC_SMPTE240M: kr = 0.212; kb = 0.087; break;
    case AVCOL_SPC_FCC: kr = 0.30; kb = 0.11; break;
    default: break;
    }
    double kg = 1 - kr - kb;
    int b = std::clamp(c.bits, 8, 16);
    double maxv = (double)((1 << b) - 1);
    double sc = (double)(1 << (b - 8));
    double ys, yo, cs, co;
    if (c.range == AVCOL_RANGE_JPEG) {
        ys = 1; yo = 0; cs = 1; co = -(double)(1 << (b - 1)) / maxv;
    } else {
        ys = maxv / (219 * sc); yo = -16.0 / 219.0;
        cs = maxv / (224 * sc); co = -128.0 / 224.0;
    }
    double rv = 2 * (1 - kr), bu = 2 * (1 - kb);
    double gu = 2 * kb * (1 - kb) / kg, gv = 2 * kr * (1 - kr) / kg;
    float r[3][4] = {
        {(float)ys, 0.0f, (float)(rv * cs), (float)(yo + rv * co)},
        {(float)ys, (float)(-gu * cs), (float)(-gv * cs), (float)(yo - (gu + gv) * co)},
        {(float)ys, (float)(bu * cs), 0.0f, (float)(yo + bu * co)},
    };
    memcpy(m, r, sizeof r);
}

}  // namespace

std::shared_ptr<DoviConsts> make_dovi(const AVFrameSideData* sd, float* peak) {
    if (!sd || !sd->data) return nullptr;
    auto data = (const AVDOVIMetadata*)sd->data;
    const AVDOVIRpuDataHeader* hdr = av_dovi_get_header(data);
    const AVDOVIDataMapping* map = av_dovi_get_mapping(data);
    const AVDOVIColorMetadata* col = av_dovi_get_color(data);
    auto o = std::make_shared<DoviConsts>();
    memset(o.get(), 0, sizeof(DoviConsts));
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) o->nonlinear[i][j] = (float)av_q2d(col->ycc_to_rgb_matrix[i * 3 + j]);
        o->offset[i] = (float)av_q2d(col->ycc_to_rgb_offset[i]);
    }
    // RPU 给的是 RGB → LMS：解码要它的逆
    double a[9];
    for (int i = 0; i < 9; i++) a[i] = av_q2d(col->rgb_to_lms_matrix[i]);
    double det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6]);
    if (std::fabs(det) < 1e-12) return nullptr;
    double inv[9] = {
        (a[4] * a[8] - a[5] * a[7]) / det, (a[2] * a[7] - a[1] * a[8]) / det, (a[1] * a[5] - a[2] * a[4]) / det,
        (a[5] * a[6] - a[3] * a[8]) / det, (a[0] * a[8] - a[2] * a[6]) / det, (a[2] * a[3] - a[0] * a[5]) / det,
        (a[3] * a[7] - a[4] * a[6]) / det, (a[1] * a[6] - a[0] * a[7]) / det, (a[0] * a[4] - a[1] * a[3]) / det,
    };
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++) o->linear[i][j] = (float)inv[i * 3 + j];

    const double piv_scale = 1.0 / ((1 << hdr->bl_bit_depth) - 1);
    const double coef_scale = 1.0 / (double)(1ll << hdr->coef_log2_denom);
    for (int c = 0; c < 3; c++) {
        const AVDOVIReshapingCurve& cu = map->curves[c];
        int np = std::clamp((int)cu.num_pivots, 0, 9);
        o->pivots[c] = np;
        for (int k = 0; k < np; k++) o->piv[c * 3 + k / 4][k % 4] = (float)(cu.pivots[k] * piv_scale);
        for (int i = 0; i + 1 < np && i < 8; i++) {
            int idx = c * 8 + i;
            if (cu.mapping_idc[i] == AV_DOVI_MAPPING_POLYNOMIAL) {
                o->info[idx][0] = 0;
                o->info[idx][1] = cu.poly_order[i];
                for (int k = 0; k < 3; k++) o->poly[idx][k] = k <= cu.poly_order[i] ? (float)(cu.poly_coef[i][k] * coef_scale) : 0.0f;
            } else {
                o->info[idx][0] = 1;
                o->info[idx][1] = cu.mmr_order[i];
                o->info[idx][2] = (float)(cu.mmr_constant[i] * coef_scale);
                for (int ord = 0; ord < cu.mmr_order[i] && ord < 3; ord++)
                    for (int k = 0; k < 7; k++) {
                        int base = (idx * 3 + ord) * 2;
                        o->mmr[base + k / 4][k % 4] = (float)(cu.mmr_coef[i][ord][k] * coef_scale);
                    }
            }
        }
    }
    if (peak && col->source_max_pq > 0) {
        double nits = pq_eotf(col->source_max_pq / 4095.0) * 10000;
        if (nits > 100) *peak = (float)nits;
    }
    return o;
}

void fit_rect(int W, int H, int vw, int vh, double sar, float r[4]) {
    if (vw <= 0 || vh <= 0 || W <= 0 || H <= 0) { r[0] = r[1] = 0; r[2] = (float)W; r[3] = (float)H; return; }
    double va = vw * (sar > 0 ? sar : 1) / vh, ta = (double)W / H;
    double dw = W, dh = H;
    if (ta > va) dw = H * va; else dh = W / va;
    r[0] = (float)std::round((W - dw) / 2);
    r[1] = (float)std::round((H - dh) / 2);
    r[2] = (float)std::round(dw);
    r[3] = (float)std::round(dh);
}

bool VideoRenderer::init() {
    auto& G = gpu();
    auto vsb = compile_shader(k_video_hlsl, k_video_hlsl_len, "video.hlsl", "VS_Full", "vs_5_0");
    auto pcb = compile_shader(k_video_hlsl, k_video_hlsl_len, "video.hlsl", "PS_Convert", "ps_5_0");
    auto ppb = compile_shader(k_video_hlsl, k_video_hlsl_len, "video.hlsl", "PS_Present", "ps_5_0");
    if (!vsb || !pcb || !ppb) return false;
    if (FAILED(G.dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &vs_))) return false;
    if (FAILED(G.dev->CreatePixelShader(pcb->GetBufferPointer(), pcb->GetBufferSize(), nullptr, &ps_convert_))) return false;
    if (FAILED(G.dev->CreatePixelShader(ppb->GetBufferPointer(), ppb->GetBufferSize(), nullptr, &ps_present_))) return false;
    auto cbuf = [&](UINT size, ComPtr<ID3D11Buffer>& b) {
        D3D11_BUFFER_DESC d{};
        d.ByteWidth = size;
        d.Usage = D3D11_USAGE_DYNAMIC;
        d.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        d.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
        return SUCCEEDED(G.dev->CreateBuffer(&d, nullptr, &b));
    };
    if (!cbuf(sizeof(ConvertConsts), cb_convert_) || !cbuf(sizeof(DoviConsts), cb_dovi_) || !cbuf(sizeof(PresentConsts), cb_present_)) return false;
    D3D11_SAMPLER_DESC sm{};
    sm.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sm.AddressU = sm.AddressV = sm.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sm.MaxLOD = D3D11_FLOAT32_MAX;
    G.dev->CreateSamplerState(&sm, &linear_);
    sm.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
    G.dev->CreateSamplerState(&sm, &point_);
    D3D11_RASTERIZER_DESC rs{};
    rs.FillMode = D3D11_FILL_SOLID;
    rs.CullMode = D3D11_CULL_NONE;
    rs.DepthClipEnable = TRUE;
    G.dev->CreateRasterizerState(&rs, &raster_);
    return true;
}

bool VideoRenderer::ensure_hw(Slot& s, ID3D11Texture2D* src) {
    D3D11_TEXTURE2D_DESC sd;
    src->GetDesc(&sd);
    if (s.tex && !s.sw && s.w == (int)sd.Width && s.h == (int)sd.Height && s.fmt == sd.Format) return true;
    s = Slot{};
    D3D11_TEXTURE2D_DESC td{};
    td.Width = sd.Width; td.Height = sd.Height; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = sd.Format; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    auto& G = gpu();
    if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &s.tex))) { log("拷贝目标纹理失败（格式 %d）", (int)sd.Format); return false; }
    bool high = sd.Format == DXGI_FORMAT_P010 || sd.Format == DXGI_FORMAT_P016;
    D3D11_SHADER_RESOURCE_VIEW_DESC vd{};
    vd.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
    vd.Texture2D.MipLevels = 1;
    vd.Format = high ? DXGI_FORMAT_R16_UNORM : DXGI_FORMAT_R8_UNORM;
    if (FAILED(G.dev->CreateShaderResourceView(s.tex.Get(), &vd, &s.y))) return false;
    vd.Format = high ? DXGI_FORMAT_R16G16_UNORM : DXGI_FORMAT_R8G8_UNORM;
    if (FAILED(G.dev->CreateShaderResourceView(s.tex.Get(), &vd, &s.uv))) return false;
    s.w = (int)sd.Width; s.h = (int)sd.Height; s.fmt = sd.Format; s.sw = false;
    return true;
}

bool VideoRenderer::ensure_sw(Slot& s, int w, int h, bool high) {
    DXGI_FORMAT f = high ? DXGI_FORMAT_P010 : DXGI_FORMAT_NV12;
    if (s.sw && s.ytex && s.w == w && s.h == h && s.fmt == f) return true;
    s = Slot{};
    auto& G = gpu();
    D3D11_TEXTURE2D_DESC td{};
    td.MipLevels = 1; td.ArraySize = 1; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DYNAMIC; td.BindFlags = D3D11_BIND_SHADER_RESOURCE; td.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    td.Width = (UINT)w; td.Height = (UINT)h; td.Format = high ? DXGI_FORMAT_R16_UNORM : DXGI_FORMAT_R8_UNORM;
    if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &s.ytex))) return false;
    td.Width = (UINT)((w + 1) / 2); td.Height = (UINT)((h + 1) / 2); td.Format = high ? DXGI_FORMAT_R16G16_UNORM : DXGI_FORMAT_R8G8_UNORM;
    if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &s.uvtex))) return false;
    if (FAILED(G.dev->CreateShaderResourceView(s.ytex.Get(), nullptr, &s.y))) return false;
    if (FAILED(G.dev->CreateShaderResourceView(s.uvtex.Get(), nullptr, &s.uv))) return false;
    s.w = w; s.h = h; s.fmt = f; s.sw = true;
    return true;
}

bool VideoRenderer::upload(AVFrame* f, int slot) {
    if (slot < 0 || slot >= kSlots) return false;
    Slot& s = slots_[slot];
    auto& G = gpu();
    if (f->format == AV_PIX_FMT_D3D11) {
        auto src = (ID3D11Texture2D*)f->data[0];
        UINT index = (UINT)(intptr_t)f->data[1];
        GpuLock gl;
        if (!ensure_hw(s, src)) return false;
        G.ctx->CopySubresourceRegion(s.tex.Get(), 0, 0, 0, 0, src, index, nullptr);
        return true;
    }
    // 软解：统一转成 NV12 / P010 的两个平面（已经是的直接拷）
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get((AVPixelFormat)f->format);
    if (!desc) return false;
    bool high = desc->comp[0].depth > 8;
    AVPixelFormat want = high ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;
    int w = f->width, h = f->height, cw = (w + 1) / 2, ch = (h + 1) / 2;
    int bpp = high ? 2 : 1;
    const uint8_t* planes[2];
    int pitches[2];
    if (f->format == want) {
        planes[0] = f->data[0]; planes[1] = f->data[1];
        pitches[0] = f->linesize[0]; pitches[1] = f->linesize[1];
    } else {
        sws_ = sws_getCachedContext(sws_, w, h, (AVPixelFormat)f->format, w, h, want, SWS_POINT, nullptr, nullptr, nullptr);
        if (!sws_) return false;
        size_t ysz = (size_t)w * h * bpp, uvsz = (size_t)cw * 2 * ch * bpp;
        sw_buf_.resize(ysz + uvsz);
        uint8_t* dst[4] = {sw_buf_.data(), sw_buf_.data() + ysz, nullptr, nullptr};
        int dls[4] = {w * bpp, cw * 2 * bpp, 0, 0};
        sws_scale(sws_, f->data, f->linesize, 0, h, dst, dls);
        planes[0] = dst[0]; planes[1] = dst[1];
        pitches[0] = dls[0]; pitches[1] = dls[1];
    }
    GpuLock gl;
    if (!ensure_sw(s, w, h, high)) return false;
    D3D11_MAPPED_SUBRESOURCE mp;
    if (SUCCEEDED(G.ctx->Map(s.ytex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mp))) {
        for (int y = 0; y < h; y++) memcpy((uint8_t*)mp.pData + (size_t)y * mp.RowPitch, planes[0] + (size_t)y * pitches[0], (size_t)w * bpp);
        G.ctx->Unmap(s.ytex.Get(), 0);
    }
    if (SUCCEEDED(G.ctx->Map(s.uvtex.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mp))) {
        for (int y = 0; y < ch; y++) memcpy((uint8_t*)mp.pData + (size_t)y * mp.RowPitch, planes[1] + (size_t)y * pitches[1], (size_t)cw * 2 * bpp);
        G.ctx->Unmap(s.uvtex.Get(), 0);
    }
    return true;
}

bool VideoRenderer::ensure_target(int w, int h) {
    if (target_ && target_w_ == w && target_h_ == h) return true;
    target_.Reset(); target_rtv_.Reset(); target_srv_.Reset();
    D3D11_TEXTURE2D_DESC td{};
    td.Width = (UINT)w; td.Height = (UINT)h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    auto& G = gpu();
    if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &target_))) return false;
    if (FAILED(G.dev->CreateRenderTargetView(target_.Get(), nullptr, &target_rtv_))) return false;
    if (FAILED(G.dev->CreateShaderResourceView(target_.Get(), nullptr, &target_srv_))) return false;
    target_w_ = w; target_h_ = h;
    return true;
}

bool VideoRenderer::convert(const VideoFrame& vf, const OutputConfig& out) {
    if (vf.slot < 0 || vf.slot >= kSlots) return false;
    Slot& s = slots_[vf.slot];
    if (!s.y || !s.uv || vf.w <= 0 || vf.h <= 0) return false;
    auto& G = gpu();
    auto* ctx = G.ctx.Get();
    if (!ensure_target(vf.w, vf.h)) return false;

    const ColorInfo& c = vf.color;
    ConvertConsts k{};
    k.uvScale[0] = (float)vf.w / s.w;
    k.uvScale[1] = (float)vf.h / s.h;
    k.uvOffset[0] = (float)vf.crop_l / s.w;
    k.uvOffset[1] = (float)vf.crop_t / s.h;
    // 4:2:0 的色度位置：左对齐（MPEG-2 / H.264 / HEVC 默认）→ 往右挪半个亮度像素
    int loc = c.chroma_loc == AVCHROMA_LOC_UNSPECIFIED ? AVCHROMA_LOC_LEFT : c.chroma_loc;
    if (loc == AVCHROMA_LOC_LEFT || loc == AVCHROMA_LOC_TOPLEFT || loc == AVCHROMA_LOC_BOTTOMLEFT) k.chromaShift[0] = 0.5f / s.w;
    if (loc == AVCHROMA_LOC_TOPLEFT || loc == AVCHROMA_LOC_TOP) k.chromaShift[1] = 0.5f / s.h;
    bool high = s.fmt == DXGI_FORMAT_P010 || s.fmt == DXGI_FORMAT_P016;
    int bits = high ? std::clamp(c.bits, 9, 16) : 8;
    k.bitScale = high ? (float)(65535.0 / (((1 << bits) - 1) * (double)(1 << (16 - bits)))) : 1.0f;
    ColorInfo cc = c;
    cc.bits = bits;
    ycbcr_matrix(cc, vf.h, k.m);
    k.mode = c.dovi && vf.dovi ? 3 : c.trc == AVCOL_TRC_SMPTE2084 ? 1 : c.trc == AVCOL_TRC_ARIB_STD_B67 ? 2 : 0;
    bool hdr_src = k.mode != 0;
    k.gamut = (c.primaries == AVCOL_PRI_BT2020 || (hdr_src && c.primaries == AVCOL_PRI_UNSPECIFIED) || k.mode == 3) ? 1 : 0;
    k.outHdr = out.hdr ? 1 : 0;
    k.srcPeak = k.mode == 2 ? 1000.0f : std::clamp(c.peak, 400.0f, 10000.0f);
    k.dstPeak = out.hdr ? std::max(100.0f, out.display_peak) : std::max(80.0f, out.sdr_target);
    k.sdrWhite = out.sdr_white;
    k.tonemap = hdr_src && k.srcPeak > k.dstPeak * 1.02f ? 1 : 0;
    k.srcPQ = (float)pq_oetf(k.srcPeak / 10000.0);
    k.dstPQ = (float)pq_oetf(k.dstPeak / 10000.0);

    D3D11_MAPPED_SUBRESOURCE mp;
    if (SUCCEEDED(ctx->Map(cb_convert_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mp))) { memcpy(mp.pData, &k, sizeof k); ctx->Unmap(cb_convert_.Get(), 0); }
    if (k.mode == 3 && SUCCEEDED(ctx->Map(cb_dovi_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mp))) {
        memcpy(mp.pData, vf.dovi.get(), sizeof(DoviConsts));
        ctx->Unmap(cb_dovi_.Get(), 0);
    }
    D3D11_VIEWPORT vp{0, 0, (float)vf.w, (float)vf.h, 0, 1};
    ctx->RSSetViewports(1, &vp);
    ctx->RSSetState(raster_.Get());
    ID3D11RenderTargetView* rtv = target_rtv_.Get();
    ctx->OMSetRenderTargets(1, &rtv, nullptr);
    ctx->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    ctx->IASetInputLayout(nullptr);
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ctx->VSSetShader(vs_.Get(), nullptr, 0);
    ctx->PSSetShader(ps_convert_.Get(), nullptr, 0);
    ID3D11Buffer* cbs[2] = {cb_convert_.Get(), cb_dovi_.Get()};
    ctx->PSSetConstantBuffers(0, 2, cbs);
    ID3D11ShaderResourceView* srv[2] = {s.y.Get(), s.uv.Get()};
    ctx->PSSetShaderResources(0, 2, srv);
    ID3D11SamplerState* ss[2] = {linear_.Get(), point_.Get()};
    ctx->PSSetSamplers(0, 2, ss);
    ctx->Draw(3, 0);
    ID3D11ShaderResourceView* none[2] = {nullptr, nullptr};
    ctx->PSSetShaderResources(0, 2, none);
    ctx->OMSetRenderTargets(0, nullptr, nullptr);
    conv_w_ = vf.w;
    conv_h_ = vf.h;
    sar_ = vf.sar > 0 ? vf.sar : 1;
    has_frame_ = true;
    return true;
}

void VideoRenderer::present(cv_surface* s, const OutputConfig& out, SubLayer* subs, double) {
    auto& G = gpu();
    auto* ctx = G.ctx.Get();
    const float black[4] = {0, 0, 0, 1};
    ctx->ClearRenderTargetView(s->rtv.Get(), black);
    PresentConsts k{};
    int W = s->w, H = s->h;
    if (has_frame_) {
        fit_rect(W, H, conv_w_, conv_h_, sar_, k.dst);
        k.bicubic = k.dst[2] > conv_w_ * 1.01f || k.dst[3] > conv_h_ * 1.01f;
    } else {
        k.dst[2] = k.dst[3] = 1;
        k.dst[0] = k.dst[1] = -10;
    }
    k.srcSize[0] = (float)std::max(1, conv_w_);
    k.srcSize[1] = (float)std::max(1, conv_h_);
    k.targetSize[0] = (float)W;
    k.targetSize[1] = (float)H;
    k.outHdr = out.hdr ? 1 : 0;
    ID3D11ShaderResourceView* sub_srv = subs ? subs->srv(W, H) : nullptr;
    k.hasSubs = sub_srv ? 1 : 0;
    k.subGain = out.sdr_white / 80.0f;
    D3D11_MAPPED_SUBRESOURCE mp;
    if (SUCCEEDED(ctx->Map(cb_present_.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mp))) { memcpy(mp.pData, &k, sizeof k); ctx->Unmap(cb_present_.Get(), 0); }
    D3D11_VIEWPORT vp{0, 0, (float)W, (float)H, 0, 1};
    ctx->RSSetViewports(1, &vp);
    ctx->RSSetState(raster_.Get());
    ID3D11RenderTargetView* rtv = s->rtv.Get();
    ctx->OMSetRenderTargets(1, &rtv, nullptr);
    ctx->OMSetBlendState(nullptr, nullptr, 0xffffffff);
    ctx->IASetInputLayout(nullptr);
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ctx->VSSetShader(vs_.Get(), nullptr, 0);
    ctx->PSSetShader(ps_present_.Get(), nullptr, 0);
    ID3D11Buffer* cb = cb_present_.Get();
    ctx->PSSetConstantBuffers(2, 1, &cb);
    ID3D11ShaderResourceView* srv[2] = {has_frame_ ? target_srv_.Get() : nullptr, sub_srv};
    ctx->PSSetShaderResources(0, 2, srv);
    ID3D11SamplerState* ss[2] = {linear_.Get(), point_.Get()};
    ctx->PSSetSamplers(0, 2, ss);
    ctx->Draw(3, 0);
    ID3D11ShaderResourceView* none[2] = {nullptr, nullptr};
    ctx->PSSetShaderResources(0, 2, none);
    ctx->OMSetRenderTargets(0, nullptr, nullptr);
}

bool VideoRenderer::readback(std::vector<uint8_t>& rgba, int& w, int& h) {
    if (!has_frame_ || !target_) return false;
    auto& G = gpu();
    GpuLock gl;
    D3D11_TEXTURE2D_DESC td;
    target_->GetDesc(&td);
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> st;
    if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &st))) return false;
    G.ctx->CopyResource(st.Get(), target_.Get());
    D3D11_MAPPED_SUBRESOURCE mp;
    if (FAILED(G.ctx->Map(st.Get(), 0, D3D11_MAP_READ, 0, &mp))) return false;
    w = (int)td.Width; h = (int)td.Height;
    rgba.resize((size_t)w * h * 4);
    auto half = [](uint16_t v) -> float {
        uint32_t sign = (v >> 15) & 1, e = (v >> 10) & 31, m = v & 1023;
        float r = e == 0 ? std::ldexp((float)m, -24) : e == 31 ? 65504.0f : std::ldexp((float)(m | 1024), (int)e - 25);
        return sign ? -r : r;
    };
    for (int y = 0; y < h; y++) {
        auto row = (const uint16_t*)((const uint8_t*)mp.pData + (size_t)y * mp.RowPitch);
        for (int x = 0; x < w; x++)
            for (int c = 0; c < 4; c++)
                rgba[((size_t)y * w + x) * 4 + c] = (uint8_t)std::clamp((int)std::lround(half(row[x * 4 + c]) * 255.0f), 0, 255);
    }
    G.ctx->Unmap(st.Get(), 0);
    return true;
}

}  // namespace cv
