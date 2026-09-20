#!/bin/bash
#
# Status line for Claude Code.
#
# Reads the JSON that Claude Code writes to stdin and prints one line:
#
#   model[ »] │ ✍️ context%[↑] │ [⚡ ]branch[*] │ ⏱ session │ effort │ ♨ cache
#         │ 5h … │ 7d … │ 7d <model> … │ extra …
#
# Design notes:
#   - The rendered line is cached per session for OUTPUT_CACHE_TTL seconds
#     and re-rendered as soon as the model, effort, context usage,
#     directory, cache warmth, 200k flag or fast mode in the stdin JSON
#     change, so the common path is one stat and two reads.
#   - » after the model name means fast mode is on: Opus at up to 2.5x the
#     speed, billed per token from usage credits rather than the plan.
#   - ↑ after the context percentage means the last request exceeded 200k
#     tokens, a fixed threshold whatever the window size. The 1M window has
#     no per-token premium beyond it, but every turn now processes 200k+
#     tokens, which is slow and is what /usage flags as long context: a
#     hint to /compact or /clear at the next natural break.
#   - The cache segment shows ♨ and the time the prompt cache goes cold, or
#     ❄ once it has; the next prompt after that re-sends the whole context.
#   - All stdin fields are extracted with a single jq call.
#   - Timers use minute resolution, so the output is stable between
#     refreshes and the terminal is not redrawn needlessly.
#   - Per-model weekly limits (e.g. Fable) and extra usage only exist in the
#     /api/oauth/usage response, which is cached for USAGE_CACHE_TTL seconds
#     and shared between sessions.
#   - Ultracode reaches the status line as effort "xhigh": inside Claude
#     Code it is a separate in-memory flag, not an effort level. It is shown
#     as "ultra" when the last ultra_effort_enter/exit marker in the session
#     transcript says it is on. Claude Code appends such a marker at the
#     next typed prompt after the flag changes, and the transcript is only
#     read when the line is re-rendered, so the label follows a toggle at
#     the next assistant message. Until the first marker exists, the
#     --effort ultracode launch flag and the ultracode settings key count.
#   - Runs on bash 3.2 (macOS /bin/bash) and with both BSD and GNU date/stat.
#
# Setup on a new machine (needs bash 3.2+, jq and curl):
#
#   mkdir -p ~/.claude/scripts
#   ln -s ../../dotfiles/.claude/scripts/statusline.sh \
#     ~/.claude/scripts/statusline.sh
#   brew install jq   # or: apt install jq
#
# Then add this to ~/.claude/settings.json:
#
#   "statusLine": {
#     "type": "command",
#     "command": "bash ~/.claude/scripts/statusline.sh",
#     "refreshInterval": 1
#   }
#
# The OAuth token is read at runtime from the macOS keychain, or from
# ~/.claude/.credentials.json / secret-tool on Linux, to fetch per-model
# weekly limits. Nothing secret is stored in this file.

# Defensive: nothing here should ever glob, so turn pathname expansion off.
set -f

readonly CACHE_DIR="${CLAUDE_STATUSLINE_CACHE_DIR:-/tmp/claude}"
readonly OUTPUT_CACHE_TTL=60  # seconds between re-renders, per session
readonly USAGE_CACHE_TTL=60   # seconds between usage API calls, shared
readonly USAGE_API_URL='https://api.anthropic.com/api/oauth/usage'
readonly USAGE_API_USER_AGENT='claude-code/2.1.34'
readonly KEYCHAIN_SERVICE='Claude Code-credentials'
readonly CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
readonly SETTINGS_FILE="${HOME}/.claude/settings.json"
readonly DEFAULT_CONTEXT_SIZE=200000
readonly BAR_WIDTH=5
readonly ISO_FORMAT='%Y-%m-%dT%H:%M:%S'

# Field separator between values extracted by jq. The ASCII unit separator
# is used rather than tab: tab is IFS whitespace, so `read` would collapse
# empty fields and shift everything after them.
readonly FIELD_SEP=$'\x1f'

# 24-bit ANSI colours.
readonly BLUE=$'\033[38;2;0;153;255m'
readonly ORANGE=$'\033[38;2;255;176;85m'
readonly GREEN=$'\033[38;2;0;175;80m'
readonly CYAN=$'\033[38;2;86;182;194m'
readonly RED=$'\033[38;2;255;85;85m'
readonly YELLOW=$'\033[38;2;230;200;0m'
readonly WHITE=$'\033[38;2;220;220;220m'
readonly DARK_ORANGE=$'\033[38;2;200;100;30m'
readonly DIM=$'\033[2m'
readonly RESET=$'\033[0m'
readonly SEP=" ${DIM}│${RESET} "

