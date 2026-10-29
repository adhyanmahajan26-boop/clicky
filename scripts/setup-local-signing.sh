#!/bin/bash
#
# One-time setup so Clicky keeps its macOS permissions across rebuilds.
#
# Without a signing identity Xcode signs Clicky ad-hoc, and macOS treats every
# rebuild as a brand-new app (Accessibility / Screen Recording prompts again).
# This creates a local self-signed code-signing identity called
# "Clicky Local Signing" in your login keychain, so every build has the same
# signature, then clears Clicky's old permission entries (Clicky only).
#
# macOS will ask for your login password once (to trust the certificate for
# code signing). Run it from Terminal:
#   bash ~/Projects/clicky/scripts/setup-local-signing.sh

set -euo pipefail

signingIdentityName="Clicky Local Signing"
clickyBundleIdentifier="com.personal.clicky"
loginKeychainPath="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$loginKeychainPath" | grep -q "$signingIdentityName"; then
    echo "✅ \"$signingIdentityName\" already exists, skipping creation."
else
    temporaryWorkDirectory="$(mktemp -d)"
    # The private key only lives here until it's imported, then it's deleted.
    trap 'rm -rf "$temporaryWorkDirectory"' EXIT
    cd "$temporaryWorkDirectory"

    cat > certificate.cnf <<EOF
[req]
distinguished_name = subject
x509_extensions = codeSigningExtensions
prompt = no
[subject]
CN = $signingIdentityName
[codeSigningExtensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout signing-key.pem -out signing-certificate.pem -config certificate.cnf 2>/dev/null

    temporaryExportPassword="$(/usr/bin/openssl rand -hex 16)"
    /usr/bin/openssl pkcs12 -export -name "$signingIdentityName" \
        -inkey signing-key.pem -in signing-certificate.pem \
        -out signing-identity.p12 -passout "pass:$temporaryExportPassword"

    security import signing-identity.p12 -k "$loginKeychainPath" \
        -P "$temporaryExportPassword" -T /usr/bin/codesign
    echo "🔐 macOS will now ask for your login password to trust the certificate for code signing."
    security add-trusted-cert -p codeSign -k "$loginKeychainPath" signing-certificate.pem
    echo "✅ Created \"$signingIdentityName\"."
fi

echo
security find-identity -v -p codesigning | grep "$signingIdentityName" || {
    echo "⚠️  The identity isn't showing as valid yet. Tell Claude what this printed."
    exit 1
}

echo
echo "🧹 Clearing Clicky's old permission entries (only $clickyBundleIdentifier)…"
for privacyService in Accessibility ScreenCapture Microphone SpeechRecognition; do
    tccutil reset "$privacyService" "$clickyBundleIdentifier" || true
done

echo
echo "Done. Tell Claude \"signing done\" and it will rebuild and relaunch Clicky."
