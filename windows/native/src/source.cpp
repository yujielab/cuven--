// 字节源：本机文件 / WinHTTP 网络（分段读 + 环形缓冲 + 断线重连）
#include "source.h"

#include <winhttp.h>

namespace cv {

// ── 本机文件 ────────────────────────────────────────────────────
class FileSource : public Source {
public:
    explicit FileSource(std::wstring path) : path_(std::move(path)) {}
    ~FileSource() override { if (h_ != INVALID_HANDLE_VALUE) CloseHandle(h_); }
    bool connect() override {
        h_ = CreateFileW(path_.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                         FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
        if (h_ == INVALID_HANDLE_VALUE) { log("本机文件打不开（%lu）", (unsigned long)GetLastError()); return false; }
        LARGE_INTEGER s;
        size_ = GetFileSizeEx(h_, &s) ? s.QuadPart : -1;
        return true;
    }
    std::string error() const override { return h_ == INVALID_HANDLE_VALUE ? "找不到这个文件（下载的文件被删了？）" : ""; }
    int read(uint8_t* buf, int n) override {
        if (aborted_) return -1;
        DWORD got = 0;
        if (!ReadFile(h_, buf, (DWORD)n, &got, nullptr)) return -1;
        pos_ += got;
        return (int)got;
    }
    int64_t seek(int64_t pos) override {
        LARGE_INTEGER p, out;
        p.QuadPart = pos;
        if (!SetFilePointerEx(h_, p, &out, FILE_BEGIN)) return -1;
        pos_ = out.QuadPart;
        return pos_;
    }
    int64_t size() const override { return size_; }
    void abort() override { aborted_ = true; }
private:
    std::wstring path_;
    HANDLE h_ = INVALID_HANDLE_VALUE;
    int64_t size_ = -1, pos_ = 0;
    std::atomic<bool> aborted_{false};
};

// ── 网络 ────────────────────────────────────────────────────────
// 读入线程一直往前读（Range: bytes=N-），存进环形缓冲；FFmpeg 跳到缓冲外面时换一条请求。
// 断线 / 5xx 自动重连（从断的地方接着读）；CDN 头一回没按 Range 回（缓存刚填）就重试，实在不行读掉前面那截
class HttpSource : public Source {
public:
    static constexpr int64_t kCap = 96ll << 20;        // 环形缓冲
    static constexpr int64_t kBack = 8ll << 20;        // 读过的留 8 MB（往回跳一点不用重新下）
    static constexpr int64_t kAhead = 2ll << 20;       // 跳到缓冲尾巴后面 2 MB 以内：等它读到就行

    explicit HttpSource(std::wstring url) : url_(std::move(url)) {}
    bool connect() override { return open(url_); }

    bool open(const std::wstring& url) {
        URL_COMPONENTS uc{};
        uc.dwStructSize = sizeof uc;
        wchar_t host[256] = {}, path[4096] = {};
        uc.lpszHostName = host; uc.dwHostNameLength = 255;
        uc.lpszUrlPath = path; uc.dwUrlPathLength = 4095;
        wchar_t extra[4096] = {};
        uc.lpszExtraInfo = extra; uc.dwExtraInfoLength = 4095;
        if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) { err_ = "地址不对"; return false; }
        host_ = host;
        path_ = std::wstring(path) + extra;
        port_ = uc.nPort;
        https_ = uc.nScheme == INTERNET_SCHEME_HTTPS;
        session_ = WinHttpOpen(L"CuvenWindows/1.0", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!session_) session_ = WinHttpOpen(L"CuvenWindows/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!session_) { err_ = "网络组件不可用"; return false; }
        WinHttpSetTimeouts(session_, 10000, 10000, 15000, 20000);
        DWORD proto = WINHTTP_PROTOCOL_FLAG_HTTP2;
        WinHttpSetOption(session_, WINHTTP_OPTION_ENABLE_HTTP_PROTOCOL, &proto, sizeof proto);
        connect_ = WinHttpConnect(session_, host_.c_str(), port_, 0);
        if (!connect_) { err_ = "无法连接服务器"; return false; }
        buf_.reset(new uint8_t[(size_t)kCap]);
        // 头一条请求同步发：知道文件多大、地址能不能用
        double t0 = now();
        for (int i = 0; i < 3; i++) {
            if (aborted_) return false;
            int r = start_request(0);
            if (r == 0) break;
            if (r < 0 || i == 2 || aborted_) { if (err_.empty()) err_ = "无法连接服务器"; return false; }
            Sleep(600 * (i + 1));
        }
        log("网络源：连上 %.0f 毫秒，文件 %lld MB", (now() - t0) * 1000, (long long)(size_ >> 20));
        th_ = std::thread([this] { loop(); });
        return true;
    }

