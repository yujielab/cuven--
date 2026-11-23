// WIC：读灰度图（配对云的密度校正图）、存 PNG（自检截图）
#include "common.h"

using namespace cv;

extern "C" {

CV_API int CV_CALL cv_load_gray(const char* path, uint8_t* out, int max_bytes, int* w, int* h) {
    if (!gpu_ok() && cv_init(0) != 0) return -1;
    auto& wic = gpu().wic;
    if (!wic) return -2;
    ComPtr<IWICBitmapDecoder> dec;
    if (FAILED(wic->CreateDecoderFromFilename(widen(path).c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &dec))) return -3;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(dec->GetFrame(0, &frame))) return -4;
    UINT fw = 0, fh = 0;
    frame->GetSize(&fw, &fh);
    if (w) *w = (int)fw;
    if (h) *h = (int)fh;
    if (!out) return 0;
    if ((int64_t)fw * fh > max_bytes) return -5;
    // 已经是 8 位灰度就原样拷（不让 WIC 做任何颜色换算）
    WICPixelFormatGUID pf{};
    frame->GetPixelFormat(&pf);
    if (pf == GUID_WICPixelFormat8bppGray) return SUCCEEDED(frame->CopyPixels(nullptr, fw, fw * fh, out)) ? 0 : -6;
    ComPtr<IWICFormatConverter> conv;
    if (FAILED(wic->CreateFormatConverter(&conv))) return -7;
    if (FAILED(conv->Initialize(frame.Get(), GUID_WICPixelFormat8bppGray, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) return -8;
    return SUCCEEDED(conv->CopyPixels(nullptr, fw, fw * fh, out)) ? 0 : -9;
}

CV_API int CV_CALL cv_save_png(const char* path, const uint8_t* rgba, int w, int h) {
    if (!gpu_ok() && cv_init(0) != 0) return -1;
    auto& wic = gpu().wic;
    if (!wic || !rgba || w <= 0 || h <= 0) return -2;
    ComPtr<IWICStream> st;
    if (FAILED(wic->CreateStream(&st)) || FAILED(st->InitializeFromFilename(widen(path).c_str(), GENERIC_WRITE))) return -3;
    ComPtr<IWICBitmapEncoder> enc;
    if (FAILED(wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &enc)) || FAILED(enc->Initialize(st.Get(), WICBitmapEncoderNoCache))) return -4;
    ComPtr<IWICBitmapFrameEncode> fr;
    if (FAILED(enc->CreateNewFrame(&fr, nullptr)) || FAILED(fr->Initialize(nullptr))) return -5;
    fr->SetSize((UINT)w, (UINT)h);
    // PNG 编码器认 BGRA（RGBA 在有的系统上不认）：自己换一下
    WICPixelFormatGUID pf = GUID_WICPixelFormat32bppBGRA;
    fr->SetPixelFormat(&pf);
    if (pf != GUID_WICPixelFormat32bppBGRA) return -6;
    std::vector<uint8_t> bgra((size_t)w * h * 4);
    for (size_t i = 0; i < bgra.size(); i += 4) {
        bgra[i] = rgba[i + 2]; bgra[i + 1] = rgba[i + 1]; bgra[i + 2] = rgba[i]; bgra[i + 3] = rgba[i + 3];
    }
    if (FAILED(fr->WritePixels((UINT)h, (UINT)w * 4, (UINT)bgra.size(), bgra.data()))) return -7;
    if (FAILED(fr->Commit()) || FAILED(enc->Commit())) return -8;
    return 0;
}

}  // extern "C"
