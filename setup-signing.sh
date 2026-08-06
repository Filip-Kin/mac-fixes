#!/bin/bash
# One-time setup: create a self-signed code-signing identity and trust it for
# code signing. This gives the app a STABLE code identity, so macOS keeps its
# Accessibility / Screen Recording permission grants across rebuilds instead of
# forgetting them (which is what ad-hoc signing causes).
#
# You only run this once. It will ask for your login password to trust the
# certificate — that step needs your credentials and cannot be automated.
set -euo pipefail

CERT_NAME="MacFixes Self-Signed"
DIR="$HOME/.macfixes-signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "$CERT_NAME"; then
    echo "Signing identity '$CERT_NAME' is already set up. Nothing to do."
    exit 0
fi

mkdir -p "$DIR"

echo "Creating self-signed certificate..."
cat > "$DIR/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$DIR/key.pem" -out "$DIR/cert.pem" \
    -config "$DIR/openssl.cnf" -extensions v3 >/dev/null 2>&1

openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" \
    -out "$DIR/id.p12" -passout pass:mfix -name "$CERT_NAME" >/dev/null 2>&1

echo "Importing into your login keychain..."
security import "$DIR/id.p12" -k "$KEYCHAIN" -P mfix -A >/dev/null

echo
echo ">>> macOS will now ask for your login password to trust the certificate."
echo
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"

echo
echo "Done. Now run ./build.sh — it will sign with this identity and your"
echo "permission grants will survive future rebuilds."
