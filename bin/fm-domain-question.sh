#!/usr/bin/env bash
# Route one Relay question through the current harness's tool-free ephemeral lane.
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

CHAT_ID=$(jq -er 'if has("chat_id") then if (.chat_id | type) == "string" or (.chat_id | type) == "number" then .chat_id | tostring else error("chat_id must be a string or number") end else "" end' "$INBOX") \
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

LANE_TMP=$(mktemp -d "$FM_HOME/state/.domain-lane.XXXXXX") || exit 2
trap 'rm -rf "$LANE_TMP"' EXIT INT TERM

snapshot_path() {
  local root=$1
  if [ -f "$root" ]; then
    jq -n --arg name "$(basename "$root")" --rawfile content "$root" '[{name:$name,content:$content}]'
    return
  fi
  find "$root" -type f ! -path '*/.*' -print0 \
    | sort -z \
    | while IFS= read -r -d '' file; do
        [ ! -L "$file" ] || exit 2
        jq -n --arg name "${file#"$root"/}" --rawfile content "$file" '{name:$name,content:$content}'
      done \
    | jq -s '.'
}
snapshot_path "$MEMORY" > "$LANE_TMP/memory.json" \
  || { echo "fm-domain-question: invalid domain memory: $DOMAIN" >&2; exit 2; }
snapshot_path "$SOURCE" > "$LANE_TMP/data.json" \
  || { echo "fm-domain-question: invalid domain source: $DOMAIN" >&2; exit 2; }
jq -n --arg domain "$DOMAIN" --arg question "$TEXT" --slurpfile memory "$LANE_TMP/memory.json" \
  --slurpfile data "$LANE_TMP/data.json" --slurpfile binding "$BINDING" '
  "You are an ephemeral domain-question lane with no tools. Answer only from the supplied JSON inputs. " +
  "Do not use outside knowledge or infer another domain.\n\n" +
  ({domain:$domain,question:$question,memory:$memory[0],data_binding:$binding[0],data:$data[0]} | tojson)
' -r > "$LANE_TMP/prompt"
mkdir "$LANE_TMP/skills"
cat > "$LANE_TMP/kimi-agent.yaml" <<'EOF'
version: 1
agent:
  name: fm-domain-lane
  system_prompt_path: ./prompt
  tools: []
  subagents: []
EOF

HARNESS=${FM_DOMAIN_HARNESS:-$("$SCRIPT_DIR/fm-harness.sh")}
case "$HARNESS" in
  claude|codex|opencode|pi|pi-signed|grok|kimi|muse) ;;
  *) echo "fm-domain-question: no verified tool-free ephemeral lane for harness: $HARNESS" >&2; exit 2 ;;
esac
if [ -n "${FM_DOMAIN_HARNESS_BIN:-}" ]; then
  HARNESS_BIN=$FM_DOMAIN_HARNESS_BIN
elif [ "$HARNESS" = pi-signed ]; then
  HARNESS_BIN=$(command -v pi-signed 2>/dev/null || true)
else
  HARNESS_BIN=$(command -v "$HARNESS" 2>/dev/null || true)
fi
[ -n "$HARNESS_BIN" ] && [ -f "$HARNESS_BIN" ] && [ -x "$HARNESS_BIN" ] \
  || { echo "fm-domain-question: unavailable harness executable: $HARNESS" >&2; exit 2; }

ANSWER="$LANE_TMP/answer.txt"
(
  cd "$LANE_TMP"
  case "$HARNESS" in
    claude)
      "$HARNESS_BIN" -p --no-session-persistence --tools "" --disable-slash-commands \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources '' --output-format text \
        < prompt > answer.txt
      ;;
    codex)
      "$HARNESS_BIN" exec --ephemeral --ignore-user-config --ignore-rules --sandbox read-only --skip-git-repo-check \
        --disable shell_tool --disable unified_exec --disable code_mode_host --disable apps --disable browser_use \
        --disable browser_use_external --disable computer_use --disable image_generation --disable multi_agent \
        --disable multi_agent_v2 --disable skill_search --disable tool_suggest --disable view_image \
        -C . --output-last-message answer.txt - < prompt >/dev/null
      ;;
    opencode)
      OPENCODE_CONFIG_CONTENT='{"instructions":[],"permission":{"*":"deny"}}' \
        "$HARNESS_BIN" run --pure --format default < prompt > answer.txt
      ;;
    pi|pi-signed)
      "$HARNESS_BIN" -p --no-context-files --no-session --no-tools < prompt > answer.txt
      ;;
    grok)
      "$HARNESS_BIN" -p --prompt-file prompt --tools "" --no-memory --disable-web-search > answer.txt
      ;;
    kimi)
      KIMI_CODE_EXPERIMENTAL_FLAG=1 "$HARNESS_BIN" -p "Answer the supplied system prompt." \
        --output-format text --agent-file kimi-agent.yaml --skills-dir skills > answer.txt
      ;;
    muse)
      MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on \
        "$HARNESS_BIN" exec --no-foreign-personal-context --no-tools --no-session-log \
        --workspace "$LANE_TMP" --prompt-file prompt > answer.txt
      ;;
  esac
)

[ -f "$ANSWER" ] && [ ! -L "$ANSWER" ] && [ -s "$ANSWER" ] \
  || { echo "fm-domain-question: lane returned no valid answer" >&2; exit 2; }
cat "$ANSWER"
