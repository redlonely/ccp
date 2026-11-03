#!/bin/bash
set -euo pipefail

# ccp — concise wrapper around `cc-switch start claude`.
# Usage: ccp [-d|--danger] [-n|--dry-run] <provider> [-- <claude args...>]

DB="${CC_SWITCH_DB:-$HOME/.cc-switch/cc-switch.db}"
DANGER=false
DRY_RUN=false
USAGE_PID=""
COMPAT_DIR=""

usage() {
  cat <<'EOF'
Usage: ccp [-d|--danger] [-n|--dry-run] <provider> [-- <claude args...>]

Options:
  -d, --danger   pass --dangerously-skip-permissions to Claude
  -n, --dry-run  preview the cc-switch launch without starting Claude
      --check    verify ccp dependencies and CLI database compatibility
  -h, --help     show this help
EOF
}

list_providers() {
  if [[ ! -f "$DB" ]]; then
    echo "ccp: cc-switch database not found: $DB" >&2
    return 1
  fi
  echo "Available providers:"
  sqlite3 "$DB" \
    "SELECT '  ' || name FROM providers WHERE app_type='claude' ORDER BY sort_index, name;"
}

check_environment() {
  local failed=0
  local command_name
  for command_name in cc-switch sqlite3; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "missing: $command_name" >&2
      failed=1
    fi
  done
  if [[ ! -f "$DB" ]]; then
    echo "missing: $DB" >&2
    failed=1
  fi
  if ((failed)); then return 1; fi
  prepare_cli_database
  local fetcher=${CCP_USAGE_FETCHER:-$HOME/.local/share/ccp/fetch-provider-usage.mjs}
  if [[ -f "$fetcher" ]] && command -v node >/dev/null 2>&1; then
    CCP_USAGE_DIR="${CCP_USAGE_DIR:-$HOME/.claude/plugins/claude-hud}" node "$fetcher" --check
  fi
  echo "ccp environment OK"
}

