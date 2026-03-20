#!/bin/sh

set -eu

pidfile="/tmp/eden-split-rootfs-sudo-keepalive.pid"

if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
fi

echo "sudo-keepalive-stopped"
