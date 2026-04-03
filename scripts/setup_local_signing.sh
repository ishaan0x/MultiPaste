#!/bin/zsh
set -euo pipefail

KEYCHAIN_PATH="$HOME/Library/Keychains/MultiPaste.keychain-db"
KEYCHAIN_PASSWORD="multipaste-local-signing"
P12_PASSWORD="multipaste-local-p12"
IDENTITY_NAME="MultiPaste Local Signer"
WORKDIR="$(mktemp -d)"
OPENSSL_CONFIG="$WORKDIR/openssl.cnf"
CERT_PEM="$WORKDIR/multipaste-cert.pem"
KEY_PEM="$WORKDIR/multipaste-key.pem"
P12_PATH="$WORKDIR/multipaste-cert.p12"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
  echo "Signing identity already exists in $KEYCHAIN_PATH"
  exit 0
fi

if [[ ! -f "$KEYCHAIN_PATH" ]]; then
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"

cat > "$OPENSSL_CONFIG" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = MultiPaste Local Signer

[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical,CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req -new -newkey rsa:2048 -nodes -x509 \
  -days 3650 \
  -config "$OPENSSL_CONFIG" \
  -keyout "$KEY_PEM" \
  -out "$CERT_PEM"

openssl pkcs12 -export \
  -inkey "$KEY_PEM" \
  -in "$CERT_PEM" \
  -name "$IDENTITY_NAME" \
  -out "$P12_PATH" \
  -passout pass:"$P12_PASSWORD"

security import "$P12_PATH" \
  -k "$KEYCHAIN_PATH" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security add-trusted-cert -d -r trustRoot -k "$KEYCHAIN_PATH" "$CERT_PEM"
CURRENT_KEYCHAINS=$(security list-keychains -d user | tr -d '"')
security list-keychains -d user -s "$KEYCHAIN_PATH" $CURRENT_KEYCHAINS

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"

echo "Created signing identity: $IDENTITY_NAME"
