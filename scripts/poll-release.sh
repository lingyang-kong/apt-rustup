#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 0 ]]; then
	printf 'Usage: %s < UPSTREAM_JSON\n' "$0" >&2
	exit 2
fi
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"
fields=$(upstream_fields)
IFS=$'\t' read -r version commit _source_url <<<"$fields"
revision=$(cat "$root/packaging/revision")
recipe=$(package_recipe_sha256)
published=$(mktemp)
trap 'rm --force -- "$published"' EXIT
url=${PUBLISHED_MANIFEST_URL:-https://lingyang-kong.github.io/apt-rustup/releases.json}
# File output lets curl discard failed response bodies before retrying.
status=$(curl --proto '=https' --tlsv1.2 --silent --show-error --location --retry 3 --output "$published" --write-out '%{http_code}' "$url")
case $status in
404)
	printf 'true\n'
	exit 0
	;;
200) ;;
*)
	printf 'Published manifest request failed: HTTP %s\n' "$status" >&2
	exit 1
	;;
esac
fields=$(jq --slurp --exit-status --raw-output '
    select(length == 1) | .[0] | select(.schema == 1)
    | [.upstream.version, .upstream.commit, .recipe_sha256, .package.deb_version]
    | select(all(.[]; type == "string" and length > 0)) | @tsv' "$published")
IFS=$'\t' read -r published_upstream published_commit published_recipe published_version <<<"$fields"
if dpkg --compare-versions "$version-$revision" lt "$published_version"; then
	printf '%s\n' 'Refusing to publish a package downgrade.' >&2
	exit 1
fi
if [[ $published_version == "$version-$revision" && ($published_commit != "$commit" || $published_recipe != "$recipe") ]]; then
	printf '%s\n' 'Source or package recipe changed; increase packaging/revision before publishing.' >&2
	exit 1
fi
if [[ $published_upstream == "$version" && $published_commit == "$commit" && $published_recipe == "$recipe" && $published_version == "$version-$revision" ]]; then
	printf 'false\n'
else
	printf 'true\n'
fi
