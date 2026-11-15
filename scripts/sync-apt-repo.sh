#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
	printf 'Usage: %s PACKAGE_DIR [OUT_DIR] < UPSTREAM_JSON\n' "$0" >&2
	exit 2
fi
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"
# shellcheck source=scripts/history.sh
source "$root/scripts/history.sh"
upstream=$(cat)
fields=$(upstream_fields <<<"$upstream")
IFS=$'\t' read -r version commit source_url <<<"$fields"
package_dir=$(realpath -- "$1")
out=${2:-$root/dist}
out="$(realpath --canonicalize-missing -- "$(dirname -- "$out")")/$(basename -- "$out")"
mkdir -p -- "$(dirname -- "$out")"
exec {output_lock}>"$out.lock"
flock "$output_lock"
exec {package_lock}>"$package_dir/.package.lock"
flock --shared "$package_lock"
if [[ -e $out && ! -L $out ]]; then
	printf 'Refusing to replace non-symlink output: %s\n' "$out" >&2
	exit 1
fi
build=$package_dir/build.json
jq -e --arg version "$version" --arg commit "$commit" --arg url "$source_url" '.version == $version and .commit == $commit and .source_url == $url' "$build" >/dev/null
deb_version=$(jq -er '.deb_version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+-[1-9][0-9]*$"))' "$build")
revision=$(cat "$root/packaging/revision")
recipe=$(package_recipe_sha256)
if [[ $deb_version != "$version-$revision" ]] || ! jq --exit-status --arg recipe "$recipe" '.recipe_sha256 == $recipe' "$build" >/dev/null; then
	printf '%s\n' 'Package receipt does not match the current recipe and revision; rebuild it.' >&2
	exit 1
fi
package="rustup_${deb_version}_amd64.deb"
[[ $(jq -er '.package' "$build") == "$package" ]]
expected_sha=$(jq -er '.package_sha256 | select(test("^[0-9a-f]{64}$"))' "$build")
[[ $(sha256sum "$package_dir/$package" | cut -d ' ' -f 1) == "$expected_sha" ]]
package_matches "$package_dir/$package" "$deb_version"
mkdir -p "$root/.build"
stage=$(mktemp -d "$root/.build/site.XXXXXXXX")
chmod 0755 "$stage"
key_home=''
link_tmp=''
history_work=''
cleanup() {
	if [[ -n $key_home ]]; then
		gpgconf --homedir "$key_home" --kill gpg-agent
		rm -rf -- "$key_home"
	fi
	if [[ -n $link_tmp ]]; then rm -f -- "$link_tmp"; fi
	if [[ -n $history_work ]]; then rm -rf -- "$history_work"; fi
	if [[ -n $stage ]]; then rm -rf -- "$stage"; fi
}
trap cleanup EXIT
if [[ -n ${APT_GPG_PRIVATE_KEY:-} ]]; then
	key_home=$(mktemp -d "$root/.build/signing.XXXXXXXX")
	export GNUPGHOME=$key_home
	chmod 700 "$GNUPGHOME"
	printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --import >/dev/null 2>&1
	unset APT_GPG_PRIVATE_KEY
fi
fingerprints=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "sec" {want=1; next} want && $1 == "fpr" {print $10; want=0}')
if [[ -n ${APT_SIGNING_KEY:-} ]]; then
	fingerprint=$APT_SIGNING_KEY
	if ! printf '%s\n' "$fingerprints" | rg -F -x -q "$fingerprint"; then
		printf '%s\n' 'Signing key fingerprint not found' >&2
		exit 1
	fi
else
	if [[ $(printf '%s\n' "$fingerprints" | rg -c '^[0-9A-F]{40,64}$') != 1 ]]; then
		printf '%s\n' 'Set APT_SIGNING_KEY to one full secret-key fingerprint' >&2
		exit 1
	fi
	fingerprint=$fingerprints
fi
mkdir -p "$stage/pool/main/r/rustup" "$stage/dists/jammy/main/binary-amd64"
install -m 644 "$package_dir/$package" "$stage/pool/main/r/rustup/$package"
gpg --batch --export "$fingerprint" >"$stage/rustup-archive-keyring.gpg"
if [[ -n ${PREVIOUS_ARCHIVE_DIR:-} && -n ${PREVIOUS_ARCHIVE_URL:-} ]]; then
	printf '%s\n' 'Specify only one previous archive source' >&2
	exit 1
fi
if [[ -z ${PREVIOUS_ARCHIVE_DIR:-} && -z ${PREVIOUS_ARCHIVE_URL:-} && -e $out ]]; then PREVIOUS_ARCHIVE_DIR=$out; fi
history_work=$(mktemp -d "$root/.build/history.XXXXXXXX")
if ! retain_history "$history_work" "$deb_version" "$expected_sha"; then
	exit 1
