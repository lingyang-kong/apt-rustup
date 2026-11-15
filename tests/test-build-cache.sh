#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"
mkdir -p "$root/.build"
work=$(mktemp -d "$root/.build/cache-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/cache/package-cache" "$work/pkg/DEBIAN" "$work/pkg/usr/bin" "$work/out"
version=1.2.3
commit=1111111111111111111111111111111111111111
url="https://codeload.github.com/rust-lang/rustup/tar.gz/$commit"
revision=$(cat "$root/packaging/revision")
deb="$version-$revision"
package="rustup_${deb}_amd64.deb"
recipe=$(package_recipe_sha256)
compiler=$(rustc +stable --version --verbose)
cargo_version=$(cargo +stable --version)
dpkg_version=$(dpkg-deb --version | head -n 1)
key=$(printf '%s\0' '1' "$commit" "$url" "$deb" "$recipe" "$compiler" "$cargo_version" "$dpkg_version" | sha256sum | cut -d ' ' -f 1)
entry="$work/cache/package-cache/$key"
mkdir -p "$entry"
jq -n --arg version "$version" --arg commit "$commit" --arg url "$url" '{version:$version,commit:$commit,source_url:$url}' >"$work/upstream.json"
cat >"$work/pkg/DEBIAN/control" <<CONTROL
Package: rustup
Version: $deb
Architecture: amd64
Maintainer: Test <test@example.invalid>
Description: Fixture
CONTROL
printf '#!/bin/sh\nexit 0\n' >"$work/pkg/usr/bin/rustup"
chmod +x "$work/pkg/usr/bin/rustup"
dpkg-deb --build --root-owner-group "$work/pkg" "$entry/$package" >/dev/null
sha=$(sha256sum "$entry/$package" | cut -d ' ' -f 1)
jq -n --arg version "$version" --arg commit "$commit" --arg source_url "$url" --arg recipe "$recipe" --arg compiler "$compiler" --arg deb "$deb" --arg package "$package" --arg sha "$sha" --arg key "$key" '{version:$version,commit:$commit,source_url:$source_url,recipe_sha256:$recipe,compiler:$compiler,deb_version:$deb,package:$package,package_sha256:$sha,cache_key:$key}' >"$entry/build.json"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
exit 42
CURL
chmod +x "$work/bin/curl"
export PATH="$work/bin:$PATH"
BUILD_DIR="$work/cache" "$root/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >"$work/hit.log"
rg -q 'Reused verified package cache' "$work/hit.log"
test "$(sha256sum "$work/out/$package" | cut -d ' ' -f 1)" = "$sha"
cp "$entry/$package" "$work/valid.deb"
cp "$entry/build.json" "$work/valid.json"
if RUSTFLAGS='-C opt-level=0' BUILD_DIR="$work/cache" "$root/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >"$work/custom.log" 2>&1; then
	printf '%s\n' 'Customized Rust flags reused cached package' >&2
	exit 1
fi
rg -q 'package cache reads and writes disabled' "$work/custom.log"
mkdir -p "$work/caller/.cargo"
printf '[build]\nrustflags = ["-C", "opt-level=0"]\n' >"$work/caller/.cargo/config.toml"
if (cd "$work/caller" && BUILD_DIR="$work/cache" "$root/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >"$work/custom.log" 2>&1); then
	printf '%s\n' 'Cargo configuration reused cached package' >&2
	exit 1
fi
rg -q 'package cache reads and writes disabled' "$work/custom.log"
test "$(sha256sum "$work/out/$package" | cut -d ' ' -f 1)" = "$sha"
exec 7>"$work/out/.package.lock"
flock 7
BUILD_DIR="$work/cache" "$root/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >"$work/concurrent.log" 2>&1 &
builder_pid=$!
sleep 0.2
if ! kill -0 "$builder_pid" 2>/dev/null; then
	printf '%s\n' 'Builder did not wait for the output lock' >&2
	exit 1
fi
flock -u 7
exec 7>&-
wait "$builder_pid"
rg -q 'Reused verified package cache' "$work/concurrent.log"
expect_miss() {
	if BUILD_DIR="$work/cache" "$root/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >/dev/null 2>&1; then
		printf 'Unexpected cache hit: %s\n' "$1" >&2
		exit 1
	fi
	test "$(sha256sum "$work/out/$package" | cut -d ' ' -f 1)" = "$sha"
}
printf 'not json' >"$entry/build.json"
expect_miss 'malformed receipt'
cp "$work/valid.json" "$entry/build.json"
sed -i 's/^Package: rustup$/Package: unrelated/' "$work/pkg/DEBIAN/control"
dpkg-deb --build --root-owner-group "$work/pkg" "$entry/$package" >/dev/null
wrong_sha=$(sha256sum "$entry/$package" | cut -d ' ' -f 1)
jq --arg sha "$wrong_sha" '.package_sha256 = $sha' "$work/valid.json" >"$entry/build.json"
expect_miss 'wrong package identity with matching checksum'
cp "$work/valid.deb" "$entry/$package"
cp "$work/valid.json" "$entry/build.json"
cat >"$work/bin/rustc" <<'RUSTC'
#!/usr/bin/env bash
printf 'different compiler\n'
RUSTC
chmod +x "$work/bin/rustc"
expect_miss 'changed compiler'
rm "$work/bin/rustc"
mkdir -p "$work/copy/scripts" "$work/copy/packaging"
cp "$root/scripts/build-package.sh" "$root/scripts/common.sh" "$root/scripts/migrate-user-install.sh" "$work/copy/scripts/"
cp "$root/packaging/revision" "$work/copy/packaging/"
printf '\n# modified recipe\n' >>"$work/copy/scripts/migrate-user-install.sh"
if BUILD_DIR="$work/cache" "$work/copy/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Changed recipe reused old cache' >&2
	exit 1
fi
cp "$root/scripts/migrate-user-install.sh" "$work/copy/scripts/migrate-user-install.sh"
printf '%s\n' "$((revision + 1))" >"$work/copy/packaging/revision"
if BUILD_DIR="$work/cache" "$work/copy/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Changed revision reused old cache' >&2
	exit 1
fi
if DEB_REVISION="$((revision + 1))" BUILD_DIR="$work/cache" "$root/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Mismatched revision override accepted' >&2
	exit 1
fi
printf corrupt >>"$entry/$package"
if BUILD_DIR="$work/cache" "$root/scripts/build-package.sh" "$work/out" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Corrupted cache entry was accepted' >&2
	exit 1
fi
test "$(sha256sum "$work/out/$package" | cut -d ' ' -f 1)" = "$sha"
printf '%s\n' 'Verified cache reuse, corrupt cache rejection, and failed build preservation passed.'