# Colours cycled through the "max" effort label, red to violet.
RAINBOW_COLORS=(
  $'\033[38;2;255;90;90m'
  $'\033[38;2;255;160;70m'
  $'\033[38;2;235;205;0m'
  $'\033[38;2;0;200;100m'
  $'\033[38;2;0;160;255m'
  $'\033[38;2;120;100;230m'
  $'\033[38;2;200;120;255m'
)
readonly RAINBOW_COLORS

#######################################
# Test whether a value extracted from JSON is present.
# Arguments:
#   The value.
# Returns:
#   0 if the value is neither empty nor the string "null", 1 otherwise.
#######################################
has_value() {
  [[ -n "$1" && "$1" != 'null' ]]
}

#######################################
# Print a file's modification time as epoch seconds.
# Arguments:
#   Path to the file.
# Outputs:
#   Epoch seconds, or nothing if the file cannot be read.
# Returns:
#   0 on success, 1 otherwise.
#######################################
file_mtime() {
  local mtime

  # BSD stat first, GNU stat as fallback; the result must be numeric.
  mtime=$(stat -f %m "$1" 2>/dev/null)
  case "${mtime}" in
    ''|*[!0-9]*) mtime=$(stat -c %Y "$1" 2>/dev/null) ;;
  esac
  case "${mtime}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "${mtime}"
}

#######################################
# Print the colour code for a utilisation percentage.
# Arguments:
#   Percentage (integer).
#######################################
color_for_pct() {
  local pct=$1

  if (( pct >= 90 )); then
    printf '%s' "${RED}"
  elif (( pct >= 70 )); then
    printf '%s' "${YELLOW}"
  elif (( pct >= 50 )); then
    printf '%s' "${ORANGE}"
  else
    printf '%s' "${GREEN}"
  fi
}

#######################################
# Render a utilisation bar such as "◉◉◕○○".
# Arguments:
#   Percentage (integer, clamped to 0..100).
#   Bar width in cells.
#######################################
build_bar() {
  local pct=$1
  local width=$2
  local step=$(( 100 / width ))
  local quarter=$(( step / 4 ))
  local bar='' bar_color i base fill

  if (( pct < 0 )); then
    pct=0
  elif (( pct > 100 )); then
    pct=100
  fi
  bar_color=$(color_for_pct "${pct}")

  for (( i = 0; i < width; i++ )); do
    base=$(( i * step ))
    fill=$(( pct - base ))
    if (( fill < 0 )); then
      fill=0
    elif (( fill > step )); then
      fill="${step}"
    fi

    if (( fill >= step )); then
      bar+='◉'
    elif (( fill >= quarter * 3 )); then
      bar+='◕'
    elif (( fill >= quarter * 2 )); then
      bar+='◐'
    elif (( fill >= quarter )); then
      bar+='◔'
    else
      bar+="${DIM}○${bar_color}"
    fi
  done

  printf '%s' "${bar_color}${bar}${RESET}"
}

#######################################
# Format epoch seconds for display.
# Arguments:
#   Epoch seconds.
#   Style: "time" gives "HH:MM", "datetime" gives "mon d, HH:MM".
# Outputs:
#   The formatted time, or nothing if the epoch is empty, null or 0.
#######################################
format_epoch_time() {
  local epoch=$1
  local style=$2
  local format result

  if ! has_value "${epoch}" || [[ "${epoch}" == '0' ]]; then
    return 0
  fi
  case "${style}" in
    time) format='%H:%M' ;;
    datetime) format='%b %-d, %H:%M' ;;
    *) return 1 ;;
  esac

  # BSD date first, GNU date as fallback.
  result=$(date -j -r "${epoch}" "+${format}" 2>/dev/null)
  [[ -z "${result}" ]] && result=$(date -d "@${epoch}" "+${format}" 2>/dev/null)
  if [[ "${style}" == 'datetime' ]]; then
    result=$(tr '[:upper:]' '[:lower:]' <<< "${result}")
  fi
  printf '%s' "${result}"
}

