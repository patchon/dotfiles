#!/bin/bash
#
# Sync shareable Claude Code settings between the live file
# (~/.claude/settings.json) and the copy kept in this repo
# (.claude/settings.json, next to this script's directory).
#
# Only the keys in SHARED_KEYS ever reach the repo. Everything else in the
# live file (permission approvals, the auto-mode environment, and so on) is
# machine state and stays local. On conflict the repo copy wins.
#
# Usage:
#   sync-claude-settings.sh export
#       Copy the shared keys from the live file into the repo.
#   sync-claude-settings.sh apply [--no-plugins]
#       Merge the repo copy into the live file, keeping local-only keys.
#       The previous live file is kept as settings.json.bak.
#   sync-claude-settings.sh diff [--no-plugins]
#       Show what apply would change.
#
# --no-plugins leaves out the keys in PLUGIN_KEYS: the plugin marketplaces,
# the plugins themselves, and the hooks, whose only entry runs a script
# shipped by the superpowers plugin. Use it on a machine where the extra
# skills are not wanted. It only skips those keys on the way in; it never
# removes plugins the live file already has.
#
# Needs bash 3.2+ and jq 1.6+. Honours CLAUDE_CONFIG_DIR.

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
readonly SHARED_FILE="${repo_dir}/settings.json"
readonly LIVE_FILE="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/settings.json"

# Keys that are preferences rather than machine state. The exported file
# keeps this order, so keep the list stable to keep diffs small.
SHARED_KEYS=(
  model
  effortLevel
  env
  tui
  editorMode
  verbose
  agentPushNotifEnabled
  autoUpdatesChannel
  skipAutoPermissionPrompt
  skipWorkflowUsageWarning
  statusLine
  hooks
  enabledPlugins
  extraKnownMarketplaces
)
readonly SHARED_KEYS

# Subset of SHARED_KEYS that --no-plugins leaves out.
PLUGIN_KEYS=(
  hooks
  enabledPlugins
  extraKnownMarketplaces
)
readonly PLUGIN_KEYS

#######################################
# Print an error message to stderr.
# Arguments:
#   Message text.
#######################################
err() {
  echo "$(basename "$0"): $*" >&2
}

#######################################
# Print usage and exit with status 2.
#######################################
usage() {
  err 'usage: sync-claude-settings.sh export' \
    '| apply [--no-plugins] | diff [--no-plugins]'
  exit 2
}

#######################################
# Print the shared subset of a settings file, keys in SHARED_KEYS order.
# Globals:
#   SHARED_KEYS
# Arguments:
#   Path to a settings file.
#######################################
shared_subset() {
  jq '
    $ARGS.positional as $keys
    | . as $all
    | [$keys[] | . as $k | select($all | has($k)) | {key: $k, value: $all[$k]}]
    | from_entries
  ' "$1" --args "${SHARED_KEYS[@]}"
}

#######################################
# Fail if JSON text contains anything that looks machine-specific: the
# home directory, the user name, or a home-directory prefix.
# Globals:
#   HOME, USER, LOGNAME
# Arguments:
#   JSON text.
# Returns:
#   0 if clean, 1 otherwise (offending lines go to stderr).
#######################################
check_private() {
  local user="${USER:-${LOGNAME:-}}"
  local hits

  hits=$(grep -nFw -e "${HOME}" -e "${user:-/}" -e /Users/ -e /home/ \
    <<< "$1")
  if [[ -n "${hits}" ]]; then
    err 'refusing to export, these lines look machine-specific:'
    printf '%s\n' "${hits}" >&2
    return 1
  fi
}

#######################################
# Print the repo copy, without PLUGIN_KEYS when asked.
# Globals:
#   SHARED_FILE, PLUGIN_KEYS
# Arguments:
#   "true" to leave out the plugin keys.
#######################################
shared_json() {
  if [[ "$1" == true ]]; then
    jq 'delpaths([$ARGS.positional[] | [.]])' "${SHARED_FILE}" \
      --args "${PLUGIN_KEYS[@]}"
  else
    jq . "${SHARED_FILE}"
  fi
}