    ~HttpSource() override {
        {
            std::lock_guard<std::mutex> l(m_);
            quit_ = true;
            aborted_ = true;
        }
        cancel_request();
        cv_.notify_all();
        if (th_.joinable()) th_.join();
        close_request();
        if (connect_) WinHttpCloseHandle(connect_);
        if (session_) WinHttpCloseHandle(session_);
    }

    int read(uint8_t* out, int n) override {
        std::unique_lock<std::mutex> l(m_);
        for (;;) {
            if (aborted_) return -1;
            if (pos_ >= start_ && pos_ < end_) {
                int64_t off = pos_ % kCap;
                int64_t k = std::min<int64_t>({(int64_t)n, end_ - pos_, kCap - off});
                memcpy(out, buf_.get() + off, (size_t)k);
                pos_ += k;
                cv_.notify_all();
                return (int)k;
            }
            if (size_ >= 0 && pos_ >= size_) return 0;
            if (pos_ == end_ && eof_) return 0;
            if (failed_) return -1;
            if (interrupted()) return -1;
            if ((pos_ < start_ || pos_ > end_ + kAhead) && want_ != pos_) {
                want_ = pos_;
                cv_.notify_all();
                l.unlock();
                cancel_request();
                l.lock();
                continue;
            }
            cv_.wait_for(l, std::chrono::milliseconds(100));
        }
    }

    int64_t seek(int64_t pos) override {
        if (pos < 0) return -1;
        bool jump = false;
        {
            std::lock_guard<std::mutex> l(m_);
            pos_ = pos;
            if (pos_ < start_ || pos_ > end_ + kAhead) {
                want_ = pos_;
                jump = true;
                cv_.notify_all();
            }
        }
        // 正在读的那条请求可能卡在慢连接上：直接掐掉，读入线程马上换到新位置
        if (jump) cancel_request();
        return pos;
    }

    int64_t size() const override { return size_; }
    void abort() override {
        {
            std::lock_guard<std::mutex> l(m_);
            aborted_ = true;
        }
        cv_.notify_all();
        cancel_request();   // 卡在连接 / 收头上的也掐掉
    }
    int64_t buffered_end() const override { return end_; }
    double mbps() const override { return mbps_; }
    bool stalled() const override { return stalled_; }
    std::string error() const override { return err_; }

private:
    std::wstring url_;
    std::wstring host_, path_;
    INTERNET_PORT port_ = 443;
    bool https_ = true;
    HINTERNET session_ = nullptr, connect_ = nullptr;
    std::mutex req_m_;
    HINTERNET req_ = nullptr;
    int64_t req_pos_ = 0;           // 当前请求读到哪（逻辑偏移）

    std::unique_ptr<uint8_t[]> buf_;
    mutable std::mutex m_;
    std::condition_variable cv_;
    int64_t start_ = 0, end_ = 0, pos_ = 0, want_ = -1;
    std::atomic<int64_t> size_{-1};
    bool eof_ = false, failed_ = false, quit_ = false;
    std::atomic<bool> aborted_{false}, stalled_{false};
    std::atomic<double> mbps_{0};
    std::string err_;
    std::thread th_;

    void close_request() {
        std::lock_guard<std::mutex> l(req_m_);
        if (req_) { WinHttpCloseHandle(req_); req_ = nullptr; }
    }
    void cancel_request() { close_request(); }

