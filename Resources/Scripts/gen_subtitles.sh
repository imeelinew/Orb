#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [gen-subtitles] argc=$# ==="
emulate -L zsh
setopt local_options no_nomatch

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
. "$(dirname "$0")/orb_popover.sh"

MODEL="$HOME/whisper-models/ggml-large-v3-turbo.bin"
WHISPER_LANG="en"
WHISPER_MODEL_SLOT_COUNT=1
LLM_SEGMENTATION_ENABLED=1
LLM_OPENROUTER_API_KEY=""
LLM_OPENROUTER_BASE_URL="https://opencode.ai/zen/go/v1/chat/completions"
LLM_OPENROUTER_MODEL="mimo-v2.5"
LLM_SEGMENTATION_BATCH_SIZE=160
LLM_TRANSLATION_ENABLED=1
LLM_TRANSLATION_BATCH_CUES=80
LLM_TRANSLATION_CONTEXT_CUES=8

CONFIG_FILE="$(dirname "$0")/subtitle-config.json"
if [ -f "$CONFIG_FILE" ]; then
    eval "$(/usr/bin/python3 - "$CONFIG_FILE" <<'PYCFG'
import json, sys, shlex
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    model_file = cfg.get("whisperModel", "ggml-large-v3-turbo.bin")
    lang = cfg.get("whisperLang", "en")
    if lang not in {"zh", "en", "ko", "ja"}:
        lang = "en"
    seg = 1 if cfg.get("llmSegmentationEnabled", True) else 0
    trans = 1 if cfg.get("llmTranslationEnabled", True) else 0
    llm_model = cfg.get("llmModel", "mimo-v2.5")
    llm_url = cfg.get("llmBaseURL", "https://opencode.ai/zen/go/v1/chat/completions")
    import os
    model_path = os.path.expanduser(f"~/whisper-models/{model_file}")
    print(f"MODEL={shlex.quote(model_path)}")
    print(f"WHISPER_LANG={shlex.quote(lang)}")
    print(f"LLM_SEGMENTATION_ENABLED={seg}")
    print(f"LLM_TRANSLATION_ENABLED={trans}")
    print(f"LLM_OPENROUTER_MODEL={shlex.quote(llm_model)}")
    print(f"LLM_OPENROUTER_BASE_URL={shlex.quote(llm_url)}")
except Exception:
    pass
PYCFG
)"
fi

LLM_OPENROUTER_API_KEY="$(/usr/bin/security find-generic-password -s com.eli.Orb -a subtitleLLMAPIKey -w 2>/dev/null || true)"
STATE_DIR="$(dirname "$0")/subtitle-jobs"
MODEL_SLOT_DIR="$STATE_DIR/model-slots"
current_src=""
current_state_file=""
tmp_base=""
tmp_wav=""
srt=""
whisper_log=""
child_pid=""
whisper_model_slot_dir=""
POSTPROCESS_ESTIMATE_SECONDS=8
ETA_ESTIMATING_TEXT="正在估算"
displayed_eta=""

notify() {
    local kind="$1"
    local title="$2"
    local subtitle="$3"
    echo "NOTICE: 生成字幕: $title${subtitle:+ | $subtitle}"
    emit_popover "$kind" "subtitles" "$title" "$subtitle"
}

job_state_file() {
    local src="$1"
    /usr/bin/python3 - "$STATE_DIR" "$src" <<'PY'
import hashlib
import os
import sys

state_dir, path = sys.argv[1], sys.argv[2]
os.makedirs(state_dir, exist_ok=True)
name = hashlib.sha256(path.encode("utf-8")).hexdigest() + ".json"
print(os.path.join(state_dir, name))
PY
}

write_job_state() {
    local stage="$1"
    local active_child_pid="${2:-}"
    [ -n "$current_src" ] || return 0
    current_state_file="$(job_state_file "$current_src")"
    /usr/bin/python3 - "$current_state_file" "$current_src" "$$" "$stage" "$active_child_pid" "$tmp_base" "$tmp_wav" "$srt" "$whisper_log" <<'PY'
import json
import os
import sys
import time

state_file, path, script_pid, stage, child_pid, tmp_base, tmp_wav, srt, whisper_log = sys.argv[1:10]
payload = {
    "path": path,
    "scriptPID": int(script_pid),
    "childPID": int(child_pid) if child_pid else None,
    "stage": stage,
    "updatedAt": time.time(),
    "temporaryFiles": [value for value in (tmp_base, tmp_wav, srt, whisper_log) if value],
}
tmp = state_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)
os.replace(tmp, state_file)
PY
}

whisper_model_slot_count() {
    local count="${WHISPER_MODEL_SLOT_COUNT:-1}"
    case "$count" in
        ''|*[!0-9]*|0)
            count=1
            ;;
    esac
    printf "%d" "$count"
}

release_whisper_model_slot() {
    if [ -n "$whisper_model_slot_dir" ]; then
        /bin/rm -rf "$whisper_model_slot_dir"
        whisper_model_slot_dir=""
    fi
}

acquire_whisper_model_slot() {
    local index="$1"
    local slot_count slot lock_dir lock_pid
    slot_count="$(whisper_model_slot_count)"
    /bin/mkdir -p "$MODEL_SLOT_DIR"

    while true; do
        for (( slot = 1; slot <= slot_count; slot++ )); do
            lock_dir="$MODEL_SLOT_DIR/slot-$slot.lock"
            if /bin/mkdir "$lock_dir" 2>/dev/null; then
                whisper_model_slot_dir="$lock_dir"
                {
                    printf "%s\n" "$$"
                    printf "%s\n" "$current_src"
                    /bin/date +%s
                } > "$lock_dir/owner"
                return 0
            fi

            lock_pid="$(/usr/bin/head -n 1 "$lock_dir/owner" 2>/dev/null || true)"
            if [ -n "$lock_pid" ] && ! /bin/kill -0 "$lock_pid" 2>/dev/null; then
                /bin/rm -rf "$lock_dir"
            fi
        done

        write_job_state "waiting-whisper-slot"
        notify_file_progress "$current_src" "$index" "等待识别队列" 12 "等待模型空闲"
        /bin/sleep 2
    done
}

cleanup_current_job() {
    local dir filename stem ext tmp_video
    if [ -n "$child_pid" ]; then
        /bin/kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
        child_pid=""
    fi
    release_whisper_model_slot
    if [ -n "$tmp_base" ] || [ -n "$tmp_wav" ] || [ -n "$srt" ] || [ -n "$whisper_log" ]; then
        /bin/rm -f "$tmp_base" "$tmp_wav" "$srt" "$whisper_log"
    fi
    if [ -n "$current_src" ]; then
        dir="${current_src:h}"
        filename="${current_src:t}"
        stem="${filename%.*}"
        ext="${filename##*.}"
        tmp_video="$dir/.${stem}.orb-subtitled.$$.$ext"
        /bin/rm -f "$tmp_video"
    fi
    if [ -n "$current_state_file" ]; then
        /bin/rm -f "$current_state_file"
    fi
}

