# shellcheck shell=bash
# ~/.bashrc: interactive bash configuration for linux and macos.
#
# Requires bash >= 4.3. macOS ships 3.2 in /bin/bash, so install a current one
# with `brew install bash`. Terminals on macOS start login shells, which read
# ~/.bash_profile, so that file must source this one.

# Do nothing for non-interactive shells.
case $- in
  *i*) ;;
  *) return ;;
esac

# Functions are defined before the aliases at the bottom on purpose: aliases
# are expanded when a function body is parsed.

#######################################
# Print a message to stderr.
# Arguments:
#   Message text
#######################################
err() {
  echo "-> $*" >&2
}

#######################################
# Prepend a directory to PATH if it exists and is not already in PATH.
# Globals:
#   PATH
# Arguments:
#   Directory, with or without trailing slash
#######################################
path_prepend() {
  local dir="${1%/}"
  [[ -d "${dir}" ]] || return 0
  [[ ":${PATH}:" == *":${dir}:"* ]] && return 0
  PATH="${dir}:${PATH}"
}

#######################################
# Load Homebrew's environment on macOS. Apple silicon installs to
# /opt/homebrew, intel to /usr/local. No-op if already loaded.
# Globals:
#   HOMEBREW_PREFIX, PATH, MANPATH, INFOPATH
#######################################
setup_homebrew() {
  local brew
  [[ -n "${HOMEBREW_PREFIX}" ]] && return 0
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "${brew}" ]]; then
      eval "$("${brew}" shellenv)"
      return 0
    fi
  done
  err "homebrew not found, see https://brew.sh"
}

#######################################
# Check whether an ssh-agent answers on SSH_AUTH_SOCK. ssh-add -l exits 0
# (keys loaded), 1 (no keys) or 2 (no agent).
# Globals:
#   SSH_AUTH_SOCK
# Returns:
#   0 if an agent answers, 1 otherwise
#######################################
ssh_agent_alive() {
  ssh-add -l &> /dev/null
  (( $? != 2 ))
}

#######################################
# Make sure an ssh-agent is reachable through SSH_AUTH_SOCK. An agent that
# already answers (launchd on macOS, systemd or gnome-keyring on linux) is
# kept. Otherwise a private agent on a fixed socket is reused or started, so
# that every shell shares one agent.
# Globals:
#   SSH_AUTH_SOCK, SSH_AGENT_PID
#######################################
setup_ssh_agent() {
  local sock="${HOME}/.ssh/ssh-agent.sock"

  [[ -n "${SSH_AUTH_SOCK}" ]] && ssh_agent_alive && return 0

  if [[ -S "${sock}" ]]; then
    export SSH_AUTH_SOCK="${sock}"
    ssh_agent_alive && return 0
    rm -f "${sock}"  # stale socket from a dead agent
  fi

  [[ -d "${HOME}/.ssh" ]] || mkdir -m 0700 "${HOME}/.ssh"
  eval "$(ssh-agent -s -a "${sock}")" > /dev/null
}

#######################################
# Add a private key to the agent unless it already holds keys.
# Arguments:
#   Path to private key
#######################################
add_ssh_key() {
  local key="$1"
  [[ -f "${key}" ]] || return 0
  ssh-add -l &> /dev/null && return 0
  ssh-add "${key}"
}

#######################################
# Point gpg-agent and git at the right binaries. gpg-agent on linux finds
# /usr/bin/pinentry by itself; on macOS it needs pinentry-mac from Homebrew.
# Files are only written when the current value differs.
# Globals:
#   HOMEBREW_PREFIX, OSTYPE
#######################################
setup_gpg() {
  local gpg_bin pinentry
  local conf="${HOME}/.gnupg/gpg-agent.conf"

  gpg_bin=$(command -v gpg) || return 0

  if [[ "${OSTYPE}" == darwin* ]]; then
    pinentry="${HOMEBREW_PREFIX}/bin/pinentry-mac"
    if [[ ! -x "${pinentry}" ]]; then
      err "missing ${pinentry}, brew install pinentry-mac ?"
    elif ! grep -qsx "pinentry-program ${pinentry}" "${conf}"; then
      [[ -d "${HOME}/.gnupg" ]] || mkdir -m 0700 "${HOME}/.gnupg"
      # Replace any old pinentry-program line, e.g. from an intel install.
      { grep -vs '^pinentry-program ' "${conf}"
        echo "pinentry-program ${pinentry}"; } > "${conf}.tmp" \
        && mv "${conf}.tmp" "${conf}"
      gpgconf --reload gpg-agent 2> /dev/null
    fi
  fi

  if command -v git &> /dev/null \
      && [[ "$(git config --global --get gpg.program)" != "${gpg_bin}" ]]; then
    git config --global gpg.program "${gpg_bin}"
  fi
}

#######################################
# man with colored headings, bold and underlined text.
# Arguments:
#   Passed through to man
#######################################
man() {
  LESS_TERMCAP_mb=$'\e[1;31m' \
  LESS_TERMCAP_md=$'\e[1;31m' \
  LESS_TERMCAP_me=$'\e[0m' \
  LESS_TERMCAP_se=$'\e[0m' \
  LESS_TERMCAP_so=$'\e[1;44;33m' \
  LESS_TERMCAP_ue=$'\e[0m' \
  LESS_TERMCAP_us=$'\e[1;32m' \
  command man "$@"
}

