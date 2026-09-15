# shellcheck shell=bash
# ~/.bash_profile: read by login shells, which is what terminals on macOS
# start. Everything lives in ~/.bashrc; this file only hands over to it, so
# that login and non-login shells behave the same.
[[ -r "${HOME}/.bashrc" ]] && source "${HOME}/.bashrc"
