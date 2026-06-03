#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [remove-subtitles] argc=$# ==="
emulate -L zsh
setopt local_options no_nomatch

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
. "$(dirname "$0")/orb_popover.sh"

notify() {
    local kind="$1"
    local title="$2"
    local subtitle="$3"
    echo "NOTICE: 移除字幕: $title${subtitle:+ | $subtitle}"
    emit_popover "$kind" "remove-subtitles" "$title" "$subtitle"
}

orb_subtitle_stream_indices() {
    local src="$1"
    /usr/bin/python3 - "$src" <<'PY'
import json
import subprocess
import sys

try:
    raw = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_streams", "-of", "json", sys.argv[1]],
        stderr=subprocess.DEVNULL,
    )
    data = json.loads(raw)
except Exception:
    sys.exit(0)

for stream in data.get("streams", []):
    if stream.get("codec_type") != "subtitle":
        continue
    tags = stream.get("tags") or {}
    if any("Orb Subtitles" in str(value) for value in tags.values()):
        index = stream.get("index")
        if index is not None:
            print(index)
PY
}

remove_orb_subtitles() {
    local src="$1"
    local dir filename stem ext tmp_video
    local -a indices args

    ffprobe -v error -show_entries format=filename -of default=nw=1:nk=1 "$src" >/dev/null 2>&1 || return 3
    indices=($(orb_subtitle_stream_indices "$src"))
    [ "${#indices[@]}" -gt 0 ] || return 2

    dir="${src:h}"
    filename="${src:t}"
    stem="${filename%.*}"
    ext="${filename##*.}"
    tmp_video="$dir/.${stem}.orb-no-subtitles.$$.$ext"

    args=(-y -loglevel error -i "$src" -map 0)
    for index in "${indices[@]}"; do
        args+=(-map "-0:$index")
    done
    args+=(-map_metadata 0 -map_chapters 0 -c copy "$tmp_video")

    echo "--- remove Orb subtitles: $src streams=${indices[*]}"
    ffmpeg "${args[@]}"
    if [ "$?" -ne 0 ]; then
        /bin/rm -f "$tmp_video"
        return 1
    fi

    /bin/mv -f "$tmp_video" "$src"
}

if ! command -v ffmpeg >/dev/null 2>&1; then
    notify "error" "移除字幕失败" "未找到 ffmpeg，请先 brew install ffmpeg"
    exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
    notify "error" "移除字幕失败" "未找到 ffprobe，请先 brew install ffmpeg"
    exit 1
fi

if [ "$#" -eq 0 ]; then
    notify "error" "移除字幕失败" "请先选中视频文件"
    exit 0
fi

ok=0
fail=0
skipped=0
typeset -a changed_files
typeset -a failure_reasons

for src in "$@"; do
    if [ ! -f "$src" ]; then
        echo "SKIP not a file: $src"
        fail=$((fail+1))
        failure_reasons+=("不是文件: ${src:t}")
        continue
    fi

    remove_orb_subtitles "$src"
    remove_status=$?
    case "$remove_status" in
        0)
            ok=$((ok+1))
            changed_files+=("${src:t}")
            echo "OK removed subtitles: $src"
            /usr/bin/osascript -e "tell application \"Finder\" to update (POSIX file \"${src:h}\" as alias)" 2>/dev/null
            ;;
        2)
            fail=$((fail+1))
            failure_reasons+=("未找到由 Orb 生成的字幕: ${src:t}")
            echo "SKIP no Orb subtitles: $src"
            ;;
        3)
            fail=$((fail+1))
            failure_reasons+=("无法读取视频信息: ${src:t}")
            echo "FAIL probe video: $src"
            ;;
        *)
            fail=$((fail+1))
            failure_reasons+=("无法重写视频文件: ${src:t}")
            echo "FAIL remove subtitles: $src"
            ;;
    esac
done

if [ "$ok" -gt 0 ] && [ "$fail" -eq 0 ]; then
    if [ "$ok" -eq 1 ]; then
        msg="已移除字幕: ${changed_files[1]}"
    else
        msg="已移除字幕: $ok 个文件"
    fi
    notify "success" "移除字幕成功" "$msg"
else
    if [ "${#failure_reasons[@]}" -gt 0 ]; then
        msg="${failure_reasons[1]}"
    else
        msg="没有移除任何字幕"
    fi
    if [ "$fail" -gt 1 ]; then
        msg="$msg 等 $fail 个问题"
    fi
    notify "error" "移除字幕失败" "$msg"
fi
echo "DONE remove subtitles: ok=$ok fail=$fail skipped=$skipped"
