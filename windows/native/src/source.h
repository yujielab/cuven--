#pragma once
#include "common.h"

namespace cv {

// 字节源：FFmpeg 通过 AVIO 回调从这里读。网络源自己有读入线程和大环形缓冲（往前读、留一截往回跳用）
class Source {
public:
    virtual ~Source() = default;
    // 读最多 n 字节；返回读到的字节数，0 = 文件尾，<0 = 出错 / 中止
    virtual int read(uint8_t* buf, int n) = 0;
    virtual int64_t seek(int64_t pos) = 0;      // 返回新位置，<0 = 失败
    virtual int64_t size() const = 0;           // 不知道 = -1
    virtual void abort() = 0;                   // 让正在等的 read 立刻返回
    virtual int64_t buffered_end() const { return size(); }   // 已经读进来的到哪（字节）
    virtual double mbps() const { return 0; }
    virtual bool stalled() const { return false; }             // 网络断了、正在重连
    virtual std::string error() const { return {}; }
    virtual bool connect() = 0;                 // 连上 / 打开（可能要几秒；abort() 能打断）
    // 打断：*flag 非 0 时正在等的 read 返回 -1（跳转、退出）
    void set_interrupt(std::atomic<int>* flag) { interrupt_ = flag; }
protected:
    bool interrupted() const { return interrupt_ && interrupt_->load() != 0; }
    std::atomic<int>* interrupt_ = nullptr;
};

std::unique_ptr<Source> make_source(const char* url_utf8);   // 只建，不连

// FFmpeg 的自定义 IO
AVIOContext* make_avio(Source* s);
void free_avio(AVIOContext*& pb);

}  // namespace cv
