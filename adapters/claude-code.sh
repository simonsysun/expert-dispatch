#!/usr/bin/env bash
set -euo pipefail

# expert-dispatch: Claude Code adapter
# Delegates tasks to Claude Code CLI with structured output, session management, and audit logging.
#
# Requirements:
#   - Claude Code CLI installed and authenticated (https://claude.ai/claude-code)
#   - python3 (for JSON parsing)
#   - bash 3.2+ (macOS default) or bash 4+ (Linux)
#   - timeout (coreutils) or gtimeout (macOS: brew install coreutils)
#
# Configuration (environment variables):
#   DISPATCH_PROJECTS_DIR  — where projects live (default: ~/dispatch-projects)
#   DISPATCH_CC_BIN        — path to claude CLI (default: auto-detect)
#   DISPATCH_TIMEOUT       — default timeout in seconds (default: 600)
#   DISPATCH_PERMISSION    — CC permission mode (default: acceptEdits)
#                            Options: acceptEdits, plan, dangerously-skip-permissions
#                            Note: headless mode (-p) requires a permission mode that doesn't
#                            prompt interactively. "acceptEdits" auto-approves file edits;
#                            "dangerously-skip-permissions" auto-approves everything.

readonly VERSION="1.0.1"
readonly PROJECTS_DIR="${DISPATCH_PROJECTS_DIR:-$HOME/dispatch-projects}"
readonly DEFAULT_TIMEOUT="${DISPATCH_TIMEOUT:-600}"
readonly DEFAULT_MAX_TURNS=0

# Auto-detect Claude Code binary
detect_cc_bin() {
  if [[ -n "${DISPATCH_CC_BIN:-}" ]]; then
    echo "$DISPATCH_CC_BIN"
  elif command -v claude &>/dev/null; then
    command -v claude
  else
    echo ""
  fi
}

# Auto-detect timeout command (GNU timeout or gtimeout on macOS)
detect_timeout_bin() {
  if command -v timeout &>/dev/null; then
    echo "timeout"
  elif command -v gtimeout &>/dev/null; then
    echo "gtimeout"
  else
    echo ""
  fi
}

CC_BIN="$(detect_cc_bin)"
TIMEOUT_BIN="$(detect_timeout_bin)"

# ── Helpers ──────────────────────────────────────────────────────────────

log()  { echo "[dispatch-cc] $(date '+%H:%M:%S') $*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

require_cc() {
  [[ -n "$CC_BIN" && -x "$CC_BIN" ]] || die "Claude Code CLI not found. Install: https://claude.ai/claude-code"
}

require_timeout() {
  if [[ -z "$TIMEOUT_BIN" ]]; then
    die "timeout command not found. On macOS: brew install coreutils (provides gtimeout)"
  fi
}

validate_slug() {
  local slug="$1"
  if [[ -z "$slug" ]] || [[ "$slug" == *..* ]] || [[ "$slug" == /* ]] || [[ "$slug" == */* ]]; then
    die "Invalid slug: '$slug' (use lowercase alphanumeric with hyphens, e.g. 'my-project')"
  fi
  # Check for valid characters (compatible with bash 3.2)
  case "$slug" in
    *[!a-zA-Z0-9._-]*) die "Invalid slug: '$slug' (use lowercase alphanumeric with hyphens, e.g. 'my-project')" ;;
  esac
}

validate_number() {
  local val="$1" name="$2"
  case "$val" in
    ''|*[!0-9]*) die "$name must be a number, got: '$val'" ;;
  esac
}

lock_dir_for_slug() {
  local slug="$1"
  local base="${TMPDIR:-/tmp}"
  echo "${base}/expert-dispatch-cc-${slug}.lock"
}

acquire_lock() {
  local lock_dir="$1"
  if mkdir "$lock_dir" 2>/dev/null; then
    echo $$ > "$lock_dir/pid"
    trap "release_lock '$lock_dir'" EXIT
    return 0
  fi
  local pid
  pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    die "Another instance is running on this project (PID $pid)"
  fi
  log "Removing stale lock (PID $pid)"
  rm -rf "$lock_dir"
  mkdir "$lock_dir" || die "Failed to acquire lock"
  echo $$ > "$lock_dir/pid"
  trap "release_lock '$lock_dir'" EXIT
}

release_lock() {
  rm -rf "$1" 2>/dev/null || true
}

