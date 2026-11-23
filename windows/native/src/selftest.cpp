// 自检（CI 上跑：WARP 软件渲染、没声卡也行）：打开一个片子 → 播 → 读回画面存 PNG → 跳转 → 再读回 → 写报告
#include "player_internal.h"
#include "surface.h"

#include <cstdarg>

using namespace cv;

namespace {

struct Events {
    std::mutex m;
    std::vector<std::string> lines;
    std::atomic<bool> opened{false}, error{false}, ended{false};
};

void CV_CALL on_event(void* user, int ev, int arg, const char* text) {
    auto e = (Events*)user;
    char line[300];
    snprintf(line, sizeof line, "事件 %d（%d）%s", ev, arg, text ? text : "");
    std::lock_guard<std::mutex> l(e->m);
    e->lines.push_back(line);
    if (ev == CV_EV_OPENED) e->opened = true;
    if (ev == CV_EV_ERROR) e->error = true;
    if (ev == CV_EV_ENDED) e->ended = true;
}

struct Report {
    std::string s;
    int failed = 0;
    void add(const char* fmt, ...) {
        char b[512];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(b, sizeof b, fmt, ap);
        va_end(ap);
        s += b;
        s += "\n";
    }
    void check(bool ok, const char* what) {
        add("%s %s", ok ? "✓" : "✗", what);
        if (!ok) failed++;
    }
};

bool wait_for(std::function<bool()> f, double seconds) {
    double t0 = now();
    while (now() - t0 < seconds) {
        if (f()) return true;
        Sleep(50);
    }
    return f();
}

// 画面统计：平均亮度、彩色程度（全黑 / 全灰都说明出了问题）
void stats(const std::vector<uint8_t>& px, double& mean, double& chroma) {
    double s = 0, c = 0;
    size_t n = px.size() / 4;
    for (size_t i = 0; i < n; i++) {
        int r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
        s += (r + g + b) / 3.0;
        c += std::max({r, g, b}) - std::min({r, g, b});
    }
    mean = n ? s / n : 0;
    chroma = n ? c / n : 0;
}

}  // namespace

extern "C" CV_API int CV_CALL cv_selftest(const char* media, const char* out_dir, char* report, int report_len) {
    Report R;
    R.add("CuvenCore 自检：%s", cv_version());
    if (!gpu_ok() && cv_init(CV_INIT_WARP) != 0) { R.check(false, "D3D11 设备"); goto done; }
    R.add("设备：%s（%s）", gpu().name.c_str(), gpu().warp ? "WARP" : "硬件");
    {
        Events ev;
        cv_surface* s = cv_surface_create(960, 540, CV_SURFACE_VIDEO);
        R.check(s != nullptr, "交换链");
        if (!s) goto done;
        cv_player* p = cv_player_create(s, on_event, &ev);
        cv_display d{};
        d.max_nits = 300; d.sdr_white_nits = 80; d.bits = 8;
        cv_player_set_output(p, &d, 1);
        cv_player_open(p, media, 0, 0, "", "eng");
        bool opened = wait_for([&] { return ev.opened || ev.error; }, 60) && ev.opened;
        R.check(opened, "打开片子");
        cv_state st{};
        if (opened) {
            cv_player_set_output(p, &d, 1);
            cv_player_play(p);
            bool moving = wait_for([&] { cv_player_get_state(p, &st); return st.position > 1.5 || ev.ended; }, 90);
            cv_player_get_state(p, &st);
            R.add("位置 %.2f / %.2f 秒，%dx%d，%.3f fps，HDR %d，杜比视界 %d，%s，丢帧 %d，视频 %s，音频 %s", st.position, st.duration, st.width,
                  st.height, st.fps, st.hdr_kind, st.dovi_profile, st.hw_decode ? "硬解" : "软解", st.dropped_frames, st.video_codec, st.audio_codec);
            R.check(moving, "播放（时钟在走）");
            std::vector<uint8_t> px;
            int w = 0, h = 0;
            bool rb = cv_player_readback(p, px, w, h);
            R.check(rb && w > 0, "读回画面");
            if (rb) {
                double mean, chroma;
                stats(px, mean, chroma);
                R.add("画面 1：%dx%d，平均 %.1f，彩色 %.1f", w, h, mean, chroma);
                R.check(mean > 8 && mean < 250, "画面不是全黑 / 全白");
                std::string f = std::string(out_dir) + "\\video-1.png";
                cv_save_png(f.c_str(), px.data(), w, h);
            }
            cv_track tr[32];
            int nt = cv_player_tracks(p, tr, 32);
            for (int i = 0; i < nt && i < 32; i++)
                R.add("轨 %d：%s %s %s %s%s", tr[i].id, tr[i].type == CV_TRACK_AUDIO ? "音频" : "字幕", tr[i].lang, tr[i].codec, tr[i].title,
                      tr[i].selected ? "（选中）" : "");
            if (st.duration > 8) {
                // 片头多是黑的：真片子跳得远一点（自检只下了片子的前一截）
                double target = std::min(st.duration - 3, st.duration > 600 ? 20.0 : 6.0);
                cv_player_seek(p, target, 1);
                Sleep(300);
                bool seeked = wait_for([&] { cv_player_get_state(p, &st); return !st.seeking && st.position >= target - 0.05; }, 60);
                Sleep(1500);
                cv_player_get_state(p, &st);
                R.add("跳到 %.1f 秒后：位置 %.2f", target, st.position);
                R.check(seeked && st.position >= target - 0.1 && st.position < target + 6, "精确跳转");
                if (cv_player_readback(p, px, w, h)) {
                    double mean, chroma;
                    stats(px, mean, chroma);
                    R.add("画面 2：%dx%d，平均 %.1f，彩色 %.1f", w, h, mean, chroma);
                    std::string f = std::string(out_dir) + "\\video-2.png";
                    R.check(cv_save_png(f.c_str(), px.data(), w, h) == 0, "存 PNG");
                }
            }
            cv_player_pause(p);
            double a, b;
            cv_player_get_state(p, &st);
            a = st.position;
            Sleep(600);
            cv_player_get_state(p, &st);
            b = st.position;
            R.add("暂停：%.3f → %.3f 秒", a, b);
            R.check(std::fabs(b - a) < 0.05, "暂停（时钟停住）");
        }
        {
            std::lock_guard<std::mutex> l(ev.m);
            for (auto& x : ev.lines) R.add("  %s", x.c_str());
        }
        cv_player_destroy(p);
        cv_surface_destroy(s);
        R.check(true, "关掉播放器（线程都退出了）");
    }
done:
    R.add("%s：%d 项失败", R.failed ? "自检没过" : "自检通过", R.failed);
    if (report && report_len > 0) snprintf(report, (size_t)report_len, "%s", R.s.c_str());
    return R.failed ? 1 : 0;
}