#######################################
# Print the live settings merged with the repo copy (repo wins).
# Globals:
#   LIVE_FILE
# Arguments:
#   "true" to leave out the plugin keys.
#######################################
merged_json() {
  if [[ -f "${LIVE_FILE}" ]]; then
    jq -s '.[0] * .[1]' "${LIVE_FILE}" <(shared_json "$1")
  else
    shared_json "$1"
  fi
}

#######################################
# Print a settings file (or JSON text on stdin) in canonical form so two
# files can be compared regardless of key order and formatting.
# Arguments:
#   Path to a file, or "-" for stdin.
#######################################
canonical() {
  jq -S . "$1"
}

#######################################
# Export the shared keys from the live file into the repo.
# Globals:
#   LIVE_FILE, SHARED_FILE
#######################################
do_export() {
  local json

  if [[ ! -f "${LIVE_FILE}" ]]; then
    err "no live settings file at ${LIVE_FILE}"
    return 1
  fi
  json=$(shared_subset "${LIVE_FILE}") || return 1
  check_private "${json}" || return 1
  printf '%s\n' "${json}" > "${SHARED_FILE}" || return 1
  echo "wrote ${SHARED_FILE}"
}

#######################################
# Show what apply would change, as a unified diff of canonical JSON.
# Globals:
#   LIVE_FILE
# Arguments:
#   "true" to leave out the plugin keys.
# Returns:
#   diff's status: 0 if identical, 1 if different.
#######################################
do_diff() {
  local skip_plugins=$1
  local merged live

  merged=$(merged_json "${skip_plugins}") || return 1
  if [[ -f "${LIVE_FILE}" ]]; then
    live=$(canonical "${LIVE_FILE}") || return 1
  else
    live='{}'
  fi
  diff -u --label "${LIVE_FILE}" --label 'after apply' \
    <(printf '%s\n' "${live}") <(canonical - <<< "${merged}")
}

#######################################
# Merge the repo copy into the live file. Local-only keys are kept, the
# previous live file is saved as settings.json.bak, and nothing is written
# when the result would be identical.
# Globals:
#   LIVE_FILE, SHARED_FILE
# Arguments:
#   "true" to leave out the plugin keys.
#######################################
do_apply() {
  local skip_plugins=$1
  local merged tmp note=''

  if [[ ! -f "${SHARED_FILE}" ]]; then
    err "no shared settings file at ${SHARED_FILE}"
    return 1
  fi
  [[ "${skip_plugins}" == true ]] && note=' (plugin keys skipped)'
  merged=$(merged_json "${skip_plugins}") || return 1
  if [[ -f "${LIVE_FILE}" ]] \
      && [[ "$(canonical "${LIVE_FILE}")" == "$(canonical - <<< "${merged}")" ]]
  then
    echo "${LIVE_FILE} is already up to date${note}"
    return 0
  fi

  mkdir -p "$(dirname "${LIVE_FILE}")" || return 1
  tmp=$(mktemp "${LIVE_FILE}.XXXXXX") || return 1
  if ! printf '%s\n' "${merged}" > "${tmp}" || ! chmod 0644 "${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  if [[ -f "${LIVE_FILE}" ]] && ! cp -p "${LIVE_FILE}" "${LIVE_FILE}.bak"; then
    rm -f "${tmp}"
    return 1
  fi
  mv "${tmp}" "${LIVE_FILE}" || return 1
  echo "updated ${LIVE_FILE}${note} (previous copy in ${LIVE_FILE}.bak)"
}

main() {
  local mode='' skip_plugins=false arg

  if ! command -v jq >/dev/null 2>&1; then
    err 'jq is required'
    exit 1
  fi
  for arg in "$@"; do
    case "${arg}" in
      export|apply|diff)
        [[ -n "${mode}" ]] && usage
        mode="${arg}"
        ;;
      --no-plugins) skip_plugins=true ;;
      *) usage ;;
    esac
  done
  [[ -z "${mode}" ]] && usage
  if [[ "${mode}" == export && "${skip_plugins}" == true ]]; then
    err '--no-plugins only applies to apply and diff'
    exit 2
  fi

  case "${mode}" in
    export) do_export ;;
    apply) do_apply "${skip_plugins}" ;;
    diff) do_diff "${skip_plugins}" ;;
  esac
}

main "$@"