#######################################
# Convert an ISO-8601 timestamp to epoch seconds.
# GNU date parses it directly. For BSD date the fractional seconds and the
# timezone suffix are stripped first; a UTC suffix is honoured, any other
# offset is read in the local timezone.
# Arguments:
#   ISO-8601 timestamp, e.g. "2026-09-07T11:49:59.702601+00:00".
# Outputs:
#   Epoch seconds, or nothing if the timestamp could not be parsed.
# Returns:
#   0 on success, 1 otherwise.
#######################################
iso_to_epoch() {
  local iso=$1
  local epoch stripped utc=false

  # GNU date reads an empty string as today at midnight, so a missing
  # timestamp would otherwise turn into a plausible-looking one.
  has_value "${iso}" || return 1
  epoch=$(date -d "${iso}" +%s 2>/dev/null)
  if [[ -z "${epoch}" ]]; then
    stripped="${iso%%.*}"
    stripped="${stripped%Z}"
    stripped="${stripped%%+*}"
    stripped="${stripped%-[0-9][0-9]:[0-9][0-9]}"
    case "${iso}" in
      *Z*|*+00:00*|*-00:00*) utc=true ;;
    esac

    if [[ "${utc}" == true ]]; then
      epoch=$(TZ=UTC date -j -f "${ISO_FORMAT}" "${stripped}" +%s \
        2>/dev/null)
      [[ -z "${epoch}" ]] \
        && epoch=$(TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
      epoch=$(date -j -f "${ISO_FORMAT}" "${stripped}" +%s 2>/dev/null)
      [[ -z "${epoch}" ]] \
        && epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi
  fi

  [[ -z "${epoch}" ]] && return 1
  printf '%s' "${epoch}"
}

#######################################
# Read the OAuth access token from Claude Code credentials JSON on stdin.
# Outputs:
#   The token, or nothing if absent.
#######################################
token_from_json() {
  local token

  token=$(jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  has_value "${token}" && printf '%s' "${token}"
  return 0
}

#######################################
# Find the Claude Code OAuth access token.
# Sources, in order: $CLAUDE_CODE_OAUTH_TOKEN, the macOS keychain, the
# credentials file, and the freedesktop secret service (Linux).
# Globals:
#   CLAUDE_CODE_OAUTH_TOKEN, KEYCHAIN_SERVICE, CREDENTIALS_FILE
# Outputs:
#   The token, or nothing if none was found.
#######################################
get_oauth_token() {
  local token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  local blob

  has_value "${token}" || token=''
  if [[ -z "${token}" ]] && command -v security >/dev/null 2>&1; then
    blob=$(security find-generic-password -s "${KEYCHAIN_SERVICE}" -w \
      2>/dev/null)
    [[ -n "${blob}" ]] && token=$(token_from_json <<< "${blob}")
  fi
  if [[ -z "${token}" && -f "${CREDENTIALS_FILE}" ]]; then
    token=$(token_from_json < "${CREDENTIALS_FILE}")
  fi
  if [[ -z "${token}" ]] && command -v secret-tool >/dev/null 2>&1; then
    blob=$(timeout 2 secret-tool lookup service "${KEYCHAIN_SERVICE}" \
      2>/dev/null)
    [[ -n "${blob}" ]] && token=$(token_from_json <<< "${blob}")
  fi
  printf '%s' "${token}"
}

#######################################
# Print the usage API response, refreshed at most once per USAGE_CACHE_TTL.
# A failed refresh falls back to the stale cache rather than nothing.
# Globals:
#   CACHE_DIR, USAGE_CACHE_TTL, USAGE_API_URL, USAGE_API_USER_AGENT
# Arguments:
#   Current epoch seconds.
# Outputs:
#   Usage JSON, or nothing if neither a response nor a cache is available.
#######################################
get_usage_data() {
  local now=$1
  local cache_file="${CACHE_DIR}/statusline-usage-cache.json"
  local cache_mtime token response

  if [[ -f "${cache_file}" ]]; then
    cache_mtime=$(file_mtime "${cache_file}")
    if [[ -n "${cache_mtime}" ]] \
        && (( now - cache_mtime < USAGE_CACHE_TTL )); then
      cat "${cache_file}" 2>/dev/null
      return 0
    fi
  fi

  token=$(get_oauth_token)
  if [[ -n "${token}" ]]; then
    response=$(curl -s --max-time 5 \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer ${token}" \
      -H 'anthropic-beta: oauth-2025-04-20' \
      -H "User-Agent: ${USAGE_API_USER_AGENT}" \
      "${USAGE_API_URL}" 2>/dev/null)
    if [[ -n "${response}" ]] \
        && jq -e '.five_hour' <<< "${response}" >/dev/null 2>&1; then
      printf '%s\n' "${response}" > "${cache_file}"
      printf '%s' "${response}"
      return 0
    fi
  fi

  [[ -f "${cache_file}" ]] && cat "${cache_file}" 2>/dev/null
  return 0
}

#######################################
# Print the effort level. Falls back to $CLAUDE_EFFORT and then to the
# effortLevel in settings.json when stdin did not provide one.
# Globals:
#   CLAUDE_EFFORT, SETTINGS_FILE
# Arguments:
#   Effort level from stdin (may be empty or "null").
#######################################
resolve_effort() {
  local effort=$1

  if has_value "${effort}"; then
    printf '%s' "${effort}"
  elif [[ -n "${CLAUDE_EFFORT:-}" ]]; then
    printf '%s' "${CLAUDE_EFFORT}"
  elif [[ -f "${SETTINGS_FILE}" ]]; then
    jq -r '.effortLevel // "default"' "${SETTINGS_FILE}" 2>/dev/null
  else
    printf 'default'
  fi
}

#######################################
# Render text with one colour per character, shifted once per minute so
# it stays stable within a refresh window.
# Globals:
#   RAINBOW_COLORS, RESET
# Arguments:
#   Text to colour.
#   Current epoch seconds.
#######################################
rainbow_text() {
  local text=$1
  local now=$2
  local count=${#RAINBOW_COLORS[@]}
  local offset=$(( (now / 60) % count ))
  local out='' i index

  for (( i = 0; i < ${#text}; i++ )); do
    index=$(( (i + offset) % count ))
    out+="${RAINBOW_COLORS[index]}${text:i:1}"
  done
  printf '%s' "${out}${RESET}"
}

#######################################
# Render the effort segment.
# Arguments:
#   Effort level, or "ultracode".
#   Current epoch seconds (drives the "max" colour cycle).
#######################################
effort_segment() {
  local effort=$1
  local now=$2

  case "${effort}" in
    max) rainbow_text '● max' "${now}" ;;
    ultracode) printf '%s' "${ORANGE}◉ ultra${RESET}" ;;
    xhigh) printf '%s' "${ORANGE}◉ xhi${RESET}" ;;
    high) printf '%s' "${YELLOW}◕ hi${RESET}" ;;
    medium) printf '%s' "${CYAN}◐ med${RESET}" ;;
    low) printf '%s' "${DARK_ORANGE}◔ lo${RESET}" ;;
    auto) printf '%s' "${GREEN}◑ auto${RESET}" ;;
    *) printf '%s' "${DIM}◑ std${RESET}" ;;
  esac
}

