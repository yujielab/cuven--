// 光学配对的粒子云：粒子（和 web/pair.js 的 buildParticles 逐个一致）+ 每帧的常量 + 自己的渲染线程
#include "surface.h"
#include "shaders_gen.h"

using namespace cv;

namespace {

constexpr int BODY_POINTS = 53000, HALO_POINTS = 16500, WISPS = 12, POINTS_PER_WISP = 1500;
constexpr int DENSITY_TILE = 112, DENSITY_COLUMNS = 12, DENSITY_FRAMES = 120, DENSITY_STRIDE = DENSITY_TILE + 2;
constexpr int DENSITY_WIDTH = DENSITY_STRIDE * DENSITY_COLUMNS, DENSITY_HEIGHT = DENSITY_STRIDE * (DENSITY_FRAMES / DENSITY_COLUMNS);
constexpr double LOOP_SECONDS = 10, TAU = 6.283185307179586;
constexpr float CODE_EXT = 1.6f;

struct Particle { float pos[4]; float det[4]; };

struct alignas(16) Consts {
    float scale[2], center[2];
    float spriteScale, phase, gathering, codeExt;
    float codeRot[2], densityScale[2];
    float densityOrigins[4];
    float densityBlend, codeScale, viewport[2];
};
static_assert(sizeof(Consts) % 16 == 0, "cbuffer");

// xorshift32，和 JS 的位运算同一串数（JS 里 <<、^ 是 32 位，>>> 是无符号）
struct Rng {
    uint32_t s = 0x7a32f9d1u;
    double next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s / 4294967296.0; }
    double bell() { double a = next(); a += next(); a += next(); a += next(); return (a - 2) * 1.73; }
};

std::vector<Particle> build_particles() {
    std::vector<Particle> p;
    p.reserve(BODY_POINTS + HALO_POINTS + WISPS * POINTS_PER_WISP);
    Rng r;
    for (int i = 0; i < BODY_POINTS + HALO_POINTS; i++) {
        bool halo = i >= BODY_POINTS;
        double lon = r.next() * TAU;
        double z = r.next() * 2 - 1;
        double eq = std::sqrt(1 - z * z);
        bool shell = r.next() < 0.82;
        double radius;
        if (halo) radius = 1.07 + 0.57 * std::pow(r.next(), 1.85);
        else if (shell) radius = 0.937 + 0.101 * r.bell();
        else radius = 0.96 * std::cbrt(r.next());
        Particle q{};
        q.pos[0] = (float)(std::cos(lon) * eq * radius);
        q.pos[1] = (float)(std::sin(lon) * eq * radius);
        q.pos[2] = (float)(z * radius);
        q.pos[3] = 0;
        q.det[0] = (float)r.next();
        q.det[1] = (float)(halo ? r.next() : 0.63 + 0.37 * r.next());
        q.det[2] = (float)r.next();
        q.det[3] = halo ? 1.0f : 0.0f;
        p.push_back(q);
    }
    for (int s = 0; s < WISPS; s++) {
        double lon2 = s * 2.399963 + 0.55 * r.next();
        double elev = std::asin((s + 0.5) / WISPS * 1.83 - 0.915) + 0.15 * r.bell();
        double idPhase = s * 1.954 + 0.5 * r.next();
        for (int i = 0; i < POINTS_PER_WISP; i++) {
            double along = r.next() * 2 - 1;
            double scatter = r.next() < 0.22 ? 2.7 : 1;
            Particle q{};
            q.pos[0] = (float)lon2;
            q.pos[1] = (float)elev;
            q.pos[2] = (float)along;
            q.pos[3] = (float)idPhase;
            q.det[0] = (float)r.next();
            q.det[1] = (float)(r.bell() * scatter);
            q.det[2] = (float)(r.bell() * scatter);
            q.det[3] = 2;
            p.push_back(q);
        }
    }
    return p;
}

// 浓淡在一个循环里的变化（照录屏拟合）
double gathering_cycle(double ph) {
    return 0.649 + 0.031 * std::cos(ph) - 0.125 * std::sin(ph) + 0.036 * std::cos(2 * ph) + 0.109 * std::sin(2 * ph)
         - 0.222 * std::cos(3 * ph) - 0.036 * std::sin(3 * ph) - 0.047 * std::cos(4 * ph) + 0.013 * std::sin(4 * ph);
}

}  // namespace

struct cv_cloud {
    cv_surface* surface = nullptr;
    ComPtr<ID3D11VertexShader> vs;
    ComPtr<ID3D11PixelShader> ps;
    ComPtr<ID3D11InputLayout> layout;
    ComPtr<ID3D11Buffer> particles, cb;
    ComPtr<ID3D11ShaderResourceView> density, code;
    ComPtr<ID3D11Texture2D> code_tex;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11BlendState> blend;
    ComPtr<ID3D11RasterizerState> raster;
    UINT count = 0;
    bool atlas_ok = false;
    float code_scale = 3.0f, code_spin = 0.05f;
    float bg[4] = {0, 0, 0, 0};
    std::atomic<bool> coded{false};
    double t0 = 0, code_t0 = 0;

