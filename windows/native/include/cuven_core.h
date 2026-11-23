/*
 * CuvenCore.dll —— Cuven for Windows 的原生核心（C 接口，C# 用 P/Invoke 调）
 *
 *   · 一个共享的 D3D11 设备（硬件解码、视频渲染、配对粒子云、字幕都在它上面）
 *   · 表面：给 WinUI 的 SwapChainPanel 用的 composition 交换链（翻转模型、可等待对象、HDR 时 FP16 scRGB）
 *   · 配对粒子云：web/pair.js 那团云的 D3D11 版（同一套顶点 / 像素着色器，码纹理由 C# 算好传进来）
 *   · 播放器：自研管线 —— WinHTTP 分段读（大缓冲、断线续读）→ FFmpeg 解封装 → D3D11VA 硬解（不行就软解）
 *     → HLSL：YCbCr→RGB、PQ / HLG / 杜比视界 5 的重塑、BT.2390 色调映射、缩放、抖动 → 交换链；
 *     WASAPI 事件驱动出声（MMCSS），音频当主时钟；字幕（文字 + PGS 图形）自己画（Direct2D / DirectWrite）
 *   · Win11 能效：EcoQoS / HighQoS、MMCSS、高精度可等待计时器，暂停时不空转
 *
 * 所有字符串都是 UTF-8。回调可能在任意线程上来。
 */
#pragma once
#include <stdint.h>

#ifdef _WIN32
#  ifdef CUVEN_CORE_BUILD
#    define CV_API __declspec(dllexport)
#  else
#    define CV_API __declspec(dllimport)
#  endif
#  define CV_CALL __cdecl
#else
#  define CV_API
#  define CV_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cv_surface cv_surface;
typedef struct cv_cloud cv_cloud;
typedef struct cv_player cv_player;

/* ── 设备 ─────────────────────────────────────────────────── */
#define CV_INIT_WARP 1          /* 软件渲染（CI 自检，没有显卡的机器） */
CV_API int CV_CALL cv_init(int flags);                 /* 0 = 成功 */
CV_API const char* CV_CALL cv_version(void);
CV_API const char* CV_CALL cv_gpu_name(void);
CV_API void CV_CALL cv_set_log_dir(const char* dir_utf8);

/* ── 显示器 ───────────────────────────────────────────────── */
typedef struct cv_display {
    int hdr;                    /* 这块屏现在开着 HDR（Windows 的「使用 HDR」） */
    int bits;                   /* 每通道位数 */
    float max_nits;             /* 峰值亮度 */
    float min_nits;
    float max_full_frame_nits;
    float sdr_white_nits;       /* 「SDR 内容亮度」滑块：SDR 白在 HDR 下多亮 */
} cv_display;
CV_API int CV_CALL cv_display_query(void* hmonitor, cv_display* out);   /* 0 = 成功 */

/* ── 表面（SwapChainPanel） ───────────────────────────────── */
#define CV_SURFACE_TRANSPARENT 1    /* 预乘透明（粒子云画在页面上） */
#define CV_SURFACE_VIDEO 2          /* 视频：不透明，可切 FP16 HDR */
CV_API cv_surface* CV_CALL cv_surface_create(int width, int height, int flags);
/* 把交换链交给 SwapChainPanel（panel = 它的 IInspectable* / IUnknown*）。必须在 UI 线程上调 */
CV_API int CV_CALL cv_surface_attach(cv_surface* s, void* panel_unknown);
/* 面板大小（物理像素）和 CompositionScale */
CV_API void CV_CALL cv_surface_resize(cv_surface* s, int width, int height, float scale_x, float scale_y);
CV_API void CV_CALL cv_surface_destroy(cv_surface* s);

/* ── 配对粒子云 ───────────────────────────────────────────── */
/* atlas：pair-density.png 的 8 位灰度像素（1368×1140） */
CV_API cv_cloud* CV_CALL cv_cloud_create(cv_surface* s, const uint8_t* atlas, int atlas_w, int atlas_h);
/* grid：G×G 的码纹理（M / code_scale × 255，第 0 行是 y 最小的一行）；换码时码平面的转角从 0 开始 */
CV_API void CV_CALL cv_cloud_set_code(cv_cloud* c, const uint8_t* grid, int g, float code_scale, float code_spin);
CV_API void CV_CALL cv_cloud_run(cv_cloud* c, int running);
/* 自检：在离屏纹理上画第 t 秒的一帧，读回 RGBA（预乘）。0 = 成功 */
CV_API int CV_CALL cv_cloud_snapshot(cv_cloud* c, double t, double code_t, int w, int h, uint8_t* rgba);
CV_API void CV_CALL cv_cloud_destroy(cv_cloud* c);

