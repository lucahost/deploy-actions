#!/usr/bin/env bash
# Daily PostgreSQL dump, run by the `backup` service of the production compose file. The service
# uses the database server's own image, so pg_dump matches the server's major version (pg_dump
# refuses a newer server, and an archive of a newer pg_dump may not load with an older
# pg_restore). Adapted from luna-eats' docker/backup/backup.sh; runs with GNU (Debian images) and
# busybox (Alpine images) tools alike.
#
#   backup.sh loop     the service: one run at start when the last success is missing or older
#                      than 24 h, then every day at BACKUP_AT local time (TZ)
#   backup.sh once     one run now, for example:
#                        docker compose -f <compose file> exec backup bash /opt/backup/backup.sh once
#   backup.sh health   the healthcheck: exit 0 while the last success is younger than 26 h
#
# Settings, from the compose file:
#   BACKUP_NAME      file name prefix (required): <name>-<YYYYMMDD-HHMM>.dump
#   BACKUP_AT        daily run time, HH:MM local time, 00:00 to 22:59 (default 03:00). Stagger
#                    it against the other databases on the host, so two dumps never run at once.
#   BACKUP_KEEP      dumps kept (default 3)
#   PGHOST, PGPORT, PGDATABASE, PGUSER     the connection
#   PGPASSWORD, or PGPASSWORD_FILE         the password, or a file that holds it (a Docker secret)
#
# One run:
#   1. wait up to 60 s for the server (a deploy may be restarting it)
#   2. pg_dump --format=custom into /backups/db/<name>-<YYYYMMDD-HHMM>.dump.partial: lowest CPU
#      and I/O priority, read-only session (pg_dump's own transaction is READ ONLY as well)
#   3. TimescaleDB only: discard the dump when a TimescaleDB job ran during it (see
#      timescale_jobs_since below)
#   4. pg_restore --list on that file (it must be a readable archive)
#   5. rename it to .dump
#   6. keep the BACKUP_KEEP newest .dump files, delete the older ones
#   7. write /backups/last-success (timestamp and file name)
#
# A failed run logs an ERROR line and ends only that run, never the service: the next attempt
# is one hour later (or at BACKUP_AT, if that comes first), until one succeeds. While runs keep
# failing, the healthcheck turns unhealthy 26 h after the last success.
#
# Everything is logged to stdout, one line per message (docker compose logs backup).
set -euo pipefail

# The pg_dump options of every dump. The connection comes from the PG* variables.
PG_DUMP_FLAGS="--format=custom --lock-wait-timeout=120s"

BACKUP_ROOT="/backups"
DB_DIR="${BACKUP_ROOT}/db"
LAST_SUCCESS="${BACKUP_ROOT}/last-success"
LOCK_FILE="${BACKUP_ROOT}/.backup.lock"

NAME="${BACKUP_NAME:-}"
KEEP="${BACKUP_KEEP:-3}"
RUN_AT="${BACKUP_AT:-03:00}"
STALE_AFTER=$((24 * 3600))      # at start: run now when the last success is older than this
UNHEALTHY_AFTER=$((26 * 3600))  # healthcheck: unhealthy when the last success is older than this
RETRY_AFTER=3600                # after a failed run
SERVER_WAIT=60                  # seconds to wait for the server before a dump
DUMP_TIMEOUT=1800               # seconds; a hanging pg_dump must not block the next days
MAX_SLEEP=900                   # sleep in steps, so a clock change cannot shift a run by much

# Dumps hold every row of the database: owner only.
umask 077
export LC_ALL=C
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-30}"
export PGAPPNAME="${PGAPPNAME:-backup}"
# Every transaction of the session is read-only: the dump cannot write, whatever it runs.
export PGOPTIONS="${PGOPTIONS:+${PGOPTIONS} }-c default_transaction_read_only=on"

SELF="${BASH_SOURCE[0]}"

log() {
  printf '%s backup %s\n' "$(date -Iseconds)" "$*"
}

