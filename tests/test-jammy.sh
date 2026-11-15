#!/usr/bin/env bash
# End-to-end APT test in a disposable Ubuntu 22.04 userspace, without host root.
set -euo pipefail
if [[ $# != 1 ]]; then
	printf 'usage: %s DIST_DIR\n' "$0" >&2
	exit 2
fi
archive=$(realpath "$1")
test -f "$archive/rustup-archive-keyring.gpg"
test -f "$archive/dists/jammy/InRelease"
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$repo_dir/.build/downloads"
work=$(mktemp -d "$repo_dir/.build/jammy-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
base=ubuntu-base-22.04.5-base-amd64.tar.gz
base_url=https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release
cache="$repo_dir/.build/downloads/$base"
curl --fail --silent --show-error --location "$base_url/SHA256SUMS" -o "$work/SHA256SUMS"
if [[ ! -f $cache ]]; then
	curl --fail --silent --show-error --location "$base_url/$base" -o "$work/$base"
	mv "$work/$base" "$cache"
fi
(
	cd "$(dirname "$cache")"
	grep -F "*$base" "$work/SHA256SUMS" | sha256sum --check --status
)
mkdir "$work/root"
unshare --user --map-root-user --mount --pid --fork bash -s -- "$work" "$archive" "$cache" <<'INNER'
set -euo pipefail
work=$1
archive=$2
cache=$3
root=$work/root
mount --make-rprivate /
tar --extract --gzip --no-same-owner --file "$cache" --directory "$root"
mkdir -p "$root/archive" "$root/proc" "$root/dev"
mount --bind "$archive" "$root/archive"
mount --rbind /dev "$root/dev"
mount -t proc proc "$root/proc"
cp --dereference /etc/resolv.conf "$root/etc/resolv.conf"
cp "$archive/rustup-archive-keyring.gpg" "$root/usr/share/keyrings/rustup-archive-keyring.gpg"
printf '%s\n' 'deb [signed-by=/usr/share/keyrings/rustup-archive-keyring.gpg] file:/archive jammy main' > "$root/etc/apt/sources.list.d/rustup.list"
chroot "$root" bash -s <<'CHROOT'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export CARGO_HOME=/root/.cargo RUSTUP_HOME=/root/.rustup
export LC_ALL=C
printf 'APT::Sandbox::User "root";\n' > /etc/apt/apt.conf.d/99sandbox-test
mv /usr/share/keyrings/rustup-archive-keyring.gpg /tmp/valid-key.gpg
touch /usr/share/keyrings/rustup-archive-keyring.gpg
if apt-get update -o APT::Update::Error-Mode=any; then
    printf '%s\n' 'APT accepted the archive without its signing key' >&2
    exit 1
fi
mv /tmp/valid-key.gpg /usr/share/keyrings/rustup-archive-keyring.gpg
apt-get update -o APT::Update::Error-Mode=any
apt-get install --yes --no-install-recommends build-essential ca-certificates
for name in rustc cargo; do
    mkdir -p "/tmp/$name/DEBIAN" "/tmp/$name/usr/bin"
    printf '%s: %s\n' \
        'Package' "$name" \
        'Version' '1.0-1' \
        'Architecture' 'amd64' \
        'Maintainer' 'Test <test@example.invalid>' \
        'Description' 'test fixture' > "/tmp/$name/DEBIAN/control"
    printf '#!/bin/sh\nexit 0\n' > "/tmp/$name/usr/bin/$name"
    chmod +x "/tmp/$name/usr/bin/$name"
    dpkg-deb --build "/tmp/$name" "/tmp/$name.deb"
    dpkg -i "/tmp/$name.deb"
done
apt-get install --yes rustup
if dpkg-query -W -f='${db:Status-Status}\n' rustc cargo | grep -qx installed; then
    printf '%s\n' 'Old compiler or cargo package remains installed' >&2
    exit 1
fi
/usr/bin/rustup --version
if /usr/bin/rustup self update; then
    printf '%s\n' 'packaged rustup unexpectedly allows self-update' >&2
    exit 1
fi
/usr/bin/rustup toolchain install stable --profile minimal
/usr/bin/rustup default stable
mkdir -p /root/test-project/src
printf '[package]\nname = "smoke"\nversion = "0.1.0"\nedition = "2021"\n' > /root/test-project/Cargo.toml
printf 'fn main() { println!("smoke"); }\n' > /root/test-project/src/main.rs
/usr/bin/rustc --version
(cd /root/test-project; /usr/bin/cargo run --offline)
printf preserved > /root/.rustup/test-sentinel
printf preserved > /root/.cargo/test-sentinel
# Exercise a real dpkg revision upgrade.
version=$(dpkg-query -W -f='${Version}' rustup)
package="/archive/pool/main/r/rustup/rustup_${version}_amd64.deb"
test -f "$package"
dpkg-deb --raw-extract "$package" /tmp/upgrade
sed -i "s/^Version: .*/Version: ${version}+test1/" /tmp/upgrade/DEBIAN/control
dpkg-deb --build /tmp/upgrade /tmp/upgrade.deb
dpkg -i /tmp/upgrade.deb
test "$(cat /root/.rustup/test-sentinel)" = preserved
test "$(cat /root/.cargo/test-sentinel)" = preserved
/usr/bin/rustc --version
apt-get purge --yes rustup
test "$(cat /root/.rustup/test-sentinel)" = preserved
test "$(cat /root/.cargo/test-sentinel)" = preserved
apt-get install --yes rustup
/usr/bin/rustc --version
printf '%s\n' 'Jammy APT authentication, migration, toolchain, upgrade and removal passed.'
CHROOT
INNER
