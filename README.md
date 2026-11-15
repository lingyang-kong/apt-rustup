# rustup APT repository

Unofficial [rustup](https://github.com/rust-lang/rustup) packages for Ubuntu 22.04 (Jammy) amd64. APT manages rustup; rustup manages per-user toolchains.

Signing-key fingerprint: [SECURITY.md](SECURITY.md).

## Install

```sh
curl -fsSL https://lingyang-kong.github.io/apt-rustup/rustup-archive-keyring.gpg \
  | sudo tee /usr/share/keyrings/rustup-archive-keyring.gpg >/dev/null
printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/rustup-archive-keyring.gpg] https://lingyang-kong.github.io/apt-rustup jammy main' \
  | sudo tee /etc/apt/sources.list.d/rustup.list
sudo apt update
sudo apt install rustup
```

Update rustup through APT; rustup self-update and self-uninstall are disabled for this build.

## Maintain

Build on Jammy amd64 with stable Rust. Dependencies: build-essential, pkg-config, libssl-dev, liblzma-dev, libcurl4-openssl-dev, dpkg-dev, apt-utils, gnupg, jq, curl, git, ripgrep, util-linux and shellcheck.

```bash
upstream=$(scripts/discover-release.sh)
scripts/build-package.sh .build/output <<< "$upstream"
package=".build/output/$(jq --raw-output .package .build/output/build.json)"
tests/test-package.sh "$package"
tests/test-repository.sh
tests/test-history.sh
tests/test-build-cache.sh
APT_SIGNING_KEY=YOUR_FINGERPRINT scripts/sync-apt-repo.sh .build/output dist <<< "$upstream"
tests/test-jammy.sh dist
```

Configure Pages for Actions, set secret `APT_GPG_PRIVATE_KEY` (optional `APT_GPG_PASSPHRASE`). Local signing uses `APT_SIGNING_KEY` in `GNUPGHOME`. Publication polls daily or runs on manual dispatch. Set repository variable `APT_BASE_URL` to override the default archive URL for both polling and retained history.

Increase `packaging/revision` for package changes at an existing upstream version. Format shell files through stdin with `shfmt -filename PATH -s`.

History defaults to the current output; use `PREVIOUS_ARCHIVE_URL` on fresh runners or `PREVIOUS_ARCHIVE_DIR` for another local snapshot. `MAX_BYTES` may lower the 1,000,000,000-byte limit. Oldest packages are evicted first; the newest must fit. Previous generations remain under `.build/` for rollback. Leave lock files in place during active runs.

[MIT license](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [Security](SECURITY.md)