# Joins a program's stderr into one log line.
one_line() {
  tr -s '\n\t' '  ' <"$1" | sed -e 's/^ *//' -e 's/ *$//'
}

check_settings() {
  [ -n "$NAME" ] || { echo "BACKUP_NAME is not set" >&2; return 2; }
  case "$NAME" in
    *[!A-Za-z0-9_.-]*) echo "BACKUP_NAME may only hold letters, digits, '_', '.' and '-'" >&2; return 2 ;;
  esac
  case "$KEEP" in
    '' | *[!0-9]* | 0) echo "BACKUP_KEEP must be a whole number of at least 1, not '${KEEP}'" >&2; return 2 ;;
  esac
  [[ "$RUN_AT" =~ ^([01][0-9]|2[0-2]):[0-5][0-9]$ ]] \
    || { echo "BACKUP_AT must be HH:MM between 00:00 and 22:59, not '${RUN_AT}'" >&2; return 2; }
}

age_of_last_success() {
  local mtime
  mtime=$(stat -c %Y "$LAST_SUCCESS" 2>/dev/null) || return 1
  echo $(($(date +%s) - mtime))
}

# ---- once -------------------------------------------------------------------------------

# The state of this run (globals: the EXIT trap runs after run_once has returned).
RUN_ERR=""
RUN_PARTIAL=""
RUN_FAILURE_LOGGED=""

# Removes the run's temporary files, and logs a failure that `fail` has not explained.
# shellcheck disable=SC2329 # called by the EXIT trap
finish_run() {
  local status=$?
  rm -f -- ${RUN_ERR:+"$RUN_ERR"} ${RUN_PARTIAL:+"$RUN_PARTIAL"}
  if [ "$status" -ne 0 ] && [ -z "$RUN_FAILURE_LOGGED" ]; then
    log "ERROR run failed (exit ${status})"
  fi
}

fail() {
  log "ERROR $*"
  RUN_FAILURE_LOGGED=yes
  exit 1
}

# nice and ionice, so the dump yields to everything else on the host. ionice is used only where
# it works (idle class needs no privileges, but the kernel or the container may refuse it).
low_priority() {
  if ionice -c 3 true 2>/dev/null; then
    nice -n 19 ionice -c 3 "$@"
  else
    nice -n 19 "$@"
  fi
}

# One value from the server, in the dump's read-only session settings. Called as
# `x=$(query ...) || fail ...`: in the command substitution's subshell, `fail` could not log.
query() {
  psql -X -At -c "$1" 2>"$RUN_ERR"
}

# TimescaleDB only: compress_chunk, decompress_chunk, drop_chunks and reorder_chunk replace a
# chunk's data without MVCC. A chunk that such a job rewrites after pg_dump took its snapshot, but
# before pg_dump locked that chunk, is dumped empty (seen in a test: 28 of 400 rows missing after
# the restore). pg_dump cannot lock before its snapshot, so a dump that overlapped a job is
# discarded instead: no job may run when the dump starts, and none may start until it is done.
# The retry an hour later finds the jobs (every few hours, seconds long) done.
# Job ids below 1000 are TimescaleDB's own (telemetry, job history), which touch no chunk.
timescale_jobs_since() {
  printf '%s' "select string_agg(format('%s %s', s.job_id, j.proc_name), ', ' order by s.job_id)
    from timescaledb_information.job_stats s join timescaledb_information.jobs j using (job_id)
    where s.job_id >= 1000 and (s.job_status = 'Running' or s.last_run_started_at >= to_timestamp($1))"
}

