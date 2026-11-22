#!/usr/bin/env bash
#
# Tests for the ssh-agent functions of .bashrc, run against real agents:
#
#   tests/ssh_agent_test.sh
#
# Every case gets a HOME and an XDG_RUNTIME_DIR of its own under /tmp, so the
# agents and keys of whoever runs this are never touched. The case that needs
# gcr-ssh-agent, GNOME's agent, is skipped where that is not installed.
#
# There is no `set -e` or `set -u` on purpose: the functions come from the
# startup file of an interactive shell and are tested under its options.

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo
readonly bashrc="${repo}/.bashrc"
readonly skipped=77

#######################################
# Print the path of gcr-ssh-agent, which distributions install in different
# places.
# Returns:
#   0 if it is installed, 1 otherwise
#######################################
find_gcr_ssh_agent() {
  local bin
  for bin in /usr/libexec/gcr-ssh-agent /usr/lib/gcr-ssh-agent; do
    if [[ -x "${bin}" ]]; then
      echo "${bin}"
      return 0
    fi
  done
  return 1
}

#######################################
# End the case that calls it as failed, or as skipped.
# Arguments:
#   Reason
#######################################
fail() {
  echo "      $*"
  exit 1
}

skip() {
  echo "      $*"
  exit "${skipped}"
}

#######################################
# Run a command until it succeeds, for five seconds at most.
# Arguments:
#   Command and its arguments
# Returns:
#   0 once the command succeeded, 1 if it never did
#######################################
wait_for() {
  local i
  for (( i = 0; i < 100; i++ )); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}

#######################################
# Check whether an agent answers on a socket. The tests' own check, apart
# from the function under test: ssh-add -l exits 2 when it reaches no agent.
# Arguments:
#   Socket
#######################################
answers() {
  SSH_AUTH_SOCK="$1" ssh-add -l &> /dev/null
  (( $? != 2 ))
}

silent() {
  ! answers "$1"
}

#######################################
# Start an agent on a socket and wait until it answers.
# Globals:
#   agent_pid, set to the agent's pid
# Arguments:
#   Socket
#######################################
start_agent() {
  ssh-agent -D -a "$1" &> /dev/null &
  agent_pid=$!
  wait_for answers "$1" || fail "no agent came up on $1"
}

#######################################
# Leave the socket of an agent that was killed: the file is there and nothing
# listens on it, since a killed agent cannot remove it.
# Arguments:
#   Socket
#######################################
leave_dead_socket() {
  start_agent "$1"
  kill -KILL "${agent_pid}"
  wait "${agent_pid}" 2> /dev/null
  [[ -S "$1" ]] || fail "the killed agent left no socket at $1"
  silent "$1" || fail "something still answers on $1"
}

#######################################
# Start gcr-ssh-agent and wait until it answers. Its environment is emptied,
# so it has no session bus and cannot reach a keyring.
# Globals:
#   gcr_pid, set to the wrapper's pid
# Arguments:
#   Directory for its ssh and .ssh sockets
#######################################
start_gcr_ssh_agent() {
  local bin
  bin=$(find_gcr_ssh_agent) || skip 'gcr-ssh-agent is not installed'
  env -i HOME="${HOME}" PATH="${PATH}" "${bin}" --base-dir "$1" &> /dev/null &
  gcr_pid=$!
  wait_for answers "$1/ssh" || fail "gcr-ssh-agent did not come up in $1"
}

#######################################
# Check what every case is about: SSH_AUTH_SOCK names the socket, programs
# the shell starts inherit it, and an agent answers there.
# Arguments:
#   Socket
#######################################
expect_agent_on() {
  [[ "$(printenv SSH_AUTH_SOCK)" == "$1" ]] \
    || fail "SSH_AUTH_SOCK is exported as '$(printenv SSH_AUTH_SOCK)', expected '$1'"
  answers "$1" || fail "no agent answers on $1"
}

#######################################
# Give a case its own HOME and runtime directory, and no agent to inherit.
# Globals:
#   HOME, XDG_RUNTIME_DIR, SSH_AUTH_SOCK, SSH_AGENT_PID
#   gcr and private, set to where setup_ssh_agent looks
#######################################
new_case() {
  local dir
  dir=$(mktemp -d "${sandbox}/XXXX") || fail 'mktemp failed'
  export HOME="${dir}/home" XDG_RUNTIME_DIR="${dir}/run"
  unset SSH_AUTH_SOCK SSH_AGENT_PID
  gcr="${XDG_RUNTIME_DIR}/gcr"
  private="${HOME}/.ssh/ssh-agent.sock"
  mkdir -p "${HOME}" "${gcr}"
}

test_keeps_an_agent_that_already_answers() {
  start_agent "${HOME}/forwarded.sock"
  export SSH_AUTH_SOCK="${HOME}/forwarded.sock"

  setup_ssh_agent

  expect_agent_on "${HOME}/forwarded.sock"
}

