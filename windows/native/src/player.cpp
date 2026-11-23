// 播放器：打开 → 解封装 → 视频 / 音频解码 → 同步上屏。线程：
//   demux（打开、读包、内封字幕当场解）· vdec（D3D11VA 硬解 / 软解 → 纹理环）· adec（解码 + 重采样 → 出声队列）
//   render（按主时钟挑帧、上屏、字幕）· 出声线程（AudioOut 里）· 网络线程（HttpSource 里）
#include "audio_out.h"
#include "source.h"
#include "subs.h"
#include "surface.h"
#include "video_render.h"

#include <avrt.h>
#include <climits>

using namespace cv;

namespace {

struct Packet {
    AVPacket* pkt = nullptr;     // nullptr = 文件尾（让解码器吐干净）
    int serial = 0;
    double dur = 0;
};

struct PacketQueue {
    std::mutex m;
    std::condition_variable cv;
    std::deque<Packet> q;
    int64_t bytes = 0;
    double dur = 0;
    double last_pts = NAN;
    bool abort = false;

    void put(AVPacket* p, int serial, double d, double pts) {
        std::lock_guard<std::mutex> l(m);
        q.push_back({p, serial, d});
        if (p) bytes += p->size;
        dur += d;
        if (std::isfinite(pts)) last_pts = pts;
        cv.notify_all();
    }
    // 阻塞取（最多 ms 毫秒）；false = 没有 / 中止
    bool get(Packet& out, int ms) {
        std::unique_lock<std::mutex> l(m);
        if (!cv.wait_for(l, std::chrono::milliseconds(ms), [&] { return abort || !q.empty(); })) return false;
        if (abort || q.empty()) return false;
        out = q.front();
        q.pop_front();
        if (out.pkt) bytes -= out.pkt->size;
        dur -= out.dur;
        if (q.empty()) dur = 0;
        return true;
    }
    void flush() {
        std::lock_guard<std::mutex> l(m);
        for (auto& p : q) if (p.pkt) av_packet_free(&p.pkt);
        q.clear();
        bytes = 0;
        dur = 0;
        last_pts = NAN;
        cv.notify_all();
    }
    void stop() {
        std::lock_guard<std::mutex> l(m);
        abort = true;
        cv.notify_all();
    }
    size_t size() { std::lock_guard<std::mutex> l(m); return q.size(); }
};

struct TrackInfo {
    cv_track t;
};

double q2d(AVRational r) { return r.den ? (double)r.num / r.den : 0; }

bool lang_is_zh(const char* l) {
    if (!l) return false;
    return !_stricmp(l, "chi") || !_stricmp(l, "zho") || !_stricmp(l, "chn") || !_stricmp(l, "zh") || !_stricmp(l, "cmn") ||
           !_stricmp(l, "yue") || !_strnicmp(l, "zh-", 3);
}

bool lang_match(const char* stream_lang, const char* want) {
    if (!want || !*want || !stream_lang) return false;
    if (!_stricmp(want, "zh")) return lang_is_zh(stream_lang);
    return !_strnicmp(stream_lang, want, strlen(want));
}

}  // namespace

struct cv_player {
    cv_surface* surface = nullptr;
    cv_event_cb cb = nullptr;
    void* user = nullptr;

    // ── 线程 ──
    std::thread demux_th, vdec_th, adec_th, render_th;
    std::atomic<bool> quit{false};
    std::atomic<int> interrupt{0};

    // ── 打开的东西 ──
    std::string url;
    double start_at = 0;
    int open_flags = 0;
    std::string want_audio, want_sub;
    std::mutex src_m;                   // src 的创建 / 中止
    std::unique_ptr<Source> src;
    AVIOContext* pb = nullptr;
    AVFormatContext* fmt = nullptr;
    int vstream = -1, astream = -1, sstream = -1;
    AVCodecContext* vdec = nullptr;
    AVCodecContext* adec = nullptr;
    AVCodecContext* sdec = nullptr;
    std::mutex codec_m;                 // 换音轨 / 字幕时保护 adec / sdec
    AVBufferRef* hwdev = nullptr;
    std::atomic<bool> hw{false};
    int dovi_profile = 0;
    int hdr_kind = CV_HDR_SDR;
    float stream_peak = 1000;
    bool bitmap_subs = false;
    double fps = 0;

    PacketQueue vq, aq;
    std::atomic<int> serial{1};
    std::atomic<bool> demux_eof{false}, video_eof{false}, audio_eof{false};

    // ── 跳转 / 换轨（demux 线程处理） ──
    std::mutex req_m;
    bool seek_req = false;
    double seek_pos = 0;
    bool seek_exact = true;
    int req_audio = INT_MIN, req_sub = INT_MIN;
    std::atomic<double> seek_target{-1};     // 解码线程丢掉这之前的帧
    std::atomic<bool> seeking{false};

    // ── 解好的视频帧 ──
    std::mutex fm;
    std::condition_variable fcv;
    std::deque<VideoFrame> frames;
    bool slot_busy[VideoRenderer::kSlots] = {};
    VideoFrame cur;                          // 屏上这一帧
    VideoRenderer vr;
    SubLayer subs;
    Waiter waiter;

    // ── 时钟 ──
    AudioOut audio;
    std::atomic<bool> paused{false}, buffering{true}, ended{false}, opened{false};
    std::atomic<bool> started{false};       // 跳转 / 打开后已经开始走
    double sys_base_pts = 0, sys_base_t = 0;
    bool sys_running = false;
    std::atomic<double> last_clock{0};
    double duration = 0;
    std::atomic<int> dropped{0};

    // ── 输出 ──
    std::mutex out_m;
    OutputConfig out;
    cv_display display{};
    int hdr_mode = 0;
    bool display_known = false;
    std::atomic<bool> redraw{true};

    std::mutex tracks_m;
    std::vector<cv_track> tracks;
    std::string ext_label;
    bool has_ext = false;

    char vcodec_name[32] = {}, acodec_name[32] = {};

    void emit(int ev, int arg = 0, const char* text = nullptr) { if (cb) cb(user, ev, arg, text); }

    // ── 时钟 ──
    double clock() {
        if (astream >= 0) {
            double c = audio.clock();
            if (std::isfinite(c)) return c;
            return NAN;
        }
        if (!sys_running) return sys_base_pts;
        return sys_base_pts + (now() - sys_base_t);
    }
    void sys_start(double pts) { sys_base_pts = pts; sys_base_t = now(); sys_running = true; }
    void sys_stop() { if (sys_running) { sys_base_pts = sys_base_pts + (now() - sys_base_t); sys_running = false; } }