run_once() {
  local stamp name final bytes waited timescale started jobs
  local -a dump_flags

  trap finish_run EXIT

  stamp=$(date +%Y%m%d-%H%M)
  name="${NAME}-${stamp}.dump"
  final="${DB_DIR}/${name}"
  RUN_ERR=$(mktemp /tmp/backup-err.XXXXXX)

  mkdir -p "$DB_DIR" || fail "cannot create ${DB_DIR} as uid $(id -u) gid $(id -g)"

  # One run at a time, also when someone starts `once` while the service runs.
  exec 9>"$LOCK_FILE" || fail "cannot open ${LOCK_FILE} as uid $(id -u) gid $(id -g)"
  flock -n 9 || fail "another run holds ${LOCK_FILE}; not starting a second one"

  # Leftovers of an interrupted run (container stopped mid-dump).
  rm -f -- "${DB_DIR}/${NAME}"-*.dump.partial

  if [ -n "${PGPASSWORD_FILE:-}" ]; then
    [ -r "$PGPASSWORD_FILE" ] || fail "cannot read ${PGPASSWORD_FILE} as uid $(id -u) gid $(id -g)"
    PGPASSWORD=$(<"$PGPASSWORD_FILE")
    export PGPASSWORD
  fi
  [ -n "${PGPASSWORD:-}" ] || fail "no password: set PGPASSWORD or PGPASSWORD_FILE"

  waited=0
  until pg_isready -q; do
    ((waited < SERVER_WAIT)) || fail "${PGHOST:-?}:${PGPORT:-5432} did not accept connections within ${SERVER_WAIT} s"
    sleep 5
    waited=$((waited + 5))
  done

  timescale=$(query "select count(*) from pg_extension where extname = 'timescaledb'") \
    || fail "cannot query ${PGDATABASE:-?}: $(one_line "$RUN_ERR")"
  if [ "$timescale" = 1 ]; then
    started=$(query "select floor(extract(epoch from now()))::bigint") \
      || fail "cannot read the server's clock: $(one_line "$RUN_ERR")"
    jobs=$(query "$(timescale_jobs_since "$started")") \
      || fail "cannot read the TimescaleDB jobs: $(one_line "$RUN_ERR")"
    [ -z "$jobs" ] || fail "TimescaleDB jobs are running (${jobs}); no dump while they may rewrite chunks"
  fi

  read -r -a dump_flags <<<"$PG_DUMP_FLAGS"
  RUN_PARTIAL="${final}.partial"

  log "dump started: ${PGUSER:-?}@${PGHOST:-?}:${PGPORT:-5432}/${PGDATABASE:-?} -> ${final}"
  low_priority timeout "$DUMP_TIMEOUT" pg_dump "${dump_flags[@]}" --file="$RUN_PARTIAL" 2>"$RUN_ERR" \
    || fail "pg_dump failed: $(one_line "$RUN_ERR")"
  if [ "$timescale" = 1 ]; then
    jobs=$(query "$(timescale_jobs_since "$started")") \
      || fail "cannot read the TimescaleDB jobs: $(one_line "$RUN_ERR")"
    [ -z "$jobs" ] || fail "TimescaleDB jobs ran during the dump (${jobs}); it may miss rows of a chunk they rewrote, so it is discarded"
  fi
  pg_restore --list "$RUN_PARTIAL" >/dev/null 2>"$RUN_ERR" \
    || fail "pg_restore --list cannot read the new dump: $(one_line "$RUN_ERR")"
  mv -f "$RUN_PARTIAL" "$final"
  RUN_PARTIAL=""
  bytes=$(stat -c %s "$final")

  rotate

  printf '%s %s\n' "$(date -Iseconds)" "$name" >"${LAST_SUCCESS}.tmp"
  mv -f "${LAST_SUCCESS}.tmp" "$LAST_SUCCESS"
  log "dump done: ${name} (${bytes} bytes), $(count_dumps) dumps kept"
}

# The dumps, oldest first: the names sort by time (<name>-YYYYMMDD-HHMM.dump), and bash sorts a
# glob's matches (LC_ALL=C: byte order).
dump_names() {
  local f
  for f in "${DB_DIR}/${NAME}"-*.dump; do
    [ -f "$f" ] && printf '%s\n' "${f##*/}"
  done
  return 0
}

count_dumps() {
  dump_names | wc -l | tr -d ' '
}

