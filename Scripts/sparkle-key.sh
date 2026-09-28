#!/bin/sh
# The key the Mac's updates are signed with, kept in the login keychain.
#
#   Scripts/sparkle-key.sh public         the public key, for SUPublicEDKey
#   Scripts/sparkle-key.sh sign <file>    the signature, for the appcast
#   Scripts/sparkle-key.sh make           once, ever: makes the key
#   Scripts/sparkle-key.sh export <file>  a copy to put somewhere safe
#
# Every copy of Paper Time from 0.9.12 on trusts this key and no other. Lose
# it and the Macs out there stop taking updates — they would have to be sent
# a new version by hand, once. So export it somewhere that is backed up.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE="Paper Time Sparkle EdDSA"
ACCOUNT="papertime"

seed() {
  security find-generic-password -s "$SERVICE" -a "$ACCOUNT" -w 2>/dev/null || {
    echo "no update key in the keychain — Scripts/sparkle-key.sh make, or import the backup" >&2
    exit 1
  }
}

case "$1" in
  make)
    if security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1; then
      echo "the key already exists; not making another" >&2; exit 1
    fi
    OUT="$(swift "$ROOT/Scripts/sparkle-sign.swift" make)"
    SEED="$(echo "$OUT" | sed -n 1p)"
    # -U never: a second key would silently replace the one the apps trust.
    security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -w "$SEED" \
      -j "Signs Paper Time's Mac updates (Sparkle). Back it up; do not lose it."
    echo "$OUT" | sed -n 2p
    ;;
  public)
    seed | swift "$ROOT/Scripts/sparkle-sign.swift" public ;;
  sign)
    [ -f "$2" ] || { echo "sign <file>" >&2; exit 64; }
    seed | swift "$ROOT/Scripts/sparkle-sign.swift" sign "$2" ;;
  export)
    [ -n "$2" ] || { echo "export <file>" >&2; exit 64; }
    [ -e "$2" ] && { echo "$2 exists; not overwriting" >&2; exit 1; }
    umask 077; seed > "$2"; echo "wrote $2 — keep it private" ;;
  import)
    [ -f "$2" ] || { echo "import <file>" >&2; exit 64; }
    security add-generic-password -s "$SERVICE" -a "$ACCOUNT" -w "$(cat "$2")" ;;
  *)
    echo "usage: $0 public | sign <file> | make | export <file> | import <file>" >&2; exit 64 ;;
esac
