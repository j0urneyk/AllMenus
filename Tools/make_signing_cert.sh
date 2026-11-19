#!/bin/zsh
# Creates the "All Menus Local Signing" code-signing certificate in your login keychain, so that
# build.sh signs every build with the same identity and macOS keeps the permissions you granted
# (Accessibility, Screen Recording) across rebuilds. Without it, builds are signed ad hoc and the
# permissions have to be granted again after each build.
#
# The certificate is self-signed, valid for 10 years, and only usable on this Mac. Its trust
# settings are not changed (Keychain Access will show it as "not trusted"; signing works anyway).
# Remove it with:
#   security delete-identity -c "All Menus Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail
NAME="All Menus Local Signing"
KEYCHAIN="${ALLMENUS_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"   # override only for testing

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists, nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# /usr/bin/openssl (LibreSSL) writes PKCS#12 files that `security import` can read.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$PASS"
# -T lets codesign use the key without a keychain prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\". Run ./build.sh; the first launch asks for permissions once, later builds keep them."
