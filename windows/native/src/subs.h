#pragma once
#include "common.h"

namespace cv {

// 字幕：文字（ASS / SRT / mov_text / 在线字幕）和图形（PGS / VobSub / DVB）都自己画进一张 BGRA 纹理，
// 只在要显示的内容变了时重画（Direct2D / DirectWrite），上屏那一遍叠上去
class SubLayer {
public:
    enum Source { None = 0, Embedded = 1, External = 2 };

    ~SubLayer();
    // 解封装线程：一条解出来的内封字幕
    void add(const AVSubtitle& s, double pts, double pkt_dur, int canvas_w, int canvas_h, bool bitmap_stream, int serial);
    void clear_embedded(int serial);
    void set_external(std::vector<std::pair<double, double>> times, std::vector<std::wstring> texts);
    void select(Source s);
    Source source() const { return src_; }
    void set_style(float scale, float bottom) { std::lock_guard<std::mutex> l(m_); scale_ = scale; bottom_ = bottom; dirty_ = true; }

    // 渲染线程：t 时刻要显示什么；画面在目标里的位置。返回 true = 和上次不一样（要重画、要重新上屏）
    bool update(double t, float vx, float vy, float vw, float vh);
    // 当前字幕层（没有要显示的 = nullptr）。W×H = 目标尺寸
    ID3D11ShaderResourceView* srv(int W, int H);

private:
    struct Event {
        int id;
        double start, end;
        bool bitmap;
        std::wstring text;
        int x = 0, y = 0, w = 0, h = 0, cw = 0, ch = 0;
        std::vector<uint8_t> bgra;   // 预乘
    };
    void draw(int W, int H);

    std::mutex m_;
    std::vector<Event> emb_, ext_;
    std::vector<int> active_;        // 当前显示的事件号
    Source src_ = None;
    int next_id_ = 1;
    int serial_ = 0;
    float scale_ = 1.0f, bottom_ = 0.06f;
    float vx_ = 0, vy_ = 0, vw_ = 0, vh_ = 0;
    bool dirty_ = true;
    int tex_w_ = 0, tex_h_ = 0;
    ComPtr<ID3D11Texture2D> tex_;
    ComPtr<ID3D11ShaderResourceView> srv_;
    ComPtr<ID2D1DeviceContext> dc_;
    ComPtr<ID2D1Bitmap1> target_;
    ComPtr<IDWriteTextFormat> fmt_;
    float fmt_size_ = 0;
};

}  // namespace cv
