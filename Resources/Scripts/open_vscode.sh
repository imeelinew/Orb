#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [vscode] argc=$# ==="
. "$(dirname "$0")/orb_popover.sh"
for dir in "$@"; do
    if /usr/bin/open -a "Visual Studio Code" "$dir"; then
        echo "OK: $dir"
        emit_popover "success" "open-vscode" "已用 VS Code 打开" "$dir"
    else
        echo "FAIL: $dir"
        emit_popover "error" "open-vscode" "用 VS Code 打开失败" "打开失败"
    fi
done
