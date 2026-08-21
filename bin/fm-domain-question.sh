#!/usr/bin/env bash
# Route one classified Relay question and dispatch its constrained domain lane.
# Usage: fm-domain-question.sh [--routes <path>] --runner <path> <inbox-file>
# The runner receives one fm-domain-lane.v1 JSON object on stdin.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ROUTES="$FM_HOME/config/domain-routing.json"
RUNNER=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --routes)
      [ "$#" -ge 2 ] || { echo "usage: fm-domain-question.sh [--routes <path>] --runner <path> <inbox-file>" >&2; exit 2; }
      ROUTES=$2
      shift 2
      ;;
    --runner)
      [ "$#" -ge 2 ] || { echo "usage: fm-domain-question.sh [--routes <path>] --runner <path> <inbox-file>" >&2; exit 2; }
      RUNNER=$2
      shift 2
      ;;
    *) break ;;
  esac
done

[ "$#" -eq 1 ] && [ -n "$RUNNER" ] || { echo "usage: fm-domain-question.sh [--routes <path>] --runner <path> <inbox-file>" >&2; exit 2; }
INBOX=$1
[ -f "$INBOX" ] && [ ! -L "$INBOX" ] || { echo "fm-domain-question: inbox is not a regular file" >&2; exit 2; }
[ -f "$RUNNER" ] && [ -x "$RUNNER" ] && [ ! -L "$RUNNER" ] || { echo "fm-domain-question: runner is not an executable regular file" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-domain-question: missing jq" >&2; exit 2; }

CHAT_ID=$(jq -er 'if (.chat_id | type) == "string" or (.chat_id | type) == "number" then .chat_id | tostring else error("chat_id must be a string or number") end' "$INBOX") \
  || { echo "fm-domain-question: invalid inbox chat_id" >&2; exit 2; }
TEXT=$(jq -er 'if (.text | type) == "string" then .text else error("text must be a string") end' "$INBOX") \
  || { echo "fm-domain-question: invalid inbox text" >&2; exit 2; }
ROUTE=$("$SCRIPT_DIR/fm-domain-route.sh" --routes "$ROUTES" "$CHAT_ID" "$TEXT") || exit $?

if [ "$(printf '%s' "$ROUTE" | jq -r '.action')" = ask ]; then
  printf '%s\n' "$ROUTE"
  exit 3
fi

DOMAIN=$(printf '%s' "$ROUTE" | jq -er '.domain')
MEMORY="$FM_HOME/data/domains/$DOMAIN"
BINDING="$FM_HOME/config/domain-bindings/$DOMAIN.json"
[ -d "$MEMORY" ] && [ ! -L "$MEMORY" ] || { echo "fm-domain-question: missing domain memory: $DOMAIN" >&2; exit 2; }
[ -f "$BINDING" ] && [ ! -L "$BINDING" ] || { echo "fm-domain-question: missing domain binding: $DOMAIN" >&2; exit 2; }
jq -e 'type == "object" and .mode == "read-only" and (.source | type) == "string" and (.source | length) > 0' "$BINDING" >/dev/null 2>&1 \
  || { echo "fm-domain-question: invalid read-only binding: $DOMAIN" >&2; exit 2; }

MEMORY_JSON=$(find "$MEMORY" -type f ! -path '*/.*' -print0 \
  | sort -z \
  | while IFS= read -r -d '' file; do
      case "$file" in "$MEMORY"/*) ;; *) exit 2 ;; esac
      [ ! -L "$file" ] || exit 2
      jq -n --arg name "${file#"$MEMORY"/}" --rawfile content "$file" '{name:$name,content:$content}'
    done \
  | jq -s '.') || { echo "fm-domain-question: invalid domain memory: $DOMAIN" >&2; exit 2; }

jq -n \
  --arg domain "$DOMAIN" \
  --arg question "$TEXT" \
  --argjson memory "$MEMORY_JSON" \
  --slurpfile binding "$BINDING" \
  '{schema:"fm-domain-lane.v1",ephemeral:true,domain:$domain,question:$question,memory:$memory,data_binding:$binding[0]}' \
  | "$RUNNER"
