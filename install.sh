#!/usr/bin/env bash
#
# Link the dotfiles in this repo into $HOME.
#
# Safe to run again at any time. A link that already points at the right
# file is left alone. Anything else in the way is moved aside as
# <name>.bak-<timestamp>, unless it is a plain file with exactly the repo's
# content, in which case it is simply replaced by the link.
#
# Links are relative (~/.bashrc -> dotfiles/.bashrc), so they keep working
# if the home directory moves.
#
# Usage:
#   ./install.sh            create the links
#   ./install.sh --dry-run  print what would be done, change nothing
#
# Runs on bash 3.2, since it has to work before Homebrew's bash is installed.

set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dry_run=false

# Paths relative to both the repo and $HOME.
LINKS=(
  .bashrc
  .bash_profile
  .gitconfig
  .vimrc
  .vim
  .config/ghostty/config
  .config/starship.toml
  .config/zed/settings.json
  .config/zed/keymap.json
  .claude/scripts/statusline.sh
)

#######################################
# Print a message to stderr.
# Arguments:
#   Message text
#######################################
err() {
  echo "install: $*" >&2
}

#######################################
# Run a command, or only print it in dry-run mode.
# Globals:
#   dry_run
# Arguments:
#   Command and its arguments
#######################################
run() {
  if [[ "${dry_run}" == true ]]; then
    echo "  would run: $*"
  else
    "$@"
  fi
}

#######################################
# Print the relative path from one directory to a file, both absolute.
# Arguments:
#   Directory the path is relative to
#   Target path
#######################################
relative_path() {
  local from=$1
  local to=$2
  local up=''

  while [[ "${to}" != "${from}"/* && "${from}" != / ]]; do
    from=${from%/*}
    [[ -z "${from}" ]] && from=/
    up+='../'
  done
  if [[ "${from}" == / ]]; then
    echo "${to}"
  else
    echo "${up}${to#"${from}"/}"
  fi
}

#######################################
# Move a file or link out of the way with a timestamped suffix.
# Arguments:
#   Path to move
#######################################
move_aside() {
  local path=$1
  local backup
  backup="${path}.bak-$(date +%Y%m%d%H%M%S)"

  echo "backup   ${path} -> ${backup}"
  run mv "${path}" "${backup}"
}

#######################################
# Link one repo path into $HOME.
# Globals:
#   repo, HOME
# Arguments:
#   Path relative to the repo root
#######################################
link() {
  local rel=$1
  local src="${repo}/${rel}"
  local dst="${HOME}/${rel}"
  local dst_dir="${dst%/*}"
  local target

  if [[ ! -e "${src}" ]]; then
    err "missing in repo, skipped: ${rel}"
    return 0
  fi
  target=$(relative_path "${dst_dir}" "${src}")

  if [[ -L "${dst}" ]]; then
    if [[ "$(readlink "${dst}")" == "${target}" ]]; then
      echo "ok       ${dst}"
      return 0
    fi
    move_aside "${dst}"
  elif [[ -f "${dst}" ]] && cmp -s "${dst}" "${src}"; then
    echo "replace  ${dst} (identical copy)"
    run rm -f "${dst}"
  elif [[ -e "${dst}" ]]; then
    move_aside "${dst}"
  fi

  run mkdir -p "${dst_dir}"
  echo "link     ${dst} -> ${target}"
  run ln -s "${target}" "${dst}"
}

#######################################
# Ghostty on macOS also reads a config under Application Support, and that
# one overrides the XDG file this repo links. Move it aside so there is a
# single source of truth.
# Globals:
#   HOME, OSTYPE
#######################################
retire_ghostty_app_support_config() {
  local conf="${HOME}/Library/Application Support/com.mitchellh.ghostty/config"

  [[ "${OSTYPE}" == darwin* ]] || return 0
  [[ -f "${conf}" && ! -L "${conf}" ]] || return 0
  echo "Ghostty also reads ${conf}; moving it aside so only the linked config counts."
  move_aside "${conf}"
}

main() {
  local arg rel

  for arg in "$@"; do
    case "${arg}" in
      --dry-run) dry_run=true ;;
      *)
        err "usage: install.sh [--dry-run]"
        exit 2
        ;;
    esac
  done

  if [[ "${repo}" != "${HOME}/dotfiles" ]]; then
    err "warning: .bashrc expects this repo at ~/dotfiles, it is at ${repo}"
  fi

  for rel in "${LINKS[@]}"; do
    link "${rel}"
  done
  retire_ghostty_app_support_config

  cat <<'EOF'

Done. Per-machine steps that are not automated:
  bash 4.3+        macOS ships 3.2: brew install bash; chsh -s /opt/homebrew/bin/bash
  fonts            a Nerd Font, e.g. MesloLGS Nerd Font, for the prompt glyphs
  gpg (macOS)      brew install gnupg pinentry-mac
  Claude Code      brew install jq; .claude/scripts/sync-claude-settings.sh apply
  git, per host    machine-specific settings go in ~/.gitconfig.local
EOF
}

main "$@"