test_picks_the_agent_behind_gnomes_wrapper() {
  start_agent "${gcr}/ssh"  # stands in for the wrapper
  start_agent "${gcr}/.ssh"

  setup_ssh_agent

  expect_agent_on "${gcr}/.ssh"
}

#######################################
# Start gcr-ssh-agent and kill the agent behind it, which is the state a
# kill leaves a desktop in: the wrapper answers, the .ssh socket is there,
# and nothing listens on it.
# Globals:
#   gcr
#######################################
kill_the_agent_behind_gnomes_wrapper() {
  start_gcr_ssh_agent "${gcr}"
  wait_for answers "${gcr}/.ssh" || fail 'the wrapper started no agent'
  pkill -KILL -P "${gcr_pid}"
  wait_for silent "${gcr}/.ssh" || fail 'the agent survived the kill'
  [[ -S "${gcr}/.ssh" ]] || fail 'the killed agent left no socket'
}

test_brings_gnomes_agent_back_after_it_was_killed() {
  kill_the_agent_behind_gnomes_wrapper

  setup_ssh_agent

  expect_agent_on "${gcr}/.ssh"
}

test_brings_gnomes_agent_back_for_a_shell_on_the_desktop() {
  kill_the_agent_behind_gnomes_wrapper
  export SSH_AUTH_SOCK="${gcr}/ssh"  # what the desktop session hands out

  setup_ssh_agent

  expect_agent_on "${gcr}/ssh"
  answers "${gcr}/.ssh" || fail 'the agent behind the wrapper is still dead'
}

test_private_agent_when_gnomes_agent_stays_dead() {
  start_agent "${gcr}/ssh"  # a wrapper that answers and can start nothing
  leave_dead_socket "${gcr}/.ssh"

  setup_ssh_agent

  expect_agent_on "${private}"
}

test_reuses_the_private_agent() {
  mkdir -m 0700 "${HOME}/.ssh"
  start_agent "${private}"

  setup_ssh_agent

  expect_agent_on "${private}"
  kill -0 "${agent_pid}" 2> /dev/null || fail 'the agent that was running is gone'
  [[ -z "${SSH_AGENT_PID}" ]] || fail 'a second agent was started'
}

test_replaces_a_dead_private_socket() {
  mkdir -m 0700 "${HOME}/.ssh"
  leave_dead_socket "${private}"

  setup_ssh_agent

  expect_agent_on "${private}"
}

test_starts_a_private_agent_from_nothing() {
  setup_ssh_agent

  expect_agent_on "${private}"
  [[ "$(ls -ld "${HOME}/.ssh")" == drwx------* ]] \
    || fail "${HOME}/.ssh is open to others"
}

#######################################
# Run one case in a subshell and report it. The output goes to a file, not
# through a pipe: an agent that inherited a pipe would keep it open.
# Globals:
#   passed, failed, skips
# Arguments:
#   Name of the case's function
#######################################
run_case() {
  local name="$1" status
  (
    new_case
    "${name}"
  ) > "${sandbox}/output" 2>&1
  status=$?
  name="${name#test_}"
  if (( status == 0 )); then
    passed=$(( passed + 1 ))
    echo "ok    ${name//_/ }"
  elif (( status == skipped )); then
    skips=$(( skips + 1 ))
    echo "skip  ${name//_/ }"
    cat "${sandbox}/output"
  else
    failed=$(( failed + 1 ))
    echo "FAIL  ${name//_/ }"
    cat "${sandbox}/output"
  fi
}

cleanup() {
  # Every agent the cases started has the sandbox in its command line.
  pkill -u "${UID}" -f -- "${sandbox}" 2> /dev/null
  rm -rf "${sandbox}"
}

main() {
  local name functions
  passed=0 failed=0 skips=0

  # A socket's path holds about a hundred bytes, and TMPDIR on macOS uses up
  # half of them, so the sandbox goes straight under /tmp.
  sandbox=$(mktemp -d /tmp/dotfiles-test.XXXXXX) || exit 1
  trap cleanup EXIT

  # .bashrc cannot be sourced here: it returns at once in a shell that is not
  # interactive, and in one that is it runs everything. Its functions start
  # and end in the first column, so the ones about the agent are cut out.
  functions=$(sed -n '/^[a-z_]*ssh_agent[a-z_]*() {$/,/^}$/p' "${bashrc}")
  [[ -n "${functions}" ]] || { echo "no ssh-agent functions in ${bashrc}" >&2; exit 1; }
  eval "${functions}"

  for name in $(compgen -A function test_); do
    run_case "${name}"
  done

  echo "${passed} passed, ${failed} failed, ${skips} skipped"
  (( failed == 0 ))
}

main "$@"
