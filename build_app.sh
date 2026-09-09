#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

APP="QuietDraft.app"
BIN=".build/$CONFIG/QuietDraft"
CERT_DIR=".certs"
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
  echo "Creating local signing keychain"
  security create-keychain -p "$KC_PASS" "$KC"
  security set-keychain-settings -t 86400 "$KC"
fi

security unlock-keychain -p "$KC_PASS" "$KC"
# Re-import is idempotent enough; ignore "already exists"
security import "$CERT_DIR/cert.p12" -k "$KC" -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null 2>&1 || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuietDraft"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign "$SIGN_ID" \
  --keychain "$KC" \
  --identifier com.local.quietdraft \
  --entitlements Resources/entitlements.plist \
  "$APP"

echo "Built $APP (config=$CONFIG)"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Identifier=|Signature=|Authority=|adhoc|Info.plist=' || true
