#!/usr/bin/env bash
# Route one Relay question and run a selected-domain-only ephemeral Codex lane.
# Usage: fm-domain-question.sh [--routes <path>] <inbox-file>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ROUTES="$FM_HOME/config/domain-routing.json"

if [ "${1:-}" = --routes ]; then
  [ "$#" -ge 3 ] || { echo "usage: fm-domain-question.sh [--routes <path>] <inbox-file>" >&2; exit 2; }
  ROUTES=$2
  shift 2
fi
[ "$#" -eq 1 ] || { echo "usage: fm-domain-question.sh [--routes <path>] <inbox-file>" >&2; exit 2; }
INBOX=$1
[ -f "$INBOX" ] && [ ! -L "$INBOX" ] || { echo "fm-domain-question: inbox is not a regular file" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-domain-question: missing jq" >&2; exit 2; }
command -v bwrap >/dev/null 2>&1 || { echo "fm-domain-question: missing bubblewrap" >&2; exit 2; }

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

SOURCE=$(jq -r '.source' "$BINDING")
case "$SOURCE" in
  /*) ;;
  *) SOURCE="$FM_HOME/$SOURCE" ;;
esac
if [ -d "$SOURCE" ] && [ ! -L "$SOURCE" ]; then
  SOURCE=$(CDPATH='' cd "$SOURCE" && pwd -P)
elif [ -f "$SOURCE" ] && [ ! -L "$SOURCE" ]; then
  SOURCE_DIR=$(CDPATH='' cd "$(dirname "$SOURCE")" && pwd -P)
  SOURCE="$SOURCE_DIR/$(basename "$SOURCE")"
else
  echo "fm-domain-question: unavailable read-only source: $DOMAIN" >&2
  exit 2
fi

CODEX_BIN=${FM_DOMAIN_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}
[ -n "$CODEX_BIN" ] || { echo "fm-domain-question: missing codex" >&2; exit 2; }
CODEX_BIN=$(readlink -f "$CODEX_BIN")
[ -f "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] || { echo "fm-domain-question: invalid codex executable" >&2; exit 2; }
AUTH=${FM_DOMAIN_CODEX_AUTH:-${CODEX_HOME:-$HOME/.codex}/auth.json}
[ -f "$AUTH" ] && [ ! -L "$AUTH" ] || { echo "fm-domain-question: missing Codex authentication" >&2; exit 2; }

LANE_TMP=$(mktemp -d "$FM_HOME/state/.domain-lane.XXXXXX") || exit 2
trap 'rm -rf "$LANE_TMP"' EXIT INT TERM
mkdir -p "$LANE_TMP/output"
touch "$LANE_TMP/output/answer.txt"
jq -n --arg domain "$DOMAIN" --arg question "$TEXT" '
  "You are an ephemeral domain-question lane. Answer only the supplied question. " +
  "Use only memory under /lane/memory and the read-only data source at /lane/data. " +
  "The binding contract is /lane/binding.json. Do not use outside knowledge or infer another domain.\n\n" +
  "Domain: " + $domain + "\nQuestion: " + $question
' -r > "$LANE_TMP/prompt"

CODEX_MOUNTS=(--ro-bind "$CODEX_BIN" /opt/codex)
CODEX_LAUNCH=(/opt/codex)
if [ "${CODEX_BIN##*.}" = js ]; then
  CODEX_ROOT=$(CDPATH='' cd "$(dirname "$CODEX_BIN")/.." && pwd -P)
  NODE_BIN=$(readlink -f "$(command -v node)")
  CODEX_MOUNTS=(--ro-bind "$CODEX_ROOT" /opt/codex-package --ro-bind "$NODE_BIN" /opt/node)
  CODEX_LAUNCH=(/opt/node /opt/codex-package/bin/codex.js)
fi

bwrap --die-with-parent --new-session --unshare-all --share-net \
  --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
  --dir /etc --ro-bind /etc/ssl /etc/ssl --ro-bind /etc/resolv.conf /etc/resolv.conf \
  --ro-bind /etc/hosts /etc/hosts --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf \
  --proc /proc --dev /dev --tmpfs /tmp \
  --dir /lane --dir /lane/home --dir /lane/home/.codex --dir /opt --dir /output \
  --ro-bind "$AUTH" /lane/home/.codex/auth.json \
  --ro-bind "$MEMORY" /lane/memory \
  --ro-bind "$BINDING" /lane/binding.json \
  --ro-bind "$SOURCE" /lane/data \
  --bind "$LANE_TMP/output" /output \
  "${CODEX_MOUNTS[@]}" \
  --clearenv --setenv HOME /lane/home --setenv CODEX_HOME /lane/home/.codex --setenv PATH /opt:/usr/bin:/bin \
  --chdir /lane \
  "${CODEX_LAUNCH[@]}" exec --ephemeral --ignore-user-config --ignore-rules --sandbox read-only \
  --skip-git-repo-check -C /lane --output-last-message /output/answer.txt - < "$LANE_TMP/prompt" >/dev/null

[ -f "$LANE_TMP/output/answer.txt" ] && [ ! -L "$LANE_TMP/output/answer.txt" ] && [ -s "$LANE_TMP/output/answer.txt" ] \
  || { echo "fm-domain-question: lane returned no valid answer" >&2; exit 2; }
cat "$LANE_TMP/output/answer.txt"
