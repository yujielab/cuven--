/*
 * tx.c — Safari 解不了的音轨（DTS / TrueHD / MLP / Opus / Vorbis / MP2 / MP3 / PCM）
 *        → AC-3，供 Cloudflare Worker（WASM）实时转码 HLS 音频分段。
 *
 * 只暴露最少的接口：解码进 PCM 队列（统一 48k/44.1k/32k、平面 float、5.1/立体声/单声道），
 * 按时间轴对齐（跳过 / 补零），再按 1536 采样一帧编码 AC-3。
 * 分段之间的无缝衔接由调用方保证：每段多解几帧做预热、AC-3 帧落在全局网格上。
 */
#include <stdlib.h>
#include <string.h>
#include "libavcodec/avcodec.h"
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libavutil/log.h"
#include "libswresample/swresample.h"

#define EXPORT __attribute__((used, visibility("default")))

typedef struct TX {
    AVCodecContext *dec, *enc;
    SwrContext *swr;
    AVPacket *pkt, *opkt;
    AVFrame *frm, *efrm;
    AVChannelLayout out_layout, in_layout;
    int out_rate, out_ch, in_rate, in_fmt;
    float *pcm[6];
    int pcm_len, pcm_cap;
    uint8_t *out;
    int out_len, out_cap;
    int *sizes;
    int nframes, sizes_cap;
    uint8_t *inbuf;
    int inbuf_cap;
    int errors;
} TX;

EXPORT void *tx_alloc(int n) { return malloc(n); }
EXPORT void tx_dealloc(void *p) { free(p); }

static int pcm_reserve(TX *t, int n) {
    if (n <= t->pcm_cap) return 0;
    int cap = t->pcm_cap ? t->pcm_cap : 16384;
    while (cap < n) cap *= 2;
    for (int c = 0; c < t->out_ch; c++) {
        float *p = realloc(t->pcm[c], (size_t)cap * sizeof(float));
        if (!p) return -1;
        t->pcm[c] = p;
    }
    t->pcm_cap = cap;
    return 0;
}

static int out_push(TX *t, const uint8_t *d, int n) {
    if (t->out_len + n > t->out_cap) {
        int cap = t->out_cap ? t->out_cap : 65536;
        while (cap < t->out_len + n) cap *= 2;
        uint8_t *p = realloc(t->out, cap);
        if (!p) return -1;
        t->out = p; t->out_cap = cap;
    }
    if (t->nframes + 1 > t->sizes_cap) {
        int cap = t->sizes_cap ? t->sizes_cap * 2 : 256;
        int *p = realloc(t->sizes, cap * sizeof(int));
        if (!p) return -1;
        t->sizes = p; t->sizes_cap = cap;
    }
    memcpy(t->out + t->out_len, d, n);
    t->out_len += n;
    t->sizes[t->nframes++] = n;
    return 0;
}

static const AVCodec *pick_decoder(int kind) {
    switch (kind) {
        case 1: return avcodec_find_decoder(AV_CODEC_ID_DTS);
        case 2: return avcodec_find_decoder(AV_CODEC_ID_TRUEHD);
        case 3: return avcodec_find_decoder(AV_CODEC_ID_MLP);
        case 4: return avcodec_find_decoder(AV_CODEC_ID_OPUS);
        case 5: return avcodec_find_decoder(AV_CODEC_ID_VORBIS);
        case 6: return avcodec_find_decoder(AV_CODEC_ID_PCM_S16LE);
        case 7: return avcodec_find_decoder(AV_CODEC_ID_PCM_S24LE);
        case 8: return avcodec_find_decoder(AV_CODEC_ID_PCM_S32LE);
        case 9: return avcodec_find_decoder(AV_CODEC_ID_PCM_F32LE);
        case 10: return avcodec_find_decoder(AV_CODEC_ID_PCM_S16BE);
        case 11: return avcodec_find_decoder(AV_CODEC_ID_PCM_S24BE);
        case 12: return avcodec_find_decoder(AV_CODEC_ID_MP2);
        case 13: return avcodec_find_decoder(AV_CODEC_ID_MP3);
        case 14: return avcodec_find_decoder(AV_CODEC_ID_PCM_U8);
        default: return NULL;
    }
}

