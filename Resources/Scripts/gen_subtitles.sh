#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [gen-subtitles] argc=$# ==="
emulate -L zsh
setopt local_options no_nomatch

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
. "$(dirname "$0")/orb_popover.sh"

MODEL="$HOME/whisper-models/ggml-medium.bin"
WHISPER_LANG="auto"

notify() {
    local kind="$1"
    local title="$2"
    local subtitle="$3"
    echo "NOTICE: 生成字幕: $title${subtitle:+ | $subtitle}"
    emit_popover "$kind" "subtitles" "$title" "$subtitle"
}

progress_remaining_text() {
    local percent="$1"
    local now elapsed remaining
    now=$(/bin/date +%s)
    elapsed=$((now - start_ts))

    if [ "$percent" -gt 2 ]; then
        remaining=$((elapsed * (100 - percent) / percent))
    else
        remaining=$eta
    fi

    if [ "$remaining" -le 1 ]; then
        printf "即将完成"
    else
        printf "约 %s" "$(fmt_time "$remaining")"
    fi
}

notify_progress() {
    local title="$1"
    local subtitle="$2"
    local percent="$3"
    local remaining
    [ "$percent" -lt 1 ] && percent=1
    [ "$percent" -gt 99 ] && percent=99
    remaining="$(progress_remaining_text "$percent")"
    echo "PROGRESS: 生成字幕: $percent% | $title${subtitle:+ | $subtitle} | $remaining"
    emit_popover_progress "subtitles" "$title" "$subtitle" "$percent" "$remaining"
}

notify_file_progress() {
    local src="$1"
    local index="$2"
    local stage="$3"
    local file_percent="$4"
    local file_work="${todo_work[$index]}"
    local completed_scaled percent subtitle

    completed_scaled=$(((processed_work_units + file_work * file_percent / 100) * 100))
    percent=$((completed_scaled / total_work_units))
    subtitle="${index}/${#todo[@]} ${stage}: ${src:t}"
    notify_progress "生成字幕中" "$subtitle" "$percent"
}

fmt_time() {
    local s=$1
    if [ "$s" -le 0 ]; then
        printf "<1s"
    elif [ "$s" -ge 3600 ]; then
        printf "%dh%dm" $((s/3600)) $(( (s%3600)/60 ))
    elif [ "$s" -ge 60 ]; then
        printf "%dm%ds" $((s/60)) $((s%60))
    else
        printf "%ds" "$s"
    fi
}

