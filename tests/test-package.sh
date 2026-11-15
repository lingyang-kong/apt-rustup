#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 || ! -f $1 ]]; then
	printf 'Usage: %s PACKAGE.deb\n' "$0" >&2
	exit 2
fi
package=$(realpath -- "$1")
sysroot=$(rustc --print sysroot)
work=$(mktemp --directory)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/pkg" "$work/home" "$work/cargo" "$work/rustup"
dpkg-deb --extract "$package" "$work/pkg"
export CARGO_HOME="$work/cargo" RUSTUP_HOME="$work/rustup"
export PATH="$work/pkg/usr/bin:/usr/bin:/bin"
printf 'preserve\n' >"$CARGO_HOME/existing-file"
rustup --version
if rustup self update >"$work/self-update.log" 2>&1; then
	printf '%s\n' 'Self-update unexpectedly succeeded' >&2
	exit 1
fi
if ! rg -q 'disabled|package manager' "$work/self-update.log"; then
	cat "$work/self-update.log" >&2
	exit 1
fi
if rustup self uninstall -y >"$work/self-uninstall.log" 2>&1; then
	printf '%s\n' 'Self-uninstall unexpectedly succeeded' >&2
	exit 1
fi
rustup toolchain link local-test "$sysroot"
rustup default local-test
rustc --version
cargo --version
if [[ $(cat "$CARGO_HOME/existing-file") != preserve ]]; then
	printf '%s\n' 'Existing Cargo home data was changed' >&2
	exit 1
fi
for tool in rustc rustdoc cargo rust-lldb rust-gdb rust-gdbgui rls cargo-clippy clippy-driver cargo-miri rust-analyzer rustfmt cargo-fmt; do
	if [[ $(readlink "$work/pkg/usr/bin/$tool") != rustup ]]; then
		printf 'Missing rustup proxy: %s\n' "$tool" >&2
		exit 1
	fi
done
printf '%s\n' 'Package smoke test passed'
