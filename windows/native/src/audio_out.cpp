#include "audio_out.h"

#include <avrt.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>

namespace cv {

// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT（自己定义一份：不同 SDK 里要 initguid / ksguid.lib 才有符号）
static const GUID kSubtypeFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};

struct AudioOut::Impl {
    ComPtr<IMMDeviceEnumerator> en;
    ComPtr<IMMDevice> dev;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioRenderClient> render;
    ComPtr<IAudioClock> clock;
    UINT32 buffer_frames = 0;
    UINT64 clock_freq = 1;
    bool started = false;
};

AudioOut::AudioOut() { event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr); }

AudioOut::~AudioOut() {
    {
        std::lock_guard<std::mutex> l(m_);
        quit_ = true;
    }
    cv_.notify_all();
    SetEvent(event_);
    if (th_.joinable()) th_.join();
    CloseHandle(event_);
}

bool AudioOut::open() {
    std::mutex mm;
    std::condition_variable cc;
    int ready = 0;
    // 客户端在放音线程上建（COM 对象跟着线程走）
    th_ = std::thread([&] {
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        d_ = new Impl();
        bool ok = init_client();
        if (!ok) { null_ = true; release_client(); }
        {
            // 在锁里通知：open() 一返回 mm / cc 就没了
            std::lock_guard<std::mutex> l(mm);
            ready = ok ? 1 : 2;
            cc.notify_all();
        }
        loop();
        release_client();
        delete d_;
        d_ = nullptr;
        CoUninitialize();
    });
    std::unique_lock<std::mutex> l(mm);
    cc.wait(l, [&] { return ready != 0; });
    if (null_) log("没有可用的声音输出：用空设备（按时钟走）");
    return !null_;
}

bool AudioOut::init_client() {
    auto& D = *d_;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&D.en)))) return false;
    if (FAILED(D.en->GetDefaultAudioEndpoint(eRender, eConsole, &D.dev))) return false;
    if (FAILED(D.dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)D.client.GetAddressOf()))) return false;
    WAVEFORMATEX* mix = nullptr;
    if (FAILED(D.client->GetMixFormat(&mix)) || !mix) return false;
    int ch = mix->nChannels, rate = (int)mix->nSamplesPerSec;
    uint64_t mask = ch == 2 ? 3 : 0;
    if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE) mask = ((WAVEFORMATEXTENSIBLE*)mix)->dwChannelMask;
    CoTaskMemFree(mix);
    if (ch <= 0 || ch > 8 || rate < 8000) return false;
    if (!mask) mask = ch == 1 ? 4 : ch == 6 ? 0x60F : ch == 8 ? 0x63F : (1ull << ch) - 1;

    // 一律要 32 位浮点、设备的声道和采样率（AUTOCONVERTPCM：引擎兜底转换）
    WAVEFORMATEXTENSIBLE f{};
    f.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    f.Format.nChannels = (WORD)ch;
    f.Format.nSamplesPerSec = (DWORD)rate;
    f.Format.wBitsPerSample = 32;
    f.Format.nBlockAlign = (WORD)(4 * ch);
    f.Format.nAvgBytesPerSec = f.Format.nBlockAlign * (DWORD)rate;
    f.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    f.Samples.wValidBitsPerSample = 32;
    f.dwChannelMask = (DWORD)mask;
    f.SubFormat = kSubtypeFloat;
    REFERENCE_TIME dur = 1000000;   // 100 ms
    HRESULT hr = D.client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                      AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                      dur, 0, &f.Format, nullptr);
    if (FAILED(hr)) { log("WASAPI Initialize 失败 0x%08lx", (unsigned long)hr); return false; }
    if (FAILED(D.client->SetEventHandle(event_))) return false;
    if (FAILED(D.client->GetBufferSize(&D.buffer_frames))) return false;
    if (FAILED(D.client->GetService(IID_PPV_ARGS(&D.render)))) return false;
    if (FAILED(D.client->GetService(IID_PPV_ARGS(&D.clock)))) return false;
    D.clock->GetFrequency(&D.clock_freq);
    if (rate != rate_ || ch != channels_ || mask != mask_) {
        rate_ = rate; channels_ = ch; mask_ = mask;
        format_gen++;
    }
    log("声音输出：%d Hz，%d 声道（0x%llx），缓冲 %u 帧", rate_, channels_, (unsigned long long)mask_, D.buffer_frames);
    return true;
}

void AudioOut::release_client() {
    if (!d_) return;
    if (d_->client && d_->started) d_->client->Stop();
    d_->started = false;
    d_->render.Reset();
    d_->clock.Reset();
    d_->client.Reset();
    d_->dev.Reset();
}

void AudioOut::push(double pts, const float* data, int frames, int serial) {
    if (frames <= 0) return;
    Chunk c;
    c.pts = pts;
    c.frames = frames;
    c.pos = 0;
    c.serial = serial;
    c.data.assign(data, data + (size_t)frames * channels_);
    std::lock_guard<std::mutex> l(m_);
    if (serial != serial_) return;
    queued_ += (double)frames / rate_;
    q_.push_back(std::move(c));
    starved_ = false;
}

double AudioOut::queued_seconds() {
    std::lock_guard<std::mutex> l(m_);
    return queued_;
}

double AudioOut::queued_end() {
    std::lock_guard<std::mutex> l(m_);
    if (q_.empty()) return next_pts_;
    auto& b = q_.back();
    return b.pts + (double)b.frames / rate_;
}