normalize_srt() {
    local srt_path="$1"
    [ -s "$srt_path" ] || return 0

    /usr/bin/python3 - "$srt_path" <<'PY'
import os
import re
import sys
import tempfile
import unicodedata

MAX_LINE_WIDTH = 24.0
MAX_CUE_WIDTH = 46.0
MAX_CUE_MS = 5000
MIN_CUE_MS = 900
NO_LINE_START = set("，。！？；：、,.!?;:%)]}》」』”’")

path = sys.argv[1]

def parse_time(value):
    match = re.match(r"(\d+):(\d{2}):(\d{2}),(\d{3})", value.strip())
    if not match:
        raise ValueError(f"bad srt timestamp: {value!r}")
    h, m, s, ms = map(int, match.groups())
    return ((h * 60 + m) * 60 + s) * 1000 + ms

def fmt_time_ms(ms):
    ms = max(0, int(round(ms)))
    h, rem = divmod(ms, 3600000)
    m, rem = divmod(rem, 60000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

def char_width(ch):
    if ch.isspace():
        return 0.5
    return 1.0 if unicodedata.east_asian_width(ch) in ("W", "F", "A") else 0.55

def width(text):
    return sum(char_width(ch) for ch in text)

def clean_text(lines):
    text = " ".join(line.strip() for line in lines if line.strip())
    return re.sub(r"\s+", " ", text).strip()

def split_by_punctuation(text):
    parts = []
    buf = []
    strong = set("。！？!?；;")
    soft = set("，,、")
    for ch in text:
        buf.append(ch)
        if ch in strong or (ch in soft and width("".join(buf)) >= MAX_LINE_WIDTH * 0.75):
            part = "".join(buf).strip()
            if part:
                parts.append(part)
            buf = []
    tail = "".join(buf).strip()
    if tail:
        parts.append(tail)
    return parts or [text]

def hard_split(text, limit):
    chunks = []
    buf = []
    current = 0.0
    for ch in text:
        w = char_width(ch)
        if buf and current + w > limit and ch in NO_LINE_START:
            buf.append(ch)
            chunks.append("".join(buf).strip())
            buf = []
            current = 0.0
            continue
        if buf and current + w > limit:
            chunks.append("".join(buf).strip())
            buf = [ch]
            current = w
        else:
            buf.append(ch)
            current += w
    if buf:
        chunks.append("".join(buf).strip())
    return [chunk for chunk in chunks if chunk]

def split_text(text):
    pieces = []
    for part in split_by_punctuation(text):
        if width(part) <= MAX_CUE_WIDTH:
            pieces.append(part)
        else:
            pieces.extend(hard_split(part, MAX_LINE_WIDTH))

    cues = []
    current = ""
    for piece in pieces:
        candidate = piece if not current else current + piece
        if current and width(candidate) > MAX_CUE_WIDTH:
            cues.append(current)
            current = piece
        else:
            current = candidate
    if current:
        cues.append(current)
    return cues or [text]

def wrap_lines(text):
    if width(text) <= MAX_LINE_WIDTH:
        return [text]

    lines = []
    buf = []
    current = 0.0
    for ch in text:
        w = char_width(ch)
        if buf and current + w > MAX_LINE_WIDTH and ch in NO_LINE_START:
            buf.append(ch)
            lines.append("".join(buf).strip())
            buf = []
            current = 0.0
            continue
        if buf and current + w > MAX_LINE_WIDTH:
            lines.append("".join(buf).strip())
            buf = [ch]
            current = w
        else:
            buf.append(ch)
            current += w
    if buf:
        lines.append("".join(buf).strip())

    if len(lines) <= 2:
        return lines

    # The text splitter should normally prevent this. Keep a hard fallback so
    # a malformed or punctuation-free line cannot become a subtitle wall.
    return lines[:2]

def parse_blocks(raw):
    blocks = re.split(r"\n\s*\n", raw.strip(), flags=re.MULTILINE)
    parsed = []
    for block in blocks:
        lines = [line.rstrip("\r") for line in block.splitlines() if line.strip()]
        if not lines:
            continue
        time_index = next((i for i, line in enumerate(lines) if "-->" in line), -1)
        if time_index < 0:
            continue
        start_text, end_text = [part.strip().split()[0] for part in lines[time_index].split("-->", 1)]
        start = parse_time(start_text)
        end = parse_time(end_text)
        text = clean_text(lines[time_index + 1:])
        if text and end > start:
            parsed.append((start, end, text))
    return parsed

with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
    source = f.read()

blocks = parse_blocks(source)
if not blocks:
    sys.exit(0)

out = []
for start, end, text in blocks:
    chunks = split_text(text)
    duration = end - start
    total_weight = max(sum(max(width(chunk), 1.0) for chunk in chunks), 1.0)
    cursor = start

    for index, chunk in enumerate(chunks):
        if index == len(chunks) - 1:
            chunk_end = end
        else:
            share = max(width(chunk), 1.0) / total_weight
            chunk_ms = max(MIN_CUE_MS, min(MAX_CUE_MS, int(duration * share)))
            remaining_chunks = len(chunks) - index - 1
            latest_end = end - remaining_chunks * MIN_CUE_MS
            chunk_end = min(cursor + chunk_ms, latest_end)
            if chunk_end <= cursor:
                chunk_end = min(end, cursor + MIN_CUE_MS)

        if chunk_end - cursor > MAX_CUE_MS and len(chunks) == 1:
            chunk_end = min(end, cursor + MAX_CUE_MS)

        out.append((cursor, max(cursor + 1, chunk_end), wrap_lines(chunk)))
        cursor = chunk_end

    if out and out[-1][1] < end:
        last_start, _last_end, last_lines = out[-1]
        out[-1] = (last_start, end, last_lines)

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".sr-srt-", suffix=".srt", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        for i, (start, end, lines) in enumerate(out, 1):
            f.write(f"{i}\n")
            f.write(f"{fmt_time_ms(start)} --> {fmt_time_ms(end)}\n")
            f.write("\n".join(lines))
            f.write("\n\n")
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

if ! command -v whisper-cli >/dev/null 2>&1; then
    notify "error" "缺少依赖" "未找到 whisper-cli，请先 brew install whisper-cpp"
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    notify "error" "缺少依赖" "未找到 ffmpeg，请先 brew install ffmpeg"
    exit 1
fi
if [ ! -f "$MODEL" ]; then
    notify "error" "未找到模型" "$MODEL"
    exit 1
fi

if [ "$#" -eq 0 ]; then
    notify "error" "生成字幕失败" "请先选中视频文件"
    exit 0
fi

# 预扫描：筛出真正要处理的文件 + 累计总时长做 ETA
typeset -a todo
typeset -a todo_work
total_secs=0
total_work_units=0
pre_skipped=0
for src in "$@"; do
    if [ ! -f "$src" ]; then
        echo "SKIP not a file: $src"
        pre_skipped=$((pre_skipped+1))
        continue
    fi
    if [ -e "${src%.*}.srt" ]; then
        echo "SKIP exists: ${src%.*}.srt"
        pre_skipped=$((pre_skipped+1))
        continue
    fi
    todo+=("$src")
    dur_int=0
    if command -v ffprobe >/dev/null 2>&1; then
        dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$src" 2>/dev/null)
        dur_int=${dur%.*}
        [ -z "$dur_int" ] && dur_int=0
        total_secs=$((total_secs + dur_int))
    fi
    work_units=$dur_int
    [ "$work_units" -le 0 ] && work_units=60
    todo_work+=("$work_units")
    total_work_units=$((total_work_units + work_units))
done

if [ "${#todo[@]}" -eq 0 ]; then
    notify "success" "没有要处理的文件" "已跳过 $pre_skipped 个"
    exit 0
fi

# 实测 whisper-cpp medium 在 Apple Silicon (Metal) 上约 13x 实时，
# 每个文件再加 2s 的 ffmpeg 抽音 + whisper 启动开销。
eta=$(( total_work_units / 13 + ${#todo[@]} * 2 ))
start_ts=$(/bin/date +%s)

if [ "$total_secs" -gt 0 ]; then
    notify_progress "生成字幕中" "共 ${#todo[@]} 个，预计 $(fmt_time $eta)" 1
else
    notify_progress "生成字幕中" "共 ${#todo[@]} 个，后台运行中" 1
fi

ok=0
fail=0
skipped=$pre_skipped
processed_work_units=0
typeset -a completed_files

for (( i = 1; i <= ${#todo[@]}; i++ )); do
    src="${todo[$i]}"
    stem="${src%.*}"
    srt="$stem.srt"
    file_work="${todo_work[$i]}"

    tmp_base=$(/usr/bin/mktemp -t sr-whisper) || {
        fail=$((fail+1))
        processed_work_units=$((processed_work_units + file_work))
        continue
    }
    tmp_wav="${tmp_base}.wav"

    notify_file_progress "$src" "$i" "抽取音频" 5
    echo "--- ffmpeg: $src"
    if ffmpeg -y -i "$src" -ar 16000 -ac 1 -c:a pcm_s16le "$tmp_wav" -loglevel error; then
        notify_file_progress "$src" "$i" "识别字幕" 12
        echo "--- whisper-cli: $src"
        whisper_start_ts=$(/bin/date +%s)
        whisper_est=$((file_work / 13 + 2))
        [ "$whisper_est" -lt 6 ] && whisper_est=6

        whisper-cli -m "$MODEL" -f "$tmp_wav" -l "$WHISPER_LANG" -ml 46 -osrt -of "$stem" &
        whisper_pid=$!
        while kill -0 "$whisper_pid" 2>/dev/null; do
            /bin/sleep 2
            kill -0 "$whisper_pid" 2>/dev/null || break
            whisper_elapsed=$(( $(/bin/date +%s) - whisper_start_ts ))
            whisper_percent=$((12 + whisper_elapsed * 76 / whisper_est))
            [ "$whisper_percent" -gt 88 ] && whisper_percent=88
            notify_file_progress "$src" "$i" "识别字幕" "$whisper_percent"
        done
        wait "$whisper_pid"
        whisper_status=$?

        if [ "$whisper_status" -eq 0 ]; then
            notify_file_progress "$src" "$i" "整理字幕" 92
            if normalize_srt "$srt"; then
                echo "NORMALIZED: $srt"
            else
                echo "WARN normalize failed, keeping original: $srt"
            fi
            ok=$((ok+1))
            completed_files+=("${src:t}")
            echo "OK: $srt"
            notify_file_progress "$src" "$i" "刷新 Finder" 97
            /usr/bin/osascript -e "tell application \"Finder\" to update (POSIX file \"${src:h}\" as alias)" 2>/dev/null
        else
            fail=$((fail+1))
            echo "FAIL whisper: $src"
        fi
    else
        fail=$((fail+1))
        echo "FAIL ffmpeg: $src"
    fi

    /bin/rm -f "$tmp_base" "$tmp_wav"
    processed_work_units=$((processed_work_units + file_work))
done

end_ts=$(/bin/date +%s)
elapsed=$((end_ts - start_ts))

if [ "$ok" -eq 1 ]; then
    msg="${completed_files[1]} | 用时 $(fmt_time $elapsed)"
else
    msg="$ok 个文件 | 用时 $(fmt_time $elapsed)"
fi
[ "$fail" -gt 0 ] && msg="$msg | 失败 $fail"
[ "$skipped" -gt 0 ] && msg="$msg | 跳过 $skipped"
if [ "$fail" -gt 0 ]; then
    notify "error" "字幕生成完成" "$msg"
else
    notify "success" "字幕生成完成" "$msg"
fi
echo "DONE: ok=$ok fail=$fail skipped=$skipped elapsed=${elapsed}s"
