#!/usr/bin/env bash
# tests/fm-codex-telegram-waker.test.sh - public-behavior regression for the
# externally owned Codex Telegram waker and its bounded user-systemd lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAKER="$ROOT/bin/fm-codex-telegram-waker.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-telegram-waker)
NETWORK_LOG="$TMP_ROOT/network.log"
: > "$NETWORK_LOG"
BACKGROUND_PID=

cleanup() {
  if [ -n "$BACKGROUND_PID" ]; then
    kill "$BACKGROUND_PID" 2>/dev/null || true
    wait "$BACKGROUND_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

make_fake_tools() {  # <case-dir>
  local dir=$1 fakebin="$1/fakebin" tool
  mkdir -p "$fakebin"
cat > "$fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_SYSTEMCTL_LOG:?}"
case "$*" in
  '--user disable --now firstmate-codex-telegram-waker.path')
    exit "${FM_FAKE_DISABLE_STATUS:-0}"
    ;;
  '--user stop firstmate-codex-telegram-waker.service')
    exit "${FM_FAKE_STOP_STATUS:-0}"
    ;;
  '--user show --property=ActiveState --value firstmate-codex-telegram-waker.service')
    [ "${FM_FAKE_ACTIVE_QUERY_STATUS:-0}" -eq 0 ] || exit "$FM_FAKE_ACTIVE_QUERY_STATUS"
    printf '%s\n' "${FM_FAKE_ACTIVE_STATE:-inactive}"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case " $* " in
  *' -o comm= '*) printf '%s\n' "${FM_FAKE_PS_COMM:-codex}" ;;
  *' -o args= '*) printf '%s\n' "${FM_FAKE_PS_ARGS:-codex}" ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_CALLS:?}"
case "${1:-}" in
  list-panes)
    printf '%%17|%s\n' "${FM_FAKE_TTY:?}"
    if [ "${FM_FAKE_TMUX_AMBIGUOUS:-0}" = 1 ]; then
      printf '%%18|%s\n' "${FM_FAKE_TTY:?}"
    fi
    ;;
  display-message)
    format=${*: -1}
    case "$format" in
      '#{pane_dead}') printf '0\n' ;;
      '#{pane_current_path}') printf '%s\n' "${FM_FAKE_PANE_PATH:-${FM_FAKE_HOME:?}}" ;;
      '#{pane_tty}') printf '%s\n' "${FM_FAKE_TTY:?}" ;;
      '#{pane_id}') printf '%%17\n' ;;
      '#{cursor_y}') printf '0\n' ;;
      *) exit 1 ;;
    esac
    ;;
  capture-pane)
    mode=$(cat "${FM_FAKE_COMPOSER_MODE:?}")
    case "$mode" in
      empty)
        printf '›\n'
        if [ "${FM_FAKE_DROP_BINDING_AFTER_COMPOSER:-0}" = 1 ]; then
          rm -rf -- "${FM_PROC_ROOT_OVERRIDE:?}/${FM_FAKE_PRIMARY_PID:?}"
        fi
        ;;
      busy) printf 'esc to interrupt\n' ;;
      pending) printf '› captain draft\n' ;;
      unknown) printf '$ shell\n' ;;
      unreadable) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  send-keys)
    target= literal=0 text= is_enter=0
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) target=${2:-}; shift 2; continue ;;
        -l) literal=1; shift; text=${1:-}; shift; continue ;;
        Enter) is_enter=1 ;;
      esac
      shift
    done
    if [ "$literal" -eq 1 ]; then
      printf 'literal\t%s\t%s\n' "$target" "$text" >> "${FM_FAKE_SEND_LOG:?}"
    elif [ "$is_enter" -eq 1 ]; then
      printf 'enter\t%s\n' "$target" >> "${FM_FAKE_SEND_LOG:?}"
      printf 'empty\n' > "${FM_FAKE_COMPOSER_MODE:?}"
    fi
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_FAKE_REMOVE_PROC_ON_SLEEP:-0}" = 1 ] && [ ! -f "${FM_FAKE_SLEEP_ONCE:?}" ]; then
  : > "$FM_FAKE_SLEEP_ONCE"
  rm -rf -- "${FM_PROC_ROOT_OVERRIDE:?}/${FM_FAKE_PRIMARY_PID:?}"
  exit 0