# Cross-platform file modification time
file_mtime() {
  local file="$1"
  if stat --version &>/dev/null 2>&1; then
    date -r "$file" '+%m-%d %H:%M' 2>/dev/null || echo ""
  else
    stat -f '%Sm' -t '%m-%d %H:%M' "$file" 2>/dev/null || echo ""
  fi
}

usage() {
  cat <<'EOF'
expert-dispatch (Claude Code adapter) — Delegate tasks to Claude Code CLI

Usage:
  dispatch-cc run     --slug NAME --prompt TEXT [OPTIONS]
  dispatch-cc review  --slug NAME [--prompt TEXT] [OPTIONS]
  dispatch-cc resume  --slug NAME --prompt TEXT [OPTIONS]
  dispatch-cc status  --slug NAME
  dispatch-cc list
  dispatch-cc search <keyword>

Commands:
  run      Execute a task with Claude Code in a project directory
  review   Run an independent review on an existing project
  resume   Resume a previous session for follow-up work
  status   Show last run info for a project
  list     List all projects with descriptions
  search   Find projects by keyword

Options:
  --slug NAME            Project name (required)
  --prompt TEXT          Task description
  --prompt-file FILE     Read prompt from file
  --desc TEXT            Project description (auto-generated if omitted)
  --timeout SEC          Max execution time (default: 600)
  --max-turns N          Limit to N agentic turns
  --model MODEL          Model override (e.g. opus, sonnet)
  --allowed-tools TOOLS  Restrict available tools
  --system-prompt TEXT   Append to system prompt
  --verbose              Show stderr output
  -h, --help             Show this help
  --version              Show version

Environment:
  DISPATCH_PROJECTS_DIR  Project root (default: ~/dispatch-projects)
  DISPATCH_CC_BIN        Claude CLI path (default: auto-detect)
  DISPATCH_TIMEOUT       Default timeout (default: 600)
  DISPATCH_PERMISSION    Permission mode (default: acceptEdits)
                         Options: acceptEdits, plan, dangerously-skip-permissions

Iterative workflow:
  dispatch-cc run    --slug my-task --prompt "build X" --max-turns 20
  dispatch-cc resume --slug my-task --prompt "change Y to Z"
  dispatch-cc review --slug my-task
EOF
}

# ── Core ─────────────────────────────────────────────────────────────────