# Keeps the KEEP newest dumps.
rotate() {
  local -a dumps
  local i excess
  mapfile -t dumps < <(dump_names)
  excess=$((${#dumps[@]} - KEEP))
  for ((i = 0; i < excess; i++)); do
    rm -f -- "${DB_DIR:?}/${dumps[i]}"
    log "removed old dump ${dumps[i]}"
  done
}

# ---- health -----------------------------------------------------------------------------

health() {
  local age
  if ! age=$(age_of_last_success); then
    echo "no successful backup yet (${LAST_SUCCESS} missing)"
    return 1
  fi
  if ((age > UNHEALTHY_AFTER)); then
    echo "last successful backup $((age / 3600)) h ago: $(cat "$LAST_SUCCESS")"
    return 1
  fi
  echo "last successful backup $((age / 60)) min ago: $(cat "$LAST_SUCCESS")"
}

# ---- loop -------------------------------------------------------------------------------

# Epoch seconds of the next RUN_AT strictly after now, in local time.
next_slot() {
  local now noon day k ts fallback
  now=$(date +%s)
  # On the night clocks go forward, 02:xx does not exist: GNU date refuses it, so run an hour
  # later then. (busybox date moves it forward by itself.)
  fallback="$(printf '%02d' $((10#${RUN_AT%%:*} + 1))):${RUN_AT#*:}"
  # Day arithmetic from noon, so a 23 h or 25 h day never skips or repeats a date.
  noon=$(date -d "$(date +%F) 12:00" +%s)
  for k in 0 1 2; do
    day=$(date -d "@$((noon + k * 86400))" +%F)
    ts=$(date -d "${day} ${RUN_AT}" +%s 2>/dev/null) || ts=$(date -d "${day} ${fallback}" +%s)
    if ((ts > now)); then
      echo "$ts"
      return 0
    fi
  done
  return 1
}

sleep_until() {
  local target=$1 now remaining
  while true; do
    now=$(date +%s)
    remaining=$((target - now))
    ((remaining > 0)) || return 0
    ((remaining <= MAX_SLEEP)) || remaining=$MAX_SLEEP
    # In the background, so the TERM trap runs at once (docker compose stop).
    sleep "$remaining" &
    wait $! || true
  done
}

loop() {
  local next age slot retry

  trap 'log "stopping"; exit 0' TERM INT

  log "started: dumps ${PGUSER:-?}@${PGHOST:-?}:${PGPORT:-5432}/${PGDATABASE:-?} daily at ${RUN_AT} ${TZ:-UTC}, keeps ${KEEP} in ${DB_DIR}"
  if ionice -c 3 true 2>/dev/null; then
    log "priority: nice 19, ionice idle"
  else
    log "priority: nice 19 (ionice refused here)"
  fi
  if [ -n "${TZ:-}" ] && [ ! -e "/usr/share/zoneinfo/${TZ}" ]; then
    log "WARNING time zone ${TZ} is not installed in this image; times are UTC"
  fi

  if age=$(age_of_last_success) && ((age <= STALE_AFTER)); then
    next=$(next_slot)
    log "last success $((age / 3600)) h ago: $(cat "$LAST_SUCCESS")"
  else
    next=$(date +%s)
    log "no success in the last 24 h: running now"
  fi

  while true; do
    if (($(date +%s) < next)); then
      log "next run at $(date -d "@${next}" -Iminutes)"
      sleep_until "$next"
    fi

    # A separate process, so `set -e` holds in the run, and a failure ends only the run.
    if bash "$SELF" once; then
      next=$(next_slot)
    else
      slot=$(next_slot)
      retry=$(($(date +%s) + RETRY_AFTER))
      next=$((retry < slot ? retry : slot))
    fi
  done
}

main() {
  check_settings || return $?
  case "${1:-loop}" in
    loop) loop ;;
    once) run_once ;;
    health) health ;;
    *)
      echo "usage: $0 [loop|once|health]" >&2
      return 2
      ;;
  esac
}

# On one line, so bash has read all of it before it runs: the deploy may overwrite this file
# while the loop sleeps.
main "$@"; exit $?
