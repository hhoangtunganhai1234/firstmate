#!/usr/bin/env bash
# fm-codex-telegram-waker.sh - wake one exact tmux-hosted Codex primary when
# the existing Telegram bridge records a queued Relay request.
#
# This is an external transport nudge, not a Relay consumer.
# The run path reads only the bridge's append-only log, keeps queued request IDs
# pending until their matching `offered` records appear, and types a fixed
# operational nudge into the uniquely bound primary Codex pane.
# It never invokes fm-x-poll.sh, /connector/poll, a reply command, or a network
# client; the awakened primary remains the only owner of the canonical poll and
# response workflow.
#
# Supported scope is deliberately narrow: Linux user systemd, the tmux runtime
# backend, and a primary whose session-lock owner is an exact Codex process.
# Any other harness, backend, ambiguous pane mapping, changed process identity,
# unreadable composer, pending input, or dead session fails closed.
#
# Usage:
#   fm-codex-telegram-waker.sh install --bridge-log <absolute-path>
#   fm-codex-telegram-waker.sh uninstall
#   fm-codex-telegram-waker.sh run --bridge-log <absolute-path>
#   fm-codex-telegram-waker.sh status
#
# `install` atomically writes exactly these user units, initializes the private
# cursor at the current end of the bridge log, reloads user systemd, and enables
# the path unit:
#   firstmate-codex-telegram-waker.path
#   firstmate-codex-telegram-waker.service
# `uninstall` refuses foreign unit files, stops those exact units, removes them
# and state/codex-telegram-waker only, then reloads user systemd.
#
# Test-only environment seams are FM_PROC_ROOT_OVERRIDE,
# FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS, FM_CODEX_TELEGRAM_WAKER_POLL_SECONDS,
# FM_CODEX_TELEGRAM_WAKER_RETRY_SECONDS, FM_CODEX_TELEGRAM_WAKER_CONFIRM_SLEEP,
# and FM_CODEX_TELEGRAM_WAKER_CONFIRM_RETRIES.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RUNTIME_DIR="$STATE_DIR/codex-telegram-waker"
STATE_FILE="$RUNTIME_DIR/state"
BEAT_FILE="$RUNTIME_DIR/beat"
BOUND_FILE="$RUNTIME_DIR/bound"
RUN_LOCK="$RUNTIME_DIR/run.lock"
UNIT_BASENAME=firstmate-codex-telegram-waker
SERVICE_UNIT="$UNIT_BASENAME.service"
PATH_UNIT="$UNIT_BASENAME.path"
MANAGED_MARKER='# Managed by fm-codex-telegram-waker.sh v1'
PROC_ROOT="${FM_PROC_ROOT_OVERRIDE:-/proc}"
WAKER_PID=${BASHPID:-$$}

die() {
  printf 'fm-codex-telegram-waker: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'fm-codex-telegram-waker: %s\n' "$*" >&2
}

usage() {
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
}

require_linux() {
  [ "$(uname 2>/dev/null)" = Linux ] \
    || die 'user-systemd Codex Telegram waking is supported only on Linux'
  [ -d "$PROC_ROOT" ] || die "process filesystem is unavailable at $PROC_ROOT"
}

