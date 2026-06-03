#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [stop-subtitles] argc=$# ==="
emulate -L zsh
setopt local_options no_nomatch

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
. "$(dirname "$0")/orb_popover.sh"

STATE_DIR="$(dirname "$0")/subtitle-jobs"

notify() {
    local kind="$1"
    local title="$2"
    local subtitle="$3"
    echo "NOTICE: 停止生成字幕: $title${subtitle:+ | $subtitle}"
    emit_popover "$kind" "stop-subtitles" "$title" "$subtitle"
}

if [ "$#" -eq 0 ]; then
    notify "error" "停止生成字幕失败" "请先选中正在生成字幕的视频"
    exit 0
fi

summary="$(
    /usr/bin/python3 - "$STATE_DIR" "$@" <<'PY'
import json
import os
import signal
import sys
import time

state_dir = sys.argv[1]
targets = set(sys.argv[2:])
jobs = []

def is_running(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False

def stop_pid(pid):
    if not pid:
        return
    pid = int(pid)
    if not is_running(pid):
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    time.sleep(0.4)
    if is_running(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

if os.path.isdir(state_dir):
    for name in os.listdir(state_dir):
        if not name.endswith(".json"):
            continue
        path = os.path.join(state_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                payload = json.load(f)
        except Exception:
            continue
        payload["_stateFile"] = path
        jobs.append(payload)

matched = {}
for job in jobs:
    path = job.get("path")
    if path in targets:
        matched[path] = job

for target in targets:
    job = matched.get(target)
    if not job:
        print(f"fail\t未找到正在生成的字幕: {os.path.basename(target)}")
        continue

    script_pid = job.get("scriptPID")
    child_pid = job.get("childPID")
    if not is_running(script_pid) and not is_running(child_pid):
        try:
            os.unlink(job["_stateFile"])
        except OSError:
            pass
        print(f"fail\t字幕生成任务已结束: {os.path.basename(target)}")
        continue

    stop_pid(child_pid)
    stop_pid(script_pid)

    for tmp in job.get("temporaryFiles") or []:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    try:
        os.unlink(job["_stateFile"])
    except OSError:
        pass

    print(f"ok\t{os.path.basename(target)}")
PY
)"

ok=0
fail=0
first_ok=""
first_reason=""

while IFS=$'\t' read -r result_status value; do
    case "$result_status" in
        ok)
            ok=$((ok+1))
            [ -z "$first_ok" ] && first_ok="$value"
            ;;
        fail)
            fail=$((fail+1))
            [ -z "$first_reason" ] && first_reason="$value"
            ;;
    esac
done <<< "$summary"

if [ "$ok" -gt 0 ]; then
    if [ "$ok" -eq 1 ]; then
        msg="已停止生成字幕: $first_ok"
    else
        msg="已停止生成字幕: $ok 个文件"
    fi
    [ "$fail" -gt 0 ] && msg="$msg | 另有 $fail 个未停止"
    notify "success" "已停止生成字幕" "$msg"
else
    [ -z "$first_reason" ] && first_reason="未找到正在生成的字幕"
    notify "error" "停止生成字幕失败" "$first_reason"
fi

echo "DONE stop subtitles: ok=$ok fail=$fail"
