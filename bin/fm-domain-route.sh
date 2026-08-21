#!/usr/bin/env bash
# Resolve a Relay question's business domain without inspecting its wording.
# Precedence: exact chat_id binding, exactly one #Com.<domain> tag, then ask.
#
# Optional config/domain-routing.json shape:
#   {"chat_domains":{"-1001234567890":"sale"}}
# Both chat ids and domains must be strings. Invalid configuration fails closed.
# Output is one JSON object with action route or ask.
# Usage: fm-domain-route.sh [--routes <path>] <chat_id> <text>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ROUTES="$FM_HOME/config/domain-routing.json"

if [ "${1:-}" = "--routes" ]; then
  [ "$#" -ge 3 ] || { echo "usage: fm-domain-route.sh [--routes <path>] <chat_id> <text>" >&2; exit 2; }
  ROUTES=$2
  shift 2
fi
[ "$#" -eq 2 ] || { echo "usage: fm-domain-route.sh [--routes <path>] <chat_id> <text>" >&2; exit 2; }
CHAT_ID=$1
TEXT=$2

command -v jq >/dev/null 2>&1 || { echo "fm-domain-route: missing jq" >&2; exit 2; }

domain=
if [ -e "$ROUTES" ]; then
  if [ ! -f "$ROUTES" ] || ! jq -e '
      type == "object" and
      (.chat_domains | type == "object") and
      all(.chat_domains | to_entries[]; (.key | type) == "string" and (.value | type) == "string" and (.value | test("^[A-Za-z][A-Za-z0-9_-]*$")))
    ' "$ROUTES" >/dev/null 2>&1; then
    echo "fm-domain-route: invalid routing file: $ROUTES" >&2
    exit 2
  fi
  domain=$(jq -r --arg chat "$CHAT_ID" '.chat_domains[$chat] // "" | ascii_downcase' "$ROUTES")
fi

if [ -n "$domain" ]; then
  jq -cn --arg domain "$domain" '{action:"route",domain:$domain,source:"chat_id"}'
  exit 0
fi

tags=$(printf '%s\n' "$TEXT" \
  | grep -Eio '#Com\.[A-Za-z][A-Za-z0-9_-]*' 2>/dev/null \
  | sed 's/^#Com\.//' \
  | tr '[:upper:]' '[:lower:]' \
  | sort -u || true)
count=$(printf '%s\n' "$tags" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$count" -eq 1 ]; then
  domain=$(printf '%s\n' "$tags" | sed '/^$/d')
  jq -cn --arg domain "$domain" '{action:"route",domain:$domain,source:"tag"}'
elif [ "$count" -gt 1 ]; then
  jq -cn '{action:"ask",reason:"ambiguous_tags"}'
else
  jq -cn '{action:"ask",reason:"missing_domain"}'
fi
