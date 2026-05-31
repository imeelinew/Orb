#!/bin/zsh
LOG="$HOME/Library/Logs/orb.log"
[ "$(/usr/bin/stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && /bin/mv "$LOG" "$LOG.1"
exec >>"$LOG" 2>&1
echo "=== $(date) [git-commit-push] argc=$# ==="
. "$(dirname "$0")/orb_popover.sh"
emulate -L zsh
setopt local_options no_nomatch

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never
export GIT_ASKPASS=/usr/bin/false
export SSH_ASKPASS=/usr/bin/false

notify() {
    echo "NOTICE: 提交并推送当前仓库: $1"
    emit_popover "error" "git-commit-push" "操作失败" "$1"
}

if [ ! -x /usr/bin/git ]; then
    notify "未找到 git"
    exit 1
fi

if [ "$#" -eq 0 ]; then
    notify "请在仓库目录空白处或仓库内文件上使用"
    exit 0
fi

repo=""
for target in "$@"; do
    if [ -d "$target" ]; then
        candidate="$target"
    else
        candidate="${target:h}"
    fi
    candidate="${candidate:A}"

    if [ -z "$repo" ]; then
        repo="$candidate"
    elif [ "$candidate" != "$repo" ]; then
        notify "请只在同一个目录中使用"
        echo "FAIL: multiple target dirs $repo vs $candidate"
        exit 0
    fi
done

if [ ! -e "$repo/.git" ]; then
    notify "当前目录不是 Git 仓库根目录"
    echo "FAIL: no .git in $repo"
    exit 0
fi

if ! top_level=$(/usr/bin/git -C "$repo" rev-parse --show-toplevel 2>/dev/null); then
    notify "无法读取 Git 仓库"
    echo "FAIL: rev-parse show-toplevel in $repo"
    exit 1
fi
top_level="${top_level:A}"
if [ "$top_level" != "$repo" ]; then
    notify "请在 Git 仓库根目录使用"
    echo "FAIL: repo root mismatch top=$top_level current=$repo"
    exit 0
fi

if ! git_dir=$(/usr/bin/git -C "$repo" rev-parse --git-dir 2>/dev/null); then
    notify "无法读取 Git 仓库"
    echo "FAIL: rev-parse git-dir in $repo"
    exit 1
fi
case "$git_dir" in
    /*) ;;
    *) git_dir="$repo/$git_dir" ;;
esac

for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [ -e "$git_dir/$marker" ]; then
        notify "仓库正在进行 Git 操作，请先处理完再提交"
        echo "FAIL: git marker $marker"
        exit 0
    fi
done
for marker_dir in rebase-merge rebase-apply; do
    if [ -e "$git_dir/$marker_dir" ]; then
        notify "仓库正在进行 Git 操作，请先处理完再提交"
        echo "FAIL: git marker $marker_dir"
        exit 0
    fi
done

branch=$(/usr/bin/git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
if [ -z "$branch" ]; then
    notify "当前不在可推送的分支上"
    echo "FAIL: detached HEAD"
    exit 0
fi

if ! /usr/bin/git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    notify "当前分支未设置上游，已取消"
    echo "FAIL: no upstream for branch $branch"
    exit 0
fi

if ! /usr/bin/git -C "$repo" add -A; then
    notify "git add 失败"
    echo "FAIL: git add -A"
    exit 1
fi

if /usr/bin/git -C "$repo" diff --cached --quiet --ignore-submodules --exit-code; then
    notify "没有可提交的改动"
    echo "OK: nothing to commit"
    exit 0
fi

msg="$(/bin/date '+%Y-%m-%d %H:%M:%S')"
if ! /usr/bin/git -C "$repo" commit -m "$msg"; then
    notify "git commit 失败"
    echo "FAIL: git commit"
    exit 1
fi

if ! /usr/bin/git -C "$repo" push; then
    notify "已提交但推送失败，请检查上游分支或远端状态"
    echo "FAIL: git push after commit $msg"
    exit 1
fi

echo "NOTICE: 提交并推送当前仓库: 已提交并推送 | $msg"
emit_popover "success" "git-commit-push" "提交并推送成功" "$msg"
echo "OK: committed and pushed $repo @ $msg"
