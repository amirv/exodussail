#!/usr/bin/env bash
# Refresh exodussail.geojson from a configured KML feed and push to gist.
# Idempotent: if the GeoJSON content didn't change, the gist is not updated.
set -euo pipefail

cd "$(dirname "$0")"

KML=exodussail.kml
GEOJSON=exodussail.geojson
GIST_ID_FILE="${EXODUSSAIL_GIST_ID_FILE:-.gist_id}"
TOKEN_FILE="${EXODUSSAIL_GITHUB_TOKEN_FILE:-}"
GITHUB_API="${EXODUSSAIL_GITHUB_API:-https://api.github.com}"
GIST_DESC="${EXODUSSAIL_GIST_DESCRIPTION:-Location track (auto-updated)}"
FEED_URL="${EXODUSSAIL_FEED_URL:-}"
START="${EXODUSSAIL_START:-2025-11-01T00:00:00Z}"
END="${EXODUSSAIL_END:-$(date -u +%FT%TZ)}"

die() {
    echo "error: $*" >&2
    exit 1
}

read_github_token() {
    local line token

    [[ -n "$TOKEN_FILE" ]] || die "EXODUSSAIL_GITHUB_TOKEN_FILE is not set"
    [[ -r "$TOKEN_FILE" ]] || die "token file is not readable: $TOKEN_FILE"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        [[ "$line" == \#* ]] || {
            case "$line" in
                GITHUB_TOKEN=*|GH_TOKEN=*|EXODUSSAIL_GITHUB_TOKEN=*)
                    token="${line#*=}"
                    ;;
                *)
                    token="$line"
                    ;;
            esac
            token="${token%\"}"
            token="${token#\"}"
            token="${token%\'}"
            token="${token#\'}"
            [[ -n "$token" ]] || break
            printf '%s' "$token"
            return 0
        }
    done < "$TOKEN_FILE"

    die "no token found in $TOKEN_FILE"
}

GITHUB_TOKEN="$(read_github_token)"
[[ -n "$FEED_URL" ]] || die "EXODUSSAIL_FEED_URL is not set"

github_api() {
    local method="$1"
    local endpoint="$2"
    local payload_file="${3:-}"
    local response_file
    local http_code

    response_file="$(mktemp)"
    if [[ -n "$payload_file" ]]; then
        http_code="$(
            curl -sS -o "$response_file" -w '%{http_code}' \
                -X "$method" \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer $GITHUB_TOKEN" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                -H "Content-Type: application/json" \
                --data-binary "@$payload_file" \
                "${GITHUB_API}${endpoint}"
        )"
    else
        http_code="$(
            curl -sS -o "$response_file" -w '%{http_code}' \
                -X "$method" \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer $GITHUB_TOKEN" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "${GITHUB_API}${endpoint}"
        )"
    fi

    if [[ "${http_code:0:1}" != "2" ]]; then
        echo "GitHub API ${method} ${endpoint} failed with HTTP ${http_code}" >&2
        cat "$response_file" >&2
        rm -f "$response_file"
        return 1
    fi

    cat "$response_file"
    rm -f "$response_file"
}

build_gist_payload() {
    local public_flag="$1"
    python3 - "$GEOJSON" "$GIST_DESC" "$public_flag" <<'PY'
import json
import sys
from pathlib import Path

geojson_path = Path(sys.argv[1])
description = sys.argv[2]
public = sys.argv[3].lower() == "true"

payload = {
    "description": description,
    "files": {
        geojson_path.name: {
            "content": geojson_path.read_text(),
        }
    },
}
if public:
    payload["public"] = True

json.dump(payload, sys.stdout, separators=(",", ":"))
PY
}

echo "Fetching MapShare KML feed..."
curl -sS --fail -o "$KML" \
    "${FEED_URL}?d1=${START}&d2=${END}"

echo "Converting to GeoJSON..."
python3 convert.py "$KML" .

if [[ ! -s "$GIST_ID_FILE" ]]; then
    echo "Bootstrapping gist (one-time)..."
    CREATE_PAYLOAD="$(mktemp)"
    trap 'rm -f "$CREATE_PAYLOAD"' EXIT
    build_gist_payload true > "$CREATE_PAYLOAD"
    CREATE_RESPONSE="$(github_api POST "/gists" "$CREATE_PAYLOAD")"
    GIST_ID="$(
        printf '%s' "$CREATE_RESPONSE" |
            python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
    )"
    GIST_URL="$(
        printf '%s' "$CREATE_RESPONSE" |
            python3 -c 'import json,sys; print(json.load(sys.stdin)["html_url"])'
    )"
    RAW_URL="$(
        printf '%s' "$CREATE_RESPONSE" |
            python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["files"][sys.argv[1]]["raw_url"])' "$GEOJSON"
    )"
    echo "$GIST_ID" > "$GIST_ID_FILE"
    echo "Created gist: $GIST_URL"
    echo "Raw URL:      $RAW_URL"
else
    GIST_ID="$(cat "$GIST_ID_FILE")"
    CURRENT="$(mktemp)"
    GIST_RESPONSE="$(mktemp)"
    UPDATE_PAYLOAD="$(mktemp)"
    trap 'rm -f "$CURRENT" "$GIST_RESPONSE" "$UPDATE_PAYLOAD"' EXIT
    github_api GET "/gists/${GIST_ID}" > "$GIST_RESPONSE"
    python3 - "$GIST_RESPONSE" "$GEOJSON" "$CURRENT" <<'PY'
import json
import sys
from pathlib import Path

response_path = Path(sys.argv[1])
filename = sys.argv[2]
output_path = Path(sys.argv[3])

data = json.loads(response_path.read_text())
content = data.get("files", {}).get(filename, {}).get("content", "")
output_path.write_text(content)
PY
    if cmp -s "$CURRENT" "$GEOJSON"; then
        echo "No changes — gist already up to date."
    else
        echo "Updating gist ${GIST_ID}..."
        build_gist_payload false > "$UPDATE_PAYLOAD"
        UPDATE_RESPONSE="$(github_api PATCH "/gists/${GIST_ID}" "$UPDATE_PAYLOAD")"
        UPDATED_URL="$(
            printf '%s' "$UPDATE_RESPONSE" |
                python3 -c 'import json,sys; print(json.load(sys.stdin)["html_url"])'
        )"
        echo "Updated: $UPDATED_URL"
    fi
fi