#######################################
# Render the git segment: branch name plus "*" when the tree is dirty.
# Arguments:
#   Working directory.
# Outputs:
#   The segment, or nothing if the directory is not inside a git work tree
#   or HEAD is detached.
#######################################
git_segment() {
  local cwd=$1
  local branch dirty=''

  git -C "${cwd}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  branch=$(git -C "${cwd}" symbolic-ref --short HEAD 2>/dev/null)
  [[ -z "${branch}" ]] && return 0
  if [[ -n "$(git -C "${cwd}" --no-optional-locks status --porcelain \
      2>/dev/null)" ]]; then
    dirty='*'
  fi
  printf '%s' "${GREEN}${branch}${RED}${dirty}${RESET}"
}

#######################################
# Print the command line of the parent Claude Code process.
# Globals:
#   PPID
#######################################
parent_command() {
  ps -o args= -p "${PPID}" 2>/dev/null
  return 0
}

#######################################
# Print a marker when Claude Code was started with
# --dangerously-skip-permissions.
# Arguments:
#   Command line of the parent Claude Code process.
#######################################
skip_permissions_marker() {
  [[ "$1" == *--dangerously-skip-permissions* ]] && printf '⚡  '
  return 0
}

#######################################
# Print the state recorded by the last ultracode marker in a session
# transcript. At the start of each typed prompt Claude Code compares its
# ultracode flag with the last marker and, when they differ, appends an
# attachment record of type ultra_effort_enter or ultra_effort_exit. The
# records are matched as fixed strings together with their surrounding
# JSON punctuation, so copies quoted inside messages (where the quotes
# are escaped) do not count.
# Arguments:
#   Path to the transcript (may be empty or missing).
# Outputs:
#   "enter", "exit", or nothing when the transcript has no marker.
#######################################
transcript_ultracode_marker() {
  local transcript=$1
  local marker

  [[ -n "${transcript}" && -f "${transcript}" ]] || return 0
  marker=$(grep -a -o -F \
    -e '"attachment":{"type":"ultra_effort_enter"' \
    -e '"attachment":{"type":"ultra_effort_exit"' \
    "${transcript}" 2>/dev/null | tail -n 1)
  case "${marker}" in
    *enter*) printf 'enter' ;;
    *exit*) printf 'exit' ;;
  esac
  return 0
}