    // ── 打开 ──
    bool open_input();
    bool open_video_decoder(bool allow_hw);
    bool open_audio_decoder(int stream);
    bool open_sub_decoder(int stream);
    void build_tracks();
    void close_all();

    // ── 线程 ──
    void demux_loop();
    void vdec_loop();
    void adec_loop();
    void render_loop();
    void handle_frame(AVFrame* f, int ser);
    void do_seek(double pos, bool exact);
    void apply_output();
};

// FFmpeg 的 D3D11VA 和我们共用立即上下文：用同一把锁
static void d3d_lock(void*) { gpu().lock.lock(); }
static void d3d_unlock(void*) { gpu().lock.unlock(); }

static enum AVPixelFormat pick_hw_format(AVCodecContext* ctx, const enum AVPixelFormat* fmts) {
    for (const enum AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_D3D11) return *p;
    // 显卡不支持这一路（比如老显卡上的 AV1）：用软解的第一个格式
    for (const enum AVPixelFormat* p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor* d = av_pix_fmt_desc_get(*p);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    (void)ctx;
    return AV_PIX_FMT_NONE;
}

static int interrupt_cb(void* opaque) {
    auto p = (cv_player*)opaque;
    return p->quit ? 1 : 0;
}

bool cv_player::open_input() {
    {
        std::lock_guard<std::mutex> l(src_m);
        if (quit) return false;
        src = make_source(url.c_str());
        if (!src) return false;
        src->set_interrupt(&interrupt);
    }
    if (!src->connect()) return false;
    pb = make_avio(src.get());
    fmt = avformat_alloc_context();
    if (!pb || !fmt) return false;
    fmt->pb = pb;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO | AVFMT_FLAG_GENPTS;
    fmt->interrupt_callback.callback = interrupt_cb;
    fmt->interrupt_callback.opaque = this;
    fmt->probesize = 8 << 20;
    fmt->max_analyze_duration = 3 * AV_TIME_BASE;
    double t0 = now();
    int r = avformat_open_input(&fmt, "", nullptr, nullptr);
    if (r < 0) { log("avformat_open_input 失败 %d", r); fmt = nullptr; return false; }
    r = avformat_find_stream_info(fmt, nullptr);
    if (r < 0) log("find_stream_info：%d（接着试）", r);
    duration = fmt->duration > 0 ? fmt->duration / (double)AV_TIME_BASE : 0;
    log("解封装：%s，%.0f 毫秒（读了 %lld KB）", fmt->iformat ? fmt->iformat->name : "?", (now() - t0) * 1000, (long long)(avio_tell(pb) >> 10));

    vstream = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    // 封面图（attached_pic）不当视频
    if (vstream >= 0 && (fmt->streams[vstream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) vstream = -1;
    // 音轨：先按首选语种，再看「默认」标记，最后交给 FFmpeg 挑
    int best_a = -1;
    if (!want_audio.empty())
        for (unsigned i = 0; i < fmt->nb_streams && best_a < 0; i++) {
            AVStream* st = fmt->streams[i];
            if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
            AVDictionaryEntry* e = av_dict_get(st->metadata, "language", nullptr, 0);
            if (e && lang_match(e->value, want_audio.c_str())) best_a = (int)i;
        }
    if (best_a < 0)
        for (unsigned i = 0; i < fmt->nb_streams && best_a < 0; i++) {
            AVStream* st = fmt->streams[i];
            if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && (st->disposition & AV_DISPOSITION_DEFAULT)) best_a = (int)i;
        }
    if (best_a < 0) best_a = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, vstream, nullptr, 0);
    // 字幕：要了语种才开（默认不开）
    int best_s = -1;
    if (!want_sub.empty())
        for (unsigned i = 0; i < fmt->nb_streams && best_s < 0; i++) {
            AVStream* st = fmt->streams[i];
            if (st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
            AVDictionaryEntry* e = av_dict_get(st->metadata, "language", nullptr, 0);
            if (e && lang_match(e->value, want_sub.c_str())) best_s = (int)i;
        }

    for (unsigned i = 0; i < fmt->nb_streams; i++) fmt->streams[i]->discard = AVDISCARD_ALL;
    if (vstream >= 0) {
        AVStream* st = fmt->streams[vstream];
        st->discard = AVDISCARD_DEFAULT;
        AVCodecParameters* par = st->codecpar;
        snprintf(vcodec_name, sizeof vcodec_name, "%s", avcodec_get_name(par->codec_id));
        fps = q2d(st->avg_frame_rate);
        if (fps <= 0) fps = q2d(st->r_frame_rate);
        const AVPacketSideData* sd = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
        if (sd && sd->data) dovi_profile = ((const AVDOVIDecoderConfigurationRecord*)sd->data)->dv_profile;
        const AVPacketSideData* md = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
        if (md && md->data) {
            auto m = (const AVMasteringDisplayMetadata*)md->data;
            if (m->has_luminance && q2d(m->max_luminance) > 100) stream_peak = (float)q2d(m->max_luminance);
        }
        const AVPacketSideData* cl = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
        if (cl && cl->data) {
            auto c = (const AVContentLightMetadata*)cl->data;
            if (c->MaxCLL > 100 && c->MaxCLL < stream_peak) stream_peak = (float)c->MaxCLL;
        }
        if (dovi_profile == 5) hdr_kind = CV_HDR_DOVI;
        else if (par->color_trc == AVCOL_TRC_SMPTE2084) hdr_kind = dovi_profile ? CV_HDR_DOVI : CV_HDR_PQ;
        else if (par->color_trc == AVCOL_TRC_ARIB_STD_B67) hdr_kind = CV_HDR_HLG;
        if (!open_video_decoder(!(open_flags & CV_OPEN_NO_HW))) { log("视频解码器打不开"); vstream = -1; }
    }
    if (best_a >= 0 && open_audio_decoder(best_a)) astream = best_a;
    if (best_s >= 0 && open_sub_decoder(best_s)) { sstream = best_s; subs.select(SubLayer::Embedded); }
    if (vstream < 0 && astream < 0) return false;
    build_tracks();
    return true;
}

bool cv_player::open_video_decoder(bool allow_hw) {
    AVStream* st = fmt->streams[vstream];
    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return false;
    AVCodecContext* c = avcodec_alloc_context3(dec);
    if (!c) return false;
    avcodec_parameters_to_context(c, st->codecpar);
    c->pkt_timebase = st->time_base;
    bool use_hw = false;
    if (allow_hw && gpu().video) {
        for (int i = 0;; i++) {
            const AVCodecHWConfig* hc = avcodec_get_hw_config(dec, i);
            if (!hc) break;
            if (hc->device_type == AV_HWDEVICE_TYPE_D3D11VA && (hc->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) { use_hw = true; break; }
        }
    }
    if (use_hw && !hwdev) {
        hwdev = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA);
        if (hwdev) {
            auto hd = (AVHWDeviceContext*)hwdev->data;
            auto d3d = (AVD3D11VADeviceContext*)hd->hwctx;
            d3d->device = gpu().dev.Get();
            d3d->device->AddRef();
            d3d->lock = d3d_lock;
            d3d->unlock = d3d_unlock;
            d3d->lock_ctx = nullptr;
            if (av_hwdevice_ctx_init(hwdev) < 0) { log("D3D11VA 初始化失败：软解"); av_buffer_unref(&hwdev); }
        }
    }
    if (use_hw && hwdev) {
        c->hw_device_ctx = av_buffer_ref(hwdev);
        c->get_format = pick_hw_format;
        c->extra_hw_frames = 6;
        c->thread_count = 1;
    } else {
        use_hw = false;
        c->thread_count = 0;     // 软解：按核数开线程
        c->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    }
    AVDictionary* opts = nullptr;
    if (avcodec_open2(c, dec, &opts) < 0) {
        av_dict_free(&opts);
        avcodec_free_context(&c);
        if (use_hw) return open_video_decoder(false);
        return false;
    }
    av_dict_free(&opts);
    if (vdec) avcodec_free_context(&vdec);
    vdec = c;
    hw = use_hw;
    log("视频：%s %dx%d，%s，杜比视界 %d", vcodec_name, st->codecpar->width, st->codecpar->height, use_hw ? "D3D11VA 硬解" : "软解", dovi_profile);
    return true;
}

bool cv_player::open_audio_decoder(int stream) {
    AVStream* st = fmt->streams[stream];
    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return false;
    AVCodecContext* c = avcodec_alloc_context3(dec);
    if (!c) return false;
    avcodec_parameters_to_context(c, st->codecpar);
    c->pkt_timebase = st->time_base;
    c->thread_count = 1;
    if (avcodec_open2(c, dec, nullptr) < 0) { avcodec_free_context(&c); return false; }
    std::lock_guard<std::mutex> l(codec_m);
    if (adec) avcodec_free_context(&adec);
    adec = c;
    st->discard = AVDISCARD_DEFAULT;
    snprintf(acodec_name, sizeof acodec_name, "%s", avcodec_get_name(st->codecpar->codec_id));
    return true;
}

bool cv_player::open_sub_decoder(int stream) {
    AVStream* st = fmt->streams[stream];
    const AVCodec* dec = avcodec_find_decoder(st->codecpar->codec_id);
    if (!dec) return false;
    AVCodecContext* c = avcodec_alloc_context3(dec);
    if (!c) return false;
    avcodec_parameters_to_context(c, st->codecpar);
    c->pkt_timebase = st->time_base;
    if (avcodec_open2(c, dec, nullptr) < 0) { avcodec_free_context(&c); return false; }
    std::lock_guard<std::mutex> l(codec_m);
    if (sdec) avcodec_free_context(&sdec);
    sdec = c;
    st->discard = AVDISCARD_DEFAULT;
    const AVCodecDescriptor* d = avcodec_descriptor_get(st->codecpar->codec_id);
    bitmap_subs = d && (d->props & AV_CODEC_PROP_BITMAP_SUB);
    return true;
}

void cv_player::build_tracks() {
    std::lock_guard<std::mutex> l(tracks_m);
    tracks.clear();
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream* st = fmt->streams[i];
        auto type = st->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_AUDIO && type != AVMEDIA_TYPE_SUBTITLE) continue;
        if (!avcodec_find_decoder(st->codecpar->codec_id)) continue;
        cv_track t{};
        t.id = (int)i;
        t.type = type == AVMEDIA_TYPE_AUDIO ? CV_TRACK_AUDIO : CV_TRACK_SUB;
        t.selected = (int)i == astream || (int)i == sstream;
        t.is_default = (st->disposition & AV_DISPOSITION_DEFAULT) != 0;
        t.channels = st->codecpar->ch_layout.nb_channels;
        const AVCodecDescriptor* d = avcodec_descriptor_get(st->codecpar->codec_id);
        t.is_bitmap = d && (d->props & AV_CODEC_PROP_BITMAP_SUB);
        AVDictionaryEntry* e = av_dict_get(st->metadata, "language", nullptr, 0);
        if (e) snprintf(t.lang, sizeof t.lang, "%s", e->value);
        e = av_dict_get(st->metadata, "title", nullptr, 0);
        if (e) snprintf(t.title, sizeof t.title, "%s", e->value);
        snprintf(t.codec, sizeof t.codec, "%s", d ? d->name : "?");
        tracks.push_back(t);
    }
    if (has_ext) {
        cv_track t{};
        t.id = -2;
        t.type = CV_TRACK_SUB;
        t.selected = subs.source() == SubLayer::External;
        snprintf(t.title, sizeof t.title, "%s", ext_label.c_str());
        snprintf(t.codec, sizeof t.codec, "webvtt");
        tracks.push_back(t);
    }
}