fi
rm -rf -- "$history_work"
history_work=''
max_bytes=${MAX_BYTES:-1000000000}
if [[ ! $max_bytes =~ ^[1-9][0-9]{0,9}$ ]] || ((max_bytes > 1000000000)); then
	printf '%s\n' 'MAX_BYTES must be between 1 and 1000000000.' >&2
	exit 1
fi
printf '%s\n' "$fingerprint" >"$stage/fingerprint.txt"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$root/SECURITY.md" "$stage/"
sed --expression="s|@VERSION@|$version|g" --expression="s|@PACKAGE@|$package|g" \
	--expression="s|@SOURCE_URL@|$source_url|g" --expression="s|@FINGERPRINT@|$fingerprint|g" \
	"$root/templates/index.html" >"$stage/index.html"

gpg_options=(--batch --yes --pinentry-mode loopback --passphrase-fd 3 --local-user "$fingerprint")
write_snapshot() {
	(cd "$stage" && apt-ftparchive packages pool >dists/jammy/main/binary-amd64/Packages)
	gzip -n -c "$stage/dists/jammy/main/binary-amd64/Packages" >"$stage/dists/jammy/main/binary-amd64/Packages.gz"
	rm -f "$stage/dists/jammy/Release" "$stage/dists/jammy/InRelease" "$stage/dists/jammy/Release.gpg"
	(cd "$stage/dists/jammy" && apt-ftparchive -o APT::FTPArchive::Release::Origin='Unofficial Rustup APT' -o APT::FTPArchive::Release::Label='Unofficial Rustup APT' -o APT::FTPArchive::Release::Suite=jammy -o APT::FTPArchive::Release::Codename=jammy -o APT::FTPArchive::Release::Architectures=amd64 -o APT::FTPArchive::Release::Components=main release . >Release)
	passphrase=${APT_GPG_PASSPHRASE:-}
	gpg "${gpg_options[@]}" --clearsign --output "$stage/dists/jammy/InRelease" "$stage/dists/jammy/Release" 3<<<"$passphrase"
	gpg "${gpg_options[@]}" --detach-sign --output "$stage/dists/jammy/Release.gpg" "$stage/dists/jammy/Release" 3<<<"$passphrase"
	gpgv --keyring "$stage/rustup-archive-keyring.gpg" "$stage/dists/jammy/InRelease"
	gpgv --keyring "$stage/rustup-archive-keyring.gpg" "$stage/dists/jammy/Release.gpg" "$stage/dists/jammy/Release"
	local retained_file retained_version
	for retained_file in "$stage"/pool/main/r/rustup/*.deb; do
		retained_version=$(dpkg-deb --field "$retained_file" Version)
		jq --null-input --arg version "$retained_version" --arg path "pool/main/r/rustup/${retained_file##*/}" \
			--arg sha256 "$(sha256sum "$retained_file" | cut --delimiter=' ' --fields=1)" \
			--arg source_commit "$(dpkg-deb --field "$retained_file" X-Rustup-Source-Commit)" \
			--arg source_url "$(dpkg-deb --field "$retained_file" X-Rustup-Source-URL)" \
			'{version:$version,path:$path,sha256:$sha256,source_commit:($source_commit | if length>0 then . else null end),source_url:($source_url | if length>0 then . else null end)}'
	done | jq --slurp --argjson upstream "$upstream" --slurpfile package "$build" \
		--arg recipe "$recipe" --arg fingerprint "$fingerprint" --arg published_at "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
		'{schema:1,upstream:$upstream,package:$package[0],retained_packages:.,recipe_sha256:$recipe,signing_fingerprint:$fingerprint,published_at:$published_at}' >"$stage/releases.json"
}

while :; do
	write_snapshot
	size=$(tar -C "$stage" -cf - . | wc -c)
	if ((size <= max_bytes)); then break; fi
	oldest=$(oldest_history "$deb_version")
	if [[ -z $oldest ]]; then
		printf '%s\n' 'Newest package exceeds archive size limit' >&2
		exit 1
	fi
	rm -- "$stage/pool/main/r/rustup/rustup_${oldest}_amd64.deb"
done
link_tmp="$(dirname "$out")/.rustup-dist-$$"
ln -s "$stage" "$link_tmp"
mv -Tf "$link_tmp" "$out"
link_tmp=''
printf 'Published local archive %s (signing fingerprint %s)\n' "$out" "$fingerprint"
stage=''