void AudioOut::flush(int serial) {
    std::lock_guard<std::mutex> l(m_);
    serial_ = serial;
    q_.clear();
    queued_ = 0;
    anchors_.clear();
    written_ = 0;
    next_pts_ = NAN;
    played_ = 0;
    reset_ = true;
    SetEvent(event_);
}

void AudioOut::play() {
    std::lock_guard<std::mutex> l(m_);
    playing_ = true;
    null_t_ = now();
    SetEvent(event_);
}

void AudioOut::pause() {
    std::lock_guard<std::mutex> l(m_);
    playing_ = false;
    SetEvent(event_);
}

double AudioOut::clock() {
    std::lock_guard<std::mutex> l(m_);
    if (anchors_.empty()) return NAN;
    int64_t played = played_;
    // 两次放音事件之间按 QPC 补上（放着的时候），不超过已经写进去的
    if (playing_ && !starved_) {
        double dt = now() - played_at_;
        if (dt > 0 && dt < 0.1) played += (int64_t)(dt * rate_);
    }
    played = std::min(played, written_);
    const Anchor* a = &anchors_.front();
    for (auto& x : anchors_) if (x.frame <= played) a = &x;
    return a->pts + (double)(played - a->frame) / rate_;
}

int AudioOut::fill(int frames, float* dst) {
    int got = 0;
    float vol = volume_;
    while (got < frames && !q_.empty()) {
        auto& c = q_.front();
        double cpts = c.pts + (double)c.pos / rate_;
        // pts 不连续（差了 50 ms 以上）就加一个锚点
        if (anchors_.empty() || !std::isfinite(next_pts_) || std::fabs(cpts - next_pts_) > 0.05)
            anchors_.push_back({written_ + got, cpts});
        int k = std::min(frames - got, c.frames - c.pos);
        const float* src = c.data.data() + (size_t)c.pos * channels_;
        float* out = dst + (size_t)got * channels_;
        size_t n = (size_t)k * channels_;
        if (vol == 1.0f) memcpy(out, src, n * sizeof(float));
        else for (size_t i = 0; i < n; i++) out[i] = src[i] * vol;
        got += k;
        c.pos += k;
        next_pts_ = c.pts + (double)c.pos / rate_;
        queued_ -= (double)k / rate_;
        if (c.pos >= c.frames) q_.pop_front();
    }
    if (anchors_.size() > 16) anchors_.erase(anchors_.begin(), anchors_.end() - 8);
    if (queued_ < 0) queued_ = 0;
    return got;
}

void AudioOut::loop() {
    name_thread(L"Cuven audio");
    DWORD task = 0;
    HANDLE mm = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
    thread_qos(CV_QOS_HIGH);
    std::vector<float> tmp;
    for (;;) {
        WaitForSingleObject(event_, null_ ? 10 : 200);
        std::unique_lock<std::mutex> l(m_);
        if (quit_) break;
        if (null_) {
            // 空设备：按真实时间「放掉」排着的采样
            double t = now();
            if (reset_) { reset_ = false; written_ = 0; played_ = 0; }
            if (playing_) {
                int want = (int)((t - null_t_) * rate_);
                if (want > 0) {
                    tmp.resize((size_t)want * channels_);
                    int got = fill(want, tmp.data());
                    written_ += got;
                    played_ = written_;
                    played_at_ = t;
                    starved_ = got < want && q_.empty();
                    null_t_ += (double)want / rate_;
                }
            } else {
                null_t_ = t;
            }
            continue;
        }
        auto& D = *d_;
        if (!D.client) {
            // 设备没了：隔一会儿重建
            l.unlock();
            Sleep(500);
            bool ok = init_client();
            l.lock();
            if (ok) { reset_ = true; q_.clear(); queued_ = 0; anchors_.clear(); written_ = 0; next_pts_ = NAN; }
            continue;
        }
        HRESULT hr = S_OK;
        if (reset_) {
            if (D.started) { D.client->Stop(); D.started = false; }
            D.client->Reset();
            reset_ = false;
            written_ = 0;
            played_ = 0;
        }
        if (!playing_) {
            if (D.started) { D.client->Stop(); D.started = false; }
            // 暂停：时钟停在设备停下的那一帧
            UINT64 pos = 0, qpc = 0;
            if (D.clock && SUCCEEDED(D.clock->GetPosition(&pos, &qpc)))
                played_ = (int64_t)((double)pos / D.clock_freq * rate_);
            played_at_ = now();
            continue;
        }
        UINT32 pad = 0;
        hr = D.client->GetCurrentPadding(&pad);
        if (SUCCEEDED(hr)) {
            UINT32 avail = D.buffer_frames - pad;
            if (avail > 0 && !q_.empty()) {
                BYTE* buf = nullptr;
                hr = D.render->GetBuffer(avail, &buf);
                if (SUCCEEDED(hr)) {
                    int got = fill((int)avail, (float*)buf);
                    hr = D.render->ReleaseBuffer((UINT32)got, 0);
                    written_ += got;
                }
            }
            starved_ = q_.empty() && pad == 0;
            if (!D.started && written_ > 0) { D.client->Start(); D.started = true; }
            UINT64 pos = 0, qpc = 0;
            if (D.clock && SUCCEEDED(D.clock->GetPosition(&pos, &qpc))) {
                played_ = (int64_t)((double)pos / D.clock_freq * rate_);
                played_at_ = now();
            }
        }
        if (hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING) {
            log("声音设备变了（0x%08lx）：重建", (unsigned long)hr);
            release_client();
        }
    }
    if (mm) AvRevertMmThreadCharacteristics(mm);
}

}  // namespace cv
