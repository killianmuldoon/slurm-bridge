#!/busybox/sh
# SPDX-FileCopyrightText: Copyright (C) SchedMD LLC.
# SPDX-License-Identifier: Apache-2.0

# Debug images run this as PID 1 instead of running Delve directly. It starts
# Delve for the current component binary and treats SIGHUP as a request to
# promote the synced replacement binary, restart Delve, and keep the pod alive.

set -eu

if [ "$#" -lt 3 ]; then
	echo "usage: $0 BINARY NEXT_BINARY DEBUG_PORT [-- APP_ARGS...]" >&2
	exit 2
fi

bin="$1"
next="$2"
port="$3"
shift 3

if [ "${1:-}" = "--" ]; then
	shift
fi

app_args="$*"
child=""
reloaded=false
continue="${DEBUG_CONTINUE:-true}"

start() {
	if [ ! -x "$bin" ]; then
		echo "debug binary is missing or not executable: $bin" >&2
		exit 1
	fi

	echo "starting delve for $bin on :$port"
	if [ "$continue" = "false" ]; then
		# This dev-only wrapper intentionally supports simple whitespace-delimited args.
		/dlv --listen=":$port" --headless=true --api-version=2 --accept-multiclient exec "$bin" -- $app_args &
	else
		/dlv --listen=":$port" --headless=true --api-version=2 --accept-multiclient --continue=true exec "$bin" -- $app_args &
	fi
	child="$!"
}

stop() {
	if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
		kill "$child" 2>/dev/null || true
		wait "$child" 2>/dev/null || true
	fi
	child=""
}

promote_next() {
	if [ ! -f "$next" ]; then
		echo "no pending debug binary at $next; restarting current binary"
		return
	fi

	tmp="${bin}.new"
	cp "$next" "$tmp"
	chmod +x "$tmp"
	mv "$tmp" "$bin"
	rm -f "$next"
	echo "promoted debug binary from $next to $bin"
}

reload() {
	echo "received SIGHUP; restarting delve"
	reloaded=true
	stop
	promote_next
	start
}

shutdown() {
	stop
	exit 0
}

trap reload HUP
trap shutdown INT TERM

start

while true; do
	status=0
	wait "$child" || status="$?"
	if [ "$reloaded" = "true" ]; then
		reloaded=false
		continue
	fi
	exit "$status"
done