run_cc() {
  local project_dir="$1" prompt="$2" timeout="$3"
  local model="$4" allowed_tools="$5" verbose="$6"
  local session_name="$7" resume_id="$8" max_turns="$9" system_prompt="${10}"

  mkdir -p "$project_dir/.dispatch-logs"

  local ts
  ts=$(date '+%Y%m%d-%H%M%S')-$$
  local log_file="$project_dir/.dispatch-logs/${ts}-result.json"
  local stderr_log="$project_dir/.dispatch-logs/${ts}-stderr.log"

  # Build command
  local -a cmd=("$CC_BIN")
  cmd+=(-p "$prompt")
  cmd+=(--print)
  cmd+=(--output-format json)

  # Permission mode — default to acceptEdits for headless operation
  local perm="${DISPATCH_PERMISSION:-acceptEdits}"
  if [[ "$perm" == "dangerously-skip-permissions" ]]; then
    cmd+=(--dangerously-skip-permissions)
  else
    cmd+=(--permission-mode "$perm")
  fi

  if [[ -n "$resume_id" ]]; then
    cmd+=(--resume "$resume_id")
  else
    cmd+=(--add-dir "$project_dir")
    cmd+=(--name "$session_name")
  fi

  [[ -n "$model" ]] && cmd+=(--model "$model")
  [[ -n "$allowed_tools" ]] && cmd+=(--allowedTools "$allowed_tools")
  if [[ "$max_turns" -gt 0 ]] 2>/dev/null; then
    cmd+=(--max-turns "$max_turns")
  fi
  [[ -n "$system_prompt" ]] && cmd+=(--append-system-prompt "$system_prompt")

  log "Project: $project_dir"
  log "Session: $session_name"
  log "Timeout: ${timeout}s | Max turns: ${max_turns:-unlimited}"
  log "Model: ${model:-default} | Permission: $perm"

  # Execute from project directory
  local exit_code=0
  (
    cd "$project_dir"
    "$TIMEOUT_BIN" "$timeout" "${cmd[@]}"
  ) > "$log_file" 2>"$stderr_log" || exit_code=$?

  # CC may output JSON to stderr in some configurations
  if [[ ! -s "$log_file" && -s "$stderr_log" ]]; then
    if python3 -c "import json,sys; json.load(sys.stdin)" < "$stderr_log" 2>/dev/null; then
      log "Recovered JSON from stderr"
      cp "$stderr_log" "$log_file"
    fi
  fi

  if [[ $exit_code -eq 124 ]]; then
    log "TIMEOUT after ${timeout}s"
    [[ -s "$log_file" ]] && cat "$log_file"
    return 124
  elif [[ $exit_code -ne 0 ]]; then
    log "Exited with code $exit_code"
    [[ "$verbose" == "true" ]] && cat "$stderr_log" >&2
    [[ -s "$log_file" ]] && cat "$log_file"
    return "$exit_code"
  fi

  # Parse result in one python3 call — also detect permission denials
  eval "$(python3 -c "
import json, sys, os
d = json.load(sys.stdin)
base = sys.argv[1]
sid = d.get('session_id', '')
if sid:
    open(os.path.join(base, 'last-session-id'), 'w').write(sid)
result = d.get('result', '')
if result:
    open(os.path.join(base, 'last-result.txt'), 'w').write(result)
sr = d.get('stop_reason', '')
nt = d.get('num_turns', 0)
denials = d.get('permission_denials', [])
blocked = 'true' if denials else 'false'
print('stop_reason=%s; num_turns=%s; session_id=%s; was_blocked=%s' % (repr(sr), repr(nt), repr(sid), blocked))
" "$project_dir/.dispatch-logs" < "$log_file" 2>/dev/null)" || true

  [[ -n "${session_id:-}" ]] && log "Session ID saved: $session_id"
  log "Stop reason: ${stop_reason:-?} | Turns: ${num_turns:-?}"

  if [[ "${was_blocked:-false}" == "true" ]]; then
    log "WARNING: Run had permission denials — some actions were blocked. Set DISPATCH_PERMISSION=dangerously-skip-permissions for fully autonomous execution."
  fi

  cat "$log_file"
  log "Done. Log: $log_file"
}

# ── Option Parsing ───────────────────────────────────────────────────────

parse_common_opts() {
  _OPT_slug=""
  _OPT_prompt=""
  _OPT_prompt_file=""
  _OPT_desc=""
  _OPT_timeout="$DEFAULT_TIMEOUT"
  _OPT_max_turns="$DEFAULT_MAX_TURNS"
  _OPT_model=""
  _OPT_allowed_tools=""
  _OPT_system_prompt=""
  _OPT_verbose="false"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --slug|--prompt|--prompt-file|--desc|--timeout|--max-turns|--model|--allowed-tools|--system-prompt)
        if [[ $# -lt 2 ]]; then die "$1 requires a value"; fi
        ;;
    esac
    case $1 in
      --slug)           _OPT_slug="$2"; shift 2 ;;
      --prompt)         _OPT_prompt="$2"; shift 2 ;;
      --prompt-file)    _OPT_prompt_file="$2"; shift 2 ;;
      --desc)           _OPT_desc="$2"; shift 2 ;;
      --timeout)        _OPT_timeout="$2"; shift 2 ;;
      --max-turns)      _OPT_max_turns="$2"; shift 2 ;;
      --model)          _OPT_model="$2"; shift 2 ;;
      --allowed-tools)  _OPT_allowed_tools="$2"; shift 2 ;;
      --system-prompt)  _OPT_system_prompt="$2"; shift 2 ;;
      --verbose)        _OPT_verbose="true"; shift ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  # Validate numeric options
  validate_number "$_OPT_timeout" "--timeout"
  validate_number "$_OPT_max_turns" "--max-turns"
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_run() {
  require_cc
  require_timeout
  parse_common_opts "$@"
  [[ -z "$_OPT_slug" ]] && die "--slug is required"
  validate_slug "$_OPT_slug"
  [[ -z "$_OPT_prompt" && -z "$_OPT_prompt_file" ]] && die "--prompt or --prompt-file required"

  if [[ -n "$_OPT_prompt_file" ]]; then
    [[ -f "$_OPT_prompt_file" ]] || die "Prompt file not found: $_OPT_prompt_file"
    _OPT_prompt=$(cat "$_OPT_prompt_file")
  fi

  local project_dir="$PROJECTS_DIR/$_OPT_slug"
  mkdir -p "$project_dir"

  # Initialize CLAUDE.md (CC auto-loads this for project context)
  if [[ ! -f "$project_dir/CLAUDE.md" ]]; then
    echo "# Project: $_OPT_slug" > "$project_dir/CLAUDE.md"
    log "Initialized CLAUDE.md"
  fi

  # Save project metadata
  mkdir -p "$project_dir/.dispatch-logs"
  local meta_file="$project_dir/.dispatch-logs/project.json"
  local created_at="" old_desc=""
  if [[ -f "$meta_file" ]]; then
    created_at=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('created',''))" < "$meta_file" 2>/dev/null || echo "")
    old_desc=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))" < "$meta_file" 2>/dev/null || echo "")
  fi
  created_at="${created_at:-$(date -Is)}"
  local desc="${_OPT_desc:-$old_desc}"
  if [[ -z "$desc" ]]; then
    desc="${_OPT_prompt:0:100}"
  fi
  python3 -c "