void cv_player::do_seek(double pos, bool exact) {
    if (!fmt) return;
    if (duration > 0) pos = std::clamp(pos, 0.0, std::max(0.0, duration - 0.5));
    if (pos < 0) pos = 0;
    int64_t ts = (int64_t)(pos * AV_TIME_BASE);
    if (fmt->start_time != AV_NOPTS_VALUE) ts += fmt->start_time;
    int r = avformat_seek_file(fmt, -1, INT64_MIN, ts, ts, 0);
    if (r < 0) r = avformat_seek_file(fmt, -1, INT64_MIN, ts, INT64_MAX, 0);
    if (r < 0) log("跳转失败 %d", r);
    int s = ++serial;
    audio.pause();
    vq.flush();
    aq.flush();
    subs.clear_embedded(s);
    audio.flush(s);
    {
        std::lock_guard<std::mutex> l(codec_m);
        if (sdec) avcodec_flush_buffers(sdec);
    }
    seek_target = exact ? pos : -1;
    demux_eof = false;
    video_eof = vstream < 0;
    audio_eof = astream < 0;
    started = false;
    ended = false;
    sys_base_pts = pos;
    sys_running = false;
    last_clock = pos;
    {
        std::lock_guard<std::mutex> l(fm);
        fcv.notify_all();
    }
    waiter.wake();
}

