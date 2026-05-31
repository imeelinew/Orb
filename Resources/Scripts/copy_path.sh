#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [copy-path] argc=$# ==="
. "$(dirname "$0")/orb_popover.sh"

if [ "$#" -eq 0 ]; then
    emit_popover "error" "copy-path" "复制路径失败" "没有可复制的路径"
    echo "SKIP: no args"
    exit 0
fi
tmp=$(/usr/bin/mktemp /tmp/sr_clip.XXXXXX) || exit 1
first=1
for p in "$@"; do
    if [ "$first" -eq 1 ]; then
        printf '%s' "$p" > "$tmp"
        first=0
    else
        printf '\n%s' "$p" >> "$tmp"
    fi
done
/usr/bin/osascript -e "set the clipboard to (read (POSIX file \"$tmp\") as «class utf8»)"
/bin/rm -f "$tmp"
if [ "$#" -eq 1 ]; then
    emit_popover "success" "copy-path" "已复制路径" "$1"
else
    joined=""
    for p in "$@"; do
        if [ -z "$joined" ]; then
            joined="$p"
        else
            joined="$joined | $p"
        fi
    done
    emit_popover "success" "copy-path" "已复制路径" "$joined"
fi
echo "OK: path(s) copied"
