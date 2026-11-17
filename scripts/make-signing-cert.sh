#!/bin/bash
# One-time setup: creates a self-signed code signing certificate called
# "Puffer Local Signing" in your login keychain.
#
# Why: macOS ties the Accessibility grant to the app's code signature. An
# ad-hoc signature changes on every build, so the grant is lost each time.
# Signing every build with the same certificate keeps it.
#
# SECURITY: for local development only.
# The key is imported with `-T /usr/bin/codesign`, so codesign can use it
# without a password prompt. Any program running as you can therefore sign
# any binary as "Puffer Local Signing" with Puffer's identifier, and macOS
# will give that binary the Accessibility permission you granted to Puffer
# (the power to read and post keystrokes). Do not run this on a Mac where
# that matters, never share a build signed this way, and remove the
# certificate when you no longer need it:
#
#   security delete-identity -c "Puffer Local Signing"
#
# Builds for other people must be signed with a Developer ID certificate
# (SIGN_ID=... scripts/build-app.sh) and notarised instead.
set -euo pipefail

name="Puffer Local Signing"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "\"$name\" already exists in the login keychain."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$work/cert.conf" -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "$name" -out "$work/identity.p12" -passout pass:puffer

# -T lets codesign use the key without asking each time. See the warning
# at the top of this file for what that costs.
security import "$work/identity.p12" -k "$keychain" -P puffer -T /usr/bin/codesign

echo "Created \"$name\". scripts/build-app.sh will now sign with it."
echo "This certificate is for local development only; see the top of this script."
