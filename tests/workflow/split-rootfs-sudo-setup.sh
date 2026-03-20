#!/bin/sh

set -eu

pidfile="/tmp/eden-split-rootfs-sudo-keepalive.pid"

if [ -f "$pidfile" ]; then
    old_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "${old_pid:-}" ] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
fi

if ! sudo -n true 2>/dev/null; then
    echo "cached sudo session required for disconnect rollback steps; run 'sudo -v' in this terminal, then rerun the workflow"
    exit 1
fi

(
    while true; do
        sudo -n true >/dev/null 2>&1 || exit 0
        sleep 60
    done
) >/dev/null 2>&1 &

echo "$!" > "$pidfile"
echo "sudo-keepalive-started"