#######################################
# Test whether ultracode is on. Claude Code reports ultracode to the
# status line as plain "xhigh" effort, so the answer comes from the
# routes that leave a trace. The transcript marker is authoritative when
# present, because it reflects the live flag as of the last typed prompt
# and also records a toggle back off. Before the first marker exists the
# launch flag and the ultracode key in a settings file (local, then
# project, then user; the first file that sets the key wins) count.
# Globals:
#   SETTINGS_FILE
# Arguments:
#   Command line of the parent Claude Code process.
#   Project directory.
#   Path to the session transcript.
# Returns:
#   0 if ultracode is on, 1 otherwise.
#######################################
ultracode_on() {
  local parent_cmd=$1
  local project_dir=$2
  local transcript=$3
  local file files=() value

  case "$(transcript_ultracode_marker "${transcript}")" in
    enter) return 0 ;;
    exit) return 1 ;;
  esac
  case "${parent_cmd}" in
    *'--effort ultracode'*|*'--effort=ultracode'*) return 0 ;;
  esac
  for file in "${project_dir}/.claude/settings.local.json" \
      "${project_dir}/.claude/settings.json" "${SETTINGS_FILE}"; do
    [[ -f "${file}" ]] && files+=("${file}")
  done
  (( ${#files[@]} > 0 )) || return 1
  value=$(jq -s 'map(select(type == "object" and has("ultracode"))
      | .ultracode) | .[0] // false' "${files[@]}" 2>/dev/null)
  [[ "${value}" == 'true' ]]
}

#######################################
# Print the session duration as "<1m", "12m" or "1h5m".
# Arguments:
#   Wall-clock session time in milliseconds, from cost.total_duration_ms
#   (may be empty or "null").
# Outputs:
#   The duration, or nothing if the value is missing or not a number.
#######################################
session_duration() {
  local duration_ms=$1
  local elapsed

  case "${duration_ms}" in
    ''|*[!0-9]*) return 0 ;;
  esac
  elapsed=$(( duration_ms / 1000 ))
  if (( elapsed >= 3600 )); then
    printf '%dh%dm' "$(( elapsed / 3600 ))" "$(( elapsed % 3600 / 60 ))"
  elif (( elapsed >= 60 )); then
    printf '%dm' "$(( elapsed / 60 ))"
  else
    printf '<1m'
  fi
}

#######################################
# Render the prompt cache segment: "♨ HH:MM" while the cache is warm (the
# time it goes cold), "❄" once it is cold.
# Arguments:
#   Warm flag: "true", "false", or anything else when unknown.
#   Expiry as epoch seconds (may be empty or "null").
# Outputs:
#   The segment, or nothing when the payload has no cache statistics.
#######################################
cache_segment() {
  local warm=$1
  local expires_at=$2
  local expires_text

  case "${warm}" in
    true)
      printf '%s' "${GREEN}♨${RESET}"
      expires_text=$(format_epoch_time "${expires_at}" time)
      [[ -n "${expires_text}" ]] \
        && printf ' %s' "${WHITE}${expires_text}${RESET}"
      ;;
    false) printf '%s' "${CYAN}❄${RESET}" ;;
  esac
  return 0
}

#######################################
# Render a rate-limit segment: "<label> <bar> <pct>%[ ⟳ <reset>]".
# Arguments:
#   Label, e.g. "5h" or "7d Fable".
#   Used percentage (integer).
#   Formatted reset time, or empty to omit it.
#######################################
limit_segment() {
  local label=$1
  local pct=$2
  local reset_text=$3
  local bar color out

  bar=$(build_bar "${pct}" "${BAR_WIDTH}")
  color=$(color_for_pct "${pct}")
  out="${WHITE}${label}${RESET} ${bar} ${color}${pct}%${RESET}"
  if [[ -n "${reset_text}" ]]; then
    out+=" ${DIM}⟳${RESET} ${WHITE}${reset_text}${RESET}"
  fi
  printf '%s' "${out}"
}

