#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 0 ]]; then
	printf 'Usage: %s\n' "$0" >&2
	exit 2
fi
channel=$(curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 https://static.rust-lang.org/rustup/release-stable.toml)
version=$(sed -n "s/^version = '\([0-9][0-9.]*\)'$/\1/p" <<<"$channel")
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	printf '%s\n' 'Invalid upstream stable release metadata' >&2
	exit 1
fi
refs=$(git ls-remote --exit-code --tags https://github.com/rust-lang/rustup.git "refs/tags/$version" "refs/tags/$version^{}")
commit=$(awk '$2 ~ /\^\{\}$/ {print $1}' <<<"$refs")
if [[ -z $commit ]]; then
	commit=$(awk '{print $1}' <<<"$refs")
fi
if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
	printf '%s\n' 'Could not resolve the upstream release to one commit' >&2
	exit 1
fi
jq --compact-output --null-input --arg version "$version" --arg commit "$commit" \
	'{version:$version, commit:$commit, source_url:("https://codeload.github.com/rust-lang/rustup/tar.gz/" + $commit)}'
