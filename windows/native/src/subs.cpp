#include "subs.h"

namespace cv {

SubLayer::~SubLayer() {
    GpuLock gl;
    target_.Reset();
    dc_.Reset();
    srv_.Reset();
    tex_.Reset();
}

// ASS 一行（ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text）→ 纯文字
static std::wstring ass_text(const char* ass) {
    const char* p = ass;
    for (int commas = 0; *p && commas < 8; p++)
        if (*p == ',') commas++;
    std::wstring w = widen(p);
    std::wstring o;
    o.reserve(w.size());
    for (size_t i = 0; i < w.size(); i++) {
        wchar_t c = w[i];
        if (c == L'{') {   // {\b1} 之类的样式标签
            size_t j = w.find(L'}', i);
            if (j != std::wstring::npos) { i = j; continue; }
        }
        if (c == L'\\' && i + 1 < w.size()) {
            wchar_t n = w[i + 1];
            if (n == L'N' || n == L'n') { o += L'\n'; i++; continue; }
            if (n == L'h') { o += L' '; i++; continue; }
        }
        o += c;
    }
    while (!o.empty() && (o.back() == L'\n' || o.back() == L' ')) o.pop_back();
    return o;
}

void SubLayer::add(const AVSubtitle& s, double pts, double pkt_dur, int cw, int ch, bool bitmap_stream, int serial) {
    std::lock_guard<std::mutex> l(m_);
    if (serial != serial_) return;
    double start = pts + s.start_display_time / 1000.0;
    if (bitmap_stream) {
        // 图形字幕是「整屏状态」：新的一条一来，前面没结束的都在这一刻结束（空的一条 = 清屏）
        for (auto& e : emb_)
            if (e.bitmap && e.end > start) e.end = start;
    }
    double end;
    if (s.end_display_time > s.start_display_time && s.end_display_time < 60000) end = pts + s.end_display_time / 1000.0;
    else if (bitmap_stream) end = 1e12;
    else end = start + (pkt_dur > 0 ? pkt_dur : 5.0);
    for (unsigned i = 0; i < s.num_rects; i++) {
        const AVSubtitleRect* r = s.rects[i];
        Event e;
        e.id = next_id_++;
        e.start = start;
        e.end = end;
        if (r->type == SUBTITLE_BITMAP && r->w > 0 && r->h > 0 && r->data[0] && r->data[1]) {
            e.bitmap = true;
            e.x = r->x; e.y = r->y; e.w = r->w; e.h = r->h;
            e.cw = cw; e.ch = ch;
            e.bgra.resize((size_t)r->w * r->h * 4);
            auto pal = (const uint32_t*)r->data[1];
            for (int y = 0; y < r->h; y++)
                for (int x = 0; x < r->w; x++) {
                    uint32_t c = pal[r->data[0][(size_t)y * r->linesize[0] + x]];
                    uint32_t a = c >> 24, rr = (c >> 16) & 255, g = (c >> 8) & 255, b = c & 255;
                    uint8_t* o = &e.bgra[((size_t)y * r->w + x) * 4];
                    o[0] = (uint8_t)(b * a / 255); o[1] = (uint8_t)(g * a / 255); o[2] = (uint8_t)(rr * a / 255); o[3] = (uint8_t)a;
                }
        } else if (r->type == SUBTITLE_ASS && r->ass) {
            e.bitmap = false;
            e.text = ass_text(r->ass);
        } else if (r->type == SUBTITLE_TEXT && r->text) {
            e.bitmap = false;
            e.text = widen(r->text);
        } else {
            continue;
        }
        if (!e.bitmap && e.text.empty()) continue;
        emb_.push_back(std::move(e));
    }
    // 只留最近的（半小时以前结束的扔掉）
    if (emb_.size() > 4000) {
        double cut = start - 1800;
        emb_.erase(std::remove_if(emb_.begin(), emb_.end(), [&](const Event& e) { return e.end < cut; }), emb_.end());
    }
}

void SubLayer::clear_embedded(int serial) {
    std::lock_guard<std::mutex> l(m_);
    serial_ = serial;
    emb_.clear();
    dirty_ = true;
}

void SubLayer::set_external(std::vector<std::pair<double, double>> times, std::vector<std::wstring> texts) {
    std::lock_guard<std::mutex> l(m_);
    ext_.clear();
    for (size_t i = 0; i < times.size() && i < texts.size(); i++) {
        Event e;
        e.id = next_id_++;
        e.start = times[i].first;
        e.end = times[i].second;
        e.bitmap = false;
        e.text = texts[i];
        ext_.push_back(std::move(e));
    }
    std::sort(ext_.begin(), ext_.end(), [](const Event& a, const Event& b) { return a.start < b.start; });
    dirty_ = true;
}

void SubLayer::select(Source s) {
    std::lock_guard<std::mutex> l(m_);
    src_ = s;
    dirty_ = true;
}

bool SubLayer::update(double t, float vx, float vy, float vw, float vh) {
    std::lock_guard<std::mutex> l(m_);
    std::vector<int> now_ids;
    const auto& list = src_ == Embedded ? emb_ : ext_;
    if (src_ != None) {
        for (const auto& e : list)
            if (e.start <= t && t < e.end) now_ids.push_back(e.id);
    }
    bool moved = vx != vx_ || vy != vy_ || vw != vw_ || vh != vh_;
    bool changed = now_ids != active_ || dirty_ || (moved && !now_ids.empty());
    if (changed) {
        active_ = std::move(now_ids);
        vx_ = vx; vy_ = vy; vw_ = vw; vh_ = vh;
        dirty_ = true;
    }
    return changed;
}

ID3D11ShaderResourceView* SubLayer::srv(int W, int H) {
    std::lock_guard<std::mutex> l(m_);
    if (active_.empty()) return nullptr;
    if (dirty_ || W != tex_w_ || H != tex_h_ || !srv_) draw(W, H);
    return srv_.Get();
}

void SubLayer::draw(int W, int H) {
    auto& G = gpu();
    dirty_ = false;
    if (!G.d2d_dev) return;
    if (!tex_ || W != tex_w_ || H != tex_h_) {
        target_.Reset(); srv_.Reset(); tex_.Reset();
        D3D11_TEXTURE2D_DESC td{};
        td.Width = (UINT)W; td.Height = (UINT)H; td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        if (FAILED(G.dev->CreateTexture2D(&td, nullptr, &tex_))) return;
        if (FAILED(G.dev->CreateShaderResourceView(tex_.Get(), nullptr, &srv_))) return;
        if (!dc_ && FAILED(G.d2d_dev->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &dc_))) return;
        ComPtr<IDXGISurface> surf;
        tex_.As(&surf);
        D2D1_BITMAP_PROPERTIES1 bp = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                                                             D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
        if (FAILED(dc_->CreateBitmapFromDxgiSurface(surf.Get(), &bp, &target_))) return;
        tex_w_ = W; tex_h_ = H;
    }
    dc_->SetTarget(target_.Get());
    dc_->BeginDraw();
    dc_->Clear(D2D1::ColorF(0, 0, 0, 0));
    const auto& list = src_ == Embedded ? emb_ : ext_;
    std::wstring text;
    float vw = vw_ > 0 ? vw_ : (float)W, vh = vh_ > 0 ? vh_ : (float)H;
    for (int id : active_) {
        auto it = std::find_if(list.begin(), list.end(), [&](const Event& e) { return e.id == id; });
        if (it == list.end()) continue;
        const Event& e = *it;
        if (e.bitmap) {
            ComPtr<ID2D1Bitmap1> bm;
            D2D1_BITMAP_PROPERTIES1 p = D2D1::BitmapProperties1(D2D1_BITMAP_OPTIONS_NONE,
                                                                D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
            if (FAILED(dc_->CreateBitmap(D2D1::SizeU((UINT32)e.w, (UINT32)e.h), e.bgra.data(), (UINT32)e.w * 4, &p, &bm))) continue;
            float cw = e.cw > 0 ? (float)e.cw : vw, ch = e.ch > 0 ? (float)e.ch : vh;
            float sx = vw / cw, sy = vh / ch;
            D2D1_RECT_F r = D2D1::RectF(vx_ + e.x * sx, vy_ + e.y * sy, vx_ + (e.x + e.w) * sx, vy_ + (e.y + e.h) * sy);
            dc_->DrawBitmap(bm.Get(), r, 1.0f, D2D1_INTERPOLATION_MODE_HIGH_QUALITY_CUBIC);
        } else {
            if (!text.empty()) text += L"\n";
            text += e.text;
        }
    }
    if (!text.empty() && G.dwrite) {
        float size = std::max(14.0f, vh * 0.052f * scale_);
        if (!fmt_ || std::fabs(size - fmt_size_) > 0.5f) {
            fmt_.Reset();
            G.dwrite->CreateTextFormat(L"Microsoft YaHei UI", nullptr, DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL,
                                       DWRITE_FONT_STRETCH_NORMAL, size, L"zh-CN", &fmt_);
            if (fmt_) {
                fmt_->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
                fmt_->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_FAR);
                fmt_->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);
            }
            fmt_size_ = size;
        }
        if (fmt_) {
            // 字幕放在画面里（贴着画面下沿往上一点）；画面很扁时最多压到屏幕底部
            float boxw = vw * 0.9f;
            float bottom = std::min((float)H - size * 0.4f, vy_ + vh * (1.0f - bottom_));
            ComPtr<IDWriteTextLayout> lay;
            G.dwrite->CreateTextLayout(text.c_str(), (UINT32)text.size(), fmt_.Get(), boxw, std::max(1.0f, bottom), &lay);
            if (lay) {
                ComPtr<ID2D1SolidColorBrush> white, shadow;
                dc_->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), &white);
                dc_->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 0.82f), &shadow);
                float x0 = vx_ + (vw - boxw) / 2;
                float o = std::max(1.0f, size * 0.06f);
                // 描边：八个方向各画一遍深色，再画白字
                static const float dirs[8][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {0.7f, 0.7f}, {-0.7f, 0.7f}, {0.7f, -0.7f}, {-0.7f, -0.7f}};
                for (auto& d : dirs) dc_->DrawTextLayout(D2D1::Point2F(x0 + d[0] * o, d[1] * o), lay.Get(), shadow.Get());
                dc_->DrawTextLayout(D2D1::Point2F(x0, 0), lay.Get(), white.Get());
            }
        }
    }
    dc_->EndDraw();
    dc_->SetTarget(nullptr);
}

}  // namespace cv