EXPORT void tx_close(TX *t) {
    if (!t) return;
    avcodec_free_context(&t->dec);
    avcodec_free_context(&t->enc);
    swr_free(&t->swr);
    av_packet_free(&t->pkt);
    av_packet_free(&t->opkt);
    av_frame_free(&t->frm);
    av_frame_free(&t->efrm);
    for (int c = 0; c < 6; c++) free(t->pcm[c]);
    free(t->out); free(t->sizes); free(t->inbuf);
    av_channel_layout_uninit(&t->in_layout);
    free(t);
}

/*
 * kind     见 pick_decoder
 * rate/ch  MKV 轨道参数；bits 只给 PCM 用
 * out_ch   6 = 5.1、2 = 立体声、1 = 单声道（AC-3 最多 5.1：7.1 由 TrueHD 子流 / DTS 核心直接给 5.1）
 */
EXPORT TX *tx_open(int kind, int rate, int ch, int bits, const uint8_t *extra, int extralen,
                   int out_ch, int bitrate) {
    av_log_set_level(AV_LOG_QUIET);
    const AVCodec *dc = pick_decoder(kind);
    const AVCodec *ec = avcodec_find_encoder(AV_CODEC_ID_AC3);
    if (!dc || !ec) return NULL;
    TX *t = calloc(1, sizeof(TX));
    if (!t) return NULL;
    t->dec = avcodec_alloc_context3(dc);
    t->dec->sample_rate = rate > 0 ? rate : 48000;
    av_channel_layout_default(&t->dec->ch_layout, ch > 0 ? ch : 2);
    if (bits) t->dec->bits_per_coded_sample = bits;
    if (extra && extralen > 0) {
        t->dec->extradata = av_mallocz(extralen + AV_INPUT_BUFFER_PADDING_SIZE);
        memcpy(t->dec->extradata, extra, extralen);
        t->dec->extradata_size = extralen;
    }
    if (kind == 1) av_opt_set_int(t->dec->priv_data, "core_only", 1, 0);
    if ((kind == 2 || kind == 3) && out_ch >= 6 && ch > 6) {
        AVChannelLayout l = AV_CHANNEL_LAYOUT_5POINT1;
        av_opt_set_chlayout(t->dec->priv_data, "downmix", &l, 0);
    }
    if (avcodec_open2(t->dec, dc, NULL) < 0) { tx_close(t); return NULL; }

    t->out_rate = (rate == 44100 || rate == 32000) ? rate : 48000;
    t->out_ch = out_ch >= 6 ? 6 : out_ch == 1 ? 1 : 2;
    if (t->out_ch == 6) t->out_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1;
    else if (t->out_ch == 2) t->out_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    else t->out_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_MONO;
    t->enc = avcodec_alloc_context3(ec);
    t->enc->sample_rate = t->out_rate;
    t->enc->sample_fmt = AV_SAMPLE_FMT_FLTP;
    av_channel_layout_copy(&t->enc->ch_layout, &t->out_layout);
    t->enc->bit_rate = bitrate;
    if (avcodec_open2(t->enc, ec, NULL) < 0) { tx_close(t); return NULL; }
    t->pkt = av_packet_alloc();
    t->opkt = av_packet_alloc();
    t->frm = av_frame_alloc();
    t->efrm = av_frame_alloc();
    t->in_fmt = -1;
    return t;
}

EXPORT int tx_out_rate(TX *t) { return t->out_rate; }
EXPORT int tx_frame_size(TX *t) { return t->enc->frame_size; }
EXPORT int tx_errors(TX *t) { return t->errors; }