    std::thread th;
    std::mutex m;
    std::condition_variable cv;
    bool running = false, quit = false;

    bool init(const uint8_t* atlas, int aw, int ah);
    void draw(ID3D11RenderTargetView* rtv, int w, int h, double t, double code_t, bool use_bg = true);
    void loop();
};

bool cv_cloud::init(const uint8_t* atlas, int aw, int ah) {
    auto& G = gpu();
    auto vsb = compile_shader(k_cloud_hlsl, k_cloud_hlsl_len, "cloud.hlsl", "VS", "vs_5_0");
    auto psb = compile_shader(k_cloud_hlsl, k_cloud_hlsl_len, "cloud.hlsl", "PS", "ps_5_0");
    if (!vsb || !psb) return false;
    if (FAILED(G.dev->CreateVertexShader(vsb->GetBufferPointer(), vsb->GetBufferSize(), nullptr, &vs))) return false;
    if (FAILED(G.dev->CreatePixelShader(psb->GetBufferPointer(), psb->GetBufferSize(), nullptr, &ps))) return false;
    D3D11_INPUT_ELEMENT_DESC el[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0, D3D11_INPUT_PER_INSTANCE_DATA, 1},
        {"DETAIL", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 16, D3D11_INPUT_PER_INSTANCE_DATA, 1},
    };
    if (FAILED(G.dev->CreateInputLayout(el, 2, vsb->GetBufferPointer(), vsb->GetBufferSize(), &layout))) return false;

    auto parts = build_particles();
    count = (UINT)parts.size();
    D3D11_BUFFER_DESC bd{};
    bd.ByteWidth = (UINT)(parts.size() * sizeof(Particle));
    bd.Usage = D3D11_USAGE_IMMUTABLE;
    bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA sd{parts.data(), 0, 0};
    if (FAILED(G.dev->CreateBuffer(&bd, &sd, &particles))) return false;

    D3D11_BUFFER_DESC cbd{};
    cbd.ByteWidth = sizeof(Consts);
    cbd.Usage = D3D11_USAGE_DYNAMIC;
    cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(G.dev->CreateBuffer(&cbd, nullptr, &cb))) return false;

    // 密度校正图：没有（或尺寸不对）就用中性的 128（不校正）
    auto r8 = [&](int w, int h, const uint8_t* px, ComPtr<ID3D11Texture2D>* keep, bool dynamic) -> ComPtr<ID3D11ShaderResourceView> {
        D3D11_TEXTURE2D_DESC td{};
        td.Width = (UINT)w; td.Height = (UINT)h; td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_R8_UNORM; td.SampleDesc.Count = 1;
        td.Usage = dynamic ? D3D11_USAGE_DEFAULT : D3D11_USAGE_IMMUTABLE;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        D3D11_SUBRESOURCE_DATA s{px, (UINT)w, 0};
        ComPtr<ID3D11Texture2D> t;
        ComPtr<ID3D11ShaderResourceView> v;
        if (FAILED(G.dev->CreateTexture2D(&td, &s, &t)) || FAILED(G.dev->CreateShaderResourceView(t.Get(), nullptr, &v))) return nullptr;
        if (keep) *keep = t;
        return v;
    };
    static const uint8_t neutral = 128, unit = 85;   // 85 / 255 × 3 = 1：没设码之前 M = 1
    atlas_ok = atlas && aw == DENSITY_WIDTH && ah == DENSITY_HEIGHT;
    density = atlas_ok ? r8(aw, ah, atlas, nullptr, false) : r8(1, 1, &neutral, nullptr, false);
    code = r8(1, 1, &unit, &code_tex, true);
    if (!density || !code) return false;

    D3D11_SAMPLER_DESC sm{};
    sm.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sm.AddressU = sm.AddressV = sm.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sm.MaxLOD = D3D11_FLOAT32_MAX;
    G.dev->CreateSamplerState(&sm, &sampler);

    // 画在透明表面上（预乘）：颜色按 over 混合，透明度累积 —— 和网页版 blendFuncSeparate 一样
    D3D11_BLEND_DESC b{};
    b.RenderTarget[0].BlendEnable = TRUE;
    b.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
    b.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    b.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    b.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    b.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    b.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    b.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    G.dev->CreateBlendState(&b, &blend);
    D3D11_RASTERIZER_DESC rs{};
    rs.FillMode = D3D11_FILL_SOLID;
    rs.CullMode = D3D11_CULL_NONE;
    rs.DepthClipEnable = TRUE;
    G.dev->CreateRasterizerState(&rs, &raster);
    t0 = now();
    log("粒子云：%u 个粒子，密度校正图 %s", count, atlas_ok ? "已载入" : "没有");
    return true;
}