void cv_player::demux_loop() {
    name_thread(L"Cuven demux");
    thread_qos(CV_QOS_HIGH);
    if (!open_input()) {
        std::string e = src ? src->error() : std::string();
        emit(CV_EV_ERROR, 0, e.empty() ? "这个片子打不开" : e.c_str());
        return;
    }
    audio.flush(serial);
    subs.clear_embedded(serial);
    opened = true;
    char info[160];
    snprintf(info, sizeof info, "%s%s / %s", vcodec_name, hw ? "（硬解）" : "", acodec_name);
    emit(CV_EV_OPENED, 0, info);
    emit(CV_EV_TRACKS);
    emit(CV_EV_VIDEO, hdr_kind);
    video_eof = vstream < 0;
    audio_eof = astream < 0;
    vdec_th = std::thread([this] { vdec_loop(); });
    adec_th = std::thread([this] { adec_loop(); });
    render_th = std::thread([this] { render_loop(); });
    if (start_at > 1) do_seek(start_at, true);
    else seek_target = -1;

    AVPacket* pkt = av_packet_alloc();
    bool eof_sent = false;
    int errors = 0;
    while (!quit) {
        // 跳转 / 换轨
        bool sk = false, ex = true;
        double pos = 0;
        int ra = INT_MIN, rs = INT_MIN;
        {
            std::lock_guard<std::mutex> l(req_m);
            if (seek_req) { sk = true; pos = seek_pos; ex = seek_exact; seek_req = false; }
            ra = req_audio; rs = req_sub;
            req_audio = req_sub = INT_MIN;
            interrupt = 0;
        }
        if (ra != INT_MIN || rs != INT_MIN) {
            if (ra != INT_MIN && ra >= 0 && ra != astream && (unsigned)ra < fmt->nb_streams) {
                if (astream >= 0) fmt->streams[astream]->discard = AVDISCARD_ALL;
                if (open_audio_decoder(ra)) astream = ra;
            }
            if (rs != INT_MIN) {
                if (sstream >= 0) fmt->streams[sstream]->discard = AVDISCARD_ALL;
                if (rs >= 0 && (unsigned)rs < fmt->nb_streams && open_sub_decoder(rs)) { sstream = rs; subs.select(SubLayer::Embedded); }
                else { sstream = -1; subs.select(rs == -2 ? SubLayer::External : SubLayer::None); }
            }
            build_tracks();
            emit(CV_EV_TRACKS);
            // 新的轨要从当前位置开始有包：原地跳一下
            if (!sk) { sk = true; pos = last_clock; ex = true; }
        }
        if (sk) {
            seeking = true;
            do_seek(pos, ex);
            eof_sent = false;
            errors = 0;
            emit(CV_EV_STATE);
        }
        // 队列够了就歇一会儿（视频 / 音频各 12 秒，或一共 160 MB）
        bool full;
        {
            std::lock_guard<std::mutex> l1(vq.m);
            std::lock_guard<std::mutex> l2(aq.m);
            double vd = vq.q.empty() || !std::isfinite(vq.last_pts) ? 0 : vq.dur;
            double ad = aq.dur;
            full = vq.bytes + aq.bytes > (160ll << 20) || ((vstream < 0 || vd > 12) && (astream < 0 || ad > 12)) || vq.q.size() > 3000;
        }
        if (full || demux_eof) {
            std::this_thread::sleep_for(std::chrono::milliseconds(15));
            continue;
        }
        int r = av_read_frame(fmt, pkt);
        if (r < 0) {
            if (quit) break;
            bool want_seek;
            {
                std::lock_guard<std::mutex> l(req_m);
                want_seek = seek_req || req_audio != INT_MIN || req_sub != INT_MIN;
            }
            if (want_seek) continue;
            if (r == AVERROR_EOF || avio_feof(pb)) {
                demux_eof = true;
                if (!eof_sent) {
                    int s = serial;
                    if (vstream >= 0) vq.put(nullptr, s, 0, NAN);
                    if (astream >= 0) aq.put(nullptr, s, 0, NAN);
                    eof_sent = true;
                }
                continue;
            }
            if (++errors > 50) {
                emit(CV_EV_ERROR, 0, src && !src->error().empty() ? src->error().c_str() : "网络中断，播放停止");
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }
        errors = 0;
        int s = serial;
        AVStream* st = fmt->streams[pkt->stream_index];
        double tb = q2d(st->time_base);
        double pts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts * tb : pkt->dts != AV_NOPTS_VALUE ? pkt->dts * tb : NAN;
        if (fmt->start_time != AV_NOPTS_VALUE && std::isfinite(pts)) pts -= fmt->start_time / (double)AV_TIME_BASE;
        double dur = pkt->duration > 0 ? pkt->duration * tb : 0;
        if (pkt->stream_index == vstream) {
            if (dur <= 0 && fps > 0) dur = 1.0 / fps;
            vq.put(av_packet_clone(pkt), s, dur, pts);
        } else if (pkt->stream_index == astream) {
            aq.put(av_packet_clone(pkt), s, dur, pts);
        } else if (pkt->stream_index == sstream) {
            std::lock_guard<std::mutex> l(codec_m);
            if (sdec) {
                AVSubtitle sub{};
                int got = 0;
                if (avcodec_decode_subtitle2(sdec, &sub, &got, pkt) >= 0 && got) {
                    subs.add(sub, std::isfinite(pts) ? pts : 0, dur, sdec->width, sdec->height, bitmap_subs, s);
                    avsubtitle_free(&sub);
                }
            }
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
}

void cv_player::handle_frame(AVFrame* f, int ser) {
    AVStream* st = fmt->streams[vstream];
    double tb = q2d(st->time_base);
    int64_t ts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
    double pts = ts != AV_NOPTS_VALUE ? ts * tb : NAN;
    if (fmt->start_time != AV_NOPTS_VALUE && std::isfinite(pts)) pts -= fmt->start_time / (double)AV_TIME_BASE;
    double dur = f->duration > 0 ? f->duration * tb : (fps > 0 ? 1.0 / fps : 0.04);
    if (!std::isfinite(pts)) pts = last_clock;
    double target = seek_target;
    if (target >= 0 && pts + dur < target - 0.001) return;   // 精确跳转：目标之前的帧不要

    // 等一个空纹理（排着的最多 5 帧）
    int slot = -1;
    {
        std::unique_lock<std::mutex> l(fm);
        fcv.wait(l, [&] {
            if (quit || ser != serial) return true;
            if (frames.size() >= 5) return false;
            for (int i = 0; i < VideoRenderer::kSlots; i++)
                if (!slot_busy[i]) return true;
            return false;
        });
        if (quit || ser != serial) return;
        for (int i = 0; i < VideoRenderer::kSlots; i++)
            if (!slot_busy[i]) { slot = i; break; }
        slot_busy[slot] = true;
    }
    if (!vr.upload(f, slot)) {
        std::lock_guard<std::mutex> l(fm);
        slot_busy[slot] = false;
        return;
    }
    VideoFrame vf;
    vf.slot = slot;
    vf.pts = pts;
    vf.dur = dur;
    vf.serial = ser;
    vf.w = f->width;
    vf.h = f->height;
    vf.crop_l = (int)f->crop_left;
    vf.crop_t = (int)f->crop_top;
    if (f->format == AV_PIX_FMT_D3D11) {
        D3D11_TEXTURE2D_DESC d;
        ((ID3D11Texture2D*)f->data[0])->GetDesc(&d);
        vf.tex_w = (int)d.Width;
        vf.tex_h = (int)d.Height;
    } else {
        vf.tex_w = f->width;
        vf.tex_h = f->height;
        vf.crop_l = vf.crop_t = 0;
    }
    vf.sar = f->sample_aspect_ratio.num > 0 ? q2d(f->sample_aspect_ratio) : 1;
    ColorInfo& c = vf.color;
    c.matrix = f->colorspace;
    c.range = f->color_range;
    c.primaries = f->color_primaries;
    c.trc = f->color_trc;
    c.chroma_loc = f->chroma_location;
    AVPixelFormat swf = (AVPixelFormat)f->format;
    if (f->format == AV_PIX_FMT_D3D11 && f->hw_frames_ctx) swf = ((AVHWFramesContext*)f->hw_frames_ctx->data)->sw_format;
    const AVPixFmtDescriptor* desc = av_pix_fmt_desc_get(swf);
    c.bits = desc ? desc->comp[0].depth : 8;
    c.peak = stream_peak;
    if (const AVFrameSideData* md = av_frame_get_side_data(f, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA)) {
        auto m = (const AVMasteringDisplayMetadata*)md->data;
        if (m->has_luminance && q2d(m->max_luminance) > 100) c.peak = (float)q2d(m->max_luminance);
    }
    if (const AVFrameSideData* cl = av_frame_get_side_data(f, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL)) {
        auto l = (const AVContentLightMetadata*)cl->data;
        if (l->MaxCLL > 100 && l->MaxCLL < c.peak) c.peak = (float)l->MaxCLL;
    }
    // 杜比视界 5：底层是 IPTPQc2，不按 RPU 重塑就是绿紫的。7 / 8 的底层兼容 HDR10，按 HDR10 放
    if (dovi_profile == 5) {
        if (const AVFrameSideData* sd = av_frame_get_side_data(f, AV_FRAME_DATA_DOVI_METADATA)) {
            float peak = c.peak;
            vf.dovi = make_dovi(sd, &peak);
            if (vf.dovi) { c.dovi = true; c.peak = peak; }
        }
        if (!c.dovi) { c.trc = AVCOL_TRC_SMPTE2084; c.primaries = AVCOL_PRI_BT2020; }
    }
    {
        std::lock_guard<std::mutex> l(fm);
        if (ser != serial) { slot_busy[slot] = false; return; }
        frames.push_back(std::move(vf));
    }
    waiter.wake();
}

void cv_player::vdec_loop() {
    name_thread(L"Cuven video decode");
    thread_qos(CV_QOS_HIGH);
    if (vstream < 0) return;
    AVFrame* f = av_frame_alloc();
    int cur_serial = serial;
    int errors = 0;
    while (!quit) {
        Packet p;
        if (!vq.get(p, 100)) continue;
        if (p.serial != cur_serial) {
            avcodec_flush_buffers(vdec);
            cur_serial = p.serial;
        }
        if (p.serial != serial) { if (p.pkt) av_packet_free(&p.pkt); continue; }
        for (;;) {
            int r = avcodec_send_packet(vdec, p.pkt);
            bool again = r == AVERROR(EAGAIN);
            if (r < 0 && !again && r != AVERROR_EOF) {
                if (++errors > 20 && hw) {
                    log("硬解连续出错：改软解");
                    if (open_video_decoder(false)) errors = 0;
                }
            }
            while (!quit && p.serial == serial && avcodec_receive_frame(vdec, f) >= 0) {
                errors = 0;
                handle_frame(f, p.serial);
                av_frame_unref(f);
            }
            if (!again || quit || p.serial != serial) break;
        }
        if (!p.pkt) {
            if (p.serial == serial) video_eof = true;
            avcodec_flush_buffers(vdec);
        }
        if (p.pkt) av_packet_free(&p.pkt);
    }
    av_frame_free(&f);
}

void cv_player::adec_loop() {
    name_thread(L"Cuven audio decode");
    thread_qos(CV_QOS_HIGH);
    if (astream < 0) return;
    AVFrame* f = av_frame_alloc();
    SwrContext* swr = nullptr;
    int swr_gen = -1, swr_rate = 0, swr_fmt = -1;
    AVChannelLayout swr_layout{};
    AVCodecContext* last_dec = nullptr;
    std::vector<float> buf;
    int cur_serial = serial;
    while (!quit) {
        Packet p;
        if (!aq.get(p, 100)) continue;
        std::unique_lock<std::mutex> cl(codec_m);
        AVCodecContext* dec = adec;
        if (!dec) { cl.unlock(); if (p.pkt) av_packet_free(&p.pkt); continue; }
        if (p.serial != cur_serial || dec != last_dec) {
            avcodec_flush_buffers(dec);
            cur_serial = p.serial;
            last_dec = dec;
            swr_free(&swr);
        }
        if (p.serial != serial) { cl.unlock(); if (p.pkt) av_packet_free(&p.pkt); continue; }
        if (avcodec_send_packet(dec, p.pkt) == AVERROR(EAGAIN)) {
            // 解码器满了（少见）：这一包丢掉不会错位，pts 跟着下一帧走
        }
        for (;;) {
            if (avcodec_receive_frame(dec, f) < 0) break;
            AVStream* st = fmt->streams[astream];
            double tb = q2d(st->time_base);
            int64_t ts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
            double pts = ts != AV_NOPTS_VALUE ? ts * tb : NAN;
            if (fmt->start_time != AV_NOPTS_VALUE && std::isfinite(pts)) pts -= fmt->start_time / (double)AV_TIME_BASE;
            // 重采样到设备的格式（声道、采样率、float）；设备换了 / 来源变了就重建
            if (!swr || swr_gen != audio.format_gen || swr_rate != f->sample_rate || swr_fmt != f->format ||
                av_channel_layout_compare(&swr_layout, &f->ch_layout) != 0) {
                swr_free(&swr);
                AVChannelLayout outl{};
                av_channel_layout_from_mask(&outl, audio.channel_mask());
                if (outl.nb_channels != audio.channels()) av_channel_layout_default(&outl, audio.channels());
                if (swr_alloc_set_opts2(&swr, &outl, AV_SAMPLE_FMT_FLT, audio.rate(), &f->ch_layout, (AVSampleFormat)f->format,
                                        f->sample_rate, 0, nullptr) < 0 || swr_init(swr) < 0) {
                    swr_free(&swr);
                    av_channel_layout_uninit(&outl);
                    break;
                }
                av_channel_layout_uninit(&outl);
                swr_gen = audio.format_gen;
                swr_rate = f->sample_rate;
                swr_fmt = f->format;
                av_channel_layout_uninit(&swr_layout);
                av_channel_layout_copy(&swr_layout, &f->ch_layout);
            }
            int ch = audio.channels();
            int max_out = (int)av_rescale_rnd(swr_get_delay(swr, f->sample_rate) + f->nb_samples, audio.rate(), f->sample_rate, AV_ROUND_UP);
            buf.resize((size_t)max_out * ch);
            uint8_t* outp[1] = {(uint8_t*)buf.data()};
            int n = swr_convert(swr, outp, max_out, (const uint8_t**)f->extended_data, f->nb_samples);
            av_frame_unref(f);
            if (n <= 0) continue;
            double opts = std::isfinite(pts) ? pts : NAN;
            // 精确跳转：目标之前的采样丢掉（整帧在前面就整帧丢，跨过目标的切一截）
            double target = seek_target;
            int skip = 0;
            if (target >= 0 && std::isfinite(opts) && opts < target) {
                skip = (int)std::min<double>(n, (target - opts) * audio.rate());
                if (skip >= n) continue;
                opts += (double)skip / audio.rate();
            }
            cl.unlock();
            // 出声队列最多排 1 秒
            while (!quit && p.serial == serial && audio.queued_seconds() > 1.0) std::this_thread::sleep_for(std::chrono::milliseconds(10));
            if (quit || p.serial != serial) { cl.lock(); break; }
            audio.push(std::isfinite(opts) ? opts : audio.queued_end(), buf.data() + (size_t)skip * ch, n - skip, p.serial);
            cl.lock();
            if (adec != dec) break;
        }
        cl.unlock();
        if (!p.pkt && p.serial == serial) audio_eof = true;
        if (p.pkt) av_packet_free(&p.pkt);
    }
    swr_free(&swr);
    av_channel_layout_uninit(&swr_layout);
    av_frame_free(&f);
}

void cv_player::apply_output() {
    std::lock_guard<std::mutex> l(out_m);
    bool hdr_content = hdr_kind != CV_HDR_SDR;
    bool want = display_known && display.hdr && hdr_mode == 0 && hdr_content;
    out.hdr = want;
    out.display_peak = display_known && display.max_nits > 100 ? display.max_nits : 1000;
    out.sdr_white = display_known && display.sdr_white_nits > 0 ? display.sdr_white_nits : 203;
    out.sdr_target = 203;
    {
        std::lock_guard<std::mutex> sl(surface->m);
        surface->want_hdr = want;
    }
    redraw = true;
    waiter.wake();
}

void cv_player::render_loop() {
    name_thread(L"Cuven render");
    DWORD task = 0;
    HANDLE mm = AvSetMmThreadCharacteristicsW(L"Playback", &task);
    thread_qos(CV_QOS_HIGH);
    {
        GpuLock gl;
        if (!vr.init()) { emit(CV_EV_ERROR, 0, "显卡着色器初始化失败"); return; }
    }
    apply_output();
    bool was_buffering = true;
    int surf_gen = -1;
    double starve_since = 0;
    int cur_serial = -1;
    bool had_frame = false;
    while (!quit) {
        bool need_convert = false, need_present = redraw.exchange(false);
        if (surface->gen != surf_gen) { surf_gen = surface->gen; need_present = true; }
        int ser = serial;
        // 1) 丢掉旧的（跳转之前解出来的）
        {
            std::lock_guard<std::mutex> l(fm);
            while (!frames.empty() && frames.front().serial != ser) {
                slot_busy[frames.front().slot] = false;
                frames.pop_front();
            }
            fcv.notify_all();
        }
        bool video_ready, audio_ready;
        {
            std::lock_guard<std::mutex> l(fm);
            video_ready = vstream < 0 || !frames.empty() || video_eof;
        }
        audio_ready = astream < 0 || audio.queued_seconds() >= 0.3 || audio_eof;

        // 2) 开始走 / 缓冲
        if (!started && video_ready && audio_ready) {
            started = true;
            seeking = false;
            double first = cur.slot >= 0 && cur_serial == ser ? cur.pts : last_clock.load();
            if (!paused) { audio.play(); sys_start(first); }
            else sys_base_pts = first;
            buffering = false;
            emit(CV_EV_STATE);
        }
        if (started && !paused && !ended) {
            bool starved = (astream >= 0 && audio.starved() && !audio_eof) ||
                           (vstream >= 0 && astream < 0 && !video_eof && vq.size() == 0 && frames.empty());
            if (starved) {
                if (starve_since == 0) starve_since = now();
                if (!buffering && now() - starve_since > 0.25) {
                    buffering = true;
                    audio.pause();
                    sys_stop();
                }
            } else {
                starve_since = 0;
            }
            if (buffering && ((astream < 0 || audio.queued_seconds() >= 1.5 || audio_eof) && (vstream < 0 || frames.size() >= 3 || video_eof))) {
                buffering = false;
                audio.play();
                sys_start(clock());
            }
        }
        if (buffering != was_buffering) {
            was_buffering = buffering;
            emit(CV_EV_BUFFERING, buffering ? 1 : 0);
        }

        // 3) 挑这一刻该显示的帧
        double t = clock();
        if (std::isfinite(t)) last_clock = t;
        else t = last_clock;
        {
            std::lock_guard<std::mutex> l(fm);
            if (!frames.empty()) {
                if (cur_serial != ser || !had_frame) {
                    // 跳转 / 打开后的第一帧：马上显示（不等时钟）
                    if (cur.slot >= 0 && cur.slot != frames.front().slot) slot_busy[cur.slot] = false;
                    cur = frames.front();
                    frames.pop_front();
                    cur_serial = ser;
                    had_frame = true;
                    need_convert = true;
                } else {
                    double half = 0.008;
                    while (!frames.empty() && frames.front().pts <= t + half) {
                        VideoFrame next = frames.front();
                        frames.pop_front();
                        // 后面一帧也到点了：这一帧来不及显示（丢）
                        if (!frames.empty() && frames.front().pts <= t + half) {
                            slot_busy[next.slot] = false;
                            dropped++;
                            continue;
                        }
                        if (cur.slot >= 0 && cur.slot != next.slot) slot_busy[cur.slot] = false;
                        cur = next;
                        need_convert = true;
                        break;
                    }
                }
                fcv.notify_all();
            }
        }

        // 4) 片尾
        if (started && !ended && demux_eof && video_eof && audio_eof) {
            bool drained;
            {
                std::lock_guard<std::mutex> l(fm);
                drained = frames.empty();
            }
            if (drained && (astream < 0 || audio.queued_seconds() < 0.01)) {
                ended = true;
                audio.pause();
                sys_stop();
                emit(CV_EV_ENDED);
            }
        }

        // 5) 字幕
        float rect[4];
        int W, H;
        {
            std::lock_guard<std::mutex> l(surface->m);
            W = std::max(1, (int)std::lround(surface->want_w * surface->extra));
            H = std::max(1, (int)std::lround(surface->want_h * surface->extra));
        }
        fit_rect(W, H, cur.slot >= 0 ? cur.w : W, cur.slot >= 0 ? cur.h : H, cur.slot >= 0 ? cur.sar : 1, rect);
        if (subs.update(t, rect[0], rect[1], rect[2], rect[3])) need_present = true;
        if (need_convert) need_present = true;

        // 6) 上屏
        if (need_present) {
            surface->wait_ready(50);
            if (surface->prepare()) {
                OutputConfig oc;
                {
                    std::lock_guard<std::mutex> l(out_m);
                    oc = out;
                    oc.hdr = surface->hdr;
                }
                {
                    GpuLock gl;
                    if (need_convert && cur.slot >= 0) vr.convert(cur, oc);
                    vr.present(surface, oc, &subs);
                }
                surface->present(1);
            }
        }

        // 7) 等到下一帧该出来的时候（暂停 / 缓冲时等事件）
        double wait = 0.1;
        if (started && !paused && !buffering && !ended) {
            std::lock_guard<std::mutex> l(fm);
            if (!frames.empty()) wait = std::clamp(frames.front().pts - t - 0.004, 0.001, 0.05);
            else wait = 0.01;
        } else if (!started) {
            wait = 0.01;
        }
        waiter.wait(wait);
    }
    if (mm) AvRevertMmThreadCharacteristics(mm);
}

void cv_player::close_all() {
    quit = true;
    interrupt = 1;
    {
        std::lock_guard<std::mutex> l(src_m);
        if (src) src->abort();
    }
    vq.stop();
    aq.stop();
    {
        std::lock_guard<std::mutex> l(fm);
        fcv.notify_all();
    }
    waiter.wake();
    if (demux_th.joinable()) demux_th.join();
    if (vdec_th.joinable()) vdec_th.join();
    if (adec_th.joinable()) adec_th.join();
    if (render_th.joinable()) render_th.join();
    vq.flush();
    aq.flush();
    {
        GpuLock gl;
        if (vdec) avcodec_free_context(&vdec);
        if (adec) avcodec_free_context(&adec);
        if (sdec) avcodec_free_context(&sdec);
        if (hwdev) av_buffer_unref(&hwdev);
    }
    if (fmt) avformat_close_input(&fmt);
    free_avio(pb);
    src.reset();
}

extern "C" {

CV_API cv_player* CV_CALL cv_player_create(cv_surface* s, cv_event_cb cb, void* user) {
    if (!s) return nullptr;
    auto p = new cv_player();
    p->surface = s;
    p->cb = cb;
    p->user = user;
    {
        std::lock_guard<std::mutex> l(s->m);
        s->on_change = [p] { p->waiter.wake(); };
    }
    p->audio.open();
    return p;
}

CV_API int CV_CALL cv_player_open(cv_player* p, const char* url, double start, int flags, const char* audio_lang, const char* sub_lang) {
    if (!p || !url || p->opened || p->demux_th.joinable()) return -1;
    p->url = url;
    p->start_at = start;
    p->open_flags = flags;
    p->want_audio = audio_lang ? audio_lang : "";
    p->want_sub = sub_lang ? sub_lang : "";
    p->demux_th = std::thread([p] { p->demux_loop(); });
    return 0;
}

CV_API void CV_CALL cv_player_play(cv_player* p) {
    if (!p) return;
    if (p->ended) { cv_player_seek(p, 0, 1); p->ended = false; }
    p->paused = false;
    if (p->started && !p->buffering) {
        p->audio.play();
        p->sys_start(p->sys_base_pts);
    }
    p->emit(CV_EV_STATE);
    p->waiter.wake();
}

CV_API void CV_CALL cv_player_pause(cv_player* p) {
    if (!p) return;
    p->paused = true;
    p->audio.pause();
    p->sys_stop();
    p->emit(CV_EV_STATE);
    p->waiter.wake();
}

CV_API void CV_CALL cv_player_seek(cv_player* p, double pos, int exact) {
    if (!p) return;
    std::lock_guard<std::mutex> l(p->req_m);
    p->seek_req = true;
    p->seek_pos = pos;
    p->seek_exact = exact != 0;
    p->seeking = true;
    p->last_clock = pos;
    p->interrupt = 1;     // 卡在网络上的读马上返回
}

CV_API void CV_CALL cv_player_set_volume(cv_player* p, float v) {
    if (!p) return;
    p->audio.set_volume(std::clamp(v, 0.0f, 1.0f));
}

CV_API void CV_CALL cv_player_get_state(cv_player* p, cv_state* o) {
    if (!p || !o) return;
    memset(o, 0, sizeof *o);
    // 现算（渲染线程忙的时候 last_clock 会落后）：已经开始走、不在跳转就直接问时钟
    o->position = p->last_clock.load();
    if (p->started && !p->seeking && !p->ended) {
        double c = p->clock();
        if (std::isfinite(c) && c >= 0) o->position = c;
    }
    o->duration = p->duration;
    double b = NAN;
    {
        std::lock_guard<std::mutex> l(p->vq.m);
        if (std::isfinite(p->vq.last_pts)) b = p->vq.last_pts;
    }
    {
        std::lock_guard<std::mutex> l(p->aq.m);
        if (std::isfinite(p->aq.last_pts)) b = std::isfinite(b) ? std::max(b, p->aq.last_pts) : p->aq.last_pts;
    }
    o->buffered = p->demux_eof ? p->duration : std::isfinite(b) ? b : o->position;
    o->paused = p->paused;
    o->buffering = p->buffering && p->opened;
    o->ended = p->ended;
    o->seeking = p->seeking;
    {
        std::lock_guard<std::mutex> l(p->fm);
        o->width = p->cur.slot >= 0 ? p->cur.w : 0;
        o->height = p->cur.slot >= 0 ? p->cur.h : 0;
    }
    o->fps = p->fps;
    o->hdr_kind = p->hdr_kind;
    o->dovi_profile = p->dovi_profile;
    o->output_hdr = p->surface ? p->surface->hdr : 0;
    o->hw_decode = p->hw;
    o->dropped_frames = p->dropped;
    {
        std::lock_guard<std::mutex> l(p->src_m);
        o->net_mbps = p->src ? p->src->mbps() : 0;
    }
    snprintf(o->video_codec, sizeof o->video_codec, "%s", p->vcodec_name);
    snprintf(o->audio_codec, sizeof o->audio_codec, "%s", p->acodec_name);
}

CV_API int CV_CALL cv_player_tracks(cv_player* p, cv_track* out, int max) {
    if (!p) return 0;
    std::lock_guard<std::mutex> l(p->tracks_m);
    int n = (int)std::min<size_t>(p->tracks.size(), (size_t)std::max(0, max));
    for (int i = 0; i < n && out; i++) out[i] = p->tracks[i];
    return (int)p->tracks.size();
}

CV_API void CV_CALL cv_player_select(cv_player* p, int type, int id) {
    if (!p) return;
    if (type == CV_TRACK_SUB && (id == -1 || id == -2)) {
        // 关字幕 / 外挂：不用重新读包
        {
            std::lock_guard<std::mutex> l(p->req_m);
            p->req_sub = INT_MIN;
        }
        p->subs.select(id == -2 ? SubLayer::External : SubLayer::None);
        {
            std::lock_guard<std::mutex> l(p->tracks_m);
            for (auto& t : p->tracks) if (t.type == CV_TRACK_SUB) t.selected = (t.id == id);
        }
        p->emit(CV_EV_TRACKS);
        p->redraw = true;
        p->waiter.wake();
        return;
    }
    std::lock_guard<std::mutex> l(p->req_m);
    if (type == CV_TRACK_AUDIO) p->req_audio = id;
    else p->req_sub = id;
    p->interrupt = 1;
}

CV_API void CV_CALL cv_player_set_ext_subs(cv_player* p, const double* starts, const double* ends, const char* const* texts, int n, const char* label) {
    if (!p) return;
    std::vector<std::pair<double, double>> times;
    std::vector<std::wstring> ws;
    for (int i = 0; i < n; i++) {
        times.push_back({starts[i], ends[i]});
        ws.push_back(widen(texts[i]));
    }
    p->subs.set_external(std::move(times), std::move(ws));
    {
        std::lock_guard<std::mutex> l(p->tracks_m);
        p->has_ext = n > 0;
        p->ext_label = label && *label ? label : "在线字幕";
    }
    if (p->opened) {
        std::lock_guard<std::mutex> l(p->tracks_m);
        p->tracks.erase(std::remove_if(p->tracks.begin(), p->tracks.end(), [](const cv_track& t) { return t.id == -2; }), p->tracks.end());
        if (n > 0) {
            cv_track t{};
            t.id = -2;
            t.type = CV_TRACK_SUB;
            snprintf(t.title, sizeof t.title, "%s", p->ext_label.c_str());
            snprintf(t.codec, sizeof t.codec, "webvtt");
            p->tracks.push_back(t);
        }
    }
    p->emit(CV_EV_TRACKS);
}

CV_API void CV_CALL cv_player_set_output(cv_player* p, const cv_display* d, int hdr_mode) {
    if (!p) return;
    {
        std::lock_guard<std::mutex> l(p->out_m);
        if (d) { p->display = *d; p->display_known = true; }
        p->hdr_mode = hdr_mode;
    }
    if (p->opened) p->apply_output();
}

CV_API void CV_CALL cv_player_set_sub_style(cv_player* p, float scale, float bottom) {
    if (!p) return;
    p->subs.set_style(scale > 0 ? scale : 1.0f, bottom >= 0 ? bottom : 0.06f);
    p->redraw = true;
    p->waiter.wake();
}

CV_API void CV_CALL cv_player_destroy(cv_player* p) {
    if (!p) return;
    {
        std::lock_guard<std::mutex> l(p->surface->m);
        p->surface->on_change = nullptr;
    }
    p->close_all();
    delete p;
}

}  // extern "C"

#include "player_internal.h"

bool cv_player_readback(cv_player* p, std::vector<uint8_t>& rgba, int& w, int& h) {
    return p && p->vr.readback(rgba, w, h);
}
