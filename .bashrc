# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# Custom .bashrc
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

if [ -f /etc/bash_completion ]; then
  . /etc/bash_completion
fi

export PATH=~/local/bin:$PATH

# Colors.
export NO_COLOR='\e[0m'
export GREEN='\e[0;32m'
export BLUE='\e[34m'
export RED='\e[0;31m'
export LSCOLORS=fxgxdxdxcxegedcbcbfxfx

# Set up prompt.
PS1="\[$BLUE\][\u@\h]\[$GREEN\] \w \[$RED\]> \[$NO_COLOR\] "

# Misc.
export HISTCONTROL=ignoredups
export HISTCONTROL=ignoreboth
export HISTFILESIZE=50000
export HISTSIZE=10000
export GREP_COLORS='31'
export EDITOR='vim'

shopt -s checkwinsize
shopt -s histappend

# Some aliases.
alias ll='ls -ahlF --color=auto'
alias gvim='gvim -p'
alias sortera="du -h | grep -e '[0-9][0-9][M|G]' | sort -n"
alias dun="du -ah | grep -E \"[0-9]*[0-9][M|G][^a-z|0-9]\" | sort -n"
alias agrep="/bin/grep --color=auto --exclude-dir=.svn --exclude=*.swp --exclude-dir=DEV --exclude-dir=named -ri $1"
alias grep="/bin/grep --color=auto"

# Bash completion.
if [ -t 0 ]; then   # only run if stdin is a terminal
  bind "set completion-ignore-case on"
  bind "set bell-style none"
  bind "set show-all-if-ambiguous on"
  bind "set visible-stats on"
  complete -d cd rmdir
  stty -ctlecho
fi

SSH_AUTH_SOCK=$(ss -xl | grep -o '/run/user/1000/keyring.*/ssh')
[ -z "$SSH_AUTH_SOCK" ] || export SSH_AUTH_SOCK

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
  debian_chroot=$(cat /etc/debian_chroot)
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi



# Source gitprompt,
source ~/.bash-git-prompt/gitprompt.sh
GIT_PROMPT_ONLY_IN_REPO=1




















# Testing new hipster stuff,

# IP addresses
alias pubip="dig +short myip.opendns.com @resolver1.opendns.com"
alias localip="sudo ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1'"
alias ips="sudo ifconfig -a | grep -o 'inet6\? \(addr:\)\?\s\?\(\(\([0-9]\+\.\)\{3\}[0-9]\+\)\|[a-fA-F0-9:]\+\)' | awk '{ sub(/inet6? (addr:)? ?/, \"\"); print }'"

# View HTTP traffic
alias sniff="sudo ngrep -d 'en1' -t '^(GET|POST) ' 'tcp and port 80'"
alias httpdump="sudo tcpdump -i en1 -n -s 0 -w - | grep -a -o -E \"Host\: .*|GET \/.*\""

# Create a new directory and enter it
mkd() {
	mkdir -p "$@" && cd "$@"
}

# Use Git’s colored diff when available
hash git &>/dev/null
if [ $? -eq 0 ]; then
	diff() {
		git diff --no-index --color-words "$@"
	}
fi

# Get colors in manual pages
man() {
	env \
		LESS_TERMCAP_mb=$(printf "\e[1;31m") \
		LESS_TERMCAP_md=$(printf "\e[1;31m") \
		LESS_TERMCAP_me=$(printf "\e[0m") \
		LESS_TERMCAP_se=$(printf "\e[0m") \
		LESS_TERMCAP_so=$(printf "\e[1;44;33m") \
		LESS_TERMCAP_ue=$(printf "\e[0m") \
		LESS_TERMCAP_us=$(printf "\e[1;32m") \
		man "$@"
}

kill_all_fucking_chrome_tabs(){
  ps ux                                             |
  grep '/opt/google/chrome/chrome --type=renderer'  |
  grep -v extension-process                         |
  tr -s ' '                                         |
  cut -d ' ' -f2                                    |
  xargs kill
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

convert_to_utf(){
  if ! [[ $1 ]]; then
    echo -e " \n Usage :"
    echo -e "  convert_to_utf file_to_convert $1\n"
    return
  fi

  vim +"set nobomb | set fenc=utf8 | x" $1
}