fi
if [ "${FM_FAKE_REUSE_PROC_ON_SLEEP:-0}" = 1 ] && [ ! -f "${FM_FAKE_SLEEP_ONCE:?}" ]; then
  : > "$FM_FAKE_SLEEP_ONCE"
  printf 'codex\0--reused-identity\0' > "${FM_PROC_ROOT_OVERRIDE:?}/${FM_FAKE_PRIMARY_PID:?}/cmdline"
  exit 0
fi
/bin/sleep "$@"
SH
  for tool in curl wget nc ncat socat connector fm-x-poll.sh; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\t%s\n' "${0##*/}" "$*" >> "${FM_FAKE_NETWORK_LOG:?}"
exit 97
SH
  done
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

make_case() {  # <name>
  local name=$1 dir pid=$$ fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/xdg" "$dir/proc/$pid/fd"
  : > "$dir/bridge.log"
  : > "$dir/systemctl.log"
  : > "$dir/tmux.log"
  : > "$dir/send.log"
  printf 'empty\n' > "$dir/composer"
  printf '%s\n' "$pid" > "$dir/home/state/.lock"
  cp "/proc/$pid/stat" "$dir/proc/$pid/stat"
  printf 'codex\0--firstmate-test\0' > "$dir/proc/$pid/cmdline"
  printf 'TMUX=/tmp/fm-test-tmux.sock,9001,0\0' > "$dir/proc/$pid/environ"
  ln -s /dev/pts/99 "$dir/proc/$pid/fd/0"
  fakebin=$(make_fake_tools "$dir")
  printf '%s\n' "$fakebin" > "$dir/fakebin.path"
  printf '%s\n' "$dir"
}

run_env() {  # <case-dir> <command...>
  local dir=$1 fakebin
  shift
  fakebin=$(cat "$dir/fakebin.path")
  env \
    HOME="$dir/user" \
    XDG_CONFIG_HOME="$dir/xdg" \
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_PROC_ROOT_OVERRIDE="$dir/proc" \
    FM_FAKE_PRIMARY_PID="$$" \
    FM_FAKE_HOME="$dir/home" \
    FM_FAKE_TTY=/dev/pts/99 \
    FM_FAKE_SYSTEMCTL_LOG="$dir/systemctl.log" \
    FM_FAKE_TMUX_CALLS="$dir/tmux.log" \
    FM_FAKE_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_MODE="$dir/composer" \
    FM_FAKE_SLEEP_ONCE="$dir/sleep.once" \
    FM_FAKE_NETWORK_LOG="$NETWORK_LOG" \
    PATH="$fakebin:$PATH" \
    "$@"
}

install_case() {  # <case-dir>
  run_env "$1" "$WAKER" install --bridge-log "$1/bridge.log" >/dev/null
}

run_case() {  # <case-dir> [extra env NAME=VALUE...]
  local dir=$1 fakebin
  shift
  fakebin=$(cat "$dir/fakebin.path")
  env \
    HOME="$dir/user" \
    XDG_CONFIG_HOME="$dir/xdg" \
    FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_PROC_ROOT_OVERRIDE="$dir/proc" \
    FM_FAKE_PRIMARY_PID="$$" \
    FM_FAKE_HOME="$dir/home" \
    FM_FAKE_TTY=/dev/pts/99 \
    FM_FAKE_SYSTEMCTL_LOG="$dir/systemctl.log" \
    FM_FAKE_TMUX_CALLS="$dir/tmux.log" \
    FM_FAKE_SEND_LOG="$dir/send.log" \
    FM_FAKE_COMPOSER_MODE="$dir/composer" \
    FM_FAKE_SLEEP_ONCE="$dir/sleep.once" \
    FM_FAKE_NETWORK_LOG="$NETWORK_LOG" \
    FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS=1 \
    FM_CODEX_TELEGRAM_WAKER_POLL_SECONDS=0 \
    FM_CODEX_TELEGRAM_WAKER_RETRY_SECONDS=0 \
    FM_CODEX_TELEGRAM_WAKER_CONFIRM_SLEEP=0 \
    FM_CODEX_TELEGRAM_WAKER_CONFIRM_RETRIES=1 \
    PATH="$fakebin:$PATH" \
    "$@" "$WAKER" run --bridge-log "$dir/bridge.log"
}

