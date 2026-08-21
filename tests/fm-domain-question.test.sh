#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISPATCH="$ROOT/bin/fm-domain-question.sh"
TMP_ROOT=$(fm_test_tmproot fm-domain-question)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config/domain-bindings" "$HOME_DIR/data/domains/sale" \
  "$HOME_DIR/data/domains/pnl" "$HOME_DIR/data/sources/sale" "$HOME_DIR/state"
printf '%s\n' '{"chat_domains":{"-1001":"sale"}}' > "$HOME_DIR/routes.json"
printf '%s\n' '{"mode":"read-only","source":"data/sources/sale"}' > "$HOME_DIR/config/domain-bindings/sale.json"
printf '%s\n' 'sale memory' > "$HOME_DIR/data/domains/sale/brief.md"
printf '%s\n' 'pnl secret' > "$HOME_DIR/data/domains/pnl/brief.md"
printf '%s\n' 'sale facts' > "$HOME_DIR/data/sources/sale/facts.txt"
printf '%s\n' 'ambient claude secret' > "$HOME_DIR/CLAUDE.md"
printf '%s\n' 'ambient agents secret' > "$HOME_DIR/AGENTS.md"

FAKE_HARNESS="$TMP_ROOT/harness"
cat > "$FAKE_HARNESS" <<'RUNNER'
#!/bin/sh
set -eu
tools_disabled=0
pure=0
isolated=0
prompt_file=
agent_file=
previous=
for argument in "$@"; do
  if [ "$previous" = tools ] && [ -z "$argument" ]; then tools_disabled=1; fi
  if [ "$previous" = prompt_file ]; then prompt_file=$argument; fi
  if [ "$previous" = agent_file ]; then agent_file=$argument; fi
  if [ "$argument" = --no-tools ]; then tools_disabled=1; fi
  if [ "$argument" = --pure ]; then pure=1; fi
  case "$argument" in
    --tools) previous=tools ;;
    --prompt-file) previous=prompt_file ;;
    --agent-file) previous=agent_file ;;
    *) previous= ;;
  esac
done
[ "${PWD##*/}" != "home" ]
case "$PWD" in */state/.domain-lane.*) isolated=1 ;; esac
[ "$isolated" -eq 1 ]
[ ! -e CLAUDE.md ] && [ ! -e AGENTS.md ]
case "${FM_DOMAIN_HARNESS:-}" in
  grok|muse) [ "$prompt_file" = prompt ]; payload=$(cat "$prompt_file") ;;
  kimi)
    [ "$agent_file" = kimi-agent.yaml ]
    [ "${KIMI_CODE_EXPERIMENTAL_FLAG:-}" = 1 ]
    grep -Fx '  tools: []' "$agent_file" >/dev/null
    tools_disabled=1
    payload=$(cat prompt)
    ;;
  *) payload=$(cat) ;;
esac
if [ "${FM_DOMAIN_HARNESS:-}" = opencode ]; then
  [ "$pure" -eq 1 ]
  [ "${OPENCODE_CONFIG_CONTENT:-}" = '{"instructions":[],"permission":{"*":"deny"}}' ]
else
  [ "$tools_disabled" -eq 1 ]
fi
printf '%s' "$payload" | grep -F 'sale memory' >/dev/null
printf '%s' "$payload" | grep -F 'sale facts' >/dev/null
if printf '%s' "$payload" | grep -F 'pnl secret' >/dev/null; then exit 23; fi
if printf '%s' "$payload" | grep -F 'ambient claude secret' >/dev/null; then exit 24; fi
if printf '%s' "$payload" | grep -F 'ambient agents secret' >/dev/null; then exit 25; fi
printf '%s\n' 'sale lane answer'
RUNNER
chmod +x "$FAKE_HARNESS"

run_lane() {
  FM_HOME="$HOME_DIR" FM_DOMAIN_HARNESS="${FM_TEST_DOMAIN_HARNESS:-claude}" FM_DOMAIN_HARNESS_BIN="$FAKE_HARNESS" \
    "$DISPATCH" --routes "$HOME_DIR/routes.json" "$INBOX"
}

INBOX="$TMP_ROOT/inbox.json"
printf '%s\n' '{"chat_id":-1001,"text":"#Com.pnl compare performance"}' > "$INBOX"
out=$(run_lane) || fail "mapped question must dispatch its constrained lane"
[ "$out" = 'sale lane answer' ] || fail "lane answer must be returned"
pass "current harness receives only selected snapshots without tools"

out=$(FM_TEST_DOMAIN_HARNESS=pi run_lane) || fail "Pi must use the same harness-neutral lane boundary"
[ "$out" = 'sale lane answer' ] || fail "Pi lane answer must be returned"
pass "harness-neutral dispatch does not require Codex"

for harness in claude opencode pi pi-signed grok kimi muse; do
  out=$(FM_TEST_DOMAIN_HARNESS="$harness" run_lane) || fail "$harness must dispatch in an isolated tool-free lane"
  [ "$out" = 'sale lane answer' ] || fail "$harness lane answer must be returned"
done
pass "all supported harnesses use isolated tool-free one-shot adapters"

printf '%s\n' '{"text":"tag fallback #Com.sale"}' > "$INBOX"
out=$(run_lane) || fail "tagged question without chat_id must route"
[ "$out" = 'sale lane answer' ] || fail "tag fallback lane answer must be returned"
pass "missing chat ids fall through to tag routing"

printf '%s\n' '{"chat_id":null,"text":"#Com.sale"}' > "$INBOX"
if run_lane >/dev/null 2>&1; then fail "malformed supplied chat_id must fail closed"; fi
pass "malformed supplied chat ids fail closed"

printf '%s\n' '{"chat_id":-999,"text":"untagged question"}' > "$INBOX"
if run_lane >/dev/null 2>&1; then fail "untagged question must require clarification"; fi
pass "every unrouteable question fails closed before dispatch"

printf '%s\n' '{"mode":"write","source":"data/sources/sale"}' > "$HOME_DIR/config/domain-bindings/sale.json"
printf '%s\n' '{"chat_id":-1001,"text":"question"}' > "$INBOX"
if run_lane >/dev/null 2>&1; then fail "writable binding must fail closed"; fi
pass "writable bindings are rejected before dispatch"

printf '%s\n' '{"mode":"read-only","source":"data/sources/sale"}' > "$HOME_DIR/config/domain-bindings/sale.json"
dd if=/dev/zero bs=1048576 count=3 2>/dev/null | tr '\0' x > "$HOME_DIR/data/sources/sale/large.txt"
printf '%s\n' '{"chat_id":-1001,"text":"large source"}' > "$INBOX"
out=$(run_lane) || fail "large snapshots must stream without argv expansion"
[ "$out" = 'sale lane answer' ] || fail "large snapshot lane answer must be returned"
pass "multi-megabyte snapshots stream outside argv"

if FM_HOME="$HOME_DIR" FM_DOMAIN_HARNESS=unknown FM_DOMAIN_HARNESS_BIN="$FAKE_HARNESS" \
  "$DISPATCH" --routes "$HOME_DIR/routes.json" "$INBOX" >/dev/null 2>&1; then
  fail "unknown harness boundary must fail closed"
fi
pass "unknown harnesses fail closed"
