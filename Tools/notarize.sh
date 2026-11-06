#!/bin/bash
set -euo pipefail
: "${APPLE_ID:?Configure APPLE_ID.}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?Configure APPLE_APP_SPECIFIC_PASSWORD.}"
: "${APPLE_TEAM_ID:?Configure APPLE_TEAM_ID.}"
target="${1:?Usage: notarize.sh APP_OR_DMG}"
if [ ! -e "$target" ]; then echo 'Notarization target does not exist.' >&2; exit 1; fi
temporary="$(mktemp -d "${TMPDIR:-/tmp}/connect6-notary.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
submission="$target"
if [[ "$target" == *.app ]]; then
    submission="$temporary/application.zip"
    ditto -c -k --sequesterRsrc --keepParent "$target" "$submission"
fi
if ! xcrun notarytool submit "$submission" --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" \
    --wait --timeout 20m --output-format json > "$temporary/result.json"; then
    cat "$temporary/result.json" >&2
    exit 1
fi
python3 - "$temporary/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    sys.exit('Apple did not accept this submission: ' + str(result.get('status')))
print('Accepted notarization:', result.get('id'))
PY
xcrun stapler staple "$target"
xcrun stapler validate "$target"
if [[ "$target" == *.app ]]; then
    spctl --assess --type execute --verbose=2 "$target"
else
    spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
fi