literal_count() {  # <case-dir>
  grep -c '^literal' "$1/send.log" 2>/dev/null || true
}

test_install_uninstall_are_bounded() {
  local dir units before after verify_out
  dir=$(make_case lifecycle)
  mkdir -p "$dir/xdg/systemd/user" "$dir/home/state/keep"
  printf 'keep\n' > "$dir/xdg/systemd/user/captain.service"
  printf 'keep\n' > "$dir/home/state/keep/sentinel"
  install_case "$dir"
  units="$dir/xdg/systemd/user"
  [ -f "$units/firstmate-codex-telegram-waker.path" ] || fail 'install did not publish the path unit'
  [ -f "$units/firstmate-codex-telegram-waker.service" ] || fail 'install did not publish the service unit'
  [ "$(find "$units" -maxdepth 1 -type f | wc -l)" -eq 3 ] || fail 'install wrote beyond its two units'
  grep -F 'enable --now firstmate-codex-telegram-waker.path' "$dir/systemctl.log" >/dev/null \
    || fail 'install did not enable the exact path unit'
  if command -v systemd-analyze >/dev/null 2>&1; then
    verify_out=$(systemd-analyze verify "$units/firstmate-codex-telegram-waker.service" \
      "$units/firstmate-codex-telegram-waker.path" 2>&1) \
      || fail "systemd rejected the generated user units: $verify_out"
  fi
  before=$(cat "$dir/home/state/keep/sentinel")
  run_env "$dir" "$WAKER" uninstall >/dev/null
  [ ! -e "$units/firstmate-codex-telegram-waker.path" ] || fail 'uninstall left the path unit'
  [ ! -e "$units/firstmate-codex-telegram-waker.service" ] || fail 'uninstall left the service unit'
  [ -f "$units/captain.service" ] || fail 'uninstall removed an unrelated user unit'
  [ ! -e "$dir/home/state/codex-telegram-waker" ] || fail 'uninstall left private waker state'
  after=$(cat "$dir/home/state/keep/sentinel")
  [ "$before" = "$after" ] || fail 'uninstall changed unrelated Firstmate state'
  pass 'Codex Telegram waker install and uninstall remain narrowly bounded and systemd-valid'
}

test_uninstall_refuses_foreign_unit() {
  local dir units out
  dir=$(make_case foreign-unit)
  units="$dir/xdg/systemd/user"
  mkdir -p "$units"
  printf '[Service]\nExecStart=/bin/true\n' > "$units/firstmate-codex-telegram-waker.service"
  set +e
  out=$(run_env "$dir" "$WAKER" uninstall 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'uninstall accepted a foreign colliding unit'
  [ -f "$units/firstmate-codex-telegram-waker.service" ] || fail 'uninstall removed a foreign colliding unit'
  assert_contains "$out" 'refusing to remove foreign' 'foreign-unit refusal was not explicit'
  pass 'Codex Telegram waker uninstall refuses foreign unit ownership'
}

test_uninstall_preserves_files_when_lifecycle_fails() {
  local dir units out status mode
  for mode in disable stop active query; do
    dir=$(make_case "uninstall-$mode-failure")
    install_case "$dir"
    units="$dir/xdg/systemd/user"
    set +e
    case "$mode" in
      disable) out=$(run_env "$dir" env FM_FAKE_DISABLE_STATUS=1 "$WAKER" uninstall 2>&1) ;;
      stop) out=$(run_env "$dir" env FM_FAKE_STOP_STATUS=1 "$WAKER" uninstall 2>&1) ;;
      active) out=$(run_env "$dir" env FM_FAKE_ACTIVE_STATE=active "$WAKER" uninstall 2>&1) ;;
      query) out=$(run_env "$dir" env FM_FAKE_ACTIVE_QUERY_STATUS=1 "$WAKER" uninstall 2>&1) ;;
    esac
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "uninstall accepted a $mode lifecycle failure"
    [ -f "$units/firstmate-codex-telegram-waker.path" ] || fail "uninstall removed its path unit after a $mode lifecycle failure"
    [ -f "$units/firstmate-codex-telegram-waker.service" ] || fail "uninstall removed its service unit after a $mode lifecycle failure"
    [ -d "$dir/home/state/codex-telegram-waker" ] || fail "uninstall removed runtime state after a $mode lifecycle failure"
    assert_contains "$out" 'no files were removed' "$mode lifecycle refusal did not promise preservation"
  done
  pass 'Codex Telegram waker uninstall preserves units and state unless shutdown is proven'
}

