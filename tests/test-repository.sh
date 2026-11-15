#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"
mkdir -p "$root/.build"
work=$(mktemp --directory "$root/.build/repository-test.XXXXXXXX")
cleanup() {
	gpgconf --homedir "$work/gnupg" --kill gpg-agent
	rm --recursive --force -- "$work"
}
trap cleanup EXIT
mkdir --mode=0700 "$work/gnupg"
export GNUPGHOME=$work/gnupg
gpg --batch --passphrase '' --quick-generate-key 'APT fixture <fixture@example.invalid>' ed25519 sign 1d >/dev/null 2>&1
export APT_SIGNING_KEY
APT_SIGNING_KEY=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
mkdir -p "$work/pkg/DEBIAN" "$work/pkg/usr/bin" "$work/output" "$work/bin"
revision=$(cat "$root/packaging/revision")
commit=1111111111111111111111111111111111111111
jq --null-input --arg commit "$commit" '{version:"1.2.3",commit:$commit,source_url:("https://codeload.github.com/rust-lang/rustup/tar.gz/"+$commit)}' >"$work/upstream.json"
cat >"$work/pkg/DEBIAN/control" <<CONTROL
Package: rustup
Version: 1.2.3-$revision
Architecture: amd64
Maintainer: Test <test@example.invalid>
Description: Archive test fixture
CONTROL
printf '#!/bin/sh\nexit 0\n' >"$work/pkg/usr/bin/rustup"
chmod u+x "$work/pkg/usr/bin/rustup"
package="rustup_1.2.3-${revision}_amd64.deb"
dpkg-deb --build --root-owner-group "$work/pkg" "$work/output/$package" >/dev/null
sha=$(sha256sum "$work/output/$package" | cut --delimiter=' ' --fields=1)
jq --arg package "$package" --arg sha "$sha" --arg deb_version "1.2.3-$revision" --arg recipe "$(package_recipe_sha256)" '. + {package:$package,package_sha256:$sha,deb_version:$deb_version,recipe_sha256:$recipe}' "$work/upstream.json" >"$work/output/build.json"
"$root/scripts/sync-apt-repo.sh" "$work/output" "$work/dist" <"$work/upstream.json" >"$work/sync.log" 2>&1
test -L "$work/dist"
gpgv --keyring "$work/dist/rustup-archive-keyring.gpg" "$work/dist/dists/jammy/InRelease" >/dev/null 2>&1
rg --quiet "^Filename: pool/main/r/rustup/$package$" "$work/dist/dists/jammy/main/binary-amd64/Packages"
rg --quiet "^SHA256: $sha$" "$work/dist/dists/jammy/main/binary-amd64/Packages"
cp "$work/dist/releases.json" "$work/published.json"
previous=$(readlink "$work/dist")
printf corruption >>"$work/output/$package"
if "$root/scripts/sync-apt-repo.sh" "$work/output" "$work/dist" <"$work/upstream.json" >"$work/rejected.log" 2>&1; then
	printf '%s\n' 'Publisher accepted a corrupted package' >&2
	exit 1
fi
test "$(readlink "$work/dist")" = "$previous"
cat >"$work/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
out=
while (( $# )); do
    case $1 in
        --output) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
if [[ -n $out ]]; then
    if [[ ${FIXTURE_TRANSPORT_FAILURE:-false} == true ]]; then
        exit 7
    fi
    cp "$FIXTURE_MANIFEST" "$out"
    printf '%s' "${FIXTURE_STATUS:-200}"
else
    printf "%s = '%s'\n" \
        'schema-version' '1' \
        'version' '1.2.3'
fi
CURL
cat >"$work/bin/git" <<'GIT'
#!/usr/bin/env bash
printf '2222222222222222222222222222222222222222\trefs/tags/1.2.3\n1111111111111111111111111111111111111111\trefs/tags/1.2.3^{}\n'
GIT
chmod u+x "$work/bin/curl" "$work/bin/git"
export PATH=$work/bin:$PATH FIXTURE_MANIFEST=$work/published.json
"$root/scripts/discover-release.sh" >"$work/discovered.json"
jq --exit-status --arg commit "$commit" '.version=="1.2.3" and .commit==$commit and (.source_url | endswith($commit))' "$work/discovered.json" >/dev/null
test "$("$root/scripts/poll-release.sh" <"$work/upstream.json")" = false
test "$(FIXTURE_STATUS=404 "$root/scripts/poll-release.sh" <"$work/upstream.json")" = true
if FIXTURE_STATUS=503 "$root/scripts/poll-release.sh" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Polling treated a server failure as a new release' >&2
	exit 1
fi
if FIXTURE_TRANSPORT_FAILURE=true "$root/scripts/poll-release.sh" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Polling ignored a transport failure' >&2
	exit 1
fi
jq '.version="1.2.4"' "$work/upstream.json" >"$work/new.json"
test "$("$root/scripts/poll-release.sh" <"$work/new.json")" = true
jq '.recipe_sha256="changed"' "$work/published.json" >"$work/recipe-change.json"
if FIXTURE_MANIFEST="$work/recipe-change.json" "$root/scripts/poll-release.sh" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Polling allowed a package recipe change without a revision increase' >&2
	exit 1
fi
jq '.package.deb_version="9.0.0-1"' "$work/published.json" >"$work/newer.json"
if FIXTURE_MANIFEST="$work/newer.json" "$root/scripts/poll-release.sh" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Polling allowed a package downgrade' >&2
	exit 1
fi
jq '.commit="3333333333333333333333333333333333333333" | .source_url=("https://codeload.github.com/rust-lang/rustup/tar.gz/"+.commit)' "$work/upstream.json" >"$work/moved.json"
if "$root/scripts/poll-release.sh" <"$work/moved.json" >/dev/null 2>&1; then
	printf '%s\n' 'Polling allowed an upstream tag to move at the same package version' >&2
	exit 1
fi
jq '.source_url="https://example.invalid/source"' "$work/upstream.json" >"$work/invalid.json"
if FIXTURE_STATUS=404 "$root/scripts/poll-release.sh" <"$work/invalid.json" >/dev/null 2>&1; then
	printf '%s\n' 'Polling accepted an invalid source URL' >&2
	exit 1
fi
if cat "$work/upstream.json" "$work/upstream.json" | "$root/scripts/poll-release.sh" >/dev/null 2>&1; then
	printf '%s\n' 'Polling accepted multiple upstream releases' >&2
	exit 1
fi
printf 'malformed manifest' >"$work/published.json"
if "$root/scripts/poll-release.sh" <"$work/upstream.json" >/dev/null 2>&1; then
	printf '%s\n' 'Polling accepted malformed published metadata' >&2
	exit 1
fi
printf '%s\n' 'Repository signing, integrity, activation, discovery and polling checks passed.'