    // 0 = 好了；1 = 暂时不行（重试）；-1 = 不会好了（404 / 403 …）
    int start_request(int64_t offset) {
        close_request();
        HINTERNET r = WinHttpOpenRequest(connect_, L"GET", path_.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                         https_ ? WINHTTP_FLAG_SECURE : 0);
        if (!r) return 1;
        DWORD dec = 0;
        WinHttpSetOption(r, WINHTTP_OPTION_DECOMPRESSION, &dec, sizeof dec);
        wchar_t hdr[96];
        swprintf(hdr, 96, L"Range: bytes=%lld-\r\nAccept: */*\r\n", (long long)offset);
        {
            std::lock_guard<std::mutex> l(req_m_);
            req_ = r;
        }
        if (!WinHttpSendRequest(r, hdr, (DWORD)-1, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) || !WinHttpReceiveResponse(r, nullptr)) {
            close_request();
            return 1;
        }
        DWORD status = 0, sl = sizeof status;
        WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &sl, WINHTTP_NO_HEADER_INDEX);
        if (status == 416) { close_request(); std::lock_guard<std::mutex> l(m_); eof_ = true; return 0; }
        if (status == 403 || status == 404 || status == 410) { close_request(); err_ = "片源暂时不可用"; return -1; }
        if (status >= 400) { close_request(); return 1; }
        wchar_t cr[128] = {};
        DWORD crl = sizeof cr;
        int64_t total = -1;
        if (WinHttpQueryHeaders(r, WINHTTP_QUERY_CONTENT_RANGE, WINHTTP_HEADER_NAME_BY_INDEX, cr, &crl, WINHTTP_NO_HEADER_INDEX)) {
            const wchar_t* slash = wcschr(cr, L'/');
            if (slash && slash[1] != L'*') total = _wcstoi64(slash + 1, nullptr, 10);
        }
        if (status == 200) {
            wchar_t cl[64] = {};
            DWORD cll = sizeof cl;
            if (WinHttpQueryHeaders(r, WINHTTP_QUERY_CONTENT_LENGTH, WINHTTP_HEADER_NAME_BY_INDEX, cl, &cll, WINHTTP_NO_HEADER_INDEX))
                total = _wcstoi64(cl, nullptr, 10);
            if (offset > 0) {
                // 没按 Range 回：前面那截读掉（不大的话），否则过会儿再试（CDN 头一回在填缓存）
                if (offset > (32ll << 20) && retries_200_++ < 3) { close_request(); return 1; }
                std::vector<uint8_t> junk(1 << 18);
                int64_t left = offset;
                while (left > 0) {
                    DWORD got = 0;
                    if (!WinHttpReadData(r, junk.data(), (DWORD)std::min<int64_t>(left, (int64_t)junk.size()), &got) || got == 0) {
                        close_request();
                        return 1;
                    }
                    left -= got;
                    if (aborted_) return 1;
                }
            }
        }
        retries_200_ = 0;
        if (total > 0) size_ = total;
        req_pos_ = offset;
        return 0;
    }
    int retries_200_ = 0;

