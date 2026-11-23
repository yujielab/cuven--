#pragma once
#include "common.h"

namespace cv {

// 出声：WASAPI 共享模式、事件驱动、MMCSS「Pro Audio」；没有声卡（CI）就按 QPC 假装在放。
// 时钟 = 设备真正放到的那个采样（IAudioClock::GetPosition）对应的 pts —— 整个播放器的主时钟
class AudioOut {
public:
    AudioOut();
    ~AudioOut();
    bool open();                 // 在调用线程上建；失败 = 用空设备
    int rate() const { return rate_; }
    int channels() const { return channels_; }
    uint64_t channel_mask() const { return mask_; }
    bool null_device() const { return null_; }

    // 解码线程：交一段交错的 float 采样（frames × channels）
    void push(double pts, const float* data, int frames, int serial);
    double queued_seconds();
    void flush(int serial);      // 跳转：清掉排着的、设备里的
    void play();
    void pause();
    void set_volume(float v) { volume_ = v; }

    // 正在放的 pts（秒）；还没开始 = NAN
    double clock();
    // 排着的最后一个采样之后的 pts（缓冲到哪）
    double queued_end();
    bool starved() const { return starved_; }
    // 设备换了格式（拔了耳机、换了输出）：解码线程要重建重采样
    std::atomic<int> format_gen{0};

private:
    struct Chunk { double pts; int frames; int pos; int serial; std::vector<float> data; };
    struct Anchor { int64_t frame; double pts; };

    void loop();
    bool init_client();
    void release_client();
    int fill(int frames, float* dst);   // 从队列里拿，返回拿到几帧

    int rate_ = 48000, channels_ = 2;
    uint64_t mask_ = 3;
    bool null_ = false;
    std::atomic<float> volume_{1.0f};

    std::mutex m_;
    std::condition_variable cv_;
    std::deque<Chunk> q_;
    double queued_ = 0;
    int serial_ = 0;
    std::vector<Anchor> anchors_;   // 写进设备的第几帧 = 哪个 pts（pts 不连续时多一个锚点）
    int64_t written_ = 0;           // 这一轮（上次 flush 以后）写进设备的帧数
    double next_pts_ = NAN;
    bool playing_ = false, quit_ = false, reset_ = false;
    std::atomic<bool> starved_{false};

    // 时钟（由放音线程更新）
    std::atomic<int64_t> played_{0};
    std::atomic<double> played_at_{0};

    std::thread th_;
    HANDLE event_ = nullptr;
    struct Impl;
    Impl* d_ = nullptr;
    double null_t_ = 0;
};

}  // namespace cv