/* ── 播放器 ───────────────────────────────────────────────── */
enum {
    CV_EV_OPENED = 1,       /* arg = 0；text = 格式说明 */
    CV_EV_STATE = 2,        /* 播放 / 暂停 / 进度大变（UI 再取 cv_state） */
    CV_EV_ENDED = 3,
    CV_EV_ERROR = 4,        /* text = 给人看的一句话 */
    CV_EV_TRACKS = 5,       /* 音轨 / 字幕表变了 */
    CV_EV_BUFFERING = 6,    /* arg = 1 开始缓冲 / 0 结束 */
    CV_EV_VIDEO = 7,        /* 视频格式定了（HDR 种类、尺寸） */
};
typedef void (CV_CALL *cv_event_cb)(void* user, int event, int arg, const char* text);

enum { CV_HDR_SDR = 0, CV_HDR_PQ = 1, CV_HDR_HLG = 2, CV_HDR_DOVI = 3 };

typedef struct cv_state {
    double position;        /* 秒 */
    double duration;
    double buffered;        /* 已经缓冲到哪（秒） */
    int paused, buffering, ended, seeking;
    int width, height;      /* 显示尺寸 */
    double fps;
    int hdr_kind;           /* CV_HDR_* */
    int dovi_profile;
    int output_hdr;         /* 交换链在 HDR（scRGB）模式 */
    int hw_decode;
    int dropped_frames;
    float volume;
    double net_mbps;        /* 网络读入速度 */
    char video_codec[32];
    char audio_codec[32];
} cv_state;

#define CV_TRACK_AUDIO 1
#define CV_TRACK_SUB 2
typedef struct cv_track {
    int id;                 /* 流号（字幕 -2 = 外挂 / 在线字幕） */
    int type;               /* CV_TRACK_* */
    int selected;
    int is_default;
    int is_bitmap;          /* 图形字幕（PGS / VobSub） */
    int channels;
    char lang[16];
    char title[128];
    char codec[32];
} cv_track;

#define CV_OPEN_NO_HW 1
CV_API cv_player* CV_CALL cv_player_create(cv_surface* s, cv_event_cb cb, void* user);
/* url：http(s) 直链或本机文件路径；start：从第几秒开始；audio_lang：首选音轨语种（"" = 片子默认的） */
CV_API int CV_CALL cv_player_open(cv_player* p, const char* url, double start, int flags, const char* audio_lang, const char* sub_lang);
CV_API void CV_CALL cv_player_play(cv_player* p);
CV_API void CV_CALL cv_player_pause(cv_player* p);
CV_API void CV_CALL cv_player_seek(cv_player* p, double pos, int exact);
CV_API void CV_CALL cv_player_set_volume(cv_player* p, float v);
CV_API void CV_CALL cv_player_get_state(cv_player* p, cv_state* out);
CV_API int CV_CALL cv_player_tracks(cv_player* p, cv_track* out, int max);
/* type = CV_TRACK_AUDIO / CV_TRACK_SUB；id = 流号，字幕 -1 = 关，-2 = 外挂 */
CV_API void CV_CALL cv_player_select(cv_player* p, int type, int id);
/* 外挂 / 在线字幕：n 条（秒、秒、UTF-8 文字）；n = 0 清掉。设完自动选上（-2） */
CV_API void CV_CALL cv_player_set_ext_subs(cv_player* p, const double* starts, const double* ends, const char* const* texts, int n, const char* label);
/* 显示器变了（窗口挪到另一块屏、开关 HDR）。hdr_mode：0 = 自动，1 = 一律 SDR */
CV_API void CV_CALL cv_player_set_output(cv_player* p, const cv_display* d, int hdr_mode);
/* 字幕：字号倍数（1 = 默认）、离底边（占画面高的比例） */
CV_API void CV_CALL cv_player_set_sub_style(cv_player* p, float scale, float bottom);
CV_API void CV_CALL cv_player_destroy(cv_player* p);

/* ── Win11 能效 ───────────────────────────────────────────── */
#define CV_QOS_DEFAULT 0
#define CV_QOS_ECO 1        /* EcoQoS：排到能效核、降频（下载、预取、图片） */
#define CV_QOS_HIGH 2       /* 明确不节流（解码、渲染） */
CV_API void CV_CALL cv_thread_qos(int mode);
/* 整个进程：1 = 后台空闲（EcoQoS），0 = 前台 */
CV_API void CV_CALL cv_process_eco(int on);

/* ── 图片（WIC） ─────────────────────────────────────────── */
/* 读成 8 位灰度（配对云的密度校正图）。out = NULL 时只回尺寸。0 = 成功 */
CV_API int CV_CALL cv_load_gray(const char* path, uint8_t* out, int max_bytes, int* w, int* h);
CV_API int CV_CALL cv_save_png(const char* path, const uint8_t* rgba, int w, int h);

/* ── 自检（CI：WARP 软件渲染，无声卡也行） ───────────────── */
/* 打开 media（本机文件），解码、渲染若干帧，结果写进 out_dir（PNG + 报告）。0 = 通过 */
CV_API int CV_CALL cv_selftest(const char* media, const char* out_dir, char* report, int report_len);

#ifdef __cplusplus
}
#endif
