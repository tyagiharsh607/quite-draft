#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

APP="$ROOT/QuietDraft.app"
BIN="$ROOT/.build/$CONFIG/QuietDraft"
CERT_DIR="$ROOT/.certs"
# Absolute path is required: a relative name is created under ~/Library/Keychains.
KC="$CERT_DIR/quietdraft.keychain-db"
KC_PASS="quietdraft-local-sign"
P12_PASS="quietdraft"
SIGN_ID="QuietDraftLocalSign"

mkdir -p "$CERT_DIR"

if [[ ! -f "$CERT_DIR/cert.p12" || ! -f "$CERT_DIR/key.pem" ]]; then
  echo "Creating $SIGN_ID certificate"
  openssl req -new -x509 -days 3650 -nodes \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
    -subj "/CN=$SIGN_ID" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "keyUsage=digitalSignature"
  openssl pkcs12 -export -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" \
    -out "$CERT_DIR/cert.p12" -name "$SIGN_ID" -passout pass:"$P12_PASS" -legacy \
    2>/dev/null || openssl pkcs12 -export -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" \
    -out "$CERT_DIR/cert.p12" -name "$SIGN_ID" -passout pass:"$P12_PASS"
fi

if [[ ! -f "$KC" ]]; then
  echo "Creating local signing keychain at $KC"
  security create-keychain -p "$KC_PASS" "$KC"
fi
security set-keychain-settings -t 86400 "$KC" || true
security unlock-keychain -p "$KC_PASS" "$KC"
security import "$CERT_DIR/cert.p12" -k "$KC" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null 2>&1 || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

LOGIN="$HOME/Library/Keychains/login.keychain-db"
security list-keychains -d user -s "$KC" "$LOGIN"

STAGE=$(mktemp -d /tmp/QuietDraft-sign.XXXXXX)
trap 'security list-keychains -d user -s "$LOGIN" >/dev/null 2>&1 || true; rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/QuietDraft.app/Contents/MacOS"
cp "$BIN" "$STAGE/QuietDraft.app/Contents/MacOS/QuietDraft"
cp "$ROOT/Resources/Info.plist" "$STAGE/QuietDraft.app/Contents/Info.plist"
printf 'APPL????' > "$STAGE/QuietDraft.app/Contents/PkgInfo"

codesign --force --sign "$SIGN_ID" \
  --keychain "$KC" \
  --identifier com.local.quietdraft \
  --entitlements "$ROOT/Resources/entitlements.plist" \
  --timestamp=none \
  "$STAGE/QuietDraft.app"

rm -rf "$APP"
ditto "$STAGE/QuietDraft.app" "$APP"
ditto "$STAGE/QuietDraft.app" /Applications/QuietDraft.app

echo "Built $APP (config=$CONFIG)"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Identifier=|Signature=|Authority=|adhoc|Info.plist=' || true
codesign -dv --verbose=2 /Applications/QuietDraft.app 2>&1 | grep -E 'Identifier=|Signature=|Authority=|adhoc' || true