#######################################
# Decode and pretty-print the header and payload of a JWT.
# Arguments:
#   Token; read from stdin when omitted
# Outputs:
#   Header and payload as JSON on stdout
# Returns:
#   0 on success, 1 on decode error, 2 on usage error
#######################################
jwt_decode() {
  local token="${1:-}"
  local part json
  local -r pad='==='

  [[ -z "${token}" && ! -t 0 ]] && read -r token
  if [[ "${token}" != *.*.* ]]; then
    err "usage: jwt_decode <header.payload.signature>"
    return 2
  fi

  local header="${token%%.*}"
  local rest="${token#*.}"
  for part in "${header}" "${rest%%.*}"; do
    # JWT uses unpadded base64url, base64(1) wants padded standard base64.
    part="${part//-/+}"
    part="${part//_//}"
    part+="${pad:0:$(( (4 - ${#part} % 4) % 4 ))}"
    if ! json=$(base64 -d <<< "${part}" 2> /dev/null); then
      err "not a valid jwt: cannot decode '${part:0:12}...'"
      return 1
    fi
    jq . <<< "${json}" || return 1
  done
}

# System-wide settings. Fedora/RHEL and macOS ship /etc/bashrc; Debian's
# /etc/bash.bashrc is sourced by bash itself.
[[ -r /etc/bashrc ]] && source /etc/bashrc

# Platform specifics. Homebrew first, everything below may need its binaries.
if [[ "${OSTYPE}" == darwin* ]]; then
  setup_homebrew
  if [[ -r "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh" ]]; then
    source "${HOMEBREW_PREFIX}/etc/profile.d/bash_completion.sh"
  fi
  export ANDROID_HOME="${HOME}/Library/Android/sdk"
else
  if [[ -r /usr/share/bash-completion/bash_completion ]]; then
    source /usr/share/bash-completion/bash_completion
  fi
  export ANDROID_HOME="${HOME}/android"
  # Android Studio 2023+ bundles its JDK in jbr/, older releases in jre/.
  path_prepend /usr/share/android-studio/jbr/bin
  path_prepend /usr/share/android-studio/jre/bin
fi
export ANDROID_SDK_ROOT="${ANDROID_HOME}"  # deprecated name, still read by some tools

path_prepend "${ANDROID_HOME}/platform-tools"
path_prepend "${HOME}/go/bin"  # GOPATH defaults to ~/go since go 1.8
path_prepend /opt/nanobrew/prefix/bin
export PATH

export EDITOR='vim'
export BASH_MAX_OUTPUT_LENGTH=15000  # claude code: truncate tool output above this

# Unlimited history, shared between shells. bash < 4.3 treats -1 as 0.
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3) )); then
  HISTSIZE=-1
  HISTFILESIZE=-1
else
  HISTSIZE=100000
  HISTFILESIZE=100000
fi
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT='%F %T '
shopt -s histappend

# Readline and tty settings, only when stdin is a terminal.
if [[ -t 0 ]]; then
  bind 'set completion-ignore-case on'
  bind 'set bell-style none'
  bind 'set show-all-if-ambiguous on'
  bind 'set visible-stats on'
  complete -d cd rmdir
  stty -echoctl  # no ^C echo on ctrl-c; gnu also calls it ctlecho, bsd only echoctl
  GPG_TTY=$(tty)
  export GPG_TTY
fi

# Terminal integration and prompt. Order matters: vte.sh overwrites
# PROMPT_COMMAND and pureline wraps whatever is in it, so the history hook is
# appended last. Fedora already sources vte.sh from /etc/bashrc, Debian/Ubuntu
# (vte-2.91.sh) only do it for login shells.
if [[ -n "${VTE_VERSION}" || -n "${TILIX_ID}" ]]; then
  for vte_sh in /etc/profile.d/vte.sh /etc/profile.d/vte-2.91.sh; do
    if [[ -r "${vte_sh}" ]]; then
      source "${vte_sh}"
      break
    fi
  done
  unset vte_sh
fi

if [[ -r "${HOME}/dotfiles/pureline" ]]; then
  source "${HOME}/dotfiles/pureline" "${HOME}/dotfiles/.pureline.conf"
fi

# Write and re-read history at every prompt so shells share it.
if [[ "${PROMPT_COMMAND}" != *'history -a'* ]]; then
  PROMPT_COMMAND="${PROMPT_COMMAND:+${PROMPT_COMMAND}; }history -a; history -n"
fi

setup_ssh_agent
add_ssh_key "${HOME}/.ssh/id_ed25519"
setup_gpg

# Aliases. GNU ls takes --color, BSD ls (macOS) takes -G.
if ls --color=auto -d / &> /dev/null; then
  alias ll='ls -ahlF --color=auto'
else
  alias ll='ls -ahlFG'
fi
alias grep='grep --color=auto'
alias agrep='grep --color=auto --exclude-dir=.git -ri'
alias cs='claude-statusbar'
alias cstatus='claude-statusbar'
