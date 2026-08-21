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
PLATFORM=${FM_DOMAIN_PLATFORM:-$(uname -s)}
case "$PLATFORM" in
  Linux) command -v bwrap >/dev/null 2>&1 || { echo "fm-domain-question: missing bubblewrap" >&2; exit 2; } ;;
  Darwin) command -v sandbox-exec >/dev/null 2>&1 || { echo "fm-domain-question: missing sandbox-exec" >&2; exit 2; } ;;
  *) echo "fm-domain-question: unsupported isolation platform: $PLATFORM" >&2; exit 2 ;;
esac

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

CODEX_BIN=${FM_DOMAIN_CODEX_BIN:-$(command -v codex 2>/dev/null || true)}
[ -n "$CODEX_BIN" ] || { echo "fm-domain-question: missing codex" >&2; exit 2; }
CODEX_BIN=$(realpath "$CODEX_BIN")
[ -f "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] || { echo "fm-domain-question: invalid codex executable" >&2; exit 2; }
AUTH=${FM_DOMAIN_CODEX_AUTH:-${CODEX_HOME:-$HOME/.codex}/auth.json}
[ -f "$AUTH" ] && [ ! -L "$AUTH" ] || { echo "fm-domain-question: missing Codex authentication" >&2; exit 2; }

LANE_TMP=$(mktemp -d "$FM_HOME/state/.domain-lane.XXXXXX") || exit 2
trap 'rm -rf "$LANE_TMP"' EXIT INT TERM
mkdir -p "$LANE_TMP/output"
mkdir -p "$LANE_TMP/scratch/home/.codex" "$LANE_TMP/scratch/tmp"
touch "$LANE_TMP/output/answer.txt"

CODEX_MOUNTS=(--ro-bind "$CODEX_BIN" /opt/codex)
CODEX_LAUNCH=(/opt/codex)
HOST_CODEX_LAUNCH=("$CODEX_BIN")
if [ "${CODEX_BIN##*.}" = js ]; then
  CODEX_ROOT=$(CDPATH='' cd "$(dirname "$CODEX_BIN")/.." && pwd -P)
  NODE_BIN=$(realpath "$(command -v node)")
  CODEX_MOUNTS=(--ro-bind "$CODEX_ROOT" /opt/codex-package --ro-bind "$NODE_BIN" /opt/node)
  CODEX_LAUNCH=(/opt/node /opt/codex-package/bin/codex.js)
  HOST_CODEX_LAUNCH=("$NODE_BIN" "$CODEX_BIN")
fi

if [ "$PLATFORM" = Darwin ]; then
  ln -s "$MEMORY" "$LANE_TMP/scratch/memory"
  ln -s "$SOURCE" "$LANE_TMP/scratch/data"
  ln -s "$BINDING" "$LANE_TMP/scratch/binding.json"
  ln -s "$AUTH" "$LANE_TMP/scratch/home/.codex/auth.json"
fi

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
MEMORY_SNAPSHOT=$(snapshot_path "$MEMORY") || { echo "fm-domain-question: invalid domain memory: $DOMAIN" >&2; exit 2; }
DATA_SNAPSHOT=$(snapshot_path "$SOURCE") || { echo "fm-domain-question: invalid domain source: $DOMAIN" >&2; exit 2; }
jq -n --arg domain "$DOMAIN" --arg question "$TEXT" --argjson memory "$MEMORY_SNAPSHOT" \
  --argjson data "$DATA_SNAPSHOT" --slurpfile binding "$BINDING" '
  "You are an ephemeral domain-question lane with no tools. Answer only from the supplied JSON inputs. " +
  "Do not use outside knowledge or infer another domain.\n\n" +
  ({domain:$domain,question:$question,memory:$memory,data_binding:$binding[0],data:$data} | tojson)
' -r > "$LANE_TMP/prompt"

CODEX_ARGS=(exec --ephemeral --ignore-user-config --ignore-rules --sandbox read-only --skip-git-repo-check \
  --disable shell_tool --disable unified_exec --disable code_mode_host --disable apps --disable browser_use \
  --disable browser_use_external --disable computer_use --disable image_generation --disable multi_agent \
  --disable multi_agent_v2 --disable skill_search --disable tool_suggest --disable view_image)

if [ "$PLATFORM" = Linux ]; then
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
    "${CODEX_LAUNCH[@]}" "${CODEX_ARGS[@]}" -C /lane --output-last-message /output/answer.txt - \
    < "$LANE_TMP/prompt" >/dev/null
else
  seatbelt_path() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  CODEX_READ=$(seatbelt_path "$(dirname "$CODEX_BIN")")
  NODE_READ=$CODEX_READ
  if [ "${CODEX_BIN##*.}" = js ]; then
    CODEX_READ=$(seatbelt_path "$CODEX_ROOT")
    NODE_READ=$(seatbelt_path "$(dirname "$NODE_BIN")")
  fi
  AUTH_READ=$(seatbelt_path "$AUTH")
  MEMORY_READ=$(seatbelt_path "$MEMORY")
  BINDING_READ=$(seatbelt_path "$BINDING")
  SOURCE_READ=$(seatbelt_path "$SOURCE")
  SCRATCH_ACCESS=$(seatbelt_path "$LANE_TMP/scratch")
  OUTPUT_ACCESS=$(seatbelt_path "$LANE_TMP/output")
  PROFILE="$LANE_TMP/lane.sb"
  printf '%s\n' \
    '(version 1)' \
    '(deny default)' \
    '(allow process* signal sysctl-read mach-lookup ipc-posix-shm network*)' \
    '(allow file-read* (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/Library") (subpath "/private/etc") (subpath "/private/var/db/timezone") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))' \
    "(allow file-read* (subpath \"$CODEX_READ\") (subpath \"$NODE_READ\") (literal \"$AUTH_READ\") (subpath \"$MEMORY_READ\") (literal \"$BINDING_READ\") (subpath \"$SOURCE_READ\") (subpath \"$SCRATCH_ACCESS\"))" \
    "(allow file-write* (subpath \"$SCRATCH_ACCESS\") (subpath \"$OUTPUT_ACCESS\"))" \
    > "$PROFILE"
  (
    cd "$LANE_TMP/scratch"
    sandbox-exec -f "$PROFILE" /usr/bin/env -i HOME="$LANE_TMP/scratch/home" \
      CODEX_HOME="$LANE_TMP/scratch/home/.codex" TMPDIR="$LANE_TMP/scratch/tmp" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      "${HOST_CODEX_LAUNCH[@]}" "${CODEX_ARGS[@]}" -C "$LANE_TMP/scratch" \
      --output-last-message "$LANE_TMP/output/answer.txt" - \
      < "$LANE_TMP/prompt" >/dev/null
  )
fi

[ -f "$LANE_TMP/output/answer.txt" ] && [ ! -L "$LANE_TMP/output/answer.txt" ] && [ -s "$LANE_TMP/output/answer.txt" ] \
  || { echo "fm-domain-question: lane returned no valid answer" >&2; exit 2; }
cat "$LANE_TMP/output/answer.txt"