    void loop() {
        name_thread(L"Cuven net");
        std::vector<uint8_t> chunk(1 << 18);
        int failures = 0;
        double win_t = now();
        int64_t win_bytes = 0;
        bool have_req = true;   // open() 里已经发了第一条
        for (;;) {
            int64_t at;
            {
                std::unique_lock<std::mutex> l(m_);
                if (quit_) return;
                if (want_ >= 0) {
                    start_ = end_ = want_;
                    want_ = -1;
                    eof_ = false;
                    have_req = false;
                    failures = 0;            // 是我们自己掐掉的，不算失败
                    stalled_ = false;
                }
                // 缓冲满了（没读的 + 留着的已经占满）或者读到头了：等
                while (!quit_ && want_ < 0 && (eof_ || failed_ || (end_ - std::max(start_, pos_ - kBack)) >= kCap - (int64_t)chunk.size())) {
                    cv_.wait_for(l, std::chrono::milliseconds(200));
                }
                if (quit_) return;
                if (want_ >= 0) continue;
                at = end_;
            }
            if (!have_req || req_pos_ != at) {
                int r = start_request(at);
                if (r < 0) {
                    std::lock_guard<std::mutex> l(m_);
                    failed_ = true;
                    cv_.notify_all();
                    continue;
                }
                if (r > 0) {
                    stalled_ = true;
                    failures++;
                    Sleep((DWORD)std::min(8000, 300 << std::min(failures, 5)));
                    continue;
                }
                have_req = true;
                {
                    std::lock_guard<std::mutex> l(m_);
                    if (eof_) { cv_.notify_all(); continue; }
                }
            }
            DWORD got = 0;
            HINTERNET r;
            {
                std::lock_guard<std::mutex> l(req_m_);
                r = req_;
            }
            BOOL ok = r && WinHttpReadData(r, chunk.data(), (DWORD)chunk.size(), &got);
            if (!ok) {
                have_req = false;
                close_request();
                if (quit_) return;
                stalled_ = true;
                failures++;
                if (failures > 2) Sleep((DWORD)std::min(8000, 200 << std::min(failures, 5)));
                continue;
            }
            if (got == 0) {
                close_request();
                have_req = false;
                std::lock_guard<std::mutex> l(m_);
                if (size_ < 0 || end_ >= size_) eof_ = true;
                cv_.notify_all();
                continue;
            }
            failures = 0;
            stalled_ = false;
            req_pos_ += got;
            win_bytes += got;
            double t = now();
            if (t - win_t > 1.0) { mbps_ = win_bytes * 8.0 / 1e6 / (t - win_t); win_t = t; win_bytes = 0; }
            std::lock_guard<std::mutex> l(m_);
            if (want_ >= 0 || at != end_) continue;   // 读的时候被要求跳走了：这截不要
            int64_t written = 0;
            while (written < got) {
                int64_t off = end_ % kCap;
                int64_t k = std::min<int64_t>((int64_t)got - written, kCap - off);
                memcpy(buf_.get() + off, chunk.data() + written, (size_t)k);
                written += k;
                end_ += k;
            }
            if (end_ - start_ > kCap) start_ = end_ - kCap;
            cv_.notify_all();
        }
    }
};

std::unique_ptr<Source> make_source(const char* url) {
    std::wstring w = widen(url);
    if (w.rfind(L"http://", 0) == 0 || w.rfind(L"https://", 0) == 0) return std::make_unique<HttpSource>(w);
    if (w.rfind(L"file:///", 0) == 0) w = w.substr(8);
    return std::make_unique<FileSource>(w);
}

// ── AVIO ────────────────────────────────────────────────────────
static int avio_read(void* opaque, uint8_t* buf, int n) {
    int r = ((Source*)opaque)->read(buf, n);
    if (r == 0) return AVERROR_EOF;
    return r < 0 ? AVERROR(EIO) : r;
}

static int64_t avio_seek(void* opaque, int64_t off, int whence) {
    auto s = (Source*)opaque;
    whence &= ~AVSEEK_FORCE;
    if (whence == AVSEEK_SIZE) return s->size();
    if (whence == SEEK_END) {
        if (s->size() < 0) return -1;
        off += s->size();
    } else if (whence == SEEK_CUR) {
        return -1;   // FFmpeg 自己算好绝对位置再来，用不到
    }
    return s->seek(off);
}

AVIOContext* make_avio(Source* s) {
    const int sz = 1 << 19;
    auto buf = (uint8_t*)av_malloc(sz);
    if (!buf) return nullptr;
    AVIOContext* pb = avio_alloc_context(buf, sz, 0, s, avio_read, nullptr, avio_seek);
    if (!pb) { av_free(buf); return nullptr; }
    pb->seekable = AVIO_SEEKABLE_NORMAL;
    return pb;
}

void free_avio(AVIOContext*& pb) {
    if (!pb) return;
    av_freep(&pb->buffer);
    avio_context_free(&pb);
}

}  // namespace cv
