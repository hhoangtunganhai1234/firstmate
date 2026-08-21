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
AUTH="$TMP_ROOT/auth.json"
printf '%s\n' '{}' > "$AUTH"

RUNNER_DIR="$TMP_ROOT/runner-bin"
mkdir -p "$RUNNER_DIR"
FAKE_CODEX="$RUNNER_DIR/codex"
cat > "$FAKE_CODEX" <<RUNNER
#!/bin/sh
set -eu
answer=
previous=
shell_disabled=0
for argument in "\$@"; do
  if [ "\$previous" = output ]; then answer=\$argument; fi
  if [ "\$previous" = disable ] && [ "\$argument" = shell_tool ]; then shell_disabled=1; fi
  case "\$argument" in
    --output-last-message) previous=output ;;
    --disable) previous=disable ;;
    *) previous= ;;
  esac
done
[ "\$shell_disabled" -eq 1 ]
if [ "\$(pwd)" = /lane ]; then
  [ "\$(cat /lane/memory/brief.md)" = 'sale memory' ]
  [ "\$(cat /lane/data/facts.txt)" = 'sale facts' ]
  [ ! -e '$HOME_DIR/data/domains/pnl' ]
  if printf probe > /lane/data/probe 2>/dev/null; then exit 20; fi
else
  [ "\$(cat memory/brief.md)" = 'sale memory' ]
  [ "\$(cat data/facts.txt)" = 'sale facts' ]
  if cat '$HOME_DIR/data/domains/pnl/brief.md' >/dev/null 2>&1; then exit 21; fi
  if printf probe > data/probe 2>/dev/null; then exit 22; fi
fi
payload=\$(cat)
printf '%s' "\$payload" | grep -F 'sale memory' >/dev/null
printf '%s' "\$payload" | grep -F 'sale facts' >/dev/null
if printf '%s' "\$payload" | grep -F 'pnl secret' >/dev/null; then exit 23; fi
printf '%s\n' 'sale lane answer' > "\$answer"
RUNNER
chmod +x "$FAKE_CODEX"

INBOX="$TMP_ROOT/inbox.json"
printf '%s\n' '{"chat_id":-1001,"text":"#Com.pnl compare performance"}' > "$INBOX"
out=$(FM_HOME="$HOME_DIR" FM_DOMAIN_CODEX_BIN="$FAKE_CODEX" FM_DOMAIN_CODEX_AUTH="$AUTH" \
  "$DISPATCH" --routes "$HOME_DIR/routes.json" "$INBOX") \
  || fail "mapped question must dispatch its constrained lane"
[ "$out" = 'sale lane answer' ] || fail "lane answer must be returned"
[ ! -e "$HOME_DIR/data/sources/sale/probe" ] || fail "lane must not mutate its bound data source"
pass "real lane entry point isolates memory and read-only data"

if [ "$(uname -s)" = Darwin ]; then
  pass "Darwin sandbox-exec denies cross-domain reads and data writes"
else
  printf '%s\n' "skip - Darwin sandbox-exec isolation proof requires macOS"
fi

printf '%s\n' '{"text":"tag fallback #Com.sale"}' > "$INBOX"
out=$(FM_HOME="$HOME_DIR" FM_DOMAIN_CODEX_BIN="$FAKE_CODEX" FM_DOMAIN_CODEX_AUTH="$AUTH" \
  "$DISPATCH" --routes "$HOME_DIR/routes.json" "$INBOX") \
  || fail "tagged question without chat_id must route"
[ "$out" = 'sale lane answer' ] || fail "tag fallback lane answer must be returned"
pass "missing chat ids fall through to tag routing"

printf '%s\n' '{"chat_id":null,"text":"#Com.sale"}' > "$INBOX"
if FM_HOME="$HOME_DIR" FM_DOMAIN_CODEX_BIN="$FAKE_CODEX" FM_DOMAIN_CODEX_AUTH="$AUTH" \
  "$DISPATCH" --routes "$HOME_DIR/routes.json" "$INBOX" >/dev/null 2>&1; then
  fail "malformed supplied chat_id must fail closed"
fi
pass "malformed supplied chat ids fail closed"

printf '%s\n' '{"chat_id":-999,"text":"untagged question"}' > "$INBOX"
if FM_HOME="$HOME_DIR" FM_DOMAIN_CODEX_BIN="$FAKE_CODEX" FM_DOMAIN_CODEX_AUTH="$AUTH" \
  "$DISPATCH" --routes "$HOME_DIR/routes.json" "$INBOX" >/dev/null 2>&1; then
  fail "untagged question must require clarification"
fi
pass "every unrouteable question fails closed before dispatch"

printf '%s\n' '{"mode":"write","source":"data/sources/sale"}' > "$HOME_DIR/config/domain-bindings/sale.json"
printf '%s\n' '{"chat_id":-1001,"text":"question"}' > "$INBOX"
if FM_HOME="$HOME_DIR" FM_DOMAIN_CODEX_BIN="$FAKE_CODEX" FM_DOMAIN_CODEX_AUTH="$AUTH" \
  "$DISPATCH" --routes "$HOME_DIR/routes.json" "$INBOX" >/dev/null 2>&1; then
  fail "writable binding must fail closed"
fi
pass "writable bindings are rejected before dispatch"
