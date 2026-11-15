# Security

Signing-key fingerprint: `2E81 B1C7 DED7 A29C 379C AB97 FB91 315F 8816 2F28`.
Public key: `rustup-archive-keyring.gpg`. Verify the fingerprint independently and scope the key with `signed-by`.

The archive signs its APT metadata. Builds use HTTPS source archives pinned to Git commits and locked Cargo dependencies; upstream signatures are not verified. Rustup downloads toolchains separately.

Retained packages are verified against an authenticated `InRelease` and package index, including hashes, sizes, paths, and Debian identity. Key rotation must preserve a trusted verification path for that history.

Report archive issues or key compromise to `lykong@utexas.edu`; report upstream vulnerabilities to the Rust Project. On compromise, stop publication and publish affected releases, revocation information, and a replacement fingerprint.