import json, sys
d = {'slug': sys.argv[1], 'description': sys.argv[2], 'created': sys.argv[3], 'updated': sys.argv[4]}
json.dump(d, open(sys.argv[5], 'w'), indent=2)
" "$_OPT_slug" "$desc" "$created_at" "$(date -Is)" "$meta_file" 2>/dev/null

  local lock_dir
  lock_dir=$(lock_dir_for_slug "$_OPT_slug")
  acquire_lock "$lock_dir"
  run_cc "$project_dir" "$_OPT_prompt" "$_OPT_timeout" \
    "$_OPT_model" "$_OPT_allowed_tools" "$_OPT_verbose" \
    "dispatch-$_OPT_slug" "" "$_OPT_max_turns" "$_OPT_system_prompt"
}

cmd_review() {
  require_cc
  require_timeout
  parse_common_opts "$@"
  [[ -z "$_OPT_slug" ]] && die "--slug is required"
  validate_slug "$_OPT_slug"

  local project_dir="$PROJECTS_DIR/$_OPT_slug"
  [[ -d "$project_dir" ]] || die "Project not found: $project_dir"

  if [[ -z "$_OPT_prompt" ]]; then
    _OPT_prompt="Review all code in this project. Check correctness, security, code quality, completeness, and tests. Output: overall assessment, issues with file:line and severity, and suggested fixes."
  fi

  local lock_dir
  lock_dir=$(lock_dir_for_slug "$_OPT_slug")
  acquire_lock "$lock_dir"
  run_cc "$project_dir" "$_OPT_prompt" "$_OPT_timeout" \
    "$_OPT_model" "$_OPT_allowed_tools" "$_OPT_verbose" \
    "dispatch-$_OPT_slug-review" "" "$_OPT_max_turns" "$_OPT_system_prompt"
}

cmd_resume() {
  require_cc
  require_timeout
  parse_common_opts "$@"
  [[ -z "$_OPT_slug" ]] && die "--slug is required"
  validate_slug "$_OPT_slug"
  [[ -z "$_OPT_prompt" && -z "$_OPT_prompt_file" ]] && die "--prompt or --prompt-file required"

  if [[ -n "$_OPT_prompt_file" ]]; then
    _OPT_prompt=$(cat "$_OPT_prompt_file")
  fi

  local project_dir="$PROJECTS_DIR/$_OPT_slug"
  [[ -d "$project_dir" ]] || die "Project not found: $project_dir"

  local resume_id=""
  if [[ -f "$project_dir/.dispatch-logs/last-session-id" ]]; then
    resume_id=$(cat "$project_dir/.dispatch-logs/last-session-id")
    log "Resuming session: $resume_id"
  else
    log "No previous session found, starting fresh"
  fi

  local lock_dir
  lock_dir=$(lock_dir_for_slug "$_OPT_slug")
  acquire_lock "$lock_dir"
  run_cc "$project_dir" "$_OPT_prompt" "$_OPT_timeout" \
    "$_OPT_model" "$_OPT_allowed_tools" "$_OPT_verbose" \
    "dispatch-$_OPT_slug" "$resume_id" "$_OPT_max_turns" "$_OPT_system_prompt"
}

