#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?This script is for an ephemeral GitHub-hosted runner.}"
keychain="$RUNNER_TEMP/connect6-signing.keychain-db"
certificate="$RUNNER_TEMP/connect6-certificate.p12"
original_search_list="$RUNNER_TEMP/connect6-original-keychains.json"
export CONNECT6_KEYCHAIN="$keychain" CONNECT6_CERTIFICATE="$certificate" CONNECT6_SEARCH_LIST="$original_search_list"
case "${1:-}" in
  import)
    : "${MACOS_CERTIFICATE_P12_BASE64:?Configure MACOS_CERTIFICATE_P12_BASE64.}"
    : "${MACOS_CERTIFICATE_PASSWORD:?Configure MACOS_CERTIFICATE_PASSWORD.}"
    : "${MACOS_SIGNING_IDENTITY:?Configure MACOS_SIGNING_IDENTITY.}"
    umask 077
    python3 - <<'PY'
import base64, json, os, pathlib, shlex, subprocess
keys = shlex.split(subprocess.check_output(['security', 'list-keychains', '-d', 'user'], text=True))
pathlib.Path(os.environ['CONNECT6_SEARCH_LIST']).write_text(json.dumps(keys))
pathlib.Path(os.environ['CONNECT6_CERTIFICATE']).write_bytes(base64.b64decode(os.environ['MACOS_CERTIFICATE_P12_BASE64'], validate=True))
PY
    keychain_password="$(openssl rand -hex 32)"
    security create-keychain -p "$keychain_password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    security import "$certificate" -k "$keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
    python3 - <<'PY'
import json, os, pathlib, subprocess
keys = json.loads(pathlib.Path(os.environ['CONNECT6_SEARCH_LIST']).read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', os.environ['CONNECT6_KEYCHAIN'], *keys], check=True)
PY
    rm -f "$certificate"
    ;;
  cleanup)
    if [ -f "$original_search_list" ]; then
      python3 - <<'PY'
import json, os, pathlib, subprocess
keys = json.loads(pathlib.Path(os.environ['CONNECT6_SEARCH_LIST']).read_text())
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *keys], check=True)
PY
    fi
    if [ -f "$keychain" ]; then security delete-keychain "$keychain"; fi
    rm -f "$certificate" "$original_search_list"
    ;;
  *) echo 'Usage: ci-signing.sh import|cleanup' >&2; exit 1 ;;
esac