void cv_cloud::draw(ID3D11RenderTargetView* rtv, int w, int h, double t, double code_t, bool use_bg) {
    auto& G = gpu();
    auto* ctx = G.ctx.Get();
    Consts c{};
    double radius = std::min(w, h) * 0.30;
    c.scale[0] = (float)(radius * 2 / w);
    c.scale[1] = (float)(radius * 2 / h);
    c.spriteScale = (float)(radius / 186.5);
    double progress = std::fmod(t / LOOP_SECONDS, 1.0), phase = progress * TAU;
    c.phase = (float)phase;
    c.gathering = (float)gathering_cycle(phase);
    c.codeExt = CODE_EXT;
    if (atlas_ok) {
        double f = progress * DENSITY_FRAMES;
        int a = (int)std::floor(f) % DENSITY_FRAMES, b = (a + 1) % DENSITY_FRAMES;
        auto left = [](int i) { return (float)(((i % DENSITY_COLUMNS) * DENSITY_STRIDE + 1) / (double)DENSITY_WIDTH); };
        auto top = [](int i) { return (float)(((i / DENSITY_COLUMNS) * DENSITY_STRIDE + 1) / (double)DENSITY_HEIGHT); };
        c.densityOrigins[0] = left(a); c.densityOrigins[1] = top(a);
        c.densityOrigins[2] = left(b); c.densityOrigins[3] = top(b);
        c.densityBlend = (float)(f - std::floor(f));
        c.densityScale[0] = (float)DENSITY_TILE / DENSITY_WIDTH;
        c.densityScale[1] = (float)DENSITY_TILE / DENSITY_HEIGHT;
    } else {
        c.densityOrigins[0] = c.densityOrigins[1] = c.densityOrigins[2] = c.densityOrigins[3] = 0.5f;
    }
    double ang = code_t * code_spin;
    c.codeRot[0] = (float)std::cos(ang);
    c.codeRot[1] = (float)std::sin(ang);
    c.codeScale = code_scale;
    c.viewport[0] = (float)w;
    c.viewport[1] = (float)h;

    D3D11_MAPPED_SUBRESOURCE mp;
    if (SUCCEEDED(ctx->Map(cb.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mp))) {
        memcpy(mp.pData, &c, sizeof c);
        ctx->Unmap(cb.Get(), 0);
    }
    const float transparent[4] = {0, 0, 0, 0};
    float clear[4] = {bg[0] * bg[3], bg[1] * bg[3], bg[2] * bg[3], bg[3]};
    ctx->ClearRenderTargetView(rtv, use_bg ? clear : transparent);
    D3D11_VIEWPORT vp{0, 0, (float)w, (float)h, 0, 1};
    ctx->RSSetViewports(1, &vp);
    ctx->RSSetState(raster.Get());
    ctx->OMSetRenderTargets(1, &rtv, nullptr);
    ctx->OMSetBlendState(blend.Get(), nullptr, 0xffffffff);
    ctx->OMSetDepthStencilState(nullptr, 0);
    ctx->IASetInputLayout(layout.Get());
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    UINT stride = sizeof(Particle), offset = 0;
    ID3D11Buffer* vb = particles.Get();
    ctx->IASetVertexBuffers(0, 1, &vb, &stride, &offset);
    ctx->VSSetShader(vs.Get(), nullptr, 0);
    ctx->PSSetShader(ps.Get(), nullptr, 0);
    ID3D11Buffer* cbs = cb.Get();
    ctx->VSSetConstantBuffers(0, 1, &cbs);
    ctx->PSSetConstantBuffers(0, 1, &cbs);
    ID3D11ShaderResourceView* srv[2] = {density.Get(), code.Get()};
    ctx->PSSetShaderResources(0, 2, srv);
    ID3D11SamplerState* ss = sampler.Get();
    ctx->PSSetSamplers(0, 1, &ss);
    ctx->DrawInstanced(4, count, 0, 0);
    ID3D11ShaderResourceView* none[2] = {nullptr, nullptr};
    ctx->PSSetShaderResources(0, 2, none);
}

