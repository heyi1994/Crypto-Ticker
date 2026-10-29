#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Crypto Ticker.app"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/CryptoTicker" "$APP_DIR/Contents/MacOS/CryptoTicker"
cp -R "$BIN_DIR/CryptoTicker_CryptoTickerCore.bundle" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP_DIR"
echo "Built: $APP_DIR"
