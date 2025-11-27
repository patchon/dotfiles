# If not running interactively, don't do anything
case $- in
  *i*) ;;
  *) return;;
esac

# Source system wide bash related things
[[ -f /etc/bashrc ]]          && source /etc/bashrc
[[ -f /etc/bash_completion ]] && source /etc/bash_completion

# Android
export ANDROID_SDK_ROOT=${HOME}/android/
export ANDROID_HOME=${ANDROID_SDK_ROOT}
export PATH="${ANDROID_SDK_ROOT}/platform-tools/:${PATH}"
export PATH="/usr/share/android-studio/jre/bin/:${PATH}"
export PATH="${HOME}/.gradle/wrapper/dists/gradle-5.4.1-all/3221gyojl5jsh0helicew7rwx/gradle-5.4.1/bin/:${PATH}"

# Set envs
export EDITOR='vim'
export GOPATH=${HOME}/go

# History
export HISTFILESIZE=-1
export HISTSIZE=-1
export HISTCONTROL=ignoreboth:erasedups
export HISTTIMEFORMAT="%F %T "
shopt -s histappend
PROMPT_COMMAND='history -a; history -n; '"$PROMPT_COMMAND"

# Aliases
alias ll='ls -ahlF --color=auto'
alias agrep="/usr/bin/grep --color=auto --exclude-dir=.git -ri ${1}"
alias grep="/usr/bin/grep --color=auto"

# Bash completion.
if [[ -t 0 ]]; then   # only run if stdin is a terminal
  bind "set completion-ignore-case on"
  bind "set bell-style none"
  bind "set show-all-if-ambiguous on"
  bind "set visible-stats on"
  complete -d cd rmdir
  stty -ctlecho
fi

# Source vte profile if present
if [[ -n "${TILIX_ID}" ]] || [[ -n "${VTE_VERSION}" ]]; then
  file_vte="/etc/profile.d/vte.sh"

  if [[ -f "${file_vte}" ]]; then
    source "${file_vte}"
  else
    echo "-> missing ${file_vte}, sudo dnf install vte-profile ?"
  fi
fi

# Source pureline,
if [[ -f ~/dotfiles/pureline ]]; then
  source ~/dotfiles/pureline ~/dotfiles/.pureline.conf
fi


# Colors in manual pages
man() {
  env                                       \
    LESS_TERMCAP_mb=$(printf "\e[1;31m")    \
    LESS_TERMCAP_md=$(printf "\e[1;31m")    \
    LESS_TERMCAP_me=$(printf "\e[0m")       \
    LESS_TERMCAP_se=$(printf "\e[0m")       \
    LESS_TERMCAP_so=$(printf "\e[1;44;33m") \
    LESS_TERMCAP_ue=$(printf "\e[0m")       \
    LESS_TERMCAP_us=$(printf "\e[1;32m")    \
    man "$@"
}

# Hande to decode jwt tokens
function jwt-decode() {
  sed 's/\./\n/g' <<< $(cut -d. -f1,2 <<< "${1}") | base64 --decode | jq
}

# Set pinentry/gpg depending on platform
if [[ $(uname -s) == Darwin* ]];then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  pinentry=$(echo $(brew --prefix)/bin/pinentry-mac)
  gpg=$(echo $(brew --prefix)/bin/gpg)
else
  pinentry=$(which pinentry)
  gpg=$(which gpg)
fi

# Make sure we have cache/gnupg directories
for dir in .cache .gnupg; do
  if ! [[ -d ${HOME}/${dir} ]]; then
    mkdir -v ${HOME}/${dir}

    if [[ "${dir}" == ".gnupg" ]]; then
      if ! perms=$(stat -c '%a' ${dir} 2>&1); then
        echo "-> failed to stat ${dir} : ${perms}"
      else
        if [[ "${perms}" != "700" ]]; then
          chmod -v 700 "${dir}"
        fi
      fi
    fi
  fi
done

# Make sure we have gnupg related files and settings
for file in "${HOME}/.gnupg/gpg.conf" "${HOME}/.gnupg/gpg-agent.conf"; do
  if ! [[ -f "${file}" ]]; then
    echo "-> creating ${file}"
    touch "${file}"
  fi

  # Setup pinentry
  if [[ "${file##*/}" == "gpg-agent.conf" ]]; then
    str_pin="pinentry-program"
    if ! grep "${str_pin}" -q "${file}"; then
      echo "-> ${str_pin} not set in ${file}, will set"
      echo "${str_pin} ${pinentry}" >> "${file}"
    fi
  fi

  # Setup agent
  if [[ "${file##*/}" == "gpg.conf" ]]; then
    str_agent="use-agent"
    if ! grep "${str_agent}" -q "${file}"; then
      echo "${str_agent}" >> "${file}"
    fi
  fi
done

# Handle different gpg programs depending on what platform we are on
if ! grep "program = ${gpg}" -q ${HOME}/.gitconfig; then
  sed -i "s|\(program =\) .*|\1 ${gpg}|" ${HOME}/.gitconfig
fi

# Check for ssh-agent
if pid=$(pgrep ssh-agent 2> /dev/null); then
  # If its running, just set environment
  export SSH_AGENT_PID=${pid}
  export SSH_AUTH_SOCK=~/.ssh/ssh-agent.sock
else
  # If not, remove old socket
  rm -fv ~/.ssh/ssh-agent.sock
  eval "$(ssh-agent -s -a ~/.ssh/ssh-agent.sock)" > /dev/null
fi

# Try to add key
if ! ssh-add -l &> /dev/null; then
  ssh-add ~/.ssh/id_ed25519
fi

gpg-connect-agent /bye
export GPG_TTY=$(tty)
