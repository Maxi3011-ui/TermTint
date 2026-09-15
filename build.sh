#!/bin/bash
# Builds TermTint.app. Pass --install to place it in /Applications and launch it.
#
# Signing matters more than it looks: macOS ties the Accessibility permission to
# the app's signature. An ad-hoc signature gets a fresh hash on every build, so
# the grant silently dies after each rebuild — without even re-prompting. Signing
# with a real Apple Development identity keeps the requirement stable, so you
# grant access once and never think about it again.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/TermTint.app"
BUNDLE_ID="eu.lecon.termtint"

pick_identity() {
    if [[ -n "${TERMTINT_IDENTITY:-}" ]]; then
        printf '%s' "$TERMTINT_IDENTITY"
        return
    fi
    local found
    found=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ { print $2; exit }')
    printf '%s' "${found:--}"
}

authority_of() {
    codesign -dvv "$1" 2>&1 | awk -F'=' '/^Authority=/ { print $2; exit }'
}

IDENTITY="$(pick_identity)"
OLD_AUTHORITY=""
[[ -d "/Applications/TermTint.app" ]] && OLD_AUTHORITY="$(authority_of /Applications/TermTint.app || true)"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/TermTint" "$APP/Contents/MacOS/TermTint"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

if [[ "$IDENTITY" == "-" ]]; then
    echo "gebaut: $APP  (ad-hoc signiert — Bedienungshilfen müssen nach jedem Rebuild neu erteilt werden)"
else
    echo "gebaut: $APP  (signiert mit: $IDENTITY)"
fi

if [[ "${1:-}" == "--install" ]]; then
    NEW_AUTHORITY="$(authority_of "$APP" || true)"

    pkill -x TermTint 2>/dev/null || true
    rm -rf /Applications/TermTint.app
    cp -R "$APP" /Applications/TermTint.app

    # A changed signing authority invalidates the old grant. Clearing the stale
    # entry is what makes macOS ask again instead of failing silently.
    if [[ "$OLD_AUTHORITY" != "$NEW_AUTHORITY" ]]; then
        tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
        echo "Signatur geändert — Bedienungshilfen einmalig neu freigeben."
    fi

    sleep 1
    open /Applications/TermTint.app
    echo "installiert und gestartet: /Applications/TermTint.app"
fi
