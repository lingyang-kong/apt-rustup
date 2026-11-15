#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
	printf 'Usage: %s OUTPUT_DIR < UPSTREAM_JSON\n' "$0" >&2
	exit 2
fi
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"
recipe=$(package_recipe_sha256)
fields=$(upstream_fields)
IFS=$'\t' read -r version commit url <<<"$fields"
mkdir -p -- "$1"
out=$(realpath -- "$1")
build_dir=${BUILD_DIR:-$root/.build}
revision=$(cat "$root/packaging/revision")
if [[ ${DEB_REVISION:-$revision} != "$revision" ]]; then
	printf '%s\n' 'DEB_REVISION must match packaging/revision' >&2
	exit 1
fi
if [[ ! $revision =~ ^[1-9][0-9]*$ ]]; then
	printf '%s\n' 'Invalid Debian revision' >&2
	exit 1
fi
if [[ $(dpkg --print-architecture) != amd64 ]]; then
	printf '%s\n' 'Only amd64 is supported' >&2
	exit 1
fi
# shellcheck source=/dev/null
. /etc/os-release
if [[ $ID != ubuntu || $VERSION_ID != 22.04 ]]; then
	printf '%s\n' 'Build on Ubuntu 22.04 to target Jammy' >&2
	exit 1
fi
mkdir -p -- "$build_dir"
build_dir=$(realpath -- "$build_dir")
exec 8>"$build_dir/.build.lock"
flock 8
compiler=$(rustc +stable --version --verbose)
cargo_version=$(cargo +stable --version)
dpkg_version=$(dpkg-deb --version | head -n 1)
deb_version="$version-$revision"
package="rustup_${deb_version}_amd64.deb"
cache_key=$(printf '%s\0' '1' "$commit" "$url" "$deb_version" "$recipe" "$compiler" "$cargo_version" "$dpkg_version" | sha256sum | cut -d ' ' -f 1)
cache="$build_dir/package-cache/$cache_key"
mkdir -p "$build_dir/package-cache"
cache_enabled=true
while IFS= read -r variable; do
	case $variable in
	CARGO_HOME | CARGO_TARGET_DIR) ;;
	CARGO_* | RUSTFLAGS | RUSTDOCFLAGS | RUSTC | RUSTC_* | RUSTDOC | CC | CC_* | CXX | CXX_* | CFLAGS | CFLAGS_* | CXXFLAGS | CXXFLAGS_* | CPPFLAGS | CPPFLAGS_* | LDFLAGS | LDFLAGS_* | AR | AR_* | RANLIB | RANLIB_* | PKG_CONFIG* | OPENSSL_* | LIBCLANG_PATH | BINDGEN_EXTRA_CLANG_ARGS*) cache_enabled=false ;;
	esac
done < <(compgen -e)
cargo_config_home=${CARGO_HOME:-$HOME/.cargo}
if [[ -e $cargo_config_home/config || -e $cargo_config_home/config.toml ]]; then
	cache_enabled=false
fi
config_dir=$PWD
while :; do
	if [[ -e $config_dir/.cargo/config || -e $config_dir/.cargo/config.toml ]]; then
		cache_enabled=false
	fi
	if [[ $config_dir == / ]]; then
		break
	fi
	config_dir=$(dirname -- "$config_dir")
done
if [[ $cache_enabled == false ]]; then
	printf '%s\n' 'Build customization detected; package cache reads and writes disabled.' >&2
fi
publish_output() {
	exec 9>"$out/.package.lock"
	flock 9
	install -m 644 "$1/$package" "$out/.${package}.$$"
	install -m 644 "$1/build.json" "$out/.build.json.$$"
	mv -f -- "$out/.${package}.$$" "$out/$package"
	mv -f -- "$out/.build.json.$$" "$out/build.json"
	flock -u 9
	exec 9>&-
}
if [[ $cache_enabled == true && -f $cache/build.json && -f $cache/$package ]] &&
	jq -e --arg key "$cache_key" --arg version "$version" --arg commit "$commit" --arg url "$url" --arg recipe "$recipe" --arg compiler "$compiler" --arg deb "$deb_version" --arg package "$package" \
		'.cache_key == $key and .version == $version and .commit == $commit and .source_url == $url and .recipe_sha256 == $recipe and .compiler == $compiler and .deb_version == $deb and .package == $package and (.package_sha256 | test("^[0-9a-f]{64}$"))' "$cache/build.json" >/dev/null 2>&1 &&
	[[ $(sha256sum "$cache/$package" | cut -d ' ' -f 1) == "$(jq -r .package_sha256 "$cache/build.json")" ]] &&
	package_matches "$cache/$package" "$deb_version" 2>/dev/null; then
	result=$cache
	printf 'Reused verified package cache %s\n' "$cache_key"
