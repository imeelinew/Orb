#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [ghostty] argc=$# ==="
. "$(dirname "$0")/orb_popover.sh"
for dir in "$@"; do
    if /usr/bin/open -a Ghostty "$dir"; then
        echo "OK: $dir"
        emit_popover "success" "open-ghostty" "已用 Ghostty 打开" "$dir"
    else
        echo "FAIL: $dir"
        emit_popover "error" "open-ghostty" "用 Ghostty 打开失败" "打开失败"
    fi
done
