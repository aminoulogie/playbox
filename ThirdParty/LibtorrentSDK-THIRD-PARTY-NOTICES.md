# Third-Party Notices

This package ships a Swift wrapper and release binaries built from libtorrent.

## libtorrent

- Source: https://github.com/arvidn/libtorrent
- Default build ref: `v2.0.13`
- License: BSD-style license, see upstream `COPYING` and `LICENSE`.

The release asset `LibtorrentNative.xcframework.zip` is built from libtorrent
and the C ABI bridge in `NativeBridge/`.

## OpenSSL

- Source: https://github.com/partout-io/openssl-apple
- Default binary release: `3.6.300` (OpenSSL 3.6.2)
- License: Apache License 2.0, see https://www.openssl.org/source/license.html.

The iOS runtime links the `openssl.xcframework` release binary to enable HTTPS
trackers and web seeds.

## Mozilla CA Certificate Store

- Distribution: https://curl.se/docs/caextract.html
- Snapshot date: May 14, 2026
- License: Mozilla Public License 2.0

The native framework embeds curl's PEM extract of Mozilla's trusted root
certificate store so OpenSSL can validate HTTPS servers on iOS.
