#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${LIBTORRENT_BUILD_ROOT:-$ROOT/.build/libtorrent-native}"
SOURCE_DIR="$BUILD_ROOT/libtorrent-src"
SLICE_DIR="$BUILD_ROOT/ios-device"
VENDOR_DIR="$ROOT/vendor"
OPENSSL_ROOT="$BUILD_ROOT/openssl"
OPENSSL_ZIP="$OPENSSL_ROOT/openssl.xcframework.zip"
OPENSSL_XCFRAMEWORK="$OPENSSL_ROOT/openssl.xcframework"
OPENSSL_VERSION="${OPENSSL_APPLE_VERSION:-3.6.300}"
CA_BUNDLE="$BUILD_ROOT/cacert.pem"
LIBTORRENT_REF="${LIBTORRENT_REF:-v2.0.13}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"

mkdir -p "$BUILD_ROOT" "$VENDOR_DIR"

if [[ ! -d "$OPENSSL_XCFRAMEWORK" ]]; then
  mkdir -p "$OPENSSL_ROOT"
  curl --fail --location --retry 3 \
    "https://github.com/partout-io/openssl-apple/releases/download/$OPENSSL_VERSION/openssl.xcframework.zip" \
    --output "$OPENSSL_ZIP"
  ditto -x -k "$OPENSSL_ZIP" "$OPENSSL_ROOT"
fi

OPENSSL_FRAMEWORK="$OPENSSL_XCFRAMEWORK/ios-arm64_arm64e/openssl.framework"
test -f "$OPENSSL_FRAMEWORK/openssl"

# OpenSSL on iOS needs an explicit trust store. Certificate validation stays on.
curl --fail --location --retry 3 \
  "https://curl.se/ca/cacert.pem" \
  --output "$CA_BUNDLE"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone \
    --branch "$LIBTORRENT_REF" \
    --depth 1 \
    --recurse-submodules \
    --shallow-submodules \
    https://github.com/arvidn/libtorrent.git \
    "$SOURCE_DIR"
else
  git -C "$SOURCE_DIR" fetch --tags --depth 1 origin "$LIBTORRENT_REF"
  git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
  git -C "$SOURCE_DIR" submodule update --init --recursive --depth 1
fi

BOOST_ROOT="$(brew --prefix boost)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
OPENSSL_INCLUDE_ROOT="$BUILD_ROOT/openssl-include"
rm -rf "$OPENSSL_INCLUDE_ROOT"
mkdir -p "$OPENSSL_INCLUDE_ROOT"
ln -s "$OPENSSL_FRAMEWORK/Headers" "$OPENSSL_INCLUDE_ROOT/openssl"

rm -rf "$SLICE_DIR"
cmake \
  -S "$ROOT/native/LibtorrentNative" \
  -B "$SLICE_DIR" \
  -G Xcode \
  -DLIBTORRENT_SOURCE_DIR="$SOURCE_DIR" \
  -DLIBTORRENT_CA_BUNDLE="$CA_BUNDLE" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH=NO \
  -DCMAKE_XCODE_ATTRIBUTE_BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  -DCMAKE_XCODE_ATTRIBUTE_SKIP_INSTALL=NO \
  -DBOOST_ROOT="$BOOST_ROOT" \
  -DBoost_INCLUDE_DIR="$BOOST_ROOT/include" \
  -DOPENSSL_ROOT_DIR="$OPENSSL_FRAMEWORK" \
  -DOPENSSL_INCLUDE_DIR="$OPENSSL_INCLUDE_ROOT" \
  -DOPENSSL_SSL_LIBRARY="$OPENSSL_FRAMEWORK/openssl" \
  -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_FRAMEWORK/openssl"

xcodebuild \
  -project "$SLICE_DIR/LibtorrentNative.xcodeproj" \
  -scheme LibtorrentNative \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  SKIP_INSTALL=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

NATIVE_FRAMEWORK="$(find "$SLICE_DIR" -type d -name LibtorrentNative.framework -print | sort | head -n 1)"
test -n "$NATIVE_FRAMEWORK"
test -f "$NATIVE_FRAMEWORK/LibtorrentNative"

rm -rf "$VENDOR_DIR/LibtorrentNative.framework" "$VENDOR_DIR/openssl.framework"
cp -R "$NATIVE_FRAMEWORK" "$VENDOR_DIR/LibtorrentNative.framework"
cp -R "$OPENSSL_FRAMEWORK" "$VENDOR_DIR/openssl.framework"

echo "Built iOS $IOS_DEPLOYMENT_TARGET libtorrent backend:"
echo "  $VENDOR_DIR/LibtorrentNative.framework"
echo "  $VENDOR_DIR/openssl.framework"
otool -L "$VENDOR_DIR/LibtorrentNative.framework/LibtorrentNative"
