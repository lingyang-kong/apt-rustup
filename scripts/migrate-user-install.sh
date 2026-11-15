#!/usr/bin/env bash
set -euo pipefail

apply=false
system_rustup=/usr/bin/rustup
while [[ $# -gt 0 ]]; do
	case $1 in
	--apply)
		apply=true
		shift
		;;
	--system-rustup)
		if [[ $# -lt 2 || $2 != /* ]]; then
			printf '%s\n' '--system-rustup requires an absolute path' >&2
			exit 2
		fi
		system_rustup=$2
		shift 2
		;;
	*)
		printf 'Usage: %s [--apply] [--system-rustup ABSOLUTE_PATH]\n' "$0" >&2
		exit 2
		;;
	esac
done
cargo_home=${CARGO_HOME:-$HOME/.cargo}
bin_dir="$cargo_home/bin"
old="$bin_dir/rustup"
if [[ ! -x $system_rustup ]]; then
	printf 'Install the APT rustup package first: %s is missing or not executable\n' "$system_rustup" >&2
	exit 1
fi
if [[ ! -e $old ]]; then
	printf '%s\n' 'No user-installed rustup binary found; nothing to migrate.'
	exit 0
fi
if [[ $old -ef $system_rustup ]]; then
	printf '%s\n' 'User rustup already points to the system binary; nothing to migrate.'
	exit 0
fi
if [[ ! -f $old || -L $old ]]; then
	printf '%s\n' 'User rustup is not a regular executable; inspect it before migrating.' >&2
	exit 1
fi
# Isolate the probe; an unpatched binary may attempt self-update.
probe=$(mktemp --directory)
trap 'rm -rf -- "$probe"' EXIT
mkdir -p "$probe/cargo/bin" "$probe/rustup"
cp -- "$system_rustup" "$probe/cargo/bin/rustup"
if probe_output=$(CARGO_HOME="$probe/cargo" RUSTUP_HOME="$probe/rustup" RUSTUP_UPDATE_ROOT='file:///nonexistent' "$probe/cargo/bin/rustup" self update 2>&1); then
	printf '%s\n' 'System rustup did not reject self-update; refusing migration.' >&2
	exit 1
fi
if [[ $probe_output != *"self-update is disabled for this build of rustup"* ]]; then
	printf '%s\n' 'System rustup did not confirm that self-update is disabled; refusing migration.' >&2
	exit 1
fi
files=()
for path in "$bin_dir"/*; do
	if [[ -e $path && $path -ef $old && $path != "$old" ]]; then
		files+=("$path")
	fi
done
files+=("$old")
printf 'User rustup files to move:\n'
printf '  %s\n' "${files[@]}"
if [[ $apply == false ]]; then
	printf '%s\n' 'Dry run: pass --apply to move these files into a backup.'
	exit 0
fi
backup=$(mktemp --directory "$cargo_home/rustup-proxies-backup.XXXXXXXX")
for path in "${files[@]}"; do
	mv -- "$path" "$backup/"
done
printf 'Moved to %s. Existing toolchains and other Cargo data were preserved.\nRun hash -r in this shell, then check command -v rustup rustc cargo.\n' "$backup"
