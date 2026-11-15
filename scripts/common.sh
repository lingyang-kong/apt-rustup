#!/usr/bin/env bash
upstream_fields() {
	jq --slurp --exit-status --raw-output '
        select(length == 1) | .[0]
        | select(
            (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
            and (.commit | test("^[0-9a-f]{40}$"))
            and .source_url == ("https://codeload.github.com/rust-lang/rustup/tar.gz/" + .commit)
        )
        | [.version, .commit, .source_url] | @tsv'
}

package_matches() {
	local fields
	# shellcheck disable=SC2016
	if ! fields=$(dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}' "$1"); then
		return 1
	fi
	[[ $fields == $'rustup\t'"$2"$'\tamd64' ]]
}

package_recipe_sha256() (
	if ! cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."; then
		return 1
	fi
	sha256sum scripts/build-package.sh scripts/migrate-user-install.sh packaging/revision | sha256sum | cut --delimiter=' ' --fields=1
)
