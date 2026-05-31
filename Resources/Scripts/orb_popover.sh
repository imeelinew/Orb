#!/bin/zsh

ORB_EVENT_DIR="$HOME/Library/Application Scripts/com.eli.Orb.FinderSync"
ORB_EVENT_FILE="$ORB_EVENT_DIR/popover-event.txt"

emit_popover() {
    /bin/mkdir -p "$ORB_EVENT_DIR"
    local tmp="$ORB_EVENT_FILE.$$"
    {
        print -r -- "$1"
        print -r -- "$2"
        print -r -- "$3"
        print -r -- "$4"
        /bin/date +%s
    } > "$tmp"
    /bin/mv "$tmp" "$ORB_EVENT_FILE"
}
