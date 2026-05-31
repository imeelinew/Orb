#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [txt] argc=$# ==="
. "$(dirname "$0")/orb_popover.sh"
printf 'arg: %s\n' "$@"
for dir in "$@"; do
    name="未命名.txt"
    i=1
    while [ -e "$dir/$name" ]; do
        name="未命名 $i.txt"
        i=$((i+1))
    done
    target="$dir/$name"
    if /usr/bin/touch "$target"; then
        echo "OK: $target"
        emit_popover "success" "new-text" "已新建文本文件" "$target"
        /usr/bin/osascript -e "tell application \"Finder\" to update (POSIX file \"$dir\" as alias)"
    else
        echo "FAIL: $target"
        emit_popover "error" "new-text" "新建文本文件失败" "创建失败"
    fi
done
