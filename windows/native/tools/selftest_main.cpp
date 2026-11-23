// CuvenSelfTest.exe —— CI 上跑的原生自检（WARP 软件渲染）
//   CuvenSelfTest <片子> <pair-density.png> <码纹理 192×192> <编号> <密钥> <输出目录>
//   · 配对粒子云：画 48 帧（400×400，和 pairing/frames/render.mjs 同样的画布），叠在白底上存 PNG，
//     目录名 <编号>-<密钥>，拿 pairing/py/eval.py 就能解（检验 D3D11 版和网页版画出来的一样能解）
//   · 播放器：cv_selftest（打开、播放、读回画面、跳转、暂停）
#define NOMINMAX
#include <windows.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "../include/cuven_core.h"

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);
    if (argc < 7) {
        printf("用法：CuvenSelfTest <片子> <pair-density.png> <grid.bin> <编号> <密钥> <输出目录>\n");
        return 2;
    }
    const char* media = argv[1];
    const char* atlas_path = argv[2];
    const char* grid_path = argv[3];
    unsigned long id = strtoul(argv[4], nullptr, 10), secret = strtoul(argv[5], nullptr, 10);
    std::string out = argv[6];
    CreateDirectoryA(out.c_str(), nullptr);
    if (cv_init(CV_INIT_WARP) != 0) { printf("✗ 设备\n"); return 1; }
    printf("%s · %s\n", cv_version(), cv_gpu_name());
    int failed = 0;

    // ── 粒子云（图集给 "-" 就跳过） ──
    bool do_cloud = strcmp(atlas_path, "-") != 0;
    int aw = 0, ah = 0;
    std::vector<uint8_t> atlas;
    if (do_cloud && cv_load_gray(atlas_path, nullptr, 0, &aw, &ah) == 0) {
        atlas.resize((size_t)aw * ah);
        if (cv_load_gray(atlas_path, atlas.data(), (int)atlas.size(), &aw, &ah) != 0) atlas.clear();
    }
    if (do_cloud) {
    printf("%s 密度校正图 %dx%d\n", atlas.empty() ? "✗" : "✓", aw, ah);
    if (atlas.empty()) failed++;
    std::vector<uint8_t> grid(192 * 192);
    FILE* gf = fopen(grid_path, "rb");
    size_t got = gf ? fread(grid.data(), 1, grid.size(), gf) : 0;
    if (gf) fclose(gf);
    printf("%s 码纹理 %zu 字节\n", got == grid.size() ? "✓" : "✗", got);
    cv_surface* s = cv_surface_create(64, 64, CV_SURFACE_TRANSPARENT);
    cv_cloud* c = s ? cv_cloud_create(s, atlas.empty() ? nullptr : atlas.data(), aw, ah) : nullptr;
    printf("%s 粒子云\n", c ? "✓" : "✗");
    if (!c) failed++;
    if (c && got == grid.size()) {
        cv_cloud_set_code(c, grid.data(), 192, 3.0f, 0.05f);
        std::string dir = out + "\\" + std::to_string(id) + "-" + std::to_string(secret);
        CreateDirectoryA(dir.c_str(), nullptr);
        const int W = 400, H = 400;
        std::vector<uint8_t> px((size_t)W * H * 4);
        int ok = 0;
        for (int k = 0; k < 48; k++) {
            double t = k / 30.0;
            if (cv_cloud_snapshot(c, t, t, W, H, px.data()) != 0) continue;
            // 预乘的颜色叠到白底上（和网页上一样）
            for (size_t i = 0; i < px.size(); i += 4) {
                int a = px[i + 3];
                for (int j = 0; j < 3; j++) px[i + j] = (uint8_t)std::min(255, px[i + j] + (255 - a));
                px[i + 3] = 255;
            }
            char name[64];
            snprintf(name, sizeof name, "\\%04d.png", k);
            if (cv_save_png((dir + name).c_str(), px.data(), W, H) == 0) ok++;
        }
        printf("%s 粒子云 %d / 48 帧\n", ok == 48 ? "✓" : "✗", ok);
        if (ok != 48) failed++;
    }
    if (c) cv_cloud_destroy(c);
    if (s) cv_surface_destroy(s);
    }

    // ── 播放器 ──
    std::vector<char> report(1 << 16);
    int r = cv_selftest(media, out.c_str(), report.data(), (int)report.size());
    printf("%s", report.data());
    FILE* rf = fopen((out + "\\report.txt").c_str(), "wb");
    if (rf) { fputs(report.data(), rf); fclose(rf); }
    if (r != 0) failed++;
    printf("\n%s\n", failed ? "自检没过" : "自检通过");
    return failed ? 1 : 0;
}
