#!/bin/zsh
# Creates a self-signed code signing certificate in the login keychain.
# Signing every build with the same certificate keeps the designated
# requirement stable, so macOS keeps the Accessibility and Input Monitoring
# permissions after a rebuild. Usage: tools/make_cert.sh ["Certificate name"]
set -euo pipefail
NAME="${1:-WE KeySwitcher Local Signing}"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists"; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
# The system LibreSSL writes PKCS#12 files that `security import` accepts.
O=/usr/bin/openssl
$O req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 -config "$TMP/cert.cnf" 2>/dev/null
PASS=$($O rand -hex 16)
$O pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\""