void cv_cloud::loop() {
    name_thread(L"Cuven pairing cloud");
    thread_qos(CV_QOS_DEFAULT);
    double last = 0, avg = 1.0 / 60;
    UINT interval = 1;
    for (;;) {
        {
            std::unique_lock<std::mutex> l(m);
            cv.wait(l, [&] { return quit || (running && coded); });
            if (quit) return;
        }
        surface->wait_ready(100);
        if (!surface->prepare()) { Sleep(50); continue; }
        double t = now();
        if (last > 0) avg = avg * 0.9 + std::min(0.1, t - last) * 0.1;
        last = t;
        // 高刷屏（120 / 144 Hz）不必每次刷新都画：隔一帧画一次，省电（动画按时间走，快慢不变）
        interval = avg < 0.0105 ? 2 : 1;
        {
            GpuLock gl;
            draw(surface->rtv.Get(), surface->w, surface->h, t - t0, t - code_t0);
        }
        surface->present(interval);
    }
}

extern "C" {

CV_API cv_cloud* CV_CALL cv_cloud_create(cv_surface* s, const uint8_t* atlas, int aw, int ah) {
    if (!s) return nullptr;
    auto c = new cv_cloud();
    c->surface = s;
    {
        std::lock_guard<std::mutex> l(s->m);
        // 和网页版一样至少按 1.5 倍像素画（100% 缩放的屏上细粒子不至于糊成一片），最多 2.5 倍
        s->ss_min = 1.5f;
        s->ss_max = 2.5f;
        s->dirty = true;
    }
    bool ok;
    {
        GpuLock gl;
        ok = c->init(atlas, aw, ah);
    }
    if (!ok) { log("粒子云初始化失败"); delete c; return nullptr; }
    c->th = std::thread([c] { c->loop(); });
    return c;
}

CV_API void CV_CALL cv_cloud_set_code(cv_cloud* c, const uint8_t* grid, int g, float code_scale, float code_spin) {
    if (!c || !grid || g <= 0) return;
    auto& G = gpu();
    D3D11_TEXTURE2D_DESC td{};
    td.Width = (UINT)g; td.Height = (UINT)g; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8_UNORM; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA s{grid, (UINT)g, 0};
    ComPtr<ID3D11Texture2D> t;
    ComPtr<ID3D11ShaderResourceView> v;
    {
        GpuLock gl;
        if (FAILED(G.dev->CreateTexture2D(&td, &s, &t)) || FAILED(G.dev->CreateShaderResourceView(t.Get(), nullptr, &v))) return;
        c->code_tex = t;
        c->code = v;
        c->code_scale = code_scale > 0 ? code_scale : 3.0f;
        c->code_spin = code_spin;
        c->code_t0 = now();
    }
    std::lock_guard<std::mutex> l(c->m);
    c->coded = true;
    c->cv.notify_all();
}

CV_API void CV_CALL cv_cloud_set_background(cv_cloud* c, float r, float g, float b, float a) {
    if (!c) return;
    GpuLock gl;
    c->bg[0] = r; c->bg[1] = g; c->bg[2] = b; c->bg[3] = a;
}

CV_API void CV_CALL cv_cloud_run(cv_cloud* c, int running) {
    if (!c) return;
    std::lock_guard<std::mutex> l(c->m);
    c->running = running != 0;
    c->cv.notify_all();
}

CV_API int CV_CALL cv_cloud_snapshot(cv_cloud* c, double t, double code_t, int w, int h, uint8_t* rgba) {
    if (!c || w <= 0 || h <= 0 || !rgba) return -1;
    auto& G = gpu();
    GpuLock gl;
    D3D11_TEXTURE2D_DESC td{};
    td.Width = (UINT)w; td.Height = (UINT)h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> rt, st;
    ComPtr<ID3D11RenderTargetView> rtv;
    if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &rt)) || FAILED(G.dev->CreateRenderTargetView(rt.Get(), nullptr, &rtv))) return -2;
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &st))) return -3;
    c->draw(rtv.Get(), w, h, t, code_t, false);   // 自检：透明地画，调用方叠到白底上
    G.ctx->CopyResource(st.Get(), rt.Get());
    D3D11_MAPPED_SUBRESOURCE mp;
    if (FAILED(G.ctx->Map(st.Get(), 0, D3D11_MAP_READ, 0, &mp))) return -4;
    for (int y = 0; y < h; y++) {
        auto src = (const uint8_t*)mp.pData + (size_t)y * mp.RowPitch;
        auto dst = rgba + (size_t)y * w * 4;
        for (int x = 0; x < w; x++) {
            dst[4 * x + 0] = src[4 * x + 2];
            dst[4 * x + 1] = src[4 * x + 1];
            dst[4 * x + 2] = src[4 * x + 0];
            dst[4 * x + 3] = src[4 * x + 3];
        }
    }
    G.ctx->Unmap(st.Get(), 0);
    return 0;
}

CV_API void CV_CALL cv_cloud_destroy(cv_cloud* c) {
    if (!c) return;
    {
        std::lock_guard<std::mutex> l(c->m);
        c->quit = true;
        c->cv.notify_all();
    }
    if (c->th.joinable()) c->th.join();
    GpuLock gl;
    delete c;
}

}  // extern "C"