cmd_status() {
  local slug=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --slug) slug="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ -z "$slug" ]] && die "--slug is required"
  validate_slug "$slug"

  local project_dir="$PROJECTS_DIR/$slug"
  [[ -d "$project_dir" ]] || die "Project not found: $project_dir"

  echo "Project: $slug"
  echo "Path: $project_dir"
  [[ -f "$project_dir/.dispatch-logs/last-session-id" ]] && echo "Last session: $(cat "$project_dir/.dispatch-logs/last-session-id")"

  local last_log
  last_log=$(ls -t "$project_dir/.dispatch-logs/"*-result.json 2>/dev/null | head -1 || echo "")
  if [[ -n "$last_log" ]]; then
    echo "Last run: $(basename "$last_log")"
    python3 -c "
import json, sys
d = json.load(sys.stdin)
denials = d.get('permission_denials', [])
if denials:
    status = 'BLOCKED (permission denials)'
elif d.get('is_error'):
    status = 'error'
else:
    status = 'success'
print(f'  Status: {status}')
print(f'  Duration: {d.get(\"duration_ms\", 0) / 1000:.1f}s')
print(f'  Turns: {d.get(\"num_turns\", 0)}')
print(f'  Stop reason: {d.get(\"stop_reason\", \"unknown\")}')
if denials:
    print(f'  Denials: {len(denials)} action(s) were blocked by permission policy')
" < "$last_log" 2>/dev/null || echo "  (could not parse)"
  else
    echo "No runs yet"
  fi

  if [[ -f "$project_dir/.dispatch-logs/last-result.txt" ]]; then
    echo ""; echo "Last result:"
    head -20 "$project_dir/.dispatch-logs/last-result.txt"
  fi
}

cmd_list() {
  [[ ! -d "$PROJECTS_DIR" ]] && { echo "No projects yet."; return; }
  local count=0
  for dir in "$PROJECTS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    count=$((count + 1))
    local name
    name=$(basename "$dir")
    local desc=""
    if [[ -f "$dir/.dispatch-logs/project.json" ]]; then
      desc=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('description','')[:80])" < "$dir/.dispatch-logs/project.json" 2>/dev/null || echo "")
    fi
    local last=""
    local last_log
    last_log=$(ls -t "$dir/.dispatch-logs/"*-result.json 2>/dev/null | head -1 || echo "")
    if [[ -n "$last_log" ]]; then
      last=$(file_mtime "$last_log")
    fi
    if [[ -n "$desc" ]]; then
      printf "  %-25s %s  — %s\n" "$name" "${last:-(new)}" "$desc"
    else
      printf "  %-25s %s\n" "$name" "${last:-(new)}"
    fi
  done
  if [[ $count -eq 0 ]]; then
    echo "No projects yet."
  else
    echo "  ($count projects)"
  fi
}

cmd_search() {
  local query=""
  while [[ $# -gt 0 ]]; do query="$query $1"; shift; done
  query="${query# }"
  [[ -z "$query" ]] && die "Usage: dispatch-cc search <keyword>"
  [[ ! -d "$PROJECTS_DIR" ]] && { echo "No projects yet."; return; }

  local found=0
  for dir in "$PROJECTS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name=$(basename "$dir")
    local desc=""
    if [[ -f "$dir/.dispatch-logs/project.json" ]]; then
      desc=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))" < "$dir/.dispatch-logs/project.json" 2>/dev/null || echo "")
    fi
    local last_result=""
    if [[ -f "$dir/.dispatch-logs/last-result.txt" ]]; then
      last_result=$(cat "$dir/.dispatch-logs/last-result.txt" 2>/dev/null || echo "")
    fi
    local haystack
    haystack=$(echo "$name $desc $last_result" | tr '[:upper:]' '[:lower:]')
    local needle
    needle=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
      found=$((found + 1))
      printf "  %-25s — %s\n" "$name" "${desc:-(no description)}"
    fi
  done
  if [[ $found -eq 0 ]]; then
    echo "No projects matching '$query'."
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  run)       shift; cmd_run "$@" ;;
  review)    shift; cmd_review "$@" ;;
  resume)    shift; cmd_resume "$@" ;;
  status)    shift; cmd_status "$@" ;;
  list)      shift; cmd_list "$@" ;;
  search)    shift; cmd_search "$@" ;;
  -h|--help) usage ;;
  --version) echo "expert-dispatch (claude-code adapter) $VERSION" ;;
  *)         usage; exit 1 ;;
esac
