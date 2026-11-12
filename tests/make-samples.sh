#!/usr/bin/env bash
# 生成测试样片（需要 ffmpeg（含 libx265 / libx264 / libsvtav1）、mkvmerge、node、curl）
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p samples/dovi && cd samples
q() { ffmpeg -hide_banner -loglevel error -y "$@"; }
DOVI=https://raw.githubusercontent.com/quietvoid/dovi_tool/main/assets/tests
for f in profile8.bin profile5.bin fel_orig.bin fel_to_81.bin mel_orig.bin mel_to_81.bin; do
  [ -f dovi/$f ] || curl -sSfL -o dovi/$f $DOVI/$f
done
cat > subs_en.srt <<'S'
1
00:00:01,000 --> 00:00:03,500
Hello <i>world</i> — first line

2
00:00:05,000 --> 00:00:07,000
Second cue
with two lines

3
00:00:12,250 --> 00:00:14,000
Third cue at 12.25s

4
00:00:21,000 --> 00:00:25,000
Fourth cue near the end
S
cat > subs_zh.ass <<'S'
[Script Info]
ScriptType: v4.00+

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\an8}中文字幕 第一句\N第二行
Dialogue: 0,0:00:08.50,0:00:10.00,Default,,0,0,0,,第二句，逗号, 测试
Dialogue: 0,0:00:18.00,0:00:20.00,Default,,0,0,0,,{\i1}斜体{\i0}第三句
S
# 5.1 测试音（每个声道不同频率）
q -f lavfi -i sine=440:sample_rate=48000:duration=30 -f lavfi -i sine=660:sample_rate=48000:duration=30 \
  -f lavfi -i sine=880:sample_rate=48000:duration=30 -f lavfi -i sine=330:sample_rate=48000:duration=30 \
  -f lavfi -i sine=550:sample_rate=48000:duration=30 -f lavfi -i sine=110:sample_rate=48000:duration=30 \
  -filter_complex "[0][1][2][3][4][5]join=inputs=6:channel_layout=5.1[a]" -map "[a]" -c:a pcm_s24le pcm51.wav
q -i pcm51.wav -c:a eac3 -b:a 640k eac3_51.eac3
q -i pcm51.wav -c:a ac3 -b:a 448k ac3_51.ac3
q -i pcm51.wav -ac 2 -c:a aac -b:a 192k aac_20.m4a
q -i pcm51.wav -ac 2 -c:a flac flac_20.flac
q -i pcm51.wav -c:a dca -strict -2 -b:a 1509k dts_51.dts
q -i pcm51.wav -c:a truehd -strict -2 truehd_51.thd
q -i pcm51.wav -ac 2 -c:a libopus -b:a 128k opus_20.opus
# HEVC 10bit HDR10（开放 GOP + B 帧金字塔）+ 全套音轨与字幕
q -f lavfi -i "testsrc2=size=640x360:rate=24000/1001,format=yuv420p10le" -t 30 -c:v libx265 -preset ultrafast \
  -x265-params "log-level=error:keyint=48:min-keyint=48:bframes=4:b-pyramid=1:open-gop=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:hdr10=1" \
  -pix_fmt yuv420p10le hdr10.hevc
mkvmerge -q -o hdr10_multi.mkv hdr10.hevc --language 0:eng --track-name 0:"English DD+ 5.1" eac3_51.eac3 \
  --language 0:jpn --track-name 0:"Japanese AC-3" ac3_51.ac3 --language 0:fre aac_20.m4a --language 0:ger flac_20.flac \
  --language 0:spa dts_51.dts --language 0:ita truehd_51.thd --language 0:kor opus_20.opus \
  --language 0:eng subs_en.srt --language 0:chi --track-name 0:"简体中文" subs_zh.ass
cp subs_en.srt hdr10_multi.chs.srt; cp subs_zh.ass hdr10_multi.cht.ass
# 杜比视界：把 dovi_tool 的 RPU 测试向量注入每个访问单元
q -f lavfi -i "testsrc2=size=1920x1080:rate=24000/1001,format=yuv420p10le" -t 12 -c:v libx265 -preset ultrafast \
  -x265-params "log-level=error:keyint=24:min-keyint=24:bframes=4:open-gop=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1" \
  -pix_fmt yuv420p10le hdr1080.hevc
q -i pcm51.wav -t 12 -c:a eac3 -b:a 768k eac3_12.eac3
node ../inject-rpu.mjs hdr1080.hevc dovi/profile8.bin dv81.hevc
node ../inject-rpu.mjs hdr1080.hevc dovi/profile5.bin dv5.hevc
node ../inject-rpu.mjs hdr1080.hevc dovi/fel_orig.bin dv7.hevc el
for f in dv81 dv5 dv7; do mkvmerge -q -o $f.mkv $f.hevc eac3_12.eac3; done
# H.264（B 帧金字塔）、zlib 压缩字幕、无 Cues、字幕无 Cues、只有 DTS、AV1 HDR10
q -f lavfi -i "testsrc2=size=1280x720:rate=25" -f lavfi -i "sine=frequency=500:sample_rate=44100" -t 20 \
  -c:v libx264 -preset veryfast -bf 3 -x264-params "b-pyramid=normal:keyint=50:min-keyint=50" -c:a aac -b:a 128k avc_raw.mp4
