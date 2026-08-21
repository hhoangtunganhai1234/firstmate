#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROUTER="$ROOT/bin/fm-domain-route.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '%s\n' '{"chat_domains":{"-1001":"sale","-1002":"pnl"}}' > "$TMP/routes.json"

assert_json() {
  actual=$1
  filter=$2
  note=$3
  printf '%s' "$actual" | jq -e "$filter" >/dev/null || {
    echo "FAIL: $note: $actual" >&2
    exit 1
  }
}

out=$("$ROUTER" --routes "$TMP/routes.json" -1001 '#Com.pnl margin?')
assert_json "$out" '.action == "route" and .domain == "sale" and .source == "chat_id"' "chat binding must win over the tag"

out=$("$ROUTER" --routes "$TMP/routes.json" -999 '#Com.SaLe doanh thu?')
assert_json "$out" '.action == "route" and .domain == "sale" and .source == "tag"' "a single tag must route case-insensitively"

out=$("$ROUTER" --routes "$TMP/routes.json" -999 'Hãy phân tích doanh thu tuần này')
assert_json "$out" '.action == "ask" and .reason == "missing_domain"' "wording must never infer a domain"

out=$("$ROUTER" --routes "$TMP/routes.json" -999 '#Com.sale so với #Com.pnl')
assert_json "$out" '.action == "ask" and .reason == "ambiguous_tags"' "conflicting tags must ask"

printf '%s\n' '{"chat_domains":[]}' > "$TMP/invalid.json"
if "$ROUTER" --routes "$TMP/invalid.json" -999 '#Com.sale test' >/dev/null 2>&1; then
  echo "FAIL: invalid configuration must fail closed" >&2
  exit 1
fi

printf '%s\n' '{"chat_domains":{"-1001":"Sale"}}' > "$TMP/uppercase.json"
if "$ROUTER" --routes "$TMP/uppercase.json" -1001 '#Com.sale test' >/dev/null 2>&1; then
  echo "FAIL: uppercase configured domains must fail closed" >&2
  exit 1
fi

echo "PASS: fm-domain-route"
