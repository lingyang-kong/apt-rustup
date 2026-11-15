#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"
mkdir -p "$root/.build"
work=$(mktemp -d "$root/.build/history-test.XXXXXXXX")
cleanup() {
	gpgconf --homedir "$work/gnupg" --kill gpg-agent
	rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -m 700 "$work/gnupg"
export GNUPGHOME="$work/gnupg"
gpg --batch --passphrase '' --quick-generate-key 'History fixture <history@example.invalid>' ed25519 sign 1d >/dev/null 2>&1
export APT_SIGNING_KEY
APT_SIGNING_KEY=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
mkdir -p "$work/pkg/DEBIAN" "$work/pkg/usr/bin" "$work/output"
revision=$(cat "$root/packaging/revision")
commit=1111111111111111111111111111111111111111
prepare() {
	local version=$1 suffix=${2:-fixture} package sha
	package="rustup_${version}-${revision}_amd64.deb"
	cat >"$work/pkg/DEBIAN/control" <<CONTROL
Package: rustup
Version: $version-$revision
Architecture: amd64
Maintainer: Test <test@example.invalid>
Description: Archive test fixture
CONTROL
	printf '%s\n' "$suffix" >"$work/pkg/usr/bin/rustup"
	dd if=/dev/zero of="$work/pkg/usr/bin/payload" bs=1024 count=128 status=none
	dpkg-deb --build --root-owner-group -Znone "$work/pkg" "$work/output/$package" >/dev/null
	sha=$(sha256sum "$work/output/$package" | cut -d ' ' -f 1)
	jq -n --arg v "$version" --arg c "$commit" '{version:$v,commit:$c,source_url:("https://codeload.github.com/rust-lang/rustup/tar.gz/"+$c)}' >"$work/upstream.json"
	jq --arg package "$package" --arg sha "$sha" --arg deb_version "$version-$revision" --arg recipe "$(package_recipe_sha256)" '. + {package:$package,package_sha256:$sha,deb_version:$deb_version,recipe_sha256:$recipe}' "$work/upstream.json" >"$work/output/build.json"
}
publish() { "$root/scripts/sync-apt-repo.sh" "$work/output" "$work/dist" <"$work/upstream.json" >"$work/log" 2>&1; }
prepare 1.2.3
publish
old_target=$(readlink "$work/dist")
old_package="pool/main/r/rustup/rustup_1.2.3-${revision}_amd64.deb"
prepare 1.2.4
publish
test -f "$work/dist/$old_package"
test -f "$work/dist/pool/main/r/rustup/rustup_1.2.4-${revision}_amd64.deb"
rg -q "^Filename: $old_package$" "$work/dist/dists/jammy/main/binary-amd64/Packages"
second_target=$(readlink "$work/dist")
prepare 1.2.4 changed
if publish; then
	printf '%s\n' 'Accepted different bytes at an existing version' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$second_target"
prepare 1.2.2
if publish; then
	printf '%s\n' 'Accepted a package downgrade' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$second_target"
prepare 1.2.5
printf tamper >>"$second_target/$old_package"
if publish; then
	printf '%s\n' 'Accepted corrupted historical package' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$second_target"
cp "$old_target/$old_package" "$second_target/$old_package"
printf tamper >>"$second_target/dists/jammy/main/binary-amd64/Packages"
if publish; then
	printf '%s\n' 'Accepted corrupted signed index' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$second_target"
gzip -dc "$second_target/dists/jammy/main/binary-amd64/Packages.gz" >"$second_target/dists/jammy/main/binary-amd64/Packages"
cp "$second_target/dists/jammy/InRelease" "$work/valid-InRelease"
sed -i "s/Unofficial Rustup APT/Corrupted Rustup APT/" "$second_target/dists/jammy/InRelease"
if publish; then
	printf '%s\n' 'Accepted corrupted signature' >&2
	exit 1
fi
cp "$work/valid-InRelease" "$second_target/dists/jammy/InRelease"
if MAX_BYTES=1 publish; then
	printf '%s\n' 'Accepted an oversized newest package' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$second_target"
two_package_size=$(tar -C "$second_target" -cf - . | wc -c)
MAX_BYTES=$((two_package_size + 30720)) publish
third_target=$(readlink "$work/dist")
test "$third_target" != "$second_target"
test ! -e "$work/dist/$old_package"
test -f "$work/dist/pool/main/r/rustup/rustup_1.2.4-${revision}_amd64.deb"
test -f "$work/dist/pool/main/r/rustup/rustup_1.2.5-${revision}_amd64.deb"
test -f "$second_target/$old_package"

prepare 1.2.6
exec 9>"$work/dist.lock"
flock 9
(
	touch "$work/publisher-started"
	publish
) 9>&- &
publisher_pid=$!
while [[ ! -e $work/publisher-started ]]; do sleep 0.05; done
sleep 0.2
if ! kill -0 "$publisher_pid"; then
	printf '%s\n' 'Publisher completed while output lock was held' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$third_target"
flock --unlock 9
wait "$publisher_pid"
exec 9>&-
fourth_target=$(readlink "$work/dist")
test "$fourth_target" != "$third_target"
prepare 1.2.5
if publish; then
	printf '%s\n' 'Stale publisher replaced newer archive' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$fourth_target"
mkdir "$work/bin"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
while (( $# )); do
    case $1 in
        --output) : > "$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s' "$FIXTURE_HTTP_STATUS"
CURL
chmod u+x "$work/bin/curl"
prepare 1.2.7
PATH="$work/bin:$PATH" FIXTURE_HTTP_STATUS=404 PREVIOUS_ARCHIVE_URL=https://example.invalid \
	"$root/scripts/sync-apt-repo.sh" "$work/output" "$work/first" <"$work/upstream.json" >"$work/first.log" 2>&1
test -L "$work/first"
if PATH="$work/bin:$PATH" FIXTURE_HTTP_STATUS=503 PREVIOUS_ARCHIVE_URL=https://example.invalid \
	"$root/scripts/sync-apt-repo.sh" "$work/output" "$work/failure" <"$work/upstream.json" >"$work/failure.log" 2>&1; then
	printf '%s\n' 'Accepted a previous-archive server error' >&2
	exit 1
fi
test ! -e "$work/failure"
printf '%s\n' 'Authenticated history and failure preservation checks passed.'