test_state_symlink_is_rejected_before_uninstall() {
  local dir units external out status
  dir=$(make_case state-symlink)
  install_case "$dir"
  units="$dir/xdg/systemd/user"
  external="$dir/external-state"
  mv "$dir/home/state" "$external"
  ln -s "$external" "$dir/home/state"
  : > "$dir/systemctl.log"
  set +e
  out=$(run_env "$dir" "$WAKER" uninstall 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'uninstall accepted a symlinked FM_HOME/state directory'
  [ -d "$external/codex-telegram-waker" ] || fail 'uninstall deleted runtime state through the state symlink'
  [ -f "$units/firstmate-codex-telegram-waker.path" ] || fail 'uninstall removed its path unit despite unsafe state ownership'
  [ -f "$units/firstmate-codex-telegram-waker.service" ] || fail 'uninstall removed its service unit despite unsafe state ownership'
  [ ! -s "$dir/systemctl.log" ] || fail "unsafe state ownership reached systemd lifecycle operations: $(cat "$dir/systemctl.log")"
  assert_contains "$out" 'requires a non-symlink FM_HOME/state directory' \
    'state-symlink refusal did not identify the ownership boundary'
  pass 'Codex Telegram waker rejects state symlinks before lifecycle mutation'
}

test_busy_pending_and_unknown_defer() {
  local mode dir
  for mode in busy pending unknown unreadable; do
    dir=$(make_case "defer-$mode")
    install_case "$dir"
    printf '%s\n' "$mode" > "$dir/composer"
    printf '2026-08-14T00:00:00Z queued tg-%s\n' "$mode" >> "$dir/bridge.log"
    run_case "$dir" >/dev/null 2>&1 || fail "$mode deferral run failed"
    [ "$(literal_count "$dir")" -eq 0 ] || fail "$mode state allowed an injection"
  done
  pass 'Codex busy, pending, unknown, and unreadable composer states all defer without typing'
}

test_failure_b_retries_until_matching_offered() {
  local dir count out
  dir=$(make_case failure-b)
  install_case "$dir"
  printf '2026-08-14T00:00:00Z queued tg-failure-b\n' >> "$dir/bridge.log"
  out=$(run_case "$dir" FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS=2 2>&1) \
    || fail "Failure B replay run failed: $out"
  count=$(literal_count "$dir")
  [ "$count" -eq 2 ] \
    || fail "Failure B should retry without offered, saw $count nudges; output=$out; state=$(cat "$dir/home/state/codex-telegram-waker/state")"
  printf '2026-08-14T00:00:01Z offered tg-someone-else\n' >> "$dir/bridge.log"
  run_case "$dir" >/dev/null 2>&1 || fail 'non-matching offered replay failed'
  [ "$(literal_count "$dir")" -eq 3 ] || fail 'a non-matching offered record cleared the pending request'
  printf '2026-08-14T00:00:02Z offered tg-failure-b\n' >> "$dir/bridge.log"
  run_case "$dir" >/dev/null 2>&1 || fail 'matching offered replay failed'
  [ "$(literal_count "$dir")" -eq 3 ] || fail 'matching offered did not stop retries'
  grep -F $'literal\t%17\t' "$dir/send.log" >/dev/null \
    || fail 'injection did not use the exact uniquely bound pane id'
  pass 'Failure B keeps retrying until the matching offered record and targets only the exact bound pane'
}

test_cursor_and_pending_survive_restart() {
  local dir before
  dir=$(make_case crash-recovery)
  install_case "$dir"
  printf '2026-08-14T00:00:00Z queued tg-crash' >> "$dir/bridge.log"
  before=$(sed -n '2p' "$dir/home/state/codex-telegram-waker/state")
  run_case "$dir" >/dev/null 2>&1 || fail 'partial-line recovery pass failed'
  [ "$(literal_count "$dir")" -eq 0 ] || fail 'partial bridge record was consumed'
  [ "$(sed -n '2p' "$dir/home/state/codex-telegram-waker/state")" = "$before" ] \
    || fail 'cursor advanced past a partial bridge record'
  printf '\n' >> "$dir/bridge.log"
  run_case "$dir" >/dev/null 2>&1 || fail 'complete-line recovery pass failed'
  [ "$(literal_count "$dir")" -eq 1 ] || fail 'completed queued record was not injected'
  run_case "$dir" >/dev/null 2>&1 || fail 'pending restart replay failed'
  [ "$(literal_count "$dir")" -eq 2 ] || fail 'unresolved pending ID did not survive process restart'
  pass 'atomic cursor and unresolved pending state recover across partial writes and process restarts'
}

test_session_death_exits_cleanly() {
  local dir out status
  dir=$(make_case session-death)
  install_case "$dir"
  set +e
  out=$(run_case "$dir" FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS=0 \
    FM_FAKE_REMOVE_PROC_ON_SLEEP=1 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "session death returned $status: $out"
  assert_contains "$out" 'session ended or changed identity; exiting cleanly' \
    'session death did not report its clean identity-bound exit'
  [ ! -e "$dir/home/state/codex-telegram-waker/bound" ] || fail 'session death left a live binding record'
  [ ! -e "$dir/home/state/codex-telegram-waker/beat" ] || fail 'session death left a live beat'
  pass 'session death invalidates /proc identity and exits cleanly without a stale liveness claim'
}

test_pid_reuse_and_log_replacement_fail_closed() {
  local dir out status replacement
  dir=$(make_case pid-reuse)
  install_case "$dir"
  set +e
  out=$(run_case "$dir" FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS=0 \
    FM_FAKE_REUSE_PROC_ON_SLEEP=1 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "PID identity change returned $status: $out"
  assert_contains "$out" 'session ended or changed identity; exiting cleanly' \
    'PID reuse did not invalidate the bound identity'
  [ "$(literal_count "$dir")" -eq 0 ] || fail 'PID reuse permitted an injection'

  dir=$(make_case log-replacement)
  install_case "$dir"
  replacement="$dir/replacement.log"
  printf '2026-08-14T00:00:00Z queued tg-replaced\n' > "$replacement"
  mv "$replacement" "$dir/bridge.log"
  set +e
  out=$(run_case "$dir" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'replaced bridge log identity was accepted'
  assert_contains "$out" 'bridge log rotated, shrank, changed identity' \
    'log identity replacement refusal was not explicit'
  [ "$(literal_count "$dir")" -eq 0 ] || fail 'replaced bridge log permitted an injection'
  pass 'PID reuse and append-only bridge-log identity replacement both fail closed'
}

test_binding_change_at_delivery_boundary_fails_closed() {
  local dir out status
  dir=$(make_case delivery-binding-change)
  install_case "$dir"
  printf '2026-08-14T00:00:00Z queued tg-delivery-boundary\n' >> "$dir/bridge.log"
  set +e
  out=$(run_case "$dir" FM_FAKE_DROP_BINDING_AFTER_COMPOSER=1 2>&1)
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "delivery-boundary identity change returned $status: $out"
  assert_contains "$out" 'changed identity before delivery; exiting cleanly' \
    'delivery-boundary identity change was not reported'
  [ "$(literal_count "$dir")" -eq 0 ] || fail 'delivery-boundary identity change permitted an injection'
  pass 'Codex binding is revalidated immediately before delivery'
}

test_singleton_and_ambiguous_binding_fail_closed() {
  local dir out status
  dir=$(make_case singleton)
  install_case "$dir"
  run_case "$dir" FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS=0 \
    FM_CODEX_TELEGRAM_WAKER_POLL_SECONDS=1 > "$dir/background.out" 2>&1 &
  BACKGROUND_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$dir/home/state/codex-telegram-waker/bound" ] && break
    /bin/sleep 0.1
  done
  [ -f "$dir/home/state/codex-telegram-waker/bound" ] || fail 'background singleton never published its binding'
  out=$(run_case "$dir" 2>&1) || fail 'second singleton invocation should exit harmlessly'
  assert_contains "$out" 'already holds the singleton lock' 'singleton collision was not reported'
  kill "$BACKGROUND_PID" 2>/dev/null || true
  wait "$BACKGROUND_PID" 2>/dev/null || true
  BACKGROUND_PID=

  dir=$(make_case ambiguity)
  install_case "$dir"
  set +e
  out=$(run_case "$dir" FM_FAKE_TMUX_AMBIGUOUS=1 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'ambiguous tty-to-pane mapping was accepted'
  assert_contains "$out" 'no unique identity-safe tmux Codex primary' 'ambiguous target refusal was not explicit'
  [ "$(literal_count "$dir")" -eq 0 ] || fail 'ambiguous binding typed into a pane'
  pass 'portable flock singleton and exact tty-to-pane binding both fail closed'
}

test_non_codex_and_wrong_path_are_not_applicable() {
  local dir out status
  dir=$(make_case non-codex)
  install_case "$dir"
  set +e
  out=$(run_case "$dir" FM_FAKE_PS_COMM=claude FM_FAKE_PS_ARGS=claude 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'a non-Codex primary was accepted'
  assert_contains "$out" 'no unique identity-safe tmux Codex primary' 'non-Codex refusal was not explicit'

  dir=$(make_case wrong-path)
  install_case "$dir"
  mkdir -p "$dir/other"
  set +e
  out=$(run_case "$dir" FM_FAKE_PANE_PATH="$dir/other" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail 'a pane outside the exact FM_HOME was accepted'
  [ "$(literal_count "$dir")" -eq 0 ] || fail 'wrong-path binding typed into a pane'
  pass 'non-Codex harnesses and panes outside the exact Firstmate home are explicitly non-applicable'
}

test_liveness_requires_proc_and_advancing_beat() {
  local dir first second out service_pid
  dir=$(make_case liveness)
  install_case "$dir"
  run_case "$dir" FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS=0 \
    FM_CODEX_TELEGRAM_WAKER_POLL_SECONDS=1 > "$dir/background.out" 2>&1 &
  BACKGROUND_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -f "$dir/home/state/codex-telegram-waker/beat" ] && break
    /bin/sleep 0.1
  done
  first=$(cat "$dir/home/state/codex-telegram-waker/beat" 2>/dev/null || true)
  service_pid=$(sed -n $'s/^pid\t//p' "$dir/home/state/codex-telegram-waker/bound" | head -1)
  [ -d "/proc/$service_pid" ] \
    || fail "bound waker process $service_pid has no live /proc entry (job $BACKGROUND_PID; bound=$(cat "$dir/home/state/codex-telegram-waker/bound"))"
  ln -s "/proc/$service_pid" "$dir/proc/$service_pid"
  /bin/sleep 1.2
  second=$(cat "$dir/home/state/codex-telegram-waker/beat" 2>/dev/null || true)
  [ -n "$first" ] && [ "$first" != "$second" ] || fail 'waker beat did not advance while its /proc process remained live'
  out=$(run_env "$dir" "$WAKER" status)
  assert_contains "$out" 'beat-advanced=yes' 'status claimed no liveness despite /proc plus an advancing beat'
  kill "$service_pid" 2>/dev/null || true
  wait "$BACKGROUND_PID" 2>/dev/null || true
  BACKGROUND_PID=
  out=$(run_env "$dir" "$WAKER" status)
  assert_contains "$out" 'not proven live' 'status trusted a prior PID or stale beat after process exit'
  pass 'liveness requires a current /proc process and a beat observed to advance'
}

test_install_uninstall_are_bounded
test_uninstall_refuses_foreign_unit
test_uninstall_preserves_files_when_lifecycle_fails
test_state_symlink_is_rejected_before_uninstall
test_busy_pending_and_unknown_defer
test_failure_b_retries_until_matching_offered
test_cursor_and_pending_survive_restart
test_session_death_exits_cleanly
test_pid_reuse_and_log_replacement_fail_closed
test_binding_change_at_delivery_boundary_fails_closed
test_singleton_and_ambiguous_binding_fail_closed
test_non_codex_and_wrong_path_are_not_applicable
test_liveness_requires_proc_and_advancing_beat

[ ! -s "$NETWORK_LOG" ] \
  || fail "waker invoked a forbidden network or Relay-consumer command: $(cat "$NETWORK_LOG")"
pass 'all service paths completed without fm-x-poll.sh, connector, or network-client invocation'
