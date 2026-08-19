#!/usr/bin/env bash
# nix-copy-closure over dumbpipe, served by a signing harmonia binary cache.
set -euo pipefail

usage() {
	cat <<EOF
nix-wormhole - serve Nix store closures through dumbpipe

Usage:
  nix-wormhole send PATH [PATH...]              Serve PATH(s) via a signed
                                                harmonia cache over dumbpipe
  nix-wormhole receive TICKET PUBKEY PATH...    Substitute the closure
                                                through the tunnel

PATH may be a /nix/store path or a symlink to one (e.g. ./result).

The sender generates a one-shot signing key; harmonia signs every narinfo
with it, and the receiver passes the matching public key to nix via
'trusted-public-keys'. Overriding that option still requires root or a
trusted-user (on standard NixOS, @wheel is already trusted), so the
receiving side may need:
  sudo nix-wormhole receive ...
EOF
}

pick_port() {
	local port
	while :; do
		port=$((20000 + RANDOM % 40000))
		if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
			echo "$port"
			return
		fi
	done
}

wait_port() {
	local port=$1 _i
	for _i in $(seq 1 100); do
		if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
			return 0
		fi
		sleep 0.1
	done
	echo "error: service on port $port did not come up" >&2
	return 1
}

send() {
	if [ $# -lt 1 ]; then
		usage >&2
		exit 1
	fi

	local paths=() p real
	for p in "$@"; do
		real=$(readlink -f "$p")
		case $real in
		/nix/store/*) paths+=("$real") ;;
		*)
			echo "error: '$p' is not a Nix store path" >&2
			exit 1
			;;
		esac
	done

	tmp=$(mktemp -d) # global: EXIT trap fires after function scope ends
	trap 'rm -rf "$tmp"; kill 0' EXIT INT TERM

	# harmonia signs narinfos on the fly, so no 'nix store sign' needed
	local pubkey
	nix --extra-experimental-features nix-command key generate-secret \
		--key-name "nix-wormhole-$$-1" >"$tmp/secret"
	chmod 600 "$tmp/secret"
	pubkey=$(nix --extra-experimental-features nix-command \
		key convert-secret-to-public <"$tmp/secret")

	cat >"$tmp/harmonia.toml" <<-EOF
		bind = "unix:$tmp/cache.sock"
		# 50 loses against cache.nixos.org (40)
		priority = 50
		sign_key_paths = ["$tmp/secret"]
	EOF

	echo "Starting harmonia binary cache..." >&2
	CONFIG_FILE=$tmp/harmonia.toml harmonia-cache >&2 &
	while [ ! -S "$tmp/cache.sock" ]; do sleep 0.1; done

	dumbpipe listen-unix --socket-path "$tmp/cache.sock" >"$tmp/dumbpipe.log" 2>&1 &
	local ticket=
	while [ -z "$ticket" ]; do
		sleep 0.1
		ticket=$(sed -n 's/.*connect-unix .* \([a-z0-9]*\)$/\1/p' "$tmp/dumbpipe.log")
	done

	cat >&2 <<-EOF

		On the other computer run:

		    nix run github:pinpox/nix-wormhole -- receive \\
		        $ticket \\
		        '$pubkey' \\
		        ${paths[*]}

		Serving; press Ctrl-C when the receiver is done.
	EOF
	wait
}

receive() {
	if [ $# -lt 3 ]; then
		usage >&2
		exit 1
	fi
	local ticket=$1 pubkey=$2
	shift 2

	local port
	port=$(pick_port)
	echo "Opening tunnel to sender..." >&2
	dumbpipe connect-tcp --addr "127.0.0.1:$port" "$ticket" >&2 &
	trap 'kill %1 2>/dev/null' EXIT
	wait_port "$port"

	echo "Substituting closure (public paths via your normal caches)..." >&2
	nix-store --realise \
		--option extra-substituters "http://127.0.0.1:$port" \
		--option extra-trusted-public-keys "$pubkey" \
		"$@" >/dev/null

	echo "Done:" >&2
	printf '%s\n' "$@"
}

case ${1:-} in
send)
	shift
	send "$@"
	;;
receive | recv)
	shift
	receive "$@"
	;;
-h | --help | help)
	usage
	;;
*)
	usage >&2
	exit 1
	;;
esac
