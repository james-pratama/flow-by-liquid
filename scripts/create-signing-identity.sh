#!/bin/bash
# Optional, one-time: creates a local self-signed "Flow Dev" code-signing certificate in your login keychain.
# build-app.sh signs with it automatically, so macOS keeps Flow's permissions (Input Monitoring, Accessibility,
# Microphone…) across rebuilds. Without it, builds are ad-hoc signed and macOS forgets the grants every rebuild.
# Remove it any time in Keychain Access (search "Flow Dev").
set -euo pipefail
if security find-identity -p codesigning 2>/dev/null | grep -q '"Flow Dev"'; then echo "Flow Dev identity already exists."; exit 0; fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '[req]\ndistinguished_name = dn\nx509_extensions = ext\nprompt = no\n[dn]\nCN = Flow Dev\n[ext]\nbasicConstraints = critical,CA:false\nkeyUsage = critical,digitalSignature\nextendedKeyUsage = critical,codeSigning\n' > "$TMP/cnf"
/usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key" -out "$TMP/crt" -days 3650 -nodes -config "$TMP/cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -out "$TMP/p12" -inkey "$TMP/key" -in "$TMP/crt" -passout pass:flowdev -name "Flow Dev" 2>/dev/null
security import "$TMP/p12" -k ~/Library/Keychains/login.keychain-db -P flowdev -T /usr/bin/codesign
echo "Created the Flow Dev signing identity. Run scripts/build-app.sh again."
