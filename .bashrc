# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

[[ -f /etc/bashrc ]]          && source /etc/bashrc
[[ -f /etc/bash_completion ]] && source /etc/bash_completion

# Set PATH, MANPATH, etc., for Homebrew.
if [[ $(uname -s) == Darwin* ]];then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  pinentry=$(echo $(brew --prefix)/bin/pinentry-mac)
  gpg=$(echo $(brew --prefix)/bin/gpg)
else
  pinentry=$(which pinentry)
  gpg=$(which gpg)
  gitdiff="/usr/share/git-core/contrib/diff-highlight"
fi

for dir in .cache .gnupg; do
  if ! [[ -d ${HOME}/${dir} ]]; then
    mkdir -v ${HOME}/${dir}

    if [[ "${dir}" == ".gnupg" ]]; then
      chmod 700 "${dir}"
    fi
  fi
done

for file in gpg.conf gpg-agent.conf; do
  if ! [[ -f "${HOME}/.gnupg/${file}" ]]; then
    echo "creating ${HOME}/.gnupg/${file}"
    touch "${HOME}/.gnupg/${file}"
  fi
done

if ! grep pinentry-program -q ${HOME}/.gnupg/gpg-agent.conf; then
  echo "pinentry-program ${pinentry}" >> ${HOME}/.gnupg/gpg-agent.conf
fi

if ! grep use-agent -q ${HOME}/.gnupg/gpg.conf; then
  echo "use-agent" >> ${HOME}/.gnupg/gpg.conf
fi

if ! grep "program = ${gpg}" -q ${HOME}/.gitconfig; then
  sed -i "s|\(program =\) .*|\1 ${gpg}|" ${HOME}/.gitconfig
fi

for param in show diff; do
  if ! grep -v auto ${HOME}/.gitconfig | grep "${param} = ${gitdiff}$" -q; then
    sed -i "s|\(${param} =\)\(?!auto\).*|\1 ${gitdiff}|" ${HOME}/.gitconfig
    sed -i "/diff = auto/! s|\(${param} =\) .*|\1 ${gitdiff}|" ~/.gitconfig
  fi
done


export ANDROID_SDK_ROOT=${HOME}/android/
export ANDROID_HOME=${ANDROID_SDK_ROOT}
export GOPATH=${HOME}/go
export PATH="${ANDROID_SDK_ROOT}/platform-tools/:${PATH}"
export PATH="/usr/share/android-studio/jre/bin/:${PATH}"
export PATH="${HOME}/.gradle/wrapper/dists/gradle-5.4.1-all/3221gyojl5jsh0helicew7rwx/gradle-5.4.1/bin/:${PATH}"

export EDITOR='vim'
export GREP_COLORS='31'

# Magical history handling,
# export HISTTIMEFORMAT="%Y-%m-%d %T "
export HISTFILESIZE=-1
export HISTSIZE=-1
HISTCONTROL=ignoredups:erasedups
shopt -s histappend
function historymerge {
  history -n; history -w; history -c; history -r;
}
trap historymerge EXIT
PROMPT_COMMAND="history -a; $PROMPT_COMMAND"

# Some aliases.
alias ll='ls -ahlF --color=auto'
alias gvim='gvim -p'
alias dun="du -ah | grep -E \"[0-9]*[0-9][M|G][^a-z|0-9]\" | sort -n"
alias agrep="/usr/bin/grep --color=auto --exclude-dir=.svn --exclude=*.swp --exclude-dir=DEV --exclude-dir=named -ri $1"
alias grep="/usr/bin/grep --color=auto"
alias kssh="export KRB5_TRACE=/dev/stderr; ssh $1"

# Bash completion.
if [[ -t 0 ]]; then   # only run if stdin is a terminal
  bind "set completion-ignore-case on"
  bind "set bell-style none"
  bind "set show-all-if-ambiguous on"
  bind "set visible-stats on"
  complete -d cd rmdir
  stty -ctlecho
fi

if [ $TILIX_ID ] || [ $VTE_VERSION ]; then
          source /etc/profile.d/vte.sh
fi

# Source pureline,
if [[ -f ~/dotfiles/pureline ]]; then
  source ~/dotfiles/pureline ~/dotfiles/.pureline.conf
fi

gpg-connect-agent /bye
export GPG_TTY=$(tty)

# Random, kinda not used,

# View HTTP traffic
alias sniff="sudo ngrep -d 'en1' -t '^(GET|POST) ' 'tcp and port 80'"
alias httpdump="sudo tcpdump -i en1 -n -s 0 -w - | grep -a -o -E \"Host\: .*|GET \/.*\""

# Use Git’s colored diff when available
hash git &>/dev/null
if [[ $? -eq 0 ]]; then
  diff() {
    git diff --no-index --color-words "$@"
  }
fi

# Get colors in manual pages
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

check_port(){

  local host=${1%:*}
  local port=${1#*:}
  local colon="${1//[^:]}"
  local re_num='^[0-9]+$'
  local err=0

  if [[ ${#colon} -ne 1 ]];then
    echo -e " \n Usage :"
    echo -e "  check_port addr:port \n"
    return
  fi

  if [[ -z $host ]];then
    echo "\n Missing host" && err=1
  fi

  if [[ ! $port ]]; then
    echo "\n Port missing" && err=1
  fi

  if ! [[ $port =~ $re_num  ]];then
    echo -e " \n Port invalid, number expected ($port)" && err=1
  fi

  if [[ $err -ne 0 ]]; then
    echo -e " \n Usage :"
    echo -e "  check_port addr:port \n"
    return
  fi

  (echo > /dev/tcp/$host/$port) >/dev/null 2>&1 \
    && echo "Yes connection." || echo "No connection."
}

