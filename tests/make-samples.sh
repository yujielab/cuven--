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
mkvmerge -q -o dts_only.mkv -A avc_raw.mp4 --language 0:eng dts_20.dts
q -f lavfi -i "testsrc2=size=1280x720:rate=30000/1001" -f lavfi -i "sine=frequency=700:sample_rate=48000" -t 12 \
  -c:v libsvtav1 -preset 12 -g 60 -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -c:a libopus -b:a 128k -f matroska av1_hdr.mkv
# 前端测试（tests/web.mjs）用：3 分钟的 MP4，续播 / 下一集要有足够长的片长
q -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=600:sample_rate=48000" -t 180 \
  -c:v libx264 -preset veryfast -crf 34 -g 50 -c:a aac -b:a 64k -movflags +faststart long.mp4
cp long.mp4 long_ep2.mp4
echo "samples ready: $(ls *.mkv | wc -l) mkv"
