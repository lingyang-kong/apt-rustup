#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 || ! -f $1 ]]; then
	printf 'Usage: %s PACKAGE.deb\n' "$0" >&2
	exit 2
fi
package=$(realpath -- "$1")
work=$(mktemp --directory)
trap 'rm -rf -- "$work"' EXIT
dpkg-deb --extract "$package" "$work/pkg"
export CARGO_HOME="$work/home/.cargo" RUSTUP_HOME="$work/home/.rustup"
mkdir -p "$CARGO_HOME/bin" "$CARGO_HOME/registry" "$RUSTUP_HOME"
cp "$work/pkg/usr/bin/rustup" "$CARGO_HOME/bin/rustup"
ln -s rustup "$CARGO_HOME/bin/rustc"
ln "$CARGO_HOME/bin/rustup" "$CARGO_HOME/bin/cargo"
printf 'custom\n' >"$CARGO_HOME/bin/custom"
printf 'registry\n' >"$CARGO_HOME/registry/sentinel"
printf 'toolchain\n' >"$RUSTUP_HOME/sentinel"
helper="$work/pkg/usr/lib/rustup/migrate-user-install.sh"
system="$work/pkg/usr/bin/rustup"
"$helper" --system-rustup "$system"
[[ -f $CARGO_HOME/bin/rustup && -L $CARGO_HOME/bin/rustc && -f $CARGO_HOME/bin/cargo ]]
"$helper" --system-rustup "$system" --apply
[[ ! -e $CARGO_HOME/bin/rustup && ! -e $CARGO_HOME/bin/rustc && ! -e $CARGO_HOME/bin/cargo ]]
[[ $(cat "$CARGO_HOME/bin/custom") == custom && $(cat "$CARGO_HOME/registry/sentinel") == registry && $(cat "$RUSTUP_HOME/sentinel") == toolchain ]]
backups=("$CARGO_HOME"/rustup-proxies-backup.*)
[[ ${#backups[@]} == 1 && -f ${backups[0]}/rustup && -L ${backups[0]}/rustc && -f ${backups[0]}/cargo ]]
"$helper" --system-rustup "$system" --apply
printf '%s\n' 'Migration smoke test passed'
