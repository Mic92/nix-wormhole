#!/usr/bin/env bash
# nix-copy-closure over croc.
set -euo pipefail

usage() {
	cat <<EOF
nix-wormhole - send Nix store closures through croc

Usage:
  nix-wormhole send PATH [PATH...]   Export the closure of PATH(s) and send it
  nix-wormhole receive [CODE]        Receive a closure and import it

PATH may be a /nix/store path or a symlink to one (e.g. ./result).

Importing unsigned store paths requires root or a trusted-user
(see nix.conf), so the receiving side may need:
  sudo nix-wormhole receive
EOF
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
	trap 'rm -rf "$tmp"' EXIT

	# Friendly file name: first root without the store hash prefix
	local name
	name=$(basename "${paths[0]}")
	name=${name#*-}
	local file="$tmp/${name:-closure}.closure.zst"

	echo "Computing closure..." >&2
	local closure=()
	mapfile -t closure < <(nix-store --query --requisites "${paths[@]}")
	echo "Exporting ${#closure[@]} store paths..." >&2
	nix-store --export "${closure[@]}" | zstd -q -T0 --long=27 -o "$file"
	echo "Compressed closure: $(du -h "$file" | cut -f1)" >&2
	echo >&2

	local code
	code=$(printf 'nix-%04d-%04d-%04d' \
		"$(($(rand4) % 10000))" "$(($(rand4) % 10000))" "$(($(rand4) % 10000))")

	cat >&2 <<-EOF
		Code is: $code
		On the other computer run:

		    nix run github:pinpox/nix-wormhole -- receive $code

	EOF

	# --no-compress: payload is already zstd. Code goes via env (croc refuses
	# secrets on argv). Banner is ours (above), so strip croc's own, which
	# tells the receiver to run plain 'croc'.
	CROC_SECRET=$code croc --no-compress send "$file" 2>&1 | strip_banner >&2
}

rand4() {
	od -An -N4 -tu4 /dev/urandom | tr -d ' '
}

strip_banner() {
	local l
	while IFS= read -r l; do
		l=${l##*$'\r'} # keep only the final segment of \r-overwritten lines
		case $l in
		# the getcroc.com URL is the last banner line we drop; everything
		# after it (clipboard note, transfer progress) streams through raw
		*getcroc.com*) exec cat ;;
		"Code is:"* | "On the other computer run"* | *"croc nix-"*) ;;
		*CROC_SECRET* | "(For "* | "Or receive in a browser:"* | "") ;;
		*) printf '%s\n' "$l" ;;
		esac
	done
}

receive() {
	tmp=$(mktemp -d) # global: EXIT trap fires after function scope ends
	trap 'rm -rf "$tmp"' EXIT

	# croc only takes the code via env or interactive prompt, not argv
	if [ $# -ge 1 ]; then
		(cd "$tmp" && CROC_SECRET=$1 croc --yes)
	else
		(cd "$tmp" && croc --yes)
	fi

	local file
	file=$(find "$tmp" -maxdepth 1 -type f | head -n 1)
	if [ -z "$file" ]; then
		echo "error: no file received" >&2
		exit 1
	fi

	echo "Importing into Nix store..." >&2
	local imported
	imported=$(zstd -qdc --long=27 "$file" | nix-store --import)

	echo "Imported $(wc -l <<<"$imported") store path(s). Root:" >&2
	tail -n 1 <<<"$imported"
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