handle_stop_signal() {
    echo "STOP subtitle generation: ${current_src:-unknown}"
    cleanup_current_job
    exit 143
}

trap handle_stop_signal TERM INT

progress_remaining_text() {
    local percent="$1"
    if [ "$percent" -ge 92 ]; then
        printf "即将完成"
    else
        printf "%s" "$ETA_ESTIMATING_TEXT"
    fi
}

notify_progress() {
    local title="$1"
    local subtitle="$2"
    local percent="$3"
    local remaining_override="${4:-}"
    local remaining
    [ "$percent" -lt 1 ] && percent=1
    [ "$percent" -gt 99 ] && percent=99
    if [ -n "$remaining_override" ]; then
        remaining="$remaining_override"
    else
        remaining="$(progress_remaining_text "$percent")"
    fi
    echo "PROGRESS: 生成字幕: $percent% | $title${subtitle:+ | $subtitle} | $remaining"
    emit_popover_progress "subtitles" "$title" "$subtitle" "$percent" "$remaining"
}

notify_file_progress() {
    local src="$1"
    local index="$2"
    local stage="$3"
    local file_percent="$4"
    local remaining_override="${5:-}"
    local file_work="${todo_work[$index]}"
    local completed_scaled percent subtitle

    completed_scaled=$(((processed_work_units + file_work * file_percent / 100) * 100))
    percent=$((completed_scaled / total_work_units))
    subtitle="${index}/${#todo[@]} ${stage}: ${src:t}"
    notify_progress "生成字幕中" "$subtitle" "$percent" "$remaining_override"
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

estimated_file_seconds() {
    local duration="$1"
    local estimate
    [ "$duration" -le 0 ] && duration=60
    estimate=$((duration / 13 + POSTPROCESS_ESTIMATE_SECONDS + 2))
    [ "$estimate" -lt 10 ] && estimate=10
    printf "%d" "$estimate"
}

remaining_queued_seconds() {
    local index="$1"
    local total=0
    local j
    for (( j = index + 1; j <= ${#todo_work[@]}; j++ )); do
        total=$((total + $(estimated_file_seconds "${todo_work[$j]}")))
    done
    printf "%d" "$total"
}

eta_warmup_seconds() {
    local duration="$1"
    local seconds
    [ "$duration" -le 0 ] && duration=60
    seconds=$((duration * 8 / 1000))
    [ "$seconds" -lt 8 ] && seconds=8
    [ "$seconds" -gt 20 ] && seconds=20
    printf "%d" "$seconds"
}

eta_audio_sample_seconds() {
    local duration="$1"
    local seconds
    [ "$duration" -le 0 ] && duration=60
    seconds=$((duration * 15 / 1000))
    [ "$seconds" -lt 30 ] && seconds=30
    [ "$seconds" -gt 90 ] && seconds=90
    printf "%d" "$seconds"
}

parse_whisper_processed_seconds() {
    local log_path="$1"
    [ -s "$log_path" ] || {
        printf "0"
        return 0
    }

    /usr/bin/python3 - "$log_path" <<'PY'
import re
import sys

pattern = re.compile(
    r"\[(\d+):(\d{2}):(\d{2})\.(\d{3})\s*-->\s*"
    r"(\d+):(\d{2}):(\d{2})\.(\d{3})\]"
)
latest = 0.0
with open(sys.argv[1], "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        match = pattern.search(line)
        if not match:
            continue
        h, m, s, ms = map(int, match.groups()[4:8])
        latest = h * 3600 + m * 60 + s + ms / 1000
print(int(latest))
PY
}

resolve_whisper_language() {
    local _log_path="$1"
    local configured_language="${2:-en}"
    case "$configured_language" in
        zh|en|ko|ja) printf "%s" "$configured_language" ;;
        *) printf "en" ;;
    esac
}

smooth_eta_text() {
    local raw_eta="$1"
    local smoothed max_down
    [ "$raw_eta" -lt 1 ] && raw_eta=1

    if [ -z "$displayed_eta" ]; then
        displayed_eta="$raw_eta"
    else
        smoothed=$(((displayed_eta * 7 + raw_eta * 3) / 10))
        max_down=$((displayed_eta / 5))
        [ "$max_down" -lt 20 ] && max_down=20
        if [ "$smoothed" -lt $((displayed_eta - max_down)) ]; then
            smoothed=$((displayed_eta - max_down))
        fi
        [ "$smoothed" -lt 1 ] && smoothed=1
        displayed_eta="$smoothed"
    fi

    printf "约 %s" "$(fmt_time "$displayed_eta")"
}

whisper_eta_text() {
    local log_path="$1"
    local duration="$2"
    local elapsed="$3"
    local index="$4"
    local processed warmup audio_sample speed_times_100 current_remaining queue_remaining total_remaining

    processed="$(parse_whisper_processed_seconds "$log_path")"
    warmup="$(eta_warmup_seconds "$duration")"
    audio_sample="$(eta_audio_sample_seconds "$duration")"

    if [ "$elapsed" -lt "$warmup" ] || [ "$processed" -lt "$audio_sample" ]; then
        printf "%s\t%s" "$ETA_ESTIMATING_TEXT" "$processed"
        return 0
    fi

    speed_times_100=$((processed * 100 / elapsed))
    if [ "$speed_times_100" -le 0 ]; then
        printf "%s\t%s" "$ETA_ESTIMATING_TEXT" "$processed"
        return 0
    fi

    current_remaining=$(((duration - processed) * 100 / speed_times_100 + POSTPROCESS_ESTIMATE_SECONDS))
    [ "$current_remaining" -lt 1 ] && current_remaining=1
    queue_remaining="$(remaining_queued_seconds "$index")"
    total_remaining=$((current_remaining + queue_remaining))
    printf "%s\t%s" "$(smooth_eta_text "$total_remaining")" "$processed"
}

semantic_segment_srt() {
    local srt_path="$1"
    [ "$LLM_SEGMENTATION_ENABLED" = "1" ] || return 1
    [ -s "$srt_path" ] || return 1
    [ -n "$LLM_OPENROUTER_API_KEY" ] || return 1

    /usr/bin/python3 - \
        "$srt_path" \
        "$LLM_OPENROUTER_BASE_URL" \
        "$LLM_OPENROUTER_MODEL" \
        "$LLM_OPENROUTER_API_KEY" \
        "$LLM_SEGMENTATION_BATCH_SIZE" <<'PY'
import json
import os
import re
import sys
import tempfile
import urllib.request

path, base_url, model, api_key, batch_size_text = sys.argv[1:6]
target_batch_tokens = max(80, int(batch_size_text or "320"))
MAX_SEGMENT_MS = 8000
MAX_SEGMENT_CHARS = 130
MAX_SEGMENT_TOKENS = 18
MAX_TOKEN_GAP_MS = 1800
MIN_SPLIT_TOKENS = 3
TOKEN_RE = re.compile(r"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)?|[\u4e00-\u9fff]")
WEAK_END_WORDS = {
    "a", "an", "the", "to", "for", "of", "in", "on", "at", "with", "from", "by",
    "and", "or", "but", "so", "because", "if", "when", "while", "as", "than",
    "like", "that", "this", "these", "those", "your", "my", "our", "their",
    "i", "you", "we", "they", "he", "she", "it", "do", "does", "did", "is",
    "are", "was", "were", "be", "being", "been", "am", "can", "could", "would",
    "should", "will", "gonna", "going", "just", "really", "very",
}

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

def clean_text(lines):
    text = " ".join(line.strip() for line in lines if line.strip())
    return re.sub(r"\s+", " ", text).strip()

def extract_tokens(text):
    return TOKEN_RE.findall(text)

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
            matches = list(TOKEN_RE.finditer(text))
            if matches:
                parsed.append({
                    "start": start,
                    "end": end,
                    "text": text,
                    "tokens": [match.group(0) for match in matches],
                    "matches": matches,
                })
    return parsed

def cue_tokens(cues):
    tokens = []
    for cue_index, cue in enumerate(cues):
        count = len(cue["tokens"])
        duration = max(cue["end"] - cue["start"], count)
        for token_index, match in enumerate(cue["matches"]):
            start = cue["start"] + int(duration * token_index / count)
            end = cue["start"] + int(duration * (token_index + 1) / count)
            tokens.append({
                "text": match.group(0),
                "start": start,
                "end": max(start + 1, end),
                "cue": cue_index,
                "source": cue["text"],
                "text_start": match.start(),
                "text_end": match.end(),
            })
    return tokens

def token_batches(cues):
    batches = []
    current_cues = []
    current_count = 0
    for cue in cues:
        token_count = len(cue["tokens"])
        if current_cues and current_count + token_count > target_batch_tokens:
            batches.append(current_cues)
            current_cues = []
            current_count = 0
        current_cues.append(cue)
        current_count += token_count
    if current_cues:
        batches.append(current_cues)
    return batches

def call_llm(tokens):
    max_tokens = min(1200, max(600, len(tokens) * 4))
    payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": max_tokens,
        "response_format": {"type": "json_object"},
        "messages": [
            {
                "role": "system",
                "content": (
                    "Return only JSON: {\"breaks\":[number]}. Tokens are indexed from 1. "
                    "Choose natural subtitle segment end indexes. The final number must equal "
                    "the token count. Do not output subtitle text. Avoid one-token or two-token "
                    "segments unless they are natural standalone phrases. Keep most segments "
                    "between 4 and 14 tokens; do not create segments longer than 18 tokens unless "
                    "the text is repetitive sound words."
                ),
            },
            {
                "role": "user",
                "content": json.dumps({
                    "token_count": len(tokens),
                    "tokens": [[index, token["text"]] for index, token in enumerate(tokens, 1)],
                }, ensure_ascii=False),
            },
        ],
    }
    request = urllib.request.Request(
        base_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Orb/1.0 (macOS) OpenAI-compatible client",
            "HTTP-Referer": "https://orb.local",
            "X-Title": "Orb Subtitle Semantic Segmentation",
        },
        method="POST",
    )

    def parse_json_content(content):
        content = content.strip()
        if content.startswith("```"):
            content = re.sub(r"^```(?:json)?\s*", "", content)
            content = re.sub(r"\s*```$", "", content)
        if content.startswith("{"):
            return json.loads(content)

        candidates = []
        depth = 0
        start = None
        in_string = False
        escape = False
        for index, ch in enumerate(content):
            if in_string:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_string = False
                continue
            if ch == '"':
                in_string = True
            elif ch == "{":
                if depth == 0:
                    start = index
                depth += 1
            elif ch == "}" and depth:
                depth -= 1
                if depth == 0 and start is not None:
                    candidates.append(content[start:index + 1])
                    start = None

        for candidate in reversed(candidates):
            try:
                return json.loads(candidate)
            except json.JSONDecodeError:
                continue
        raise ValueError("no valid JSON object in LLM response")

    with urllib.request.urlopen(request, timeout=45) as response:
        data = json.loads(response.read().decode("utf-8"))
    message = data["choices"][0]["message"]
    content = (message.get("content") or message.get("reasoning_content") or "").strip()
    return parse_json_content(content)

def validate_breaks(payload, expected_tokens):
    breaks = payload.get("breaks")
    if not isinstance(breaks, list) or not breaks:
        raise ValueError("missing breaks")
    cleaned = []
    previous = 0
    total = len(expected_tokens)
    for value in breaks:
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValueError("break is not an integer")
        if value <= previous or value > total:
            raise ValueError("breaks are not strictly increasing")
        cleaned.append(value)
        previous = value
    if cleaned[-1] != total:
        raise ValueError("breaks do not cover all tokens")
    return repair_breaks(cleaned, expected_tokens)

def plain_join(tokens):
    return " ".join(token["text"] for token in tokens)

def normalized_token_text(token):
    return token["text"].lower().replace("’", "'").strip(".,!?;:，。！？；：")

def is_weak_token_run(tokens):
    if not tokens:
        return False
    if len(tokens) <= 2:
        return True
    last = normalized_token_text(tokens[-1])
    if last in WEAK_END_WORDS:
        return True
    if len(tokens) <= 3 and not has_hard_break_after(tokens[-1]):
        return True
    return False

def repair_breaks(breaks, tokens):
    repaired = list(breaks)
    changed = True
    while changed and len(repaired) > 1:
        changed = False
        start = 0
        for index, end in enumerate(list(repaired)):
            run = tokens[start:end]
            if is_weak_token_run(run):
                if index < len(repaired) - 1:
                    del repaired[index]
                else:
                    del repaired[index - 1]
                changed = True
                break
            start = end
    return repaired

def join_text(left, right):
    if not left:
        return right
    if not right:
        return left
    if left[-1].isspace() or right[0].isspace():
        return left + right
    if re.search(r"[A-Za-z0-9]$", left) and re.search(r"^[A-Za-z0-9]", right):
        return left + " " + right
    return left + right

def token_span_text(tokens):
    if not tokens:
        return ""
    fragments = []
    index = 0
    while index < len(tokens):
        cue = tokens[index]["cue"]
        source = tokens[index]["source"]
        start = tokens[index]["text_start"]
        end = tokens[index]["text_end"]
        index += 1
        while index < len(tokens) and tokens[index]["cue"] == cue:
            end = tokens[index]["text_end"]
            index += 1
        fragment = re.sub(r"\s+", " ", source[start:end]).strip()
        if fragment:
            fragments.append(fragment)
    text = ""
    for fragment in fragments:
        text = join_text(text, fragment)
    return text or plain_join(tokens)

def has_hard_break_after(token):
    tail = token["source"][token["text_end"]:token["text_end"] + 4]
    return bool(re.search(r"[。！？!?；;：:]", tail))

def has_soft_break_after(token):
    tail = token["source"][token["text_end"]:token["text_end"] + 3]
    return bool(re.search(r"[，,、]", tail))

def is_phrase_start(token):
    return token["text"].lower() in {
        "and", "but", "so", "because", "when", "while", "if", "then", "now",
        "okay", "ok", "or", "do", "does", "did", "what", "where", "why", "how",
        "i", "you", "we", "it", "this", "that",
    }

def choose_natural_split(tokens, start, hard_limit):
    lower = start + MIN_SPLIT_TOKENS
    upper = max(lower, hard_limit)
    hard_candidates = []
    soft_candidates = []
    phrase_candidates = []
    for end in range(lower, upper + 1):
        previous = tokens[end - 1]
        next_token = tokens[end] if end < len(tokens) else None
        if has_hard_break_after(previous):
            hard_candidates.append(end)
        elif has_soft_break_after(previous):
            soft_candidates.append(end)
        elif next_token and is_phrase_start(next_token):
            phrase_candidates.append(end)

    if hard_candidates:
        return hard_candidates[-1]
    if soft_candidates:
        return soft_candidates[-1]
    if phrase_candidates:
        return phrase_candidates[-1]
    return upper

def split_token_run(tokens):
    chunks = []
    start = 0
    while start < len(tokens):
        if len(tokens) - start <= MAX_SEGMENT_TOKENS:
            chunks.append(tokens[start:])
            break

        hard_limit = min(len(tokens), start + MAX_SEGMENT_TOKENS)
        while hard_limit > start + MIN_SPLIT_TOKENS:
            candidate = tokens[start:hard_limit]
            candidate_text = token_span_text(candidate)
            candidate_duration = candidate[-1]["end"] - candidate[0]["start"]
            if candidate_duration <= MAX_SEGMENT_MS and len(candidate_text) <= MAX_SEGMENT_CHARS:
                break
            hard_limit -= 1

        if hard_limit <= start + MIN_SPLIT_TOKENS:
            hard_limit = min(len(tokens), start + MAX_SEGMENT_TOKENS)

        end = choose_natural_split(tokens, start, hard_limit)
        chunks.append(tokens[start:end])
        start = end

    chunks = [chunk for chunk in chunks if chunk]
    repaired = []
    for chunk in chunks:
        if repaired and is_weak_token_run(repaired[-1]):
            repaired[-1] = repaired[-1] + chunk
        else:
            repaired.append(chunk)
    if len(repaired) > 1 and is_weak_token_run(repaired[-1]):
        repaired[-2] = repaired[-2] + repaired[-1]
        repaired.pop()
    return repaired

def split_on_time_gaps(tokens):
    if not tokens:
        return []
    runs = []
    current = [tokens[0]]
    for token in tokens[1:]:
        previous = current[-1]
        if token["start"] - previous["end"] > MAX_TOKEN_GAP_MS:
            runs.append(current)
            current = [token]
        else:
            current.append(token)
    if current:
        runs.append(current)
    return runs

def split_long_segment(text, tokens):
    if not tokens:
        return []

    out = []
    for run in split_on_time_gaps(tokens):
        run_text = token_span_text(run)
        duration = run[-1]["end"] - run[0]["start"]
        if duration <= MAX_SEGMENT_MS and len(run_text) <= MAX_SEGMENT_CHARS and len(run) <= MAX_SEGMENT_TOKENS:
            out.append((run[0]["start"], run[-1]["end"], run_text))
            continue

        for chunk in split_token_run(run):
            out.append((chunk[0]["start"], chunk[-1]["end"], token_span_text(chunk)))
    return out

def breaks_to_timed_entries(breaks, tokens):
    out = []
    start = 0
    for end in breaks:
        selected = tokens[start:end]
        if not selected:
            raise ValueError("segment token mapping failed")
        segment = token_span_text(selected)
        out.extend(split_long_segment(segment, selected))
        start = end
    if start != len(tokens):
        raise ValueError("segment token count mismatch")
    return out

def fallback_entries(cues):
    return [(cue["start"], cue["end"], cue["text"]) for cue in cues]

with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
    cues = parse_blocks(f.read())

if len(cues) < 2:
    raise SystemExit(1)

out = []
semantic_batches = 0
for batch in token_batches(cues):
    tokens = cue_tokens(batch)
    try:
        payload = call_llm(tokens)
        breaks = validate_breaks(payload, tokens)
        out.extend(breaks_to_timed_entries(breaks, tokens))
        semantic_batches += 1
    except Exception as error:
        print(f"WARN semantic batch fallback: {error}", file=sys.stderr)
        out.extend(fallback_entries(batch))

if not out or semantic_batches == 0:
    raise SystemExit(1)

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".sr-semantic-", suffix=".srt", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        for index, (start, end, text) in enumerate(out, 1):
            f.write(f"{index}\n")
            f.write(f"{fmt_time_ms(start)} --> {fmt_time_ms(end)}\n")
            f.write(text)
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

normalize_srt() {
    local srt_path="$1"
    local source_lang="${2:-en}"
    [ -s "$srt_path" ] || return 0

    /usr/bin/python3 - "$srt_path" "$source_lang" <<'PY'
import os
import re
import sys
import tempfile
import unicodedata

MAX_LINE_WIDTH = 24.0
MAX_CUE_WIDTH = 46.0
MIN_CUE_MS = 900
SHORT_CUE_JOIN_GAP_MS = 500
NO_LINE_START = set("，。！？；：、,.!?;:%)]}》」』”’")
TOKEN_RE = re.compile(
    r"[A-Za-zÀ-ÖØ-öø-ÿĀ-ɏ0-9]+(?:['’][A-Za-zÀ-ÖØ-öø-ÿĀ-ɏ0-9]+)?"
    r"|[\u0400-\u052f]+"
    r"|[\uac00-\ud7af]+"
    r"|[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff]"
)
REPEAT_BOUNDARY_PUNCTUATION = set("，。！？；：、,.!?;:")
WORD_TRAILING_PUNCTUATION = set("，。！？；：、,.!?;:%)]}》」』”’")
WEAK_END_WORDS = {
    "a", "an", "the", "to", "for", "of", "in", "on", "at", "with", "from", "by",
    "and", "or", "but", "so", "because", "if", "when", "while", "as", "than",
    "like", "that", "this", "these", "those", "your", "my", "our", "their",
    "i", "you", "we", "they", "he", "she", "it", "do", "does", "did", "is",
    "are", "was", "were", "be", "being", "been", "am", "can", "could", "would",
    "should", "will", "gonna", "going", "just", "really", "very", "kind",
}

path = sys.argv[1]
source_lang = (sys.argv[2] if len(sys.argv) > 2 else "en").lower()
if source_lang not in ("zh", "en", "ko", "ja"):
    source_lang = "en"
english_like = source_lang == "en"
uses_word_spacing = source_lang in ("en", "ko")

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

def join_text(left, right):
    if not left:
        return right
    if not right:
        return left
    if left[-1].isspace() or right[0].isspace():
        return left + right
    if uses_word_spacing and right[0].isalnum() \
            and (left[-1].isalnum() or left[-1] in WORD_TRAILING_PUNCTUATION):
        return left + " " + right
    return left + right

def token_count(text):
    return len(TOKEN_RE.findall(text))

def ends_with_weak_word(text):
    tokens = TOKEN_RE.findall(text)
    if not tokens:
        return False
    return tokens[-1].lower().replace("’", "'").strip(".,!?;:，。！？；：") in WEAK_END_WORDS

def split_units(text):
    if re.search(r"\s", text):
        return re.findall(r"\S+\s*", text)
    return list(text)

def split_long_unit(unit, limit):
    chunks = []
    buf = []
    current = 0.0
    for ch in unit.strip():
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

def merge_single_tail(chunks, limit):
    if len(chunks) < 2 or (token_count(chunks[-1]) > 1 and not ends_with_weak_word(chunks[-2])):
        return chunks
    combined = join_text(chunks[-2], chunks[-1])
    if width(combined) <= limit * 1.35:
        chunks[-2] = combined
        chunks.pop()
    return chunks

def split_by_width(text, limit):
    chunks = []
    current = ""
    for unit in split_units(text):
        candidate = join_text(current, unit)
        if current and width(candidate) > limit:
            if ends_with_weak_word(current) and width(candidate) <= limit * 1.35:
                current = candidate
                continue
            chunks.append(current.strip())
            current = unit.strip()
        elif not current and width(unit) > limit:
            chunks.extend(split_long_unit(unit, limit))
            current = ""
        else:
            current = candidate
    if current.strip():
        chunks.append(current.strip())
    return merge_single_tail([chunk for chunk in chunks if chunk], limit)

def clean_text(lines):
    text = " ".join(line.strip() for line in lines if line.strip())
    return re.sub(r"\s+", " ", text).strip()

def text_tokens(text):
    return TOKEN_RE.findall(text)

def minimum_repeated_tokens(text):
    if source_lang in ("zh", "ja"):
        return 12
    if source_lang == "ko":
        return 6
    return 8

def repetition_key(text):
    tokens = text_tokens(text)
    if len(tokens) < minimum_repeated_tokens(text):
        return ""
    return " ".join(
        token.lower().replace("’", "'").strip(".,!?;:，。！？；：")
        for token in tokens
    )

def collapse_repeated_phrase_text(text):
    min_repeated_tokens = minimum_repeated_tokens(text)
    changed = True
    while changed:
        changed = False
        matches = list(TOKEN_RE.finditer(text))
        keys = [
            match.group(0).lower().replace("’", "'").strip(".,!?;:，。！？；：")
            for match in matches
        ]
        max_run = len(keys) // 2
        for run_length in range(max_run, min_repeated_tokens - 1, -1):
            for start in range(0, len(keys) - run_length * 2 + 1):
                left = keys[start:start + run_length]
                right = keys[start + run_length:start + run_length * 2]
                if left != right:
                    continue
                remove_start = matches[start + run_length].start()
                remove_end = matches[start + run_length * 2 - 1].end()
                left = text[:remove_start].rstrip()
                right = text[remove_end:].lstrip()
                if left and right and left[-1] in REPEAT_BOUNDARY_PUNCTUATION \
                        and right[0] in REPEAT_BOUNDARY_PUNCTUATION:
                    left = left.rstrip("".join(REPEAT_BOUNDARY_PUNCTUATION)).rstrip()
                text = join_text(left, right)
                text = re.sub(r"\s+", " ", text).strip()
                changed = True
                break
            if changed:
                break
    return text

def remove_repeated_phrase_runs(blocks):
    if len(blocks) < 3:
        return blocks

    cleaned = []
    index = 0
    while index < len(blocks):
        start, end, text = blocks[index]
        key = repetition_key(text)
        if not key:
            cleaned.append(blocks[index])
            index += 1
            continue

        run_end = index + 1
        while run_end < len(blocks) and repetition_key(blocks[run_end][2]) == key:
            run_end += 1

        cleaned.append(blocks[index])
        if run_end - index >= 3:
            index = run_end
        else:
            index += 1
    return cleaned

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
    return split_by_width(text, limit)

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
        candidate = join_text(current, piece)
        if current and width(candidate) > MAX_CUE_WIDTH:
            if ends_with_weak_word(current) and width(candidate) <= MAX_CUE_WIDTH * 1.25:
                current = candidate
                continue
            cues.append(current)
            current = piece
        else:
            current = candidate
    if current:
        cues.append(current)
    return cues or [text]

def coalesce_chunks(chunks, max_count):
    if len(chunks) <= max_count:
        return chunks

    groups = []
    for index in range(max_count):
        lower = index * len(chunks) // max_count
        upper = (index + 1) * len(chunks) // max_count
        combined = ""
        for chunk in chunks[lower:upper]:
            combined = join_text(combined, chunk)
        groups.append(combined)
    return groups

def wrap_lines(text):
    if width(text) <= MAX_LINE_WIDTH:
        return [text]

    lines = split_by_width(text, MAX_LINE_WIDTH)
    return lines or [text]

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

def can_join(left, right):
    left_start, left_end, left_text = left
    right_start, right_end, right_text = right
    if right_start - left_end > SHORT_CUE_JOIN_GAP_MS:
        return False
    combined = join_text(left_text, right_text)
    return right_end > left_start and width(combined) <= MAX_CUE_WIDTH * 1.8

def merge_short_cues(blocks):
    if len(blocks) < 2:
        return blocks

    out = []
    index = 0
    while index < len(blocks):
        current = blocks[index]
        current_tokens = text_tokens(current[2])
        if len(current_tokens) <= 1:
            prev_ok = bool(out) and can_join(out[-1], current)
            next_ok = index + 1 < len(blocks) and can_join(current, blocks[index + 1])

            if prev_ok:
                prev_start, _prev_end, prev_text = out[-1]
                out[-1] = (prev_start, current[1], join_text(prev_text, current[2]))
                index += 1
                continue

            if next_ok:
                next_start, next_end, next_text = blocks[index + 1]
                out.append((current[0], next_end, join_text(current[2], next_text)))
                index += 2
                continue

        out.append(current)
        index += 1

    return out

def output_text(lines):
    return re.sub(r"\s+", " ", " ".join(lines)).strip()

def is_weak_output_cue(entry):
    _start, _end, lines = entry
    text = output_text(lines)
    return token_count(text) <= 2 or ends_with_weak_word(text)

def can_merge_output(left, right):
    left_start, left_end, left_lines = left
    right_start, right_end, right_lines = right
    if right_start - left_end > SHORT_CUE_JOIN_GAP_MS:
        return False
    combined = join_text(output_text(left_lines), output_text(right_lines))
    return right_end > left_start and width(combined) <= MAX_CUE_WIDTH * 1.8

def merge_weak_output_cues(entries):
    if len(entries) < 2:
        return entries
    out = []
    index = 0
    while index < len(entries):
        current = entries[index]
        if is_weak_output_cue(current):
            prev_ok = bool(out) and can_merge_output(out[-1], current)
            next_ok = index + 1 < len(entries) and can_merge_output(current, entries[index + 1])

            if prev_ok:
                prev_start, _prev_end, prev_lines = out[-1]
                merged = join_text(output_text(prev_lines), output_text(current[2]))
                out[-1] = (prev_start, current[1], wrap_lines(merged))
                index += 1
                continue

            if next_ok:
                next_start, next_end, next_lines = entries[index + 1]
                merged = join_text(output_text(current[2]), output_text(next_lines))
                out.append((current[0], next_end, wrap_lines(merged)))
                index += 2
                continue

        out.append(current)
        index += 1
    return out

with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
    source = f.read()

blocks = parse_blocks(source)
if not blocks:
    sys.exit(0)
blocks = [(start, end, collapse_repeated_phrase_text(text)) for start, end, text in blocks]
blocks = remove_repeated_phrase_runs(blocks)
if english_like:
    blocks = merge_short_cues(blocks)

out = []
for start, end, text in blocks:
    duration = end - start
    chunks = coalesce_chunks(split_text(text), max(1, duration))
    weights = [max(width(chunk), 1.0) for chunk in chunks]
    remaining_weight = max(sum(weights), 1.0)
    cursor = start

    for index, chunk in enumerate(chunks):
        if index == len(chunks) - 1:
            chunk_end = end
        else:
            remaining_chunks = len(chunks) - index - 1
            available = end - cursor
            minimum_ms = MIN_CUE_MS if available >= MIN_CUE_MS * (remaining_chunks + 1) else 1
            ideal_ms = int(round(available * weights[index] / remaining_weight))
            maximum_ms = available - remaining_chunks
            chunk_ms = min(max(minimum_ms, ideal_ms), maximum_ms)
            chunk_end = cursor + chunk_ms

        out.append((cursor, chunk_end, wrap_lines(chunk)))
        cursor = chunk_end
        remaining_weight -= weights[index]

if english_like:
    out = merge_weak_output_cues(out)

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

translate_srt_to_bilingual() {
    local srt_path="$1"
    local source_lang="${2:-en}"
    [ "$LLM_TRANSLATION_ENABLED" = "1" ] || return 0
    [ -s "$srt_path" ] || return 0
    [ -n "$LLM_OPENROUTER_API_KEY" ] || return 0

    /usr/bin/python3 - \
        "$srt_path" \
        "$LLM_OPENROUTER_BASE_URL" \
        "$LLM_OPENROUTER_MODEL" \
        "$LLM_OPENROUTER_API_KEY" \
        "$LLM_TRANSLATION_BATCH_CUES" \
        "$LLM_TRANSLATION_CONTEXT_CUES" \
        "$source_lang" <<'PY'
import json
import os
import re
import sys
import tempfile
import unicodedata
import urllib.request

path, base_url, model, api_key, batch_size_text, context_size_text, source_lang = sys.argv[1:8]
batch_size = max(10, int(batch_size_text or "80"))
context_size = max(0, int(context_size_text or "8"))
source_lang = (source_lang or "en").lower()
MAX_ZH_LINE_WIDTH = 28.0

def parse_time(value):
    match = re.match(r"(\d+):(\d{2}):(\d{2}),(\d{3})", value.strip())
    if not match:
        raise ValueError(f"bad srt timestamp: {value!r}")
    h, m, s, ms = map(int, match.groups())
    return ((h * 60 + m) * 60 + s) * 1000 + ms

def clean_text(lines):
    text = " ".join(line.strip() for line in lines if line.strip())
    return re.sub(r"\s+", " ", text).strip()

def char_width(ch):
    if ch.isspace():
        return 0.5
    return 1.0 if unicodedata.east_asian_width(ch) in ("W", "F", "A") else 0.55

def width(text):
    return sum(char_width(ch) for ch in text)

def wrap_zh(text):
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    if width(text) <= MAX_ZH_LINE_WIDTH:
        return [text]

    parts = []
    buf = ""
    for ch in text:
        candidate = buf + ch
        if buf and width(candidate) > MAX_ZH_LINE_WIDTH and ch not in "，。！？；：、,.!?;:%)]}》」』”’":
            parts.append(buf.strip())
            buf = ch
        else:
            buf = candidate
    if buf.strip():
        parts.append(buf.strip())
    if len(parts) <= 2:
        return parts

    first = parts[0]
    rest = "".join(parts[1:])
    return [first, rest] if rest else [first]

def parse_blocks(raw):
    blocks = re.split(r"\n\s*\n", raw.strip(), flags=re.MULTILINE)
    parsed = []
    for fallback_index, block in enumerate(blocks, 1):
        lines = [line.rstrip("\r") for line in block.splitlines() if line.strip()]
        if not lines:
            continue
        time_index = next((i for i, line in enumerate(lines) if "-->" in line), -1)
        if time_index < 0:
            continue
        start_text, end_text = [part.strip().split()[0] for part in lines[time_index].split("-->", 1)]
        parse_time(start_text)
        parse_time(end_text)
        cue_id = int(lines[0]) if lines[0].isdigit() else fallback_index
        en_lines = lines[time_index + 1:]
        en_text = clean_text(en_lines)
        if en_text:
            parsed.append({
                "id": cue_id,
                "time": lines[time_index],
                "en_lines": en_lines,
                "en": en_text,
                "zh": "",
            })
    return parsed

def parse_json_content(content):
    content = content.strip()
    if content.startswith("```"):
        content = re.sub(r"^```(?:json)?\s*", "", content)
        content = re.sub(r"\s*```$", "", content)
    if content.startswith("{"):
        try:
            return json.loads(content)
        except json.JSONDecodeError:
            pass

    candidates = []
    depth = 0
    start = None
    in_string = False
    escape = False
    for index, ch in enumerate(content):
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = index
            depth += 1
        elif ch == "}" and depth:
            depth -= 1
            if depth == 0 and start is not None:
                candidates.append(content[start:index + 1])
                start = None

    for candidate in reversed(candidates):
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue
    raise ValueError("no valid JSON object in LLM response")

def call_llm(payload):
    request = urllib.request.Request(
        base_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Orb/1.0 (macOS) OpenAI-compatible client",
            "HTTP-Referer": "https://orb.local",
            "X-Title": "Orb Bilingual Subtitle Translation",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.loads(response.read().decode("utf-8"))
    message = data["choices"][0]["message"]
    content = (message.get("content") or message.get("reasoning_content") or "").strip()
    return parse_json_content(content)

def source_language_name():
    names = {
        "en": "English",
        "ja": "Japanese",
        "zh": "Chinese",
        "ko": "Korean",
        "fr": "French",
        "de": "German",
        "es": "Spanish",
        "it": "Italian",
        "pt": "Portuguese",
        "ru": "Russian",
    }
    return names.get(source_lang, "source-language")

def translation_system_prompt():
    base = (
        "Return only JSON: {\"translations\":[{\"id\":number,\"zh\":\"...\"}]}. "
        f"Translate the target {source_language_name()} subtitle cues into natural Simplified Chinese. "
        "Use surrounding context to keep names, terms, pronouns, style, and repeated concepts consistent. "
        "Return translations only for target ids. Preserve item count and ids. "
    )
    if source_lang == "ja":
        return (
            base
            + "Preserve the soft ASMR and roleplay tone. Do not over-explain, do not invent missing details, "
            + "and keep short interjections natural in Chinese."
        )
    if source_lang == "en":
        return base + "Do not translate ASMR sound words too literally; keep them natural and concise."
    return base + "Do not over-explain or invent missing details; keep the subtitle concise."

def translate_batch(cues, start, end):
    translations, failures = translate_batch_range(cues, start, end)
    if failures:
        print(
            f"WARN bilingual translation partial fallback: {failures} cue(s) kept English-only",
            file=sys.stderr,
        )
    return translations

def translate_batch_range(cues, start, end):
    context_start = max(0, start - context_size)
    context_end = min(len(cues), end + context_size)
    target_ids = [cue["id"] for cue in cues[start:end]]
    context = [{"id": cue["id"], "en": cue["en"]} for cue in cues[context_start:context_end]]
    targets = [{"id": cue["id"], "en": cue["en"]} for cue in cues[start:end]]
    char_count = sum(len(item["en"]) for item in context)
    max_tokens = min(8000, max(1800, int(char_count * 1.4) + 1200))
    payload = {
        "model": model,
        "temperature": 0.2,
        "max_tokens": max_tokens,
        "response_format": {"type": "json_object"},
        "messages": [
            {
                "role": "system",
                "content": translation_system_prompt(),
            },
            {
                "role": "user",
                "content": json.dumps({
                    "target_ids": target_ids,
                    "context": context,
                    "targets": targets,
                }, ensure_ascii=False),
            },
        ],
    }
    expected = set(target_ids)
    last_error = None
    for attempt in range(2):
        try:
            response = call_llm(payload)
            translations = response.get("translations")
            if not isinstance(translations, list):
                raise ValueError("missing translations")
            by_id = {}
            for item in translations:
                if not isinstance(item, dict):
                    raise ValueError("translation item is not an object")
                cue_id = item.get("id")
                zh = re.sub(r"\s+", " ", str(item.get("zh", ""))).strip()
                if cue_id in by_id or cue_id not in expected or not zh:
                    raise ValueError("translation id mismatch")
                by_id[cue_id] = zh
            if set(by_id) != expected:
                raise ValueError("translation ids incomplete")
            return by_id, 0
        except Exception as error:
            last_error = error
            if attempt == 0:
                continue

    if end - start > 1:
        mid = start + (end - start) // 2
        print(
            f"WARN bilingual translation batch split: ids {target_ids[0]}-{target_ids[-1]} failed: {last_error}",
            file=sys.stderr,
        )
        left, left_failures = translate_batch_range(cues, start, mid)
        right, right_failures = translate_batch_range(cues, mid, end)
        merged = {}
        merged.update(left)
        merged.update(right)
        return merged, left_failures + right_failures

    print(f"WARN bilingual translation cue fallback: id {target_ids[0]} failed: {last_error}", file=sys.stderr)
    return {}, 1

with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
    cues = parse_blocks(f.read())

if not cues:
    raise SystemExit(0)

for start in range(0, len(cues), batch_size):
    end = min(len(cues), start + batch_size)
    translations = translate_batch(cues, start, end)
    for cue in cues[start:end]:
        cue["zh"] = translations.get(cue["id"], "")

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".sr-bilingual-", suffix=".srt", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        for index, cue in enumerate(cues, 1):
            lines = list(cue["en_lines"])
            zh_lines = wrap_zh(cue["zh"])
            if zh_lines:
                lines.extend(zh_lines)
            f.write(f"{index}\n")
            f.write(cue["time"])
            f.write("\n")
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

file_extension() {
    printf "%s" "${1##*.}" | /usr/bin/tr "[:upper:]" "[:lower:]"
}

subtitle_codec_for() {
    local src="$1"
    case "$(file_extension "$src")" in
        mp4|m4v|mov)
            printf "mov_text"
            ;;
        mkv)
            printf "copy"
            ;;
        *)
            return 1
            ;;
    esac
}

subtitle_stream_count() {
    local src="$1"
    if ! command -v ffprobe >/dev/null 2>&1; then
        printf "0"
        return
    fi
    ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$src" 2>/dev/null \
        | /usr/bin/wc -l \
        | /usr/bin/tr -d " "
}

has_orb_subtitles() {
    local src="$1"
    command -v ffprobe >/dev/null 2>&1 || return 1
    ffprobe -v error -select_streams s -show_entries stream_tags -of default=nw=1:nk=1 "$src" 2>/dev/null \
        | /usr/bin/grep -Fqi "Orb Subtitles"
}

embed_subtitles() {
    local src="$1"
    local srt="$2"
    local codec existing_subtitle_count subtitle_index dir filename stem ext tmp_video

    codec="$(subtitle_codec_for "$src")" || return 2
    existing_subtitle_count="$(subtitle_stream_count "$src")"
    [ -z "$existing_subtitle_count" ] && existing_subtitle_count=0
    subtitle_index="$existing_subtitle_count"

    dir="${src:h}"
    filename="${src:t}"
    stem="${filename%.*}"
    ext="${filename##*.}"
    tmp_video="$dir/.${stem}.orb-subtitled.$$.$ext"

    echo "--- embed subtitles: $src"
    if [ "$codec" = "mov_text" ]; then
        ffmpeg -y -loglevel error \
            -i "$src" -i "$srt" \
            -map 0 -map 1 \
            -map_metadata 0 -map_chapters 0 \
            -c copy -c:s mov_text \
            "-metadata:s:s:${subtitle_index}" "title=Orb Subtitles" \
            "-metadata:s:s:${subtitle_index}" "handler_name=Orb Subtitles" \
            "-disposition:s:${subtitle_index}" default \
            "$tmp_video" &
    else
        ffmpeg -y -loglevel error \
            -i "$src" -i "$srt" \
            -map 0 -map 1 \
            -map_metadata 0 -map_chapters 0 \
            -c copy -c:s copy \
            "-metadata:s:s:${subtitle_index}" "title=Orb Subtitles" \
            "-metadata:s:s:${subtitle_index}" "handler_name=Orb Subtitles" \
            "-disposition:s:${subtitle_index}" default \
            "$tmp_video" &
    fi
    child_pid=$!
    write_job_state "embed-subtitles" "$child_pid"
    wait "$child_pid"
    embed_status=$?
    child_pid=""

    if [ "$embed_status" -ne 0 ]; then
        /bin/rm -f "$tmp_video"
        return 1
    fi

    /bin/mv -f "$tmp_video" "$src"
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
    if ! subtitle_codec_for "$src" >/dev/null; then
        echo "SKIP unsupported container: $src"
        pre_skipped=$((pre_skipped+1))
        continue
    fi
    if has_orb_subtitles "$src"; then
        echo "SKIP embedded Orb subtitles exist: $src"
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

# whisper.cpp large-v3-turbo on Apple Silicon (Metal) is fast enough for optimistic ETA.
eta=0
for work_units in "${todo_work[@]}"; do
    eta=$((eta + $(estimated_file_seconds "$work_units")))
done
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
    current_src="$src"
    current_state_file="$(job_state_file "$current_src")"
    stem="${src%.*}"
    file_work="${todo_work[$i]}"

    tmp_base=$(/usr/bin/mktemp -t sr-whisper) || {
        fail=$((fail+1))
        processed_work_units=$((processed_work_units + file_work))
        continue
    }
    tmp_wav="${tmp_base}.wav"
    srt="${tmp_base}.srt"
    whisper_log="${tmp_base}.whisper.log"
    displayed_eta=""

    notify_file_progress "$src" "$i" "抽取音频" 5 "$ETA_ESTIMATING_TEXT"
    echo "--- ffmpeg: $src"
    ffmpeg -y -i "$src" -ar 16000 -ac 1 -c:a pcm_s16le "$tmp_wav" -loglevel error &
    child_pid=$!
    write_job_state "extract-audio" "$child_pid"
    wait "$child_pid"
    ffmpeg_status=$?
    child_pid=""
    if [ "$ffmpeg_status" -eq 0 ]; then
        acquire_whisper_model_slot "$i"
        notify_file_progress "$src" "$i" "识别字幕" 12 "$ETA_ESTIMATING_TEXT"
        echo "--- whisper-cli: $src"
        whisper_start_ts=$(/bin/date +%s)
        whisper_est=$((file_work / 13 + 2))
        [ "$whisper_est" -lt 6 ] && whisper_est=6

        whisper-cli -m "$MODEL" -f "$tmp_wav" -l "$WHISPER_LANG" -ml 46 -osrt -of "$tmp_base" > >(/usr/bin/tee -a "$whisper_log") 2>&1 &
        child_pid=$!
        write_job_state "recognize-subtitles" "$child_pid"
        while kill -0 "$child_pid" 2>/dev/null; do
            /bin/sleep 2
            kill -0 "$child_pid" 2>/dev/null || break
            whisper_elapsed=$(( $(/bin/date +%s) - whisper_start_ts ))
            eta_result="$(whisper_eta_text "$whisper_log" "$file_work" "$whisper_elapsed" "$i")"
            IFS=$'\t' read -r remaining_text processed_audio <<< "$eta_result"
            if [ -n "$processed_audio" ] && [ "$processed_audio" -gt 0 ]; then
                whisper_percent=$((12 + processed_audio * 76 / file_work))
            else
                whisper_percent=$((12 + whisper_elapsed * 76 / whisper_est))
            fi
            [ "$whisper_percent" -gt 88 ] && whisper_percent=88
            [ "$whisper_percent" -lt 12 ] && whisper_percent=12
            write_job_state "recognize-subtitles" "$child_pid"
            notify_file_progress "$src" "$i" "识别字幕" "$whisper_percent" "$remaining_text"
        done
        wait "$child_pid"
        whisper_status=$?
        child_pid=""
        release_whisper_model_slot

        if [ "$whisper_status" -eq 0 ]; then
            detected_lang="$(resolve_whisper_language "$whisper_log" "$WHISPER_LANG")"
            echo "DETECTED LANGUAGE: $detected_lang"
            if [ "$detected_lang" = "en" ]; then
                notify_file_progress "$src" "$i" "语义分句" 90 "正在整理"
                if semantic_segment_srt "$srt"; then
                    echo "SEMANTIC SEGMENTED: $srt"
                else
                    echo "WARN semantic segmentation failed, using local normalization: $srt"
                fi
            else
                echo "SKIP semantic segmentation for non-English language: $detected_lang"
            fi
            notify_file_progress "$src" "$i" "整理字幕" 92 "即将完成"
            write_job_state "normalize-subtitles"
            if normalize_srt "$srt" "$detected_lang"; then
                echo "NORMALIZED: $srt"
            else
                echo "WARN normalize failed, keeping original: $srt"
            fi
            if [[ "$detected_lang" == zh* ]]; then
                echo "SKIP bilingual translation for Chinese source language: $detected_lang"
            else
                notify_file_progress "$src" "$i" "翻译字幕" 93 "正在整理"
                write_job_state "translate-subtitles"
                if translate_srt_to_bilingual "$srt" "$detected_lang"; then
                    echo "BILINGUAL TRANSLATED: $srt"
                else
                    echo "WARN bilingual translation failed, keeping source-language subtitles: $srt"
                fi
            fi
            notify_file_progress "$src" "$i" "封装字幕" 96 "即将完成"
            if embed_subtitles "$src" "$srt"; then
                ok=$((ok+1))
                completed_files+=("${src:t}")
                echo "OK embedded subtitles: $src"
                notify_file_progress "$src" "$i" "刷新 Finder" 98 "即将完成"
                /usr/bin/osascript -e "tell application \"Finder\" to update (POSIX file \"${src:h}\" as alias)" 2>/dev/null
            else
                fail=$((fail+1))
                fallback_srt="$stem.srt"
                if /bin/cp -f "$srt" "$fallback_srt"; then
                    echo "FAIL embed subtitles, kept fallback: $fallback_srt"
                else
                    echo "FAIL embed subtitles: $src"
                fi
            fi
        else
            fail=$((fail+1))
            echo "FAIL whisper: $src"
        fi
    else
        fail=$((fail+1))
        echo "FAIL ffmpeg: $src"
    fi

    cleanup_current_job
    current_src=""
    current_state_file=""
    tmp_base=""
    tmp_wav=""
    srt=""
    whisper_log=""
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
