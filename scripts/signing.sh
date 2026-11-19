#!/bin/zsh
# OPT-IN (DOTLOGI_LOCAL_SIGNING=1 scripts/install.sh): a local, self-signed code-signing identity, so macOS
# keeps the agent's Accessibility and Input Monitoring permissions across rebuilds.
#
# Trade-off: the keychain password is stored where any program running as you can read it without a prompt,
# and the signing keychain stays unlocked until you log out, so such a program could sign its own code as
# dotlogI and inherit both permissions. While the identity is being created, the passwords also appear briefly
# in the process list. The default ad-hoc signing ties the permissions to one exact build instead. Use this
# only on a machine where you accept that.
#
# The identity lives in its own keychain, ~/Library/Keychains/dotlogi-signing.keychain-db. A random password for
# that keychain is kept in the login keychain (service "dotlogi-signing"); it is never printed.
# Sourced by install.sh, which then calls: sign_app <bundle> <identifier>
#   scripts/signing.sh remove   deletes the keychain and the stored password

SIGNING_NAME="dotlogI Local Signing"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/dotlogi-signing.keychain-db"
SIGNING_SERVICE="dotlogi-signing"
# macOS's own LibreSSL: OpenSSL 3 writes PKCS#12 files that `security import` cannot read.
OPENSSL=/usr/bin/openssl

signing_password() {
  security find-generic-password -s "$SIGNING_SERVICE" -a "$USER" -w 2>/dev/null
}

ensure_signing_identity() {
  if [[ -f "$SIGNING_KEYCHAIN" ]] && signing_password >/dev/null \
     && security unlock-keychain -p "$(signing_password)" "$SIGNING_KEYCHAIN" 2>/dev/null \
     && security find-identity -p codesigning "$SIGNING_KEYCHAIN" | grep -q "$SIGNING_NAME"; then
    return
  fi
  # Start over from a clean state (an earlier attempt may have stopped half way).
  security delete-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || true
  echo "Creating a local code-signing identity ($SIGNING_NAME)..."
  local password work
  password=$($OPENSSL rand -hex 24)
  work=$(mktemp -d)
  # Delete only our own temporary files, whatever happens.
  trap "rm -rf '$work'" EXIT

  security add-generic-password -U -s "$SIGNING_SERVICE" -a "$USER" -w "$password" \
    -T /usr/bin/security -l "dotlogI signing keychain"
  security create-keychain -p "$password" "$SIGNING_KEYCHAIN"
  security set-keychain-settings "$SIGNING_KEYCHAIN" # no auto-lock
  security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"

  cat > "$work/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGNING_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
  $OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.conf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  local p12pass
  p12pass=$($OPENSSL rand -hex 16)
  $OPENSSL pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$SIGNING_NAME" \
    -passout "pass:$p12pass" -out "$work/identity.p12" 2>/dev/null
  security import "$work/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$p12pass" -T /usr/bin/codesign >/dev/null
  # Let codesign use the key without a dialog.
  security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$SIGNING_KEYCHAIN" >/dev/null
  rm -rf "$work"
  trap - EXIT
}

sign_app() {
  codesign --force --options runtime --keychain "$SIGNING_KEYCHAIN" --sign "$SIGNING_NAME" --identifier "$2" "$1"
}

if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file* && "${1:-}" == "remove" ]]; then
  security delete-keychain "$SIGNING_KEYCHAIN" 2>/dev/null || true
  security delete-generic-password -s "$SIGNING_SERVICE" -a "$USER" >/dev/null 2>&1 || true
  echo "Removed $SIGNING_KEYCHAIN and its stored password."
fi