canonical_dir() {  # <directory>
  [ -d "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

canonical_file() {  # <file>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  local dir base
  dir=$(canonical_dir "$(dirname "$1")") || return 1
  base=$(basename "$1")
  printf '%s/%s\n' "$dir" "$base"
}

reject_unsafe_value() {  # <label> <value>
  case "$2" in
    ''|*$'\n'*|*$'\r'*) die "$1 must be a non-empty single-line value" ;;
  esac
}

atomic_write() {  # <path>, content on stdin
  local path=$1 tmp
  mkdir -p "$(dirname "$path")" || return 1
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! cat > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
}

systemd_quote() {  # <value>
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  printf '"%s"' "$value"
}

systemd_path_value() {  # <absolute-path>
  local value=$1
  value=${value//\\/\\x5c}
  value=${value// /\\x20}
  value=${value//$'\t'/\\x09}
  value=${value//%/%%}
  printf '%s' "$value"
}

unit_dir() {
  local config_home
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    config_home=$XDG_CONFIG_HOME
  else
    [ -n "${HOME:-}" ] || die 'HOME or XDG_CONFIG_HOME is required for user units'
    config_home="$HOME/.config"
  fi
  reject_unsafe_value XDG_CONFIG_HOME "$config_home"
  case "$config_home" in /*) ;; *) die 'XDG_CONFIG_HOME must be absolute' ;; esac
  printf '%s/systemd/user\n' "$config_home"
}

unit_owned_for_home() {  # <unit-path> <canonical-home>
  local path=$1 home=$2 encoded
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r encoded < "$path" 2>/dev/null || return 1
  [ "$encoded" = "$MANAGED_MARKER" ] || return 1
  grep -Fqx "# FM_HOME=$home" "$path" 2>/dev/null
}

stat_triplet() {  # <path> -> device inode size
  stat -Lc '%d %i %s' "$1" 2>/dev/null
}

initialize_state() {  # <bridge-log>
  local bridge_log=$1 triplet device inode size
  mkdir -p "$RUNTIME_DIR" || return 1
  chmod 700 "$RUNTIME_DIR" || return 1
  if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
    [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 1
    return 0
  fi
  triplet=$(stat_triplet "$bridge_log") || return 1
  read -r device inode size <<< "$triplet"
  {
    printf 'v1\n'
    printf 'cursor\t%s\t%s\t%s\t1\n' "$device" "$inode" "$size"
  } | atomic_write "$STATE_FILE"
}

state_matches_log() {  # <bridge-log>
  local triplet device inode size
  load_state || return 1
  triplet=$(stat_triplet "$1") || return 1
  read -r device inode size <<< "$triplet"
  [ "$device" = "$CURSOR_DEVICE" ] \
    && [ "$inode" = "$CURSOR_INODE" ] \
    && [ "$size" -ge "$CURSOR_OFFSET" ]
}

render_service_unit() {  # <script> <home> <bridge-log>
  local script=$1 home=$2 bridge_log=$3 q_script q_home q_log writable
  q_script=$(systemd_quote "$script")
  q_home=$(systemd_quote "FM_HOME=$home")
  q_log=$(systemd_quote "$bridge_log")
  writable=$(systemd_path_value "$RUNTIME_DIR")
  printf '%s\n' "$MANAGED_MARKER"
  printf '# FM_HOME=%s\n' "$home"
  cat <<EOF
[Unit]
Description=Wake the current Firstmate Codex primary for queued Telegram Relay requests
Documentation=file:$FM_ROOT/docs/codex-telegram-waker.md

[Service]
Type=simple
Environment=$q_home
ExecStart=$q_script run --bridge-log $q_log
Restart=no
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$writable
RestrictAddressFamilies=AF_UNIX
IPAddressDeny=any
LockPersonality=yes

EOF
}

render_path_unit() {  # <home>
  local home=$1 q_lock
  q_lock=$(systemd_path_value "$home/state/.lock")
  printf '%s\n' "$MANAGED_MARKER"
  printf '# FM_HOME=%s\n' "$home"
  cat <<EOF
[Unit]
Description=Watch for a new Firstmate primary session lock
Documentation=file:$FM_ROOT/docs/codex-telegram-waker.md

[Path]
PathChanged=$q_lock
Unit=$SERVICE_UNIT

[Install]
WantedBy=default.target

EOF
}

install_units() {  # <bridge-log>
  require_linux
  command -v systemctl >/dev/null 2>&1 || die 'systemctl is required'
  command -v flock >/dev/null 2>&1 || die 'flock is required'
  local bridge_log=$1 home script units service_path path_path existing
  bridge_log=$(canonical_file "$bridge_log") \
    || die "bridge log must be an existing non-symlink regular file: $bridge_log"
  home=$(canonical_dir "$FM_HOME") || die "FM_HOME is not an existing directory: $FM_HOME"
  [ "$FM_HOME" = "$home" ] || die 'FM_HOME must be an absolute canonical directory'
  [ "$STATE_DIR" = "$home/state" ] || die 'install requires the standard FM_HOME/state directory'
  script=$(canonical_file "$0") || die "cannot resolve the tracked waker script: $0"
  reject_unsafe_value bridge-log "$bridge_log"
  reject_unsafe_value FM_HOME "$home"
  units=$(unit_dir)
  service_path="$units/$SERVICE_UNIT"
  path_path="$units/$PATH_UNIT"
  for existing in "$service_path" "$path_path"; do
    if [ -e "$existing" ] || [ -L "$existing" ]; then
      unit_owned_for_home "$existing" "$home" \
        || die "refusing to replace foreign or differently bound unit: $existing"
    fi
  done
  initialize_state "$bridge_log" || die 'could not initialize private cursor state'
  state_matches_log "$bridge_log" \
    || die 'existing private cursor does not match this append-only bridge log; uninstall before rebinding'
  mkdir -p "$units" || die "could not create user unit directory: $units"
  render_service_unit "$script" "$home" "$bridge_log" | atomic_write "$service_path" \
    || die "could not publish $service_path"
  render_path_unit "$home" | atomic_write "$path_path" \
    || die "could not publish $path_path"
  systemctl --user daemon-reload || die 'user systemd daemon-reload failed'
  systemctl --user enable --now "$PATH_UNIT" || die "could not enable $PATH_UNIT"
  printf 'installed: %s watches future primary lock changes for %s\n' "$PATH_UNIT" "$home"
}

uninstall_units() {
  require_linux
  command -v systemctl >/dev/null 2>&1 || die 'systemctl is required'
  local home units service_path path_path existing
  home=$(canonical_dir "$FM_HOME") || die "FM_HOME is not an existing directory: $FM_HOME"
  [ "$FM_HOME" = "$home" ] || die 'FM_HOME must be an absolute canonical directory'
  [ "$STATE_DIR" = "$home/state" ] || die 'uninstall requires the standard FM_HOME/state directory'
  units=$(unit_dir)
  service_path="$units/$SERVICE_UNIT"
  path_path="$units/$PATH_UNIT"
  for existing in "$service_path" "$path_path"; do
    if [ -e "$existing" ] || [ -L "$existing" ]; then
      unit_owned_for_home "$existing" "$home" \
        || die "refusing to remove foreign or differently bound unit: $existing"
    fi
  done
  systemctl --user disable --now "$PATH_UNIT" >/dev/null 2>&1 \
    || die "could not disable and stop $PATH_UNIT; no files were removed"
  systemctl --user stop "$SERVICE_UNIT" >/dev/null 2>&1 \
    || die "could not stop $SERVICE_UNIT; no files were removed"
  if systemctl --user is-active --quiet "$SERVICE_UNIT"; then
    die "$SERVICE_UNIT remains active; no files were removed"
  fi
  rm -f -- "$service_path" "$path_path"
  case "$RUNTIME_DIR" in
    "$home/state/codex-telegram-waker") rm -rf -- "$RUNTIME_DIR" ;;
    *) die "refusing unexpected runtime directory: $RUNTIME_DIR" ;;
  esac
  systemctl --user daemon-reload || die 'user systemd daemon-reload failed'
  printf 'uninstalled: removed only %s, %s, and %s\n' "$service_path" "$path_path" "$RUNTIME_DIR"
}

codex_pid_exact() {  # <pid>
  local pid=$1 comm args base argv0
  comm=$(LC_ALL=C ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(LC_ALL=C ps -o args= -p "$pid" 2>/dev/null) || return 1
  fm_harness_process_matches "$comm" "$args" || return 1
  comm=${comm#"${comm%%[![:space:]]*}"}
  comm=${comm%"${comm##*[![:space:]]}"}
  base=$(basename -- "$comm")
  argv0=${args%% *}
  case "$base" in codex|codex-*) return 0 ;; esac
  case "$(basename -- "$argv0")" in codex|codex-*) return 0 ;; esac
  return 1
}

read_proc_environment() {  # <pid> <name>
  local pid=$1 name=$2 line found=''
  [ -r "$PROC_ROOT/$pid/environ" ] || return 1
  while IFS= read -r line; do
    case "$line" in "$name="*) found=${line#*=} ;; esac
  done < <(tr '\0' '\n' < "$PROC_ROOT/$pid/environ")
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

LOCK_PID=
LOCK_IDENTITY=
LOCK_TTY=
LOCK_TMUX=
LOCK_PANE=

bind_primary() {
  local lock="$STATE_DIR/.lock" pid identity tty tmux_env pane_path pane_dead
  local line pane pane_tty matches=0 matched=''
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  IFS= read -r pid < "$lock" 2>/dev/null || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "$PROC_ROOT/$pid" ] || return 1
  fm_pid_alive "$pid" || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  codex_pid_exact "$pid" || return 1
  tty=$(readlink "$PROC_ROOT/$pid/fd/0" 2>/dev/null) || return 1
  case "$tty" in /dev/pts/*|/dev/tty*) ;; *) return 1 ;; esac
  tmux_env=$(read_proc_environment "$pid" TMUX) || return 1
  case "$tmux_env" in /*,*,*) ;; *) return 1 ;; esac
  TMUX=$tmux_env tmux list-panes -a -F '#{pane_id}|#{pane_tty}' 2>/dev/null > "$RUNTIME_DIR/panes.tmp" \
    || { rm -f "$RUNTIME_DIR/panes.tmp"; return 1; }
  while IFS= read -r line; do
    pane=${line%%|*}
    pane_tty=${line#*|}
    [ "$pane_tty" = "$tty" ] || continue
    case "$pane" in %*) ;; *) continue ;; esac
    matches=$((matches + 1))
    matched=$pane
  done < "$RUNTIME_DIR/panes.tmp"
  rm -f "$RUNTIME_DIR/panes.tmp"
  [ "$matches" -eq 1 ] || return 1
  pane_dead=$(TMUX=$tmux_env tmux display-message -p -t "$matched" '#{pane_dead}' 2>/dev/null) || return 1
  [ "$pane_dead" = 0 ] || return 1
  pane_path=$(TMUX=$tmux_env tmux display-message -p -t "$matched" '#{pane_current_path}' 2>/dev/null) || return 1
  pane_path=$(canonical_dir "$pane_path") || return 1
  [ "$pane_path" = "$(canonical_dir "$FM_HOME")" ] || return 1
  LOCK_PID=$pid
  LOCK_IDENTITY=$identity
  LOCK_TTY=$tty
  LOCK_TMUX=$tmux_env
  LOCK_PANE=$matched
  export TMUX=$LOCK_TMUX
}

binding_alive() {
  local pid identity tty pane_path pane_dead current_lock
  pid=$LOCK_PID
  [ -d "$PROC_ROOT/$pid" ] || return 1
  fm_pid_alive "$pid" || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  [ "$identity" = "$LOCK_IDENTITY" ] || return 1
  IFS= read -r current_lock < "$STATE_DIR/.lock" 2>/dev/null || return 1
  [ "$current_lock" = "$pid" ] || return 1
  tty=$(readlink "$PROC_ROOT/$pid/fd/0" 2>/dev/null) || return 1
  [ "$tty" = "$LOCK_TTY" ] || return 1
  pane_dead=$(tmux display-message -p -t "$LOCK_PANE" '#{pane_dead}' 2>/dev/null) || return 1
  [ "$pane_dead" = 0 ] || return 1
  [ "$(tmux display-message -p -t "$LOCK_PANE" '#{pane_tty}' 2>/dev/null)" = "$LOCK_TTY" ] || return 1
  pane_path=$(tmux display-message -p -t "$LOCK_PANE" '#{pane_current_path}' 2>/dev/null) || return 1
  pane_path=$(canonical_dir "$pane_path") || return 1
  [ "$pane_path" = "$(canonical_dir "$FM_HOME")" ]
}

declare -A PENDING_ORDER=()
declare -A PENDING_LAST=()
CURSOR_DEVICE=
CURSOR_INODE=
CURSOR_OFFSET=
NEXT_ORDER=

request_id_valid() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

load_state() {
  local line kind a b c d extra seen_header=0 seen_cursor=0
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 1
  PENDING_ORDER=()
  PENDING_LAST=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$seen_header" -eq 0 ]; then
      [ "$line" = v1 ] || return 1
      seen_header=1
      continue
    fi
    IFS=$'\t' read -r kind a b c d extra <<< "$line"
    [ -z "${extra:-}" ] || return 1
    case "$kind" in
      cursor)
        [ "$seen_cursor" -eq 0 ] || return 1
        case "$a:$b:$c:$d" in *[!0-9:]*|:*|*:|*::* ) return 1 ;; esac
        CURSOR_DEVICE=$a
        CURSOR_INODE=$b
        CURSOR_OFFSET=$c
        NEXT_ORDER=$d
        seen_cursor=1
        ;;
      pending)
        [ "$seen_cursor" -eq 1 ] || return 1
        request_id_valid "$a" || return 1
        case "$b:$c" in *[!0-9:]*|:*|*:) return 1 ;; esac
        [ -z "${PENDING_ORDER[$a]+x}" ] || return 1
        PENDING_ORDER[$a]=$b
        PENDING_LAST[$a]=$c
        ;;
      *) return 1 ;;
    esac
  done < "$STATE_FILE"
  [ "$seen_header" -eq 1 ] && [ "$seen_cursor" -eq 1 ]
}

write_state() {
  local tmp id
  tmp=$(mktemp "$RUNTIME_DIR/state.tmp.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'v1\n'
    printf 'cursor\t%s\t%s\t%s\t%s\n' "$CURSOR_DEVICE" "$CURSOR_INODE" "$CURSOR_OFFSET" "$NEXT_ORDER"
    for id in "${!PENDING_ORDER[@]}"; do
      printf 'pending\t%s\t%s\t%s\n' "$id" "${PENDING_ORDER[$id]}" "${PENDING_LAST[$id]}"
    done | LC_ALL=C sort -t $'\t' -k3,3n -k2,2
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$STATE_FILE"
}

fold_bridge_log() {  # <bridge-log>
  local bridge_log=$1 triplet after_triplet device inode size after_device after_inode after_size
  local count chunk last_byte line id
  triplet=$(stat_triplet "$bridge_log") || return 1
  read -r device inode size <<< "$triplet"
  [ "$device" = "$CURSOR_DEVICE" ] && [ "$inode" = "$CURSOR_INODE" ] || return 1
  [ "$size" -ge "$CURSOR_OFFSET" ] || return 1
  [ "$size" -gt "$CURSOR_OFFSET" ] || return 0
  count=$((size - CURSOR_OFFSET))
  chunk=$(mktemp "$RUNTIME_DIR/chunk.tmp.XXXXXX") || return 1
  if ! dd if="$bridge_log" of="$chunk" iflag=skip_bytes,count_bytes skip="$CURSOR_OFFSET" count="$count" status=none; then
    rm -f "$chunk"
    return 1
  fi
  after_triplet=$(stat_triplet "$bridge_log") || { rm -f "$chunk"; return 1; }
  read -r after_device after_inode after_size <<< "$after_triplet"
  if [ "$after_device" != "$device" ] || [ "$after_inode" != "$inode" ] || [ "$after_size" -lt "$size" ]; then
    rm -f "$chunk"
    return 1
  fi
  last_byte=$(tail -c 1 "$chunk" | od -An -tuC | tr -d '[:space:]')
  if [ "$last_byte" != 10 ]; then
    rm -f "$chunk"
    return 0
  fi
  while IFS= read -r line; do
    if [[ $line =~ [[:space:]]queued[[:space:]]+([A-Za-z0-9._-]+)$ ]]; then
      id=${BASH_REMATCH[1]}
      if [ -z "${PENDING_ORDER[$id]+x}" ]; then
        PENDING_ORDER[$id]=$NEXT_ORDER
        PENDING_LAST[$id]=0
        NEXT_ORDER=$((NEXT_ORDER + 1))
      fi
    elif [[ $line =~ [[:space:]]offered[[:space:]]+([A-Za-z0-9._-]+)$ ]]; then
      id=${BASH_REMATCH[1]}
      unset 'PENDING_ORDER[$id]'
      unset 'PENDING_LAST[$id]'
    fi
  done < "$chunk"
  rm -f "$chunk"
  CURSOR_OFFSET=$size
  write_state
}

select_due_request() {  # <now> <retry-seconds>
  local now=$1 retry=$2 id best='' best_order='' order last
  for id in "${!PENDING_ORDER[@]}"; do
    order=${PENDING_ORDER[$id]}
    last=${PENDING_LAST[$id]}
    [ $((now - last)) -ge "$retry" ] || continue
    if [ -z "$best" ] || [ "$order" -lt "$best_order" ]; then
      best=$id
      best_order=$order
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

write_bound_record() {
  {
    printf 'v1\n'
    printf 'pid\t%s\n' "$WAKER_PID"
    printf 'primary-pid\t%s\n' "$LOCK_PID"
    printf 'primary-identity\t%s\n' "$LOCK_IDENTITY"
    printf 'tty\t%s\n' "$LOCK_TTY"
    printf 'pane\t%s\n' "$LOCK_PANE"
  } | atomic_write "$BOUND_FILE"
}

write_beat() {  # <sequence>
  printf 'v1\t%s\t%s\t%s\n' "$WAKER_PID" "$1" "$(date +%s)" | atomic_write "$BEAT_FILE"
}

cleanup_runtime_claim() {
  rm -f -- "$BOUND_FILE" "$BEAT_FILE"
}

inject_request() {  # <request-id> <now>
  local id=$1 now=$2 busy composer body message verdict retries sleep_s
  busy=$(fm_pane_busy_state "$LOCK_PANE" codex 2>/dev/null)
  [ "$busy" = idle ] || return 0
  composer=$(fm_backend_composer_state tmux "$LOCK_PANE" 2>/dev/null)
  [ "$composer" = empty ] || return 0
  PENDING_LAST[$id]=$now
  write_state || return 1
  body="Telegram Relay request $id is still queued. Run bin/fm-x-poll.sh once through the canonical Relay workflow, handle only the offered request, and leave captain decisions for the captain."
  fm_operational_input_encode watcher "$body" message || return 1
  retries=${FM_CODEX_TELEGRAM_WAKER_CONFIRM_RETRIES:-3}
  sleep_s=${FM_CODEX_TELEGRAM_WAKER_CONFIRM_SLEEP:-0.2}
  binding_alive || return 2
  verdict=$(fm_backend_send_text_submit tmux "$LOCK_PANE" "$message" "$retries" "$sleep_s" "$sleep_s")
  if [ "$verdict" = empty ]; then
    log "nudged $id; awaiting matching offered record"
  else
    log "submit for $id was not confirmed (verdict=${verdict:-unknown}); request remains pending"
  fi
}

run_service() {  # <bridge-log>
  require_linux
  command -v flock >/dev/null 2>&1 || die 'flock is required'
  command -v tmux >/dev/null 2>&1 || die 'tmux is required'
  local bridge_log=$1 poll retry max_loops loops=0 now due result
  bridge_log=$(canonical_file "$bridge_log") \
    || die "bridge log must be an existing non-symlink regular file: $bridge_log"
  mkdir -p "$RUNTIME_DIR" || die "cannot create runtime directory: $RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR" || die "cannot protect runtime directory: $RUNTIME_DIR"
  initialize_state "$bridge_log" || die 'could not initialize private cursor state'
  # Load the existing identity and delivery owners only on the active run path.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  exec 9> "$RUN_LOCK" || die "cannot open singleton lock: $RUN_LOCK"
  if ! flock -n 9; then
    log 'another identity-bound waker already holds the singleton lock'
    return 0
  fi
  load_state || die 'private cursor state is malformed'
  bind_primary || die 'no unique identity-safe tmux Codex primary matches the current session lock'
  fm_backend_source tmux || die 'could not load the verified tmux delivery primitives'
  write_bound_record || die 'could not publish bound-session record'
  trap cleanup_runtime_claim EXIT
  trap 'exit 0' HUP INT TERM
  poll=${FM_CODEX_TELEGRAM_WAKER_POLL_SECONDS:-2}
  retry=${FM_CODEX_TELEGRAM_WAKER_RETRY_SECONDS:-30}
  max_loops=${FM_CODEX_TELEGRAM_WAKER_MAX_LOOPS:-0}
  [[ $poll =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'poll interval must be a non-negative number'
  case "$retry:$max_loops" in *[!0-9:]*|:*|*:) die 'retry and loop settings must be non-negative integers' ;; esac
  while :; do
    if ! binding_alive; then
      log 'bound primary session ended or changed identity; exiting cleanly'
      return 0
    fi
    loops=$((loops + 1))
    write_beat "$loops" || die 'could not advance liveness beat'
    fold_bridge_log "$bridge_log" || die 'bridge log rotated, shrank, changed identity, or became unreadable'
    now=$(date +%s)
    if due=$(select_due_request "$now" "$retry"); then
      inject_request "$due" "$now"
      result=$?
      if [ "$result" -ne 0 ]; then
        if [ "$result" -eq 2 ]; then
          log 'bound primary session ended or changed identity before delivery; exiting cleanly'
          return 0
        fi
        die "could not persist retry state for $due"
      fi
    fi
    if [ "$max_loops" -gt 0 ] && [ "$loops" -ge "$max_loops" ]; then
      return 0
    fi
    sleep "$poll"
  done
}

show_status() {
  local units pid first second
  units=$(unit_dir)
  printf 'units: %s %s\n' "$units/$PATH_UNIT" "$units/$SERVICE_UNIT"
  if [ -f "$BOUND_FILE" ]; then
    pid=$(sed -n 's/^pid\t//p' "$BOUND_FILE" | head -1)
    first=$(cat "$BEAT_FILE" 2>/dev/null || true)
    sleep 3
    second=$(cat "$BEAT_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && [ -d "$PROC_ROOT/$pid" ] && [ -n "$first" ] && [ "$first" != "$second" ]; then
      printf 'runtime: live pid=%s beat-advanced=yes\n' "$pid"
      return 0
    fi
  fi
  printf 'runtime: not proven live\n'
}

parse_bridge_log() {
  local bridge_log=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bridge-log)
        [ "$#" -ge 2 ] || die '--bridge-log requires a path'
        bridge_log=$2
        shift 2
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$bridge_log" ] || die '--bridge-log is required'
  printf '%s\n' "$bridge_log"
}

main() {
  local action=${1:-} bridge_log
  [ "$#" -gt 0 ] && shift
  case "$action" in
    install)
      bridge_log=$(parse_bridge_log "$@")
      install_units "$bridge_log"
      ;;
    uninstall)
      [ "$#" -eq 0 ] || die 'uninstall accepts no arguments'
      uninstall_units
      ;;
    run)
      bridge_log=$(parse_bridge_log "$@")
      run_service "$bridge_log"
      ;;
    status)
      [ "$#" -eq 0 ] || die 'status accepts no arguments'
      show_status
      ;;
    -h|--help|help|'') usage ;;
    *) die "unknown action: $action" ;;
  esac
}

main "$@"
