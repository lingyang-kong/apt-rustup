#!/usr/bin/env bash
# shellcheck disable=SC2154
fetch_previous() {
	local path=$1 destination=$2 status
	if [[ -n ${PREVIOUS_ARCHIVE_DIR:-} ]]; then
		cp -- "$PREVIOUS_ARCHIVE_DIR/$path" "$destination" || return 1
	else
		status=$(curl --proto '=https' --tlsv1.2 --silent --show-error --location --retry 3 --output "$destination" --write-out '%{http_code}' "${PREVIOUS_ARCHIVE_URL%/}/$path") || return 1
		if [[ $status != 200 ]]; then
			if [[ $path == dists/jammy/InRelease && $status == 404 ]]; then return 2; fi
			printf 'Previous archive request failed: %s HTTP %s\n' "$path" "$status" >&2
			return 1
		fi
	fi
}

retain_history() {
	local work=$1 current_version=$2 current_sha=$3 path index_sha index_size actual_sha actual_size old_version old_sha old_size file
	if [[ -z ${PREVIOUS_ARCHIVE_DIR:-} && -z ${PREVIOUS_ARCHIVE_URL:-} ]]; then return 0; fi
	if fetch_previous dists/jammy/InRelease "$work/InRelease"; then :; else
		local status=$?
		if ((status == 2)); then return 0; fi
		return "$status"
	fi
	gpgv --keyring "$stage/rustup-archive-keyring.gpg" --output "$work/Release" "$work/InRelease" || return 1
	read -r index_sha index_size < <(awk '/^SHA256:/{in_sha=1;next} /^[^ ]/{in_sha=0} in_sha && $3=="main/binary-amd64/Packages" {print $1, $2}' "$work/Release")
	if [[ ! $index_sha =~ ^[0-9a-f]{64}$ || ! $index_size =~ ^[0-9]+$ ]]; then
		printf '%s\n' 'Signed Release lacks the Packages SHA256 entry' >&2
		return 1
	fi
	fetch_previous dists/jammy/main/binary-amd64/Packages "$work/Packages" || return 1
	actual_sha=$(sha256sum "$work/Packages" | cut -d ' ' -f 1)
	actual_size=$(wc -c <"$work/Packages")
	[[ $actual_sha == "$index_sha" && $actual_size == "$index_size" ]] || return 1
	awk 'BEGIN { RS=""; FS="\n"; OFS="\t" }
      { delete f; for (i=1;i<=NF;i++) if ($i ~ /^(Package|Version|Architecture|Filename|Size|SHA256): /) { k=$i; sub(/:.*/,"",k); if (k in f) exit 1; f[k]=$i; sub(/^[^:]+: /,"",f[k]) }
        if (f["Package"]!="rustup" || f["Architecture"]!="amd64" || !f["Version"] || !f["Filename"] || !f["Size"] || !f["SHA256"]) exit 1;
        print f["Version"],f["Filename"],f["Size"],f["SHA256"] }' "$work/Packages" >"$work/entries" || return 1
	if [[ ! -s $work/entries ]]; then
		printf '%s\n' 'Previous archive has no rustup packages' >&2
		return 1
	fi
	declare -A seen=()
	while IFS=$'\t' read -r old_version path old_size old_sha; do
		[[ $old_version =~ ^[0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*$ && $old_size =~ ^[0-9]+$ && $old_sha =~ ^[0-9a-f]{64}$ ]] || return 1
		[[ $path == "pool/main/r/rustup/rustup_${old_version}_amd64.deb" && -z ${seen[$old_version]+x} ]] || return 1
		seen[$old_version]=1
		if dpkg --compare-versions "$old_version" gt "$current_version"; then
			printf 'Refusing to replace newer published version %s\n' "$old_version" >&2
			return 1
		fi
		if [[ $old_version == "$current_version" && $old_sha != "$current_sha" ]]; then
			printf 'Published package %s has different bytes\n' "$old_version" >&2
			return 1
		fi
		file="$work/previous.deb"
		fetch_previous "$path" "$file" || return 1
		actual_sha=$(sha256sum "$file" | cut -d ' ' -f 1)
		actual_size=$(wc -c <"$file")
		[[ $actual_sha == "$old_sha" && $actual_size == "$old_size" ]] || return 1
		if ! package_matches "$file" "$old_version"; then return 1; fi
		if [[ $old_version != "$current_version" ]]; then install -m 644 "$file" "$stage/$path" || return 1; fi
	done <"$work/entries"
}

oldest_history() {
	local current=$1 path ver oldest=''
	for path in "$stage"/pool/main/r/rustup/*.deb; do
		ver=${path##*/rustup_}
		ver=${ver%_amd64.deb}
		if [[ $ver == "$current" ]]; then continue; fi
		if [[ -z $oldest ]] || dpkg --compare-versions "$ver" lt "$oldest"; then oldest=$ver; fi
	done
	printf '%s\n' "$oldest"
}