sql_string() {
  local value=${1//\'/\'\'}
  printf "'%s'" "$value"
}

resolve_provider() {
  local query=$1 quoted rows count
  quoted=$(sql_string "$query")

  rows=$(sqlite3 -separator $'\t' "$DB" "
    SELECT id, name FROM providers
    WHERE app_type='claude' AND (id = $quoted OR name = $quoted)
    ORDER BY CASE WHEN id = $quoted THEN 0 ELSE 1 END, sort_index LIMIT 1;
  ")

  if [[ -z "$rows" ]]; then
    rows=$(sqlite3 -separator $'\t' "$DB" "
      SELECT id, name FROM providers
      WHERE app_type='claude' AND LOWER(name) = LOWER($quoted)
      ORDER BY sort_index LIMIT 1;
    ")
  fi

  if [[ -z "$rows" ]]; then
    rows=$(sqlite3 -separator $'\t' "$DB" "
      SELECT id, name FROM providers
      WHERE app_type='claude'
        AND (INSTR(LOWER(name), LOWER($quoted)) > 0
             OR INSTR(LOWER(id), LOWER($quoted)) > 0)
      ORDER BY sort_index, name;
    ")
    count=$(printf '%s\n' "$rows" | awk 'NF { count++ } END { print count + 0 }')
    if ((count > 1)); then
      echo "ccp: provider '$query' is ambiguous:" >&2
      printf '%s\n' "$rows" | awk -F '\t' 'NF { print "  " $2 }' >&2
      return 2
    fi
  fi

  if [[ -z "$rows" ]]; then
    echo "ccp: provider '$query' not found" >&2
    list_providers >&2 || true
    return 1
  fi
  printf '%s\n' "${rows%%$'\n'*}"
}

stop_usage_refresher() {
  if [[ -n "$USAGE_PID" ]]; then
    kill "$USAGE_PID" 2>/dev/null || true
    wait "$USAGE_PID" 2>/dev/null || true
  fi
}

cleanup() {
  stop_usage_refresher
  if [[ -n "$COMPAT_DIR" ]]; then
    python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "$COMPAT_DIR"
  fi
}

# shortcut: schema relabeling requires compatible tables; update the CLI if migrations break them.
prepare_cli_database() {
  local schema max_schema cli_error state_dir
  schema=$(sqlite3 "$DB" 'PRAGMA user_version;')
  if cli_error=$(cc-switch provider list 2>&1 >/dev/null); then return; fi
  if [[ "$cli_error" =~ 最高支持数据库版本:[[:space:]]*([0-9]+) ]]; then
    max_schema=${BASH_REMATCH[1]}
  else
    printf '%s\n' "$cli_error" >&2
    echo "ccp: cannot determine the CLI schema limit; database unchanged" >&2
    return 1
  fi
  if ((schema <= max_schema)); then
    printf '%s\n' "$cli_error" >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "ccp: python3 is needed for temporary database cleanup" >&2
    return 1
  fi
  state_dir=${CCP_STATE_DIR:-$HOME/.local/state/ccp}
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  COMPAT_DIR=$(mktemp -d "$state_dir/schema${max_schema}-compat.XXXXXX")
  trap cleanup EXIT
  chmod 700 "$COMPAT_DIR"
  sqlite3 "$DB" ".backup '$COMPAT_DIR/cc-switch.db'"
  chmod 600 "$COMPAT_DIR/cc-switch.db"
  sqlite3 "$COMPAT_DIR/cc-switch.db" "PRAGMA user_version=$max_schema;"
  export CC_SWITCH_CONFIG_DIR="$COMPAT_DIR"
  echo "ccp: using a temporary CLI-compatible database snapshot (schema $schema -> $max_schema); live database unchanged" >&2
  cc-switch provider list >/dev/null
}

start_usage_refresher() {
  local fetcher=${CCP_USAGE_FETCHER:-$HOME/.local/share/ccp/fetch-provider-usage.mjs}
  local output_dir=${CCP_USAGE_DIR:-$HOME/.claude/plugins/claude-hud}
  local state_dir=${CCP_STATE_DIR:-$HOME/.local/state/ccp}
  local interval=${CCP_USAGE_INTERVAL_SECONDS:-60}

  if [[ ${CCP_USAGE_REFRESH:-1} == 0 || ! -f "$fetcher" ]]; then return; fi
  if ! command -v node >/dev/null 2>&1; then return; fi
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ ]]; then
    echo "ccp: invalid CCP_USAGE_INTERVAL_SECONDS: $interval" >&2
    return
  fi

  mkdir -p "$output_dir" "$state_dir"
  (
    while true; do
      CCP_USAGE_DIR="$output_dir" node "$fetcher" \
        >>"$state_dir/provider-usage.log" \
        2>>"$state_dir/provider-usage.err" || true
      sleep "$interval"
    done
  ) &
  USAGE_PID=$!
  trap cleanup EXIT
}

if (($# == 0)); then
  usage
  echo
  list_providers
  exit 0
fi

while (($#)); do
  case "$1" in
    -d|--danger) DANGER=true; shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    --check) check_environment; exit ;;
    -h|--help) usage; exit 0 ;;
    --) echo "ccp: provider must appear before --" >&2; exit 2 ;;
    -*) echo "ccp: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) break ;;
  esac
done

if (($# == 0)); then
  echo "ccp: provider is required" >&2
  exit 2
fi

QUERY=$1
shift
if [[ ${1:-} == "--" ]]; then shift; fi
NATIVE_ARGS=("$@")
NATIVE_COUNT=$#

for dependency in cc-switch sqlite3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "ccp: $dependency is not installed or not in PATH" >&2
    exit 1
  fi
done
if [[ ! -f "$DB" ]]; then
  echo "ccp: cc-switch database not found: $DB" >&2
  exit 1
fi

ROW=$(resolve_provider "$QUERY")
PROVIDER_ID=${ROW%%$'\t'*}
PROVIDER_NAME=${ROW#*$'\t'}

prepare_cli_database

COMMAND=(cc-switch start claude "$PROVIDER_ID")
if $DRY_RUN; then COMMAND+=(--dry-run); fi
if $DANGER || ((NATIVE_COUNT > 0)); then
  COMMAND+=(--)
  if $DANGER; then COMMAND+=(--dangerously-skip-permissions); fi
  if ((NATIVE_COUNT > 0)); then COMMAND+=("${NATIVE_ARGS[@]}"); fi
fi

if $DRY_RUN; then
  echo "ccp: $QUERY -> $PROVIDER_NAME"
  "${COMMAND[@]}"
  exit $?
fi

start_usage_refresher
set +e
"${COMMAND[@]}"
STATUS=$?
set -e
exit "$STATUS"
