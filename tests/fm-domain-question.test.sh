#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISPATCH="$ROOT/bin/fm-domain-question.sh"
TMP_ROOT=$(fm_test_tmproot fm-domain-question)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config/domain-bindings" "$HOME_DIR/data/domains/sale" "$HOME_DIR/data/domains/pnl"
printf '%s\n' '{"chat_domains":{"-1001":"sale"}}' > "$HOME_DIR/routes.json"
printf '%s\n' '{"mode":"read-only","source":"sale-view"}' > "$HOME_DIR/config/domain-bindings/sale.json"
printf '%s\n' '{"mode":"read-only","source":"pnl-view"}' > "$HOME_DIR/config/domain-bindings/pnl.json"
printf '%s\n' 'sale memory' > "$HOME_DIR/data/domains/sale/brief.md"
printf '%s\n' 'pnl secret' > "$HOME_DIR/data/domains/pnl/brief.md"

RUNNER="$TMP_ROOT/runner"
cat > "$RUNNER" <<'RUNNER'
#!/usr/bin/env bash
set -eu
payload=$(cat)
printf '%s' "$payload" | jq -e '
  .schema == "fm-domain-lane.v1" and
  .ephemeral == true and
  .domain == "sale" and
  .data_binding.mode == "read-only" and
  .data_binding.source == "sale-view" and
  (.memory | length) == 1 and
  .memory[0].content == "sale memory\n"
' >/dev/null
if printf '%s' "$payload" | jq -e '.. | strings | select(contains("pnl secret"))' >/dev/null; then
  exit 9
fi
printf '%s\n' 'sale lane answer'
RUNNER
chmod +x "$RUNNER"

INBOX="$TMP_ROOT/inbox.json"
printf '%s\n' '{"chat_id":-1001,"text":"#Com.pnl compare performance"}' > "$INBOX"
out=$(FM_HOME="$HOME_DIR" "$DISPATCH" --routes "$HOME_DIR/routes.json" --runner "$RUNNER" "$INBOX") \
  || fail "mapped question must dispatch its constrained lane"
[ "$out" = 'sale lane answer' ] || fail "lane answer must be returned"
pass "mapped questions dispatch only selected memory and a read-only binding"

CALLED="$TMP_ROOT/called"
REFUSING_RUNNER="$TMP_ROOT/refusing-runner"
cat > "$REFUSING_RUNNER" <<RUNNER
#!/usr/bin/env bash
touch '$CALLED'
RUNNER
chmod +x "$REFUSING_RUNNER"
printf '%s\n' '{"chat_id":-999,"text":"untagged question"}' > "$INBOX"
if FM_HOME="$HOME_DIR" "$DISPATCH" --routes "$HOME_DIR/routes.json" --runner "$REFUSING_RUNNER" "$INBOX" >/dev/null 2>&1; then
  fail "untagged question must require clarification"
fi
[ ! -e "$CALLED" ] || fail "clarification path must not invoke a lane"
pass "every unrouteable question fails closed before dispatch"

printf '%s\n' '{"mode":"write","source":"sale-view"}' > "$HOME_DIR/config/domain-bindings/sale.json"
printf '%s\n' '{"chat_id":-1001,"text":"question"}' > "$INBOX"
if FM_HOME="$HOME_DIR" "$DISPATCH" --routes "$HOME_DIR/routes.json" --runner "$REFUSING_RUNNER" "$INBOX" >/dev/null 2>&1; then
  fail "writable binding must fail closed"
fi
[ ! -e "$CALLED" ] || fail "invalid binding must not invoke a lane"
pass "writable bindings are rejected before dispatch"
