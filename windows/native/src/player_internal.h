#pragma once
#include "common.h"

// 自检用：读回播放器中间纹理上的这一帧（8 位 RGBA，SDR 编码）
bool cv_player_readback(cv_player* p, std::vector<uint8_t>& rgba, int& w, int& h);