else
	work=$(mktemp --directory "$build_dir/package.XXXXXXXX")
	trap 'rm -rf -- "$work"' EXIT
	result=$work/output
	curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location "$url" --output "$work/source.tar.gz"
	source_sha=$(sha256sum "$work/source.tar.gz" | cut -d ' ' -f 1)
	mkdir "$work/source" "$result"
	tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$work/source"
	if ! rg -q "^version = \"$version\"$" "$work/source/Cargo.toml"; then
		printf '%s\n' 'Source version differs from metadata' >&2
		exit 1
	fi
	SOURCE_DATE_EPOCH=$(stat -c %Y "$work/source/Cargo.toml")
	export SOURCE_DATE_EPOCH
	export CARGO_TARGET_DIR="$build_dir/target"
	cargo +stable build --manifest-path "$work/source/Cargo.toml" --locked --release --features no-self-update
	cargo +stable metadata --manifest-path "$work/source/Cargo.toml" --locked --format-version 1 >"$work/metadata.json"
	pkg="$work/pkg"
	mkdir -p "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/rustup" "$pkg/usr/share/doc/rustup/licenses" "$work/debian"
	install -m 755 "$CARGO_TARGET_DIR/release/rustup-init" "$pkg/usr/bin/rustup"
	install --mode=0755 "$root/scripts/migrate-user-install.sh" "$pkg/usr/lib/rustup/migrate-user-install.sh"
	for tool in rustc rustdoc cargo rust-lldb rust-gdb rust-gdbgui rls cargo-clippy clippy-driver cargo-miri rust-analyzer rustfmt cargo-fmt; do
		ln -s rustup "$pkg/usr/bin/$tool"
	done
	install -m 644 "$work/source/LICENSE-MIT" "$work/source/LICENSE-APACHE" "$pkg/usr/share/doc/rustup/"
	cat >"$pkg/usr/share/doc/rustup/copyright" <<COPYRIGHT
Upstream: rustup, https://github.com/rust-lang/rustup
Copyright: The rustup developers.
License: MIT or Apache-2.0; see LICENSE-MIT and LICENSE-APACHE in this directory.

Rustup incorporates third-party crates. Their declared licenses are listed in
dependencies.tsv; accompanying license and notice files are in licenses/.
COPYRIGHT
	jq -r '.packages[] | [.name, .version, (.license // "see source"), .manifest_path] | @tsv' "$work/metadata.json" |
		while IFS=$'\t' read -r name dep_version license manifest; do
			printf '%s\t%s\t%s\n' "$name" "$dep_version" "$license"
			dep_dir=$(dirname -- "$manifest")
			license_dir="$pkg/usr/share/doc/rustup/licenses/$name-$dep_version"
			for file in "$dep_dir"/LICENSE* "$dep_dir"/COPYING* "$dep_dir"/NOTICE*; do
				if [[ -f $file ]]; then
					mkdir -p "$license_dir"
					cp -- "$file" "$license_dir/"
				fi
			done
		done >"$pkg/usr/share/doc/rustup/dependencies.tsv"
	cat >"$work/debian/control" <<'CONTROL'
Source: rustup
Section: devel
Priority: optional
Homepage: https://github.com/rust-lang/rustup
Maintainer: lingyang-kong <lykong@utexas.edu>
Standards-Version: 4.6.0

Package: rustup
Architecture: amd64
Description: Rust toolchain manager
CONTROL
	depends=$(cd -- "$work" && dpkg-shlibdeps -O "$pkg/usr/bin/rustup" | sed --quiet 's/^shlibs:Depends=//p')
	if [[ -z $depends ]]; then
		printf '%s\n' 'Failed to determine runtime dependencies' >&2
		exit 1
	fi
	cat >"$pkg/DEBIAN/control" <<CONTROL
Package: rustup
Version: $deb_version
Architecture: amd64
Maintainer: lingyang-kong <lykong@utexas.edu>
Section: devel
Priority: optional
Homepage: https://github.com/rust-lang/rustup
Depends: $depends, ca-certificates
Conflicts: rustc, cargo, rustfmt, rust-clippy, rust-gdb, rust-lldb, rust-analyzer, rust-all
X-Rustup-Source-Commit: $commit
X-Rustup-Source-URL: $url
X-Rustup-Source-SHA256: $source_sha
Description: Rust toolchain manager
 Install and manage per-user Rust toolchains. Updates to rustup are supplied
 by APT; toolchains are installed separately by each user.
CONTROL
	find "$pkg" -exec touch --no-dereference --date="@$SOURCE_DATE_EPOCH" {} +
	dpkg-deb --build --root-owner-group "$pkg" "$result/$package"
	package_sha=$(sha256sum "$result/$package" | cut -d ' ' -f 1)
	jq -n --arg version "$version" --arg commit "$commit" --arg source_url "$url" --arg source_sha256 "$source_sha" --arg deb_version "$deb_version" --arg package "$package" --arg package_sha256 "$package_sha" --arg compiler "$compiler" --arg recipe "$recipe" --arg cache_key "$cache_key" '{version:$version,commit:$commit,source_url:$source_url,source_sha256:$source_sha256,deb_version:$deb_version,package:$package,package_sha256:$package_sha256,compiler:$compiler,recipe_sha256:$recipe,cache_key:$cache_key}' >"$result/build.json"
	if [[ $cache_enabled == true ]]; then
		if [[ -e $cache ]]; then
			rm -rf -- "$cache"
		fi
		mv -- "$result" "$cache"
		result=$cache
	fi
fi
publish_output "$result"