#######################################
# Render the extra-usage segment: "extra <bar> $used/$limit ⟳ <reset>".
# Globals:
#   FIELD_SEP, BAR_WIDTH
# Arguments:
#   Usage API JSON.
#######################################
extra_usage_segment() {
  local usage_data=$1
  local pct_raw used_raw limit_raw pct used limit bar color reset_text out

  IFS="${FIELD_SEP}" read -r pct_raw used_raw limit_raw < <(
    jq -r --arg sep "${FIELD_SEP}" '[
      (.extra_usage.utilization // 0),
      (.extra_usage.used_credits // 0),
      (.extra_usage.monthly_limit // 0)
    ] | map(tostring) | join($sep)' <<< "${usage_data}" 2>/dev/null
  )
  printf -v pct '%.0f' "${pct_raw}" 2>/dev/null
  # Credits are reported in cents.
  used=$(awk -v n="${used_raw:-0}" 'BEGIN { printf "%.2f", n / 100 }')
  limit=$(awk -v n="${limit_raw:-0}" 'BEGIN { printf "%.2f", n / 100 }')
  bar=$(build_bar "${pct}" "${BAR_WIDTH}")
  color=$(color_for_pct "${pct}")

  # Extra usage resets on the first of next month; BSD date first.
  reset_text=$(date -v+1m -v1d +'%b %-d' 2>/dev/null \
    | tr '[:upper:]' '[:lower:]')
  if [[ -z "${reset_text}" ]]; then
    reset_text=$(date -d "$(date +%Y-%m-01) +1 month" +'%b %-d' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]')
  fi

  out="${WHITE}extra${RESET} ${bar}"
  out+=" ${color}\$${used}${DIM}/${RESET}${WHITE}\$${limit}${RESET}"
  out+=" ${DIM}⟳${RESET} ${WHITE}${reset_text}${RESET}"
  printf '%s' "${out}"
}

#######################################
# Build the status line from the Claude Code stdin JSON.
# Globals:
#   Colour constants, SEP, FIELD_SEP, DEFAULT_CONTEXT_SIZE
# Arguments:
#   Stdin JSON from Claude Code.
#   Current epoch seconds.
#######################################
render_line() {
  local input=$1
  local now=$2
  local model_name context_size input_tokens cache_create cache_read cwd \
    project_dir transcript_path duration_ms effort five_hour_used \
    five_hour_resets seven_day_used seven_day_resets cache_warm \
    cache_expires exceeds_200k fast_mode parent_cmd
  local current_tokens context_pct=0 pct_color line git_seg duration \
    cache_seg
  local has_stdin_rates=false five_hour_pct='' five_hour_reset_epoch='' \
    seven_day_pct='' seven_day_reset_epoch='' seven_day_reset_text='' \
    reset_text reset_epoch
  local usage_data extra_enabled=false scoped_limits='' api_five_hour_used \
    api_five_hour_resets api_seven_day_used api_seven_day_resets
  local name pct_raw pct reset_iso

  # Extract every stdin field with one jq call.
  IFS="${FIELD_SEP}" read -r model_name context_size input_tokens \
    cache_create cache_read cwd project_dir transcript_path duration_ms \
    effort five_hour_used five_hour_resets seven_day_used \
    seven_day_resets cache_warm cache_expires exceeds_200k fast_mode < <(
    jq -r --arg sep "${FIELD_SEP}" '[
      (.model.display_name // "Claude"),
      (.context_window.context_window_size // 0),
      (.context_window.current_usage.input_tokens // 0),
      (.context_window.current_usage.cache_creation_input_tokens // 0),
      (.context_window.current_usage.cache_read_input_tokens // 0),
      (.cwd // ""),
      (.workspace.project_dir // ""),
      (.transcript_path // ""),
      (.cost.total_duration_ms // ""
        | if type == "number" then floor else . end),
      (.effort.level // ""),
      (.rate_limits.five_hour.used_percentage // ""),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage // ""),
      (.rate_limits.seven_day.resets_at // ""),
      (.prompt_cache.warm | tostring),
      (.prompt_cache.expires_at // ""),
      (.exceeds_200k_tokens | tostring),
      (.fast_mode | tostring)
    ] | map(tostring) | join($sep)' <<< "${input}" 2>/dev/null
  )

  model_name="${model_name:-Claude}"
  input_tokens="${input_tokens:-0}"
  cache_create="${cache_create:-0}"
  cache_read="${cache_read:-0}"
  if [[ -z "${context_size}" || "${context_size}" == '0' ]]; then
    context_size="${DEFAULT_CONTEXT_SIZE}"
  fi
  current_tokens=$(( input_tokens + cache_create + cache_read ))
  if (( context_size > 0 )); then
    context_pct=$(( current_tokens * 100 / context_size ))
  fi
  has_value "${cwd}" || cwd="${PWD}"
  has_value "${project_dir}" || project_dir="${cwd}"
  parent_cmd=$(parent_command)
  effort=$(resolve_effort "${effort}")
  if [[ "${effort}" == 'xhigh' ]] \
      && ultracode_on "${parent_cmd}" "${project_dir}" \
        "${transcript_path}"; then
    effort='ultracode'
  fi

  # Model[ »] │ context %[↑] │ [⚡ ]branch │ ⏱ session │ effort │ cache
  pct_color=$(color_for_pct "${context_pct}")
  line="${BLUE}${model_name}${RESET}"
  [[ "${fast_mode}" == 'true' ]] && line+=" ${ORANGE}»${RESET}"
  line+="${SEP}✍️ ${pct_color}${context_pct}%${RESET}"
  [[ "${exceeds_200k}" == 'true' ]] && line+="${RED}↑${RESET}"
  git_seg=$(git_segment "${cwd}")
  if [[ -n "${git_seg}" ]]; then
    line+="${SEP}$(skip_permissions_marker "${parent_cmd}")${git_seg}"
  fi
  duration=$(session_duration "${duration_ms}")
  if [[ -n "${duration}" ]]; then
    line+="${SEP}${DIM}⏱ ${RESET}${WHITE}${duration}${RESET}"
  fi
  line+="${SEP}$(effort_segment "${effort}" "${now}")"
  cache_seg=$(cache_segment "${cache_warm}" "${cache_expires}")
  if [[ -n "${cache_seg}" ]]; then
    line+="${SEP}${cache_seg}"
  fi

  # Rate limits: stdin is primary because it is fresher. The usage API is
  # still fetched, because per-model weekly limits and extra usage only
  # exist there.
  if has_value "${five_hour_used}"; then
    has_stdin_rates=true
    printf -v five_hour_pct '%.0f' "${five_hour_used}" 2>/dev/null
    five_hour_reset_epoch="${five_hour_resets}"
    if has_value "${seven_day_used}"; then
      printf -v seven_day_pct '%.0f' "${seven_day_used}" 2>/dev/null
    fi
    seven_day_reset_epoch="${seven_day_resets}"
  fi

  usage_data=$(get_usage_data "${now}")
  if [[ -n "${usage_data}" ]]; then
    IFS="${FIELD_SEP}" read -r api_five_hour_used api_five_hour_resets \
      api_seven_day_used api_seven_day_resets extra_enabled < <(
      jq -r --arg sep "${FIELD_SEP}" '[
        (.five_hour.utilization // ""),
        (.five_hour.resets_at // ""),
        (.seven_day.utilization // ""),
        (.seven_day.resets_at // ""),
        (.extra_usage.is_enabled // false)
      ] | map(tostring) | join($sep)' <<< "${usage_data}" 2>/dev/null
    )
    # Use the API's 5h/7d totals only when stdin did not provide them.
    if [[ "${has_stdin_rates}" == false \
        && -n "${api_five_hour_used}" ]]; then
      printf -v five_hour_pct '%.0f' "${api_five_hour_used}" 2>/dev/null
      five_hour_reset_epoch=$(iso_to_epoch "${api_five_hour_resets}")
      # Absent rather than zero: a response without a weekly total should
      # print no 7d segment, not a full-looking one reading 0%.
      if [[ -n "${api_seven_day_used}" ]]; then
        printf -v seven_day_pct '%.0f' "${api_seven_day_used}" 2>/dev/null
        seven_day_reset_epoch=$(iso_to_epoch "${api_seven_day_resets}")
      fi
    fi

    # Per-model weekly limits. Prefer limits[] entries of kind weekly_scoped
    # with a model scope (what /usage shows as "Current week (Fable)"), and
    # fall back to the older seven_day_opus/seven_day_sonnet fields.
    # Output: one line per model, "name <sep> percent <sep> resets_at".
    scoped_limits=$(jq -r --arg sep "${FIELD_SEP}" '
      def scoped: [
        (.limits // [])[]
        | select(.kind == "weekly_scoped"
                 and ((.scope.model.display_name? // "") != ""))
        | {name: .scope.model.display_name, pct: .percent, reset: .resets_at}
      ];
      def legacy: [
        (.seven_day_opus | select(. != null)
          | {name: "Opus", pct: .utilization, reset: .resets_at}),
        (.seven_day_sonnet | select(. != null)
          | {name: "Sonnet", pct: .utilization, reset: .resets_at})
      ];
      (if (scoped | length) > 0 then scoped else legacy end)[]
      | [.name, (.pct // 0), (.reset // "")] | map(tostring) | join($sep)
    ' <<< "${usage_data}" 2>/dev/null)
  fi

  if [[ -n "${five_hour_pct}" ]]; then
    reset_text=$(format_epoch_time "${five_hour_reset_epoch}" time)
    line+="${SEP}$(limit_segment '5h' "${five_hour_pct}" "${reset_text}")"
  fi
  if [[ -n "${seven_day_pct}" ]]; then
    seven_day_reset_text=$(format_epoch_time "${seven_day_reset_epoch}" \
      datetime)
    line+="${SEP}$(limit_segment '7d' "${seven_day_pct}" \
      "${seven_day_reset_text}")"
  fi

  # Per-model 7d segments, e.g. "7d Fable ◉◉◉◉◕ 96%". The reset time
  # is shown only when it differs from the 7d total, to save width.
  if [[ -n "${scoped_limits}" ]]; then
    while IFS="${FIELD_SEP}" read -r name pct_raw reset_iso; do
      [[ -z "${name}" ]] && continue
      printf -v pct '%.0f' "${pct_raw}" 2>/dev/null || pct=0
      reset_text=''
      if reset_epoch=$(iso_to_epoch "${reset_iso}"); then
        reset_text=$(format_epoch_time "${reset_epoch}" datetime)
        [[ "${reset_text}" == "${seven_day_reset_text}" ]] && reset_text=''
      fi
      line+="${SEP}$(limit_segment "7d ${name}" "${pct}" "${reset_text}")"
    done <<< "${scoped_limits}"
  fi

  if [[ "${extra_enabled}" == true && -n "${usage_data}" ]]; then
    line+="${SEP}$(extra_usage_segment "${usage_data}")"
  fi

  printf '%s' "${line}"
}

#######################################
# Print a fingerprint of the stdin fields that change the rendered line:
# model, effort, context usage, working directory, cache warmth, the 200k
# flag and fast mode. Volatile fields such as cost.total_duration_ms are
# left out, so the once-a-second refreshes keep hitting the cache (the
# duration is shown at minute resolution, which the cache TTL matches).
# Plain string operations keep this fork-free.
# Arguments:
#   Stdin JSON from Claude Code.
#######################################
input_fingerprint() {
  local input=$1
  local key rest out=''

  # Flat objects: everything up to their closing brace.
  for key in model effort current_usage; do
    rest="${input#*\""${key}"\":\{}"
    [[ "${rest}" == "${input}" ]] && continue
    out+="${rest%%\}*};"
  done
  # Flat scalars: everything up to the next comma or closing brace.
  for key in warm exceeds_200k_tokens fast_mode; do
    rest="${input#*\""${key}"\":}"
    [[ "${rest}" == "${input}" ]] && continue
    out+="${rest%%[,\}]*};"
  done
  rest="${input#*\"cwd\":\"}"
  [[ "${rest}" != "${input}" ]] && out+="${rest%%\"*}"
  printf '%s' "${out}"
}

#######################################
# Entry point: read stdin, serve the cached line while it is fresh and
# was rendered from the same inputs, otherwise render, cache and print a
# new one. The cache file holds the input fingerprint on the first line
# and the rendered line on the second.
# Globals:
#   CACHE_DIR, OUTPUT_CACHE_TTL
#######################################
main() {
  local input session_id output_cache key now cache_mtime cached_key line

  input=$(cat)
  if [[ -z "${input}" ]]; then
    printf 'Claude'
    return 0
  fi
  [[ -d "${CACHE_DIR}" ]] || mkdir -p "${CACHE_DIR}"

  # Pull the session id out with plain string operations (no forks).
  session_id="${input#*\"session_id\":\"}"
  if [[ "${session_id}" == "${input}" ]]; then
    session_id='default'
  else
    session_id="${session_id%%\"*}"
  fi
  output_cache="${CACHE_DIR}/statusline-out-${session_id}.cache"
  key=$(input_fingerprint "${input}")

  # EPOCHSECONDS needs bash >= 5; older shells pay one fork for date.
  now="${EPOCHSECONDS:-$(date +%s)}"

  # Fast path: the cached line is still fresh and the model, effort,
  # context usage and directory have not changed, so print it and leave.
  if [[ -f "${output_cache}" ]]; then
    cache_mtime=$(file_mtime "${output_cache}")
    if [[ -n "${cache_mtime}" ]] \
        && (( now - cache_mtime < OUTPUT_CACHE_TTL )); then
      { IFS= read -r cached_key; IFS= read -r line; } < "${output_cache}"
      if [[ "${cached_key}" == "${key}" && -n "${line}" ]]; then
        printf '%s' "${line}"
        return 0
      fi
    fi
  fi

  line=$(render_line "${input}" "${now}")
  printf '%s\n%s\n' "${key}" "${line}" > "${output_cache}"
  printf '%s' "${line}"
}

main "$@"