q -i pcm51.wav -t 20 -c:a ac3 -b:a 384k ac3_20.ac3
q -i pcm51.wav -t 20 -c:a dca -strict -2 -b:a 1509k dts_20.dts
mkvmerge -q -o avc_zsub.mkv avc_raw.mp4 ac3_20.ac3 --compression 0:zlib --language 0:chi subs_zh.ass
mkvmerge -q -o nocues.mkv --no-cues avc_raw.mp4
mkvmerge -q -o subscan.mkv avc_raw.mp4 --cues 0:none --language 0:eng subs_en.srt
# ASS 转出来的 SRT：\h、\N、{\an8} 还留在文字里，开头两条是署名与广告（内封的文本字幕轨也要洗干净）
cat > subs_left.srt <<'S'
1
00:00:01,000 --> 00:00:04,000
翻\h译
blossomoon\h\h\h大头小波\h\h一只小蜜蜂啊\h\h不求富贵只求大鱼大肉

2
00:00:05,000 --> 00:00:08,000
片头推广合作洽谈\h请联系普罗米修斯邮箱\hPLMXS2016@GmaiL.com

3
00:00:09,000 --> 00:00:11,000
{\an8}你好\h世界\N第二行

4
00:00:12,000 --> 00:00:14,000
我们出发吧
S
mkvmerge -q -o srt_left.mkv avc_raw.mp4 --language 0:chi subs_left.srt
mkvmerge -q -o dts_only.mkv -A avc_raw.mp4 --language 0:eng dts_20.dts
q -f lavfi -i "testsrc2=size=1280x720:rate=30000/1001" -f lavfi -i "sine=frequency=700:sample_rate=48000" -t 12 \
  -c:v libsvtav1 -preset 12 -g 60 -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -c:a libopus -b:a 128k -f matroska av1_hdr.mkv
# 参数集：编码器在每个关键帧前重复 VPS / SPS / PPS（x265 repeat-headers；x264 裸流默认就这样），
# 再由 mkv-variants.mjs 原地派生「配置盒里没有参数集 / 没有 CodecPrivate / Annex B 帧」三种不规范的版本
q -f lavfi -i "testsrc2=size=640x360:rate=25" -t 10 -c:v libx265 -preset ultrafast \
  -x265-params "log-level=error:keyint=25:min-keyint=25:bframes=3:repeat-headers=1" -pix_fmt yuv420p hevc_rh.hevc
q -f lavfi -i "testsrc2=size=640x360:rate=25" -t 10 -c:v libx264 -preset veryfast -bf 3 -g 25 -f h264 avc_rh.h264
mkvmerge -q -o hevc_rh.mkv hevc_rh.hevc
mkvmerge -q -o avc_rh.mkv --default-duration 0:25fps avc_rh.h264
node ../mkv-variants.mjs hevc_rh.mkv hevc
node ../mkv-variants.mjs avc_rh.mkv avc
node ../mkv-variants.mjs av1_hdr.mkv av1
# 前端测试（tests/web.mjs）用：3 分钟的 MP4，续播 / 下一集要有足够长的片长
q -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=600:sample_rate=48000" -t 180 \
  -c:v libx264 -preset veryfast -crf 34 -g 50 -c:a aac -b:a 64k -movflags +faststart long.mp4
cp long.mp4 long_ep2.mp4
# 在线字幕自动对齐（tests/run.mjs）用：3 分钟、内封约 100 条英文字幕当参照（间隔、时长都不规则，像真对白）；
# sync_nosub.mkv 不带字幕 —— 只能拿 OpenSubtitles 上同哈希的他语种字幕当参照
node -e '
let seed = 11, t = 1.2; const r = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const tc = x => { const ms = Math.round(x * 1000), p = (v, n = 2) => String(v).padStart(n, "0");
  return p(Math.floor(ms / 3600000)) + ":" + p(Math.floor(ms / 60000) % 60) + ":" + p(Math.floor(ms / 1000) % 60) + "," + p(ms % 1000, 3); };
const out = [];
for (let i = 0; i < 150 && t < 176; i++) { const d = 0.5 + r() * 1.4; out.push((i + 1) + "\n" + tc(t) + " --> " + tc(t + d) + "\nLine " + (i + 1) + "\n"); t += d + 0.12 + r() * r() * 1.6; }
require("fs").writeFileSync("sync_en.srt", out.join("\n"));'
mkvmerge -q -o sync_ref.mkv long.mp4 --language 0:eng sync_en.srt
mkvmerge -q -o sync_nosub.mkv long.mp4
# 同目录外挂字幕（中文那份故意放了两条一模一样的 cue：播放页只该画一行）
cat > long.zh.srt <<'S'
1
00:00:01,000 --> 00:00:04,000
第一句中文字幕

2
00:00:01,000 --> 00:00:04,000
第一句中文字幕

3
00:00:05,000 --> 00:00:08,000
第二句，<i>斜体</i>

4
00:01:40,000 --> 00:01:44,000
一百秒处的字幕
S
cat > long.en.srt <<'S'
1
00:00:01,000 --> 00:00:04,000
First English line

2
00:00:05,000 --> 00:00:08,000
Second English line
S
echo "samples ready: $(ls *.mkv | wc -l) mkv"