/** 送一个压缩帧；解出的 PCM 追加进队列，返回追加的采样数（输出采样率下） */
EXPORT int tx_decode(TX *t, const uint8_t *data, int len) {
    if (len + AV_INPUT_BUFFER_PADDING_SIZE > t->inbuf_cap) {
        int cap = len + AV_INPUT_BUFFER_PADDING_SIZE + 4096;
        uint8_t *p = realloc(t->inbuf, cap);
        if (!p) return -1;
        t->inbuf = p; t->inbuf_cap = cap;
    }
    memcpy(t->inbuf, data, len);
    memset(t->inbuf + len, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    t->pkt->data = t->inbuf;
    t->pkt->size = len;
    int ret = avcodec_send_packet(t->dec, t->pkt);
    if (ret < 0) { t->errors++; return 0; }
    int added = 0;
    while (avcodec_receive_frame(t->dec, t->frm) >= 0) {
        AVFrame *f = t->frm;
        if (!t->swr || f->sample_rate != t->in_rate || f->format != t->in_fmt ||
            av_channel_layout_compare(&f->ch_layout, &t->in_layout)) {
            swr_free(&t->swr);
            if (swr_alloc_set_opts2(&t->swr, &t->out_layout, AV_SAMPLE_FMT_FLTP, t->out_rate,
                                    &f->ch_layout, f->format, f->sample_rate, 0, NULL) < 0 ||
                swr_init(t->swr) < 0) {
                av_frame_unref(f);
                t->errors++;
                continue;
            }
            t->in_rate = f->sample_rate;
            t->in_fmt = f->format;
            av_channel_layout_uninit(&t->in_layout);
            av_channel_layout_copy(&t->in_layout, &f->ch_layout);
        }
        int max = swr_get_out_samples(t->swr, f->nb_samples);
        if (pcm_reserve(t, t->pcm_len + max) < 0) { av_frame_unref(f); return -1; }
        uint8_t *dst[6];
        for (int c = 0; c < t->out_ch; c++) dst[c] = (uint8_t *)(t->pcm[c] + t->pcm_len);
        int n = swr_convert(t->swr, dst, max, (const uint8_t **)f->extended_data, f->nb_samples);
        if (n > 0) { t->pcm_len += n; added += n; }
        av_frame_unref(f);
    }
    return added;
}

/** 丢掉队列头部 n 个采样（对齐到 AC-3 网格） */
EXPORT int tx_skip(TX *t, int n) {
    if (n <= 0) return 0;
    if (n > t->pcm_len) n = t->pcm_len;
    for (int c = 0; c < t->out_ch; c++)
        memmove(t->pcm[c], t->pcm[c] + n, (size_t)(t->pcm_len - n) * sizeof(float));
    t->pcm_len -= n;
    return n;
}
/** 在队列头部补 n 个静音采样（可解码点晚于网格起点时） */
EXPORT int tx_pad(TX *t, int n) {
    if (n <= 0) return 0;
    if (pcm_reserve(t, t->pcm_len + n) < 0) return -1;
    for (int c = 0; c < t->out_ch; c++) {
        memmove(t->pcm[c] + n, t->pcm[c], (size_t)t->pcm_len * sizeof(float));
        memset(t->pcm[c], 0, (size_t)n * sizeof(float));
    }
    t->pcm_len += n;
    return n;
}
/** 在队尾补 n 个静音采样（源音频提前结束时凑满最后几帧） */
EXPORT int tx_tail(TX *t, int n) {
    if (n <= 0) return 0;
    if (pcm_reserve(t, t->pcm_len + n) < 0) return -1;
    for (int c = 0; c < t->out_ch; c++) memset(t->pcm[c] + t->pcm_len, 0, (size_t)n * sizeof(float));
    t->pcm_len += n;
    return n;
}
EXPORT int tx_pcm_len(TX *t) { return t->pcm_len; }

/** 编码队列里完整的帧（最多 max 帧），输出追加到 out；返回本次产出的帧数 */
EXPORT int tx_encode(TX *t, int max) {
    const int fs = t->enc->frame_size;
    int made = 0;
    while (t->pcm_len >= fs && made < max) {
        AVFrame *e = t->efrm;
        e->nb_samples = fs;
        e->format = AV_SAMPLE_FMT_FLTP;
        e->sample_rate = t->out_rate;
        av_channel_layout_copy(&e->ch_layout, &t->out_layout);
        if (av_frame_get_buffer(e, 0) < 0) return -1;
        for (int c = 0; c < t->out_ch; c++) memcpy(e->extended_data[c], t->pcm[c], (size_t)fs * sizeof(float));
        tx_skip(t, fs);
        int ret = avcodec_send_frame(t->enc, e);
        av_frame_unref(e);
        if (ret < 0) return -1;
        while (avcodec_receive_packet(t->enc, t->opkt) >= 0) {
            if (out_push(t, t->opkt->data, t->opkt->size) < 0) { av_packet_unref(t->opkt); return -1; }
            av_packet_unref(t->opkt);
            made++;
        }
    }
    return made;
}

EXPORT uint8_t *tx_out(TX *t) { return t->out; }
EXPORT int tx_out_len(TX *t) { return t->out_len; }
EXPORT int *tx_sizes(TX *t) { return t->sizes; }
EXPORT int tx_nframes(TX *t) { return t->nframes; }
EXPORT void tx_out_reset(TX *t) { t->out_len = 0; t->nframes = 0; }
