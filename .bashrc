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
export GREP_OPTIONS='--color=auto'

shopt -s checkwinsize
shopt -s histappend

# Some aliases.
alias ll='ls -ahlF --color=auto'
alias gvim='gvim -p'
alias sortera="du -h | grep -e '[0-9][0-9][M|G]' | sort -n"
alias dun="du -ah | grep -E \"[0-9]*[0-9][M|G][^a-z|0-9]\" | sort -n"
alias agrep="grep --exclude-dir=.svn --exclude=*.swp --exclude-dir=DEV --exclude-dir=named -ri $1"
alias grep="/bin/grep $GREP_OPTIONS"

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
