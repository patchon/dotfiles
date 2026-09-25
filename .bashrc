# shellcheck shell=bash disable=SC1090,SC1091
# ~/.bashrc: interactive bash configuration for linux and macos.
#
# Requires bash >= 4.3. macOS ships 3.2 in /bin/bash, so install a current one
# with `brew install bash`. Terminals on macOS start login shells, which read
# ~/.bash_profile, so that file must source this one. Every file sourced below
# is optional and machine-specific, hence the shellcheck directive above.

# Do nothing for non-interactive shells.
case $- in
  *i*) ;;
  *) return ;;
esac

# Functions are defined before the aliases at the bottom on purpose: aliases
# are expanded when a function body is parsed.

#######################################
# Print a message to stderr, with the same " -> " prefix as the status lines
# of check_tcp_port and check_tls_chain, the arrow in their colour on a tty.
# Globals:
#   NO_COLOR
# Arguments:
#   Message text
#######################################
err() {
  local arrow='->'
  [[ -t 2 && -z "${NO_COLOR:-}" ]] && arrow=$'\e[36m\e[1m->\e[0m'
  echo " ${arrow} $*" >&2
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
# Check whether a file is a private key that needs a passphrase. Only those
# gain anything from the agent: ssh reads a passphrase-less key straight
# from its IdentityFile.
# Arguments:
#   Path to check
# Returns:
#   0 if the file is a passphrase-protected private key, 1 otherwise
#######################################
is_encrypted_key() {
  local first
  [[ -f "$1" ]] || return 1
  read -r first < "$1"
  [[ "${first}" == '-----BEGIN '*'PRIVATE KEY-----' ]] || return 1
  ! ssh-keygen -y -P '' -f "$1" &> /dev/null
}

#######################################
# Check whether the agent holds a private key, by fingerprint. ssh-keygen
# takes the fingerprint from the .pub next to the key when there is one, and
# from the key itself otherwise. No signing, so a hardware key is not asked
# for a touch.
# Arguments:
#   Path to private key
# Returns:
#   0 if the agent lists the key, 1 otherwise
#######################################
ssh_key_loaded() {
  local fp
  read -r _ fp _ < <(ssh-keygen -lf "$1" 2> /dev/null)
  [[ -n "${fp}" ]] && ssh-add -l 2> /dev/null | grep -qF " ${fp} "
}

#######################################
# Add a private key to the agent.
#
# On macOS the passphrase is kept in the keychain: the first time a key is
# added the user is asked once and the passphrase stored, after that
# ssh-add reads it from the keychain silently. Apple's /usr/bin/ssh-add is
# used explicitly for that, since a Homebrew openssh earlier in PATH does
# not know the --apple-* options. Elsewhere ssh-add prompts.
#
# Warns when the key went in but its .pub sibling belongs to another key:
# ssh trips over that too, and every shell would re-add the key.
# Globals:
#   OSTYPE
# Arguments:
#   Path to private key
# Returns:
#   ssh-add's exit status
#######################################
add_ssh_key() {
  local key="$1"

  if [[ "${OSTYPE}" == darwin* && -x /usr/bin/ssh-add ]]; then
    /usr/bin/ssh-add --apple-use-keychain "${key}" || return
  else
    ssh-add "${key}" || return
  fi
  ssh_key_loaded "${key}" || err "${key}.pub does not belong to ${key}"
}

#######################################
# Load every passphrase-protected key in ~/.ssh that the agent does not hold
# yet. Runs at every shell start; the checks cost a few ms per key file.
# Globals:
#   HOME
# Returns:
#   0, or 1 when no agent answers
#######################################
add_ssh_keys() {
  local key
  ssh_agent_alive || { err 'no ssh-agent'; return 1; }
  for key in "${HOME}"/.ssh/*; do
    is_encrypted_key "${key}" || continue
    ssh_key_loaded "${key}" && continue
    add_ssh_key "${key}"
  done
  return 0
}

#######################################
# Set one "key value" line in gpg-agent.conf, under GNUPGHOME when that is
# set and ~/.gnupg otherwise, which is the same file gpg itself reads. Any
# other line with the same key is dropped, so a stale value (a pinentry from
# an intel homebrew install, a ttl from an older version of this file) does
# not linger. Writing nothing when the line is already there matters: the
# reload that a change needs also flushes every cached passphrase, so a
# config rewritten on each shell start would undo unlock_gpg_keys every time.
# Globals:
#   GNUPGHOME, HOME
# Arguments:
#   Option name, option value
# Returns:
#   0 if the file was changed, 1 if it already said this
#######################################
set_gpg_agent_conf() {
  local key="$1" value="$2"
  local dir="${GNUPGHOME:-${HOME}/.gnupg}"
  local conf="${dir}/gpg-agent.conf"

  grep -qsx "${key} ${value}" "${conf}" && return 1

  # -m applies to the last directory only, the home, which is the one gpg
  # wants 0700; any parents it creates get the usual mode.
  # shellcheck disable=SC2174
  [[ -d "${dir}" ]] || mkdir -p -m 0700 "${dir}"
  { grep -vs "^${key} " "${conf}"
    echo "${key} ${value}"; } > "${conf}.tmp" && mv "${conf}.tmp" "${conf}"
}

#######################################
# Re-indent a git config file with spaces. git config indents every entry it
# writes with one tab and offers no way to ask for anything else, so a file
# it has touched is normalised afterwards. Two spaces, to match .gitconfig
# in this repo.
#
# Only a file that still holds a leading tab is rewritten, for the same
# reason set_gpg_agent_conf looks before it writes: a shell start should not
# touch a file it has nothing to change. Leading tabs are the only ones
# replaced, so a tab inside a value is left alone.
#
# grep -P and sed \t are GNU only, hence the literal tab.
# Arguments:
#   Path to the file
# Returns:
#   0 if the file was rewritten, 1 if it needed nothing
#######################################
space_indent_git_config() {
  local file="$1" tab=$'\t'

  grep -qs "^${tab}" "${file}" || return 1

  sed -E "s/^${tab}+/  /" "${file}" > "${file}.tmp" \
    && mv "${file}.tmp" "${file}"
}

#######################################
# Point gpg-agent and git at the right binaries, and let the agent hold a
# passphrase for as long as ssh-agent holds a key. gpg-agent on linux finds
# /usr/bin/pinentry by itself; on macOS it needs pinentry-mac from Homebrew.
# Files are only written when the current value differs.
#
# The gpg path goes into ~/.gitconfig.local, which ~/.gitconfig includes,
# rather than into ~/.gitconfig itself: that file is a symlink into the
# dotfiles repo, and writing a machine-specific path there dirties the repo.
# Globals:
#   HOMEBREW_PREFIX, OSTYPE
#######################################
setup_gpg() {
  local gpg_bin pinentry reload=
  local git_local="${HOME}/.gitconfig.local"

  gpg_bin=$(command -v gpg) || return 0

  # gpg-agent caches the passphrase, not the key, and by default forgets it
  # 600s after the last use or 7200s after it was typed. ssh-agent has no
  # such limit, so a key unlocked at shell start would be gone by mid
  # morning while the ssh key was still there. 400 days is the agent's way
  # of saying "until it is restarted", which a reboot does.
  set_gpg_agent_conf default-cache-ttl 34560000 && reload=1
  set_gpg_agent_conf max-cache-ttl 34560000 && reload=1

  if [[ "${OSTYPE}" == darwin* ]]; then
    pinentry="${HOMEBREW_PREFIX}/bin/pinentry-mac"
    if [[ ! -x "${pinentry}" ]]; then
      err "missing ${pinentry}, brew install pinentry-mac ?"
    else
      set_gpg_agent_conf pinentry-program "${pinentry}" && reload=1
    fi
  fi

  [[ -n "${reload}" ]] && gpgconf --reload gpg-agent 2> /dev/null

  if command -v git &> /dev/null; then
    if [[ "$(git config --file "${git_local}" --get gpg.program)" != "${gpg_bin}" ]]; then
      git config --file "${git_local}" gpg.program "${gpg_bin}"
    fi
    space_indent_git_config "${git_local}"
  fi
  return 0
}

#######################################
# Check whether gpg-agent answers. gpg-connect-agent starts one if none is
# running, which is the gpg counterpart of setup_ssh_agent: the agent lives
# on a socket under /run/user and every shell shares it.
# Returns:
#   0 if the agent answers, 1 otherwise
#######################################
gpg_agent_alive() {
  gpg-connect-agent /bye &> /dev/null
}

#######################################
# Ask gpg-agent about one private key. The reply is
#   S KEYINFO <keygrip> <type> <serialno> <idstr> <cached> <protection> ...
# where cached is 1 or -, and protection is P for a key behind a passphrase
# and C for one stored in the clear. Nothing is signed, so this neither asks
# for a passphrase nor caches one as a side effect.
# Arguments:
#   Keygrip
# Outputs:
#   The cached and protection fields, space separated
# Returns:
#   0 if the agent knows the key, 1 otherwise
#######################################
gpg_key_state() {
  local grip cached protection
  read -r _ _ grip _ _ _ cached protection _ \
    < <(gpg-connect-agent "keyinfo $1" /bye 2> /dev/null)
  [[ "${grip}" == "$1" ]] || return 1
  echo "${cached} ${protection}"
}

#######################################
# Unlock one private key, asking for its passphrase through pinentry.
#
# There is no gpg equivalent of ssh-add: the agent reads a key only when an
# operation needs it. So an operation the key can actually do is made up and
# its output thrown away. The trailing "!" pins gpg to this exact key
# instead of letting it pick a subkey. A key that can neither sign nor
# encrypt, certify-only or authenticate-only, has no gpg command to drive
# it, so the agent is asked for a bare signature over a block of zeroes.
#
# Success comes from the exit status, not from the agent's cache: when the
# agent already learnt this passphrase from a sibling key it unlocks this
# one without recording it under its own keygrip, and the cache would report
# a perfectly usable key as locked.
# Arguments:
#   Keygrip, fingerprint, capability letters from --with-colons
# Returns:
#   0 if the key is now usable, 1 if not
#######################################
unlock_gpg_key() {
  local grip="$1" fpr="$2" caps="$3"

  case "${caps}" in
    *s*)
      echo | gpg --batch --local-user "${fpr}!" --sign --output /dev/null
      ;;
    *e*)
      echo | gpg --batch --trust-model always --recipient "${fpr}!" --encrypt \
        | gpg --batch --decrypt --output /dev/null 2> /dev/null
      ;;
    *)
      ! printf 'SIGKEY %s\nSETHASH --hash=sha256 %064d\nPKSIGN\nBYE\n' "${grip}" 0 \
        | gpg-connect-agent --quiet 2>&1 | grep -q '^ERR'
      ;;
  esac
}

#######################################
# Unlock every passphrase-protected secret key the agent does not hold yet.
# The counterpart of add_ssh_keys, and it runs next to it at every shell
# start. Keys come from the keyring rather than from the agent's own list,
# which also holds keygrips whose public half has since been deleted.
#
# The awk walks the colon records: sec and ssb open a key and carry its
# capabilities, the first fpr after one is its fingerprint, and grp its
# keygrip.
# Returns:
#   0, or 1 when no agent answers
#######################################
unlock_gpg_keys() {
  local grip fpr caps cached protection

  command -v gpg &> /dev/null || return 0
  gpg_agent_alive || { err 'no gpg-agent'; return 1; }

  while read -r grip fpr caps; do
    read -r cached protection < <(gpg_key_state "${grip}") || continue
    [[ "${protection}" == 'P' ]] || continue  # no passphrase, nothing to unlock
    [[ "${cached}" == '1' ]] && continue      # the agent already has it
    unlock_gpg_key "${grip}" "${fpr}" "${caps}" || err "gpg key ${fpr} is still locked"
  done < <(gpg --list-secret-keys --with-keygrip --with-colons 2> /dev/null | awk -F: '
    $1 == "sec" || $1 == "ssb" { caps = $12; fpr = ""; next }
    $1 == "fpr" && fpr == ""   { fpr = $10; next }
    $1 == "grp" && fpr != ""   { print $10, fpr, caps }')
  return 0
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

#######################################
# Test whether a TCP port accepts connections, using bash's own /dev/tcp so
# it works on hosts without nc, nmap or curl. The connect runs in a
# background subshell because bash cannot give connect() a timeout itself;
# its error text is captured because it names the reason, and the group
# around it keeps job-control chatter out of an interactive shell.
# bash picks the descriptor number: on macOS a host name lookup leaves a
# guarded network-policy descriptor on the lowest free fd, and redirecting
# onto a fixed number such as 3 dup2()s over it, which the kernel answers
# with EXC_GUARD and SIGKILL, so the port looked "closed".
# Globals:
#   LANG, LC_ALL, LC_CTYPE, NO_COLOR
# Arguments:
#   Host name or address
#   Port number
#   Timeout in whole seconds, default 3
# Outputs:
#   " -> checking '<host> tcp/<port>'" plus a green tick or a red cross on
#   stdout; after a cross, " -> err: <reason>" on stderr with the reason:
#   closed, unknown host, no answer in <n>s, check died with status <n>, or
#   what bash reported. ok and FAIL replace the glyphs when the locale is
#   set and is not UTF-8, the same rule as the prompt.
# Returns:
#   0 if the port accepts a connection, 1 if not, 2 on usage error
#######################################
probe_tcp_port() {
  local host="${1:-}" port="${2:-}" timeout="${3:-3}"
  local -r usage='usage: check_tcp_port <host> <port> [timeout-seconds]'
  local output status reason ctype mark arrow='->' tick='✔' cross='✘'
  local red='' green='' reset=''

  if [[ -z "${host}" || ! "${port}" =~ ^[1-9][0-9]{0,4}$ ]] \
      || [[ ! "${timeout}" =~ ^[1-9][0-9]*$ ]] || (( port > 65535 )); then
    err "${usage}"
    return 2
  fi
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    red=$'\e[31m' green=$'\e[32m' reset=$'\e[0m' arrow=$'\e[36m\e[1m->\e[0m'
  fi
  ctype="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ -n "${ctype}" && "${ctype,,}" != *utf* ]]; then
    tick=ok cross=FAIL
  fi

  output=$(
    {
      ( exec {fd}<> "/dev/tcp/${host}/${port}" && exec {fd}>&- ) 2>&1 &
      pid=$!
      for (( i = 0; i < timeout * 10; i++ )); do
        kill -0 "${pid}" 2> /dev/null || break
        sleep 0.1
      done
      if kill -0 "${pid}" 2> /dev/null; then
        kill "${pid}" 2> /dev/null
        exit 124
      fi
      wait "${pid}"
    } 2> /dev/null
  )
  status=$?

  if (( status == 0 )); then
    mark="${green}${tick}${reset}"
  else
    mark="${red}${cross}${reset}"
    case "${status}" in
      124) reason="no answer in ${timeout}s" ;;
      *)
        # bash's first line names the cause, e.g. "bash: connect: Connection
        # refused" or "bash: host: nodename nor servname provided, or not
        # known" (glibc says "Name or service not known"; scripts add
        # "line N:").
        reason="${output%%$'\n'*}"
        reason="${reason##*: }"
        case "${reason}" in
          *refused*) reason=closed ;;
          *'not known'*|*nodename*|*'name resolution'*) reason='unknown host' ;;
          '') reason="check died with status ${status}" ;;
          *) reason="${reason,}" ;;
        esac
        ;;
    esac
  fi
  printf " %s checking '%s tcp/%s' %s\n" "${arrow}" "${host}" "${port}" "${mark}"
  (( status == 0 )) && return 0
  err "err: ${reason}"
  return 1
}

#######################################
# probe_tcp_port with a blank line before and after, for use at the prompt.
# Arguments:
#   Passed through to probe_tcp_port
# Returns:
#   The status of probe_tcp_port
#######################################
check_tcp_port() {
  local status
  echo
  probe_tcp_port "$@"
  status=$?
  echo
  return "${status}"
}

#######################################
# Print the first http or https CA Issuers URL in a certificate's Authority
# Information Access extension: where the CA that signed it publishes its own
# certificate. The ldap URLs that Active Directory CAs list first are skipped.
# Arguments:
#   Certificate, PEM
# Outputs:
#   The URL on stdout, nothing if there is none
#######################################
ca_issuers_url() {
  local line
  while IFS= read -r line; do
    case "${line}" in
      *'CA Issuers - URI:http://'*|*'CA Issuers - URI:https://'*)
        echo "${line#*URI:}"
        return
        ;;
    esac
  done < <(openssl x509 -noout -text <<< "$1" 2> /dev/null)
}

#######################################
# Download a CA certificate from a CA Issuers URL, the way browsers fill in a
# missing intermediate. RFC 5280 has the URL serve one DER certificate or a
# "certs-only" PKCS#7 bundle (.p7c) of them; a few CAs serve PEM instead.
# Arguments:
#   URL
# Outputs:
#   Every certificate found, as PEM, on stdout, or on failure why
# Returns:
#   0 on success, 1 if not
#######################################
fetch_ca_cert() {
  local url="$1" tmp reason out='' status=0
  if ! command -v curl &> /dev/null; then
    echo 'curl not found'
    return 1
  fi
  if ! tmp=$(mktemp 2>&1); then
    echo "${tmp}"
    return 1
  fi
  # curl -sS says why in one line, e.g. "curl: (22) The requested URL
  # returned error: 404"; keep what follows the error number.
  if ! reason=$(curl -fsSL --max-time 5 -o "${tmp}" "${url}" 2>&1); then
    reason="${reason%%$'\n'*}"
    reason="${reason#curl: }"
    reason="${reason#\(*\) }"
    reason="${reason,}"
    echo "${reason:-curl failed}"
    status=1
  else
    out=$(openssl x509 -inform DER -in "${tmp}" 2> /dev/null) \
      || out=$(openssl x509 -in "${tmp}" 2> /dev/null) \
      || out=$(openssl pkcs7 -inform DER -print_certs -in "${tmp}" 2> /dev/null) \
      || out=$(openssl pkcs7 -print_certs -in "${tmp}" 2> /dev/null)
    if [[ "${out}" == *'-----BEGIN CERTIFICATE-----'* ]]; then
      # -print_certs puts subject and issuer lines around each one.
      sed -n '/^-----BEGIN CERTIFICATE-----$/,/^-----END CERTIFICATE-----$/p' <<< "${out}"
    else
      echo 'the file is neither a certificate nor a PKCS#7 bundle of them'
      status=1
    fi
  fi
  rm -f "${tmp}"
  return "${status}"
}

#######################################
# Show the certificates a TLS server sends and check that the chain is set up
# the way clients expect: the server certificate first, then every
# intermediate in signing order, no root, and a chain that verifies against
# the local trust store. Browsers hide a missing intermediate by fetching it
# themselves; curl, java and most libraries do not, so servers get this wrong
# without anyone noticing.
#
# The trust store is whatever openssl uses by default, so the verdict matches
# openssl on the same machine. SSL_CERT_FILE=bundle.pem or SSL_CERT_DIR=dir
# names another store; openssl still adds its default directory and Apple's
# LibreSSL its keychain roots, so a bundle cannot make a public root untrusted.
# When the issuer at the top of the chain was neither sent nor found in the
# store, it is downloaded with curl from the CA Issuers URL, and so on up to a
# root, to tell a missing intermediate from a CA that is not trusted here.
# The hostname check and the "your store had the intermediate" detection need
# OpenSSL 1.1.1+ and are skipped on LibreSSL. The connect timeout comes from
# probe_tcp_port, since s_client has none; a port that accepts the connection
# but never answers hangs until ctrl-c.
# Globals:
#   COLUMNS, NO_COLOR, OSTYPE, SSL_CERT_DIR, SSL_CERT_FILE
# Arguments:
#   Host name or address
#   Port number, default 443
# Outputs:
#   The probe_tcp_port line, then protocol, cipher and certificate count,
#   every certificate sent, then one ok/warn/FAIL line per check, on stdout
# Returns:
#   0 if every check passes, 1 if one fails or no TLS session was made,
#   2 on usage error
#######################################
report_tls_chain() {
  local host="${1:-}" port="${2:-443}"
  local -r usage='usage: check_tls_chain <host> [port]'
  local -r nameopt='RFC2253,sep_comma_plus_space,-esc_msb'
  local raw line info ssl_lib ssl_dir store now epoch days when plural
  local i j k n top next detail broken entry status name rest colour cont
  local missing unit url from want fsub fiss stop lost last inter root with
  local got field count san low lhost text col width
  local proto='' new_proto='' cipher='' vcode='' vtext='' pem='' in_pem=false
  local checkname='-checkhost' connect="${host}:${port}" failed=0
  local bold='' dim='' red='' green='' yellow='' cyan='' reset='' arrow
  local -a certs=() subject=() issuer=() notafter=() sans=() role=() checks=()
  local -a sni=() verify_opts=() supplied=()
  local -a fetched=() fsubject=() fissuer=() furl=()

  if [[ -z "${host}" || ! "${port}" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
    err "${usage}"
    return 2
  fi
  if ! command -v openssl &> /dev/null; then
    err 'openssl not found'
    return 1
  fi
  if [[ -n "${SSL_CERT_FILE:-}" && ! -r "${SSL_CERT_FILE}" ]]; then
    err "cannot read SSL_CERT_FILE=${SSL_CERT_FILE}"
    return 1
  fi
  if [[ -n "${SSL_CERT_DIR:-}" && ! -d "${SSL_CERT_DIR}" ]]; then
    err "SSL_CERT_DIR=${SSL_CERT_DIR} is not a directory"
    return 1
  fi
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    bold=$'\e[1m' dim=$'\e[2m' red=$'\e[31m' green=$'\e[32m'
    yellow=$'\e[33m' cyan=$'\e[36m' reset=$'\e[0m'
  fi
  arrow="${cyan}${bold}->${reset}"

  # SNI must not be an IP literal (RFC 6066), and an IP is matched against the
  # certificate's IP entries rather than its DNS names.
  if [[ "${host}" =~ ^[0-9]+(\.[0-9]+){3}$ || "${host}" == *:* ]]; then
    checkname='-checkip'
    [[ "${host}" == *:* ]] && connect="[${host}]:${port}"
  else
    sni=(-servername "${host}")
  fi

  probe_tcp_port "${host}" "${port}" || return 1
  raw=$(openssl s_client -connect "${connect}" "${sni[@]}" -showcerts < /dev/null 2>&1)
  if [[ "${raw}" != *'-----BEGIN CERTIFICATE-----'* ]]; then
    err "no certificate from ${host}:${port}"
    while IFS= read -r line; do
      err "  ${line}"
    done < <(grep -E ':error:|alert' <<< "${raw}" | head -n 5)
    return 1
  fi

  # Collect the PEM blocks in the order sent, plus the protocol and cipher.
  # OpenSSL 3 prints "Protocol: X" and "New, X, Cipher is Y" for every
  # session but the "Protocol  : X" / "Cipher    : Y" block only for TLS 1.2;
  # LibreSSL prints the block but says TLSv1/SSLv3 on the "New," line.
  while IFS= read -r line; do
    if [[ "${in_pem}" == true ]]; then
      pem+=$'\n'"${line}"
      if [[ "${line}" == '-----END CERTIFICATE-----' ]]; then
        certs+=("${pem}")
        in_pem=false
      fi
    else
      case "${line}" in
        '-----BEGIN CERTIFICATE-----') pem="${line}"; in_pem=true ;;
        'Protocol: '*|*'Protocol  : '*) proto="${line##*: }" ;;
        *'Cipher    : '*) cipher="${line##*: }" ;;
        'New, '*', Cipher is '*)
          cipher="${line##*Cipher is }"
          new_proto="${line#New, }"
          new_proto="${new_proto%%,*}"
          ;;
      esac
    fi
  done <<< "${raw}"
  [[ -z "${proto}" && "${new_proto}" != */* ]] && proto="${new_proto}"
  n="${#certs[@]}"
  if (( n == 0 )); then
    err "no complete certificate from ${host}:${port}"
    return 1
  fi

  # RFC2253 order (CN first) prints the same on OpenSSL and LibreSSL and is
  # what the checks below compare; -esc_msb keeps non-ASCII names readable.
  # The SANs come from the -text dump, on the line after its heading, as
  # "DNS:a, DNS:b, IP Address:c" on both flavours; LibreSSL has no -ext.
  for (( i = 0; i < n; i++ )); do
    subject[i]='' issuer[i]='' notafter[i]='' sans[i]='' san=false
    info=$(openssl x509 -noout -subject -issuer -enddate -text \
      -nameopt "${nameopt}" <<< "${certs[i]}" 2> /dev/null)
    while IFS= read -r line; do
      if [[ "${san}" == true ]]; then
        sans[i]="${line#"${line%%[![:space:]]*}"}"
        san=false
        continue
      fi
      case "${line}" in
        subject=*) line="${line#subject=}"; subject[i]="${line# }" ;;
        issuer=*) line="${line#issuer=}"; issuer[i]="${line# }" ;;
        notAfter=*) notafter[i]="${line#notAfter=}" ;;
        *'X509v3 Subject Alternative Name:'*) san=true ;;
      esac
    done <<< "${info}"
  done

  # Roles come from the signing links, not the position, so a misordered
  # chain is still labelled right and the order check below can say so.
  for (( i = 0; i < n; i++ )); do
    if [[ "${subject[i]}" == "${issuer[i]}" ]]; then
      role[i]=root
      (( i == 0 )) && role[i]=self-signed
      continue
    fi
    role[i]=leaf
    for (( j = 0; j < n; j++ )); do
      if (( j != i )) && [[ "${issuer[j]}" == "${subject[i]}" ]]; then
        role[i]=intermediate
        break
      fi
    done
  done

  # Follow the issuer links up from certificate 0 to the top of the chain the
  # server actually delivered. Bounded by n so a looping chain cannot hang it.
  top=0
  for (( k = 0; k < n; k++ )); do
    next=''
    for (( j = 0; j < n; j++ )); do
      if (( j != top )) && [[ "${subject[j]}" == "${issuer[top]}" ]]; then
        next="${j}"
        break
      fi
    done
    [[ -n "${next}" ]] || break
    top="${next}"
  done

  plural=s
  (( n == 1 )) && plural=''
  printf ' %s %s  %s  %d certificate%s sent\n' \
    "${arrow}" "${proto:-?}" "${cipher:-?}" "${n}" "${plural}"
  echo

  now=$(date +%s)
  lhost="${host,,}"
  width=$(( ${COLUMNS:-80} - 15 ))  # what is left of a line after the labels
  (( width < 20 )) && width=20
  for (( i = 0; i < n; i++ )); do
    # LC_ALL=C: openssl prints English month names whatever the locale is.
    if [[ "${OSTYPE}" == darwin* ]]; then
      epoch=$(LC_ALL=C date -j -u -f '%b %e %H:%M:%S %Y %Z' "${notafter[i]}" +%s \
        2> /dev/null)
    else
      epoch=$(LC_ALL=C date -u -d "${notafter[i]}" +%s 2> /dev/null)
    fi
    when=''
    if [[ -n "${epoch}" ]]; then
      days=$(( (epoch - now) / 86400 ))
      unit=days
      (( days == 1 || days == -1 )) && unit=day
      if (( epoch < now )); then
        when="  ${red}(expired $(( -days )) ${unit} ago)${reset}"
      elif (( days < 30 )); then
        when="  ${yellow}(expires in ${days} ${unit})${reset}"
      else
        when="  ${green}(${days} ${unit})${reset}"
      fi
    fi
    printf ' %s[%d] %s%s\n' "${cyan}${bold}" "${i}" "${role[i]}" "${reset}"
    printf '     %ssubject%s   %s\n' "${dim}" "${reset}" "${subject[i]}"
    if [[ -n "${sans[i]}" ]]; then
      # Every name, wrapped under the value column. The one the host matches,
      # exactly or through a wildcard for one label, is highlighted.
      text='' col=0 rest="${sans[i]}, "
      while [[ -n "${rest}" ]]; do
        san="${rest%%, *}"
        rest="${rest#*, }"
        case "${san}" in
          DNS:*) san="${san#DNS:}" ;;
          'IP Address:'*) san="IP ${san#IP Address:}" ;;
        esac
        if (( col > 0 && col + 2 + ${#san} >= width )); then
          printf -v text '%s,\n%15s' "${text}" ''
          col=0
        elif (( col > 0 )); then
          text+=', '
          col=$(( col + 2 ))
        fi
        col=$(( col + ${#san} ))
        low="${san,,}"
        if [[ "${low}" == "${lhost}" || "${low}" == "ip ${lhost}" ]] \
            || [[ "${low}" == '*.'* && "${lhost}" == ?*.* \
              && "${lhost#*.}" == "${low#\*.}" ]]; then
          san="${bold}${green}${san}${reset}"
        fi
        text+="${san}"
      done
      printf '     %ssans%s      %s\n' "${dim}" "${reset}" "${text}"
    fi
    printf '     %sissuer%s    %s\n' "${dim}" "${reset}" "${issuer[i]}"
    printf '     %snotAfter%s  %s%s\n' "${dim}" "${reset}" "${notafter[i]}" "${when}"
  done
  echo

  if [[ -n "${SSL_CERT_FILE:-}" ]]; then
    store="${SSL_CERT_FILE} (SSL_CERT_FILE)"
  elif [[ -n "${SSL_CERT_DIR:-}" ]]; then
    store="${SSL_CERT_DIR} (SSL_CERT_DIR)"
  else
    ssl_dir=$(openssl version -d)  # OPENSSLDIR: "/opt/homebrew/etc/openssl@3"
    ssl_dir="${ssl_dir#*\"}"
    ssl_dir="${ssl_dir%\"*}"
    if [[ -f "${ssl_dir}/cert.pem" ]]; then
      store="${ssl_dir}/cert.pem"
    elif [[ -d "${ssl_dir}/certs" ]]; then
      store="${ssl_dir}/certs"
    else
      store="${ssl_dir}"
    fi
  fi

  # Each check is "status name detail"; detail may span lines.
  ssl_lib=$(openssl version)
  if [[ "${ssl_lib}" == LibreSSL* ]]; then
    checks+=("skip hostname needs OpenSSL 1.1.1+, this is ${ssl_lib}")
  else
    # Only OpenSSL 3.2+ reports the outcome in the exit status; the printed
    # text has been stable since 1.1.1.
    detail=$(openssl x509 -noout "${checkname}" "${host}" <<< "${certs[0]}" 2> /dev/null)
    if [[ "${detail}" == *' does match certificate'* ]]; then
      checks+=("ok hostname ${host} matches certificate 0")
    else
      checks+=("FAIL hostname ${host} does not match certificate 0")
    fi
  fi

  if (( n == 1 )); then
    checks+=("ok order single certificate")
  else
    broken=''
    for (( i = 0; i < n - 1; i++ )); do
      if [[ "${issuer[i]}" != "${subject[i + 1]}" ]]; then
        broken="certificate ${i} is not issued by certificate $(( i + 1 ))"
        break
      fi
    done
    if [[ -n "${broken}" ]]; then
      checks+=("FAIL order ${broken}")
    else
      checks+=("ok order each certificate is issued by the next one")
    fi
  fi

  detail=''
  for (( i = 0; i < n; i++ )); do
    if [[ "${role[i]}" == root ]]; then
      detail="certificate ${i} is a self-signed root, send only the leaf and intermediates"
    fi
  done
  if [[ -n "${detail}" ]]; then
    checks+=("warn root ${detail}")
  elif [[ "${role[0]}" == self-signed ]]; then
    checks+=("warn root certificate 0 is self-signed, there is no chain to check")
  else
    checks+=("ok root not sent, as it should be")
  fi

  # The verdict comes from openssl verify rather than from s_client, because
  # Apple's LibreSSL s_client verifies through the system trust store, which
  # fetches missing intermediates itself and so never sees an incomplete
  # chain. With -show_chain (OpenSSL only) the certificates that came from the
  # server are tagged "(untrusted)"; the others came from the store.
  # LibreSSL's verify ignores SSL_CERT_FILE and SSL_CERT_DIR, so name the
  # store on the command line to get the same verdict from both flavours.
  [[ "${ssl_lib}" == LibreSSL* ]] || verify_opts=(-show_chain -nameopt "${nameopt}")
  [[ -n "${SSL_CERT_FILE:-}" ]] && verify_opts+=(-CAfile "${SSL_CERT_FILE}")
  [[ -n "${SSL_CERT_DIR:-}" ]] && verify_opts+=(-CApath "${SSL_CERT_DIR}")
  # A missing issuer (error 20) can be an intermediate the server leaves out
  # or a root this store lacks. To tell which, fetch it from the CA Issuers
  # URL and verify again, passing it as untrusted like the certificates sent,
  # until openssl reaches a root. Four fetches cover any real chain.
  from="${certs[top]}" want="${issuer[top]}" stop=''
  while true; do
    vcode='' vtext='' supplied=()
    while IFS= read -r line; do
      case "${line}" in
        'depth='*)
          [[ "${line}" == *' (untrusted)' ]] || supplied+=("${line#depth=*: }")
          ;;
        'error '*' depth lookup:'*)
          if [[ -z "${vcode}" ]]; then
            vtext="${line#error }"  # e.g. "20 at 0 depth lookup: unable to ..."
            vcode="${vtext%% *}"
            vtext="${vtext#*depth lookup:}"
            vtext="${vtext# }"
          fi
          ;;
        *': OK') vcode=0 ;;
      esac
    done < <(openssl verify "${verify_opts[@]}" \
      -untrusted <(printf '%s\n' "${certs[@]}" "${fetched[@]}") \
      <(printf '%s\n' "${certs[0]}") 2>&1)

    if [[ "${vcode}" != 20 ]] || (( ${#fetched[@]} == 4 )); then
      break
    fi
    url=$(ca_issuers_url "${from}")
    [[ -n "${url}" ]] || break
    if ! got=$(fetch_ca_cert "${url}"); then
      stop="could not fetch it from ${url}: ${got}"
      break
    fi
    # A bundle can hold several certificates issued to the CA, such as
    # cross-certificates; follow the first one with the subject wanted.
    pem='' fsub='' count=0
    while IFS= read -r line; do
      pem+="${line}"$'\n'
      [[ "${line}" == '-----END CERTIFICATE-----' ]] || continue
      count=$(( count + 1 ))
      fsub='' fiss=''
      while IFS= read -r field; do
        case "${field}" in
          subject=*) field="${field#subject=}"; fsub="${field# }" ;;
          issuer=*) field="${field#issuer=}"; fiss="${field# }" ;;
        esac
      done < <(openssl x509 -noout -subject -issuer -nameopt "${nameopt}" <<< "${pem}" 2> /dev/null)
      [[ "${fsub}" == "${want}" ]] && break
      pem=''
    done <<< "${got}"
    if [[ "${fsub}" != "${want}" ]]; then
      if (( count == 1 )); then
        stop="could not fetch it: ${url} has \"${fsub}\" instead"
      else
        stop="could not fetch it: none of the ${count} certificates at ${url} has that subject"
      fi
      break
    fi
    fetched+=("${pem}") fsubject+=("${fsub}") fissuer+=("${fiss}") furl+=("${url}")
    from="${pem}" want="${fiss}"
  done

  lost="issuer \"${issuer[top]}\" of certificate ${top}"
  lost+=" was neither sent nor found in"$'\n'"${store}"
  if (( ${#fetched[@]} > 0 )); then
    # Self-signed ones are roots, the server should send all the others.
    detail="${lost}" inter=0
    for (( i = 0; i < ${#fetched[@]}; i++ )); do
      [[ "${fsubject[i]}" == "${fissuer[i]}" ]] && continue
      if (( i == 0 )); then
        detail+=$'\n'"fetched it from ${furl[i]}: an intermediate, the server should send it"
      else
        detail+=$'\n'"fetched its issuer \"${fsubject[i]}\" from ${furl[i]}:"
        detail+=" an intermediate, the server should send it too"
      fi
      inter=$(( inter + 1 ))
    done
    last=$(( ${#fetched[@]} - 1 ))
    with=it
    (( inter > 1 )) && with=them
    case "${vcode}" in
      0)
        root="${fissuer[last]}"
        (( ${#supplied[@]} > 0 )) && root="${supplied[-1]}"
        detail+=$'\n'"with ${with} the chain verifies to root \"${root}\" in the store"
        ;;
      19)
        if (( inter == 0 )); then
          detail+=$'\n'"fetched it from ${furl[0]}: a root, so the server sends all it should;"
          detail+=" the CA is not trusted here"
        else
          detail+=$'\n'"its root \"${fsubject[last]}\" is not in the store either,"
          detail+=" the CA is not trusted here"
        fi
        ;;
      20)
        detail+=$'\n'"its issuer \"${fissuer[last]}\" is not in the store either"
        [[ -n "${stop}" ]] && detail+=$'\n'"${stop}"
        ;;
      *) detail+=$'\n'"with ${with}, verify error ${vcode:-?}: ${vtext}" ;;
    esac
    checks+=("FAIL trusted ${detail}")
  else
    case "${vcode}" in
      0)
        # openssl prefers the store's copy of an intermediate over the sent one,
        # so a store entry below the anchor is only missing from the server when
        # no sent certificate has its subject.
        missing=''
        for (( i = 0; i < ${#supplied[@]} - 1; i++ )); do
          for (( j = 0; j < n; j++ )); do
            [[ "${subject[j]}" == "${supplied[i]}" ]] && continue 2
          done
          missing="${supplied[i]}"
          break
        done
        if [[ -n "${missing}" ]]; then
          detail="supplied intermediate \"${missing}\", which other clients"
          detail+=" will not have. the server should send it"
          checks+=("warn trusted verifies, but only because ${store}"$'\n'"${detail}")
        elif (( ${#supplied[@]} > 0 )); then
          checks+=("ok trusted anchored by \"${supplied[-1]}\""$'\n'"in ${store}")
        else
          checks+=("ok trusted chain verifies against ${store}")
        fi
        ;;
      20)
        # Nothing could be fetched, so both explanations remain.
        detail="${lost}"
        detail+=$'\n'"the server is missing intermediate(s), or the CA is not trusted here"
        [[ -n "${stop}" ]] && detail+=$'\n'"${stop}"
        checks+=("FAIL trusted ${detail}")
        ;;
      19)
        detail="root \"${subject[top]}\" was sent but is not in"$'\n'"${store}"
        checks+=("FAIL trusted ${detail}")
        ;;
      18)
        detail="certificate 0 is self-signed and not in"$'\n'"${store}"
        checks+=("FAIL trusted ${detail}")
        ;;
      10) checks+=("FAIL trusted a certificate has expired, see notAfter above") ;;
      '') checks+=("FAIL trusted openssl verify gave no result") ;;
      *) checks+=("FAIL trusted verify error ${vcode}: ${vtext}") ;;
    esac
  fi

  printf -v cont '\n%17s' ''  # continuation lines align with the detail column
  for entry in "${checks[@]}"; do
    status="${entry%% *}"
    rest="${entry#* }"
    name="${rest%% *}"
    detail="${rest#* }"
    case "${status}" in
      ok) colour="${green}" ;;
      warn) colour="${yellow}" ;;
      skip) colour="${dim}" ;;
      *) colour="${red}"; failed=1 ;;
    esac
    printf ' %s%-4s%s  %s%-8s%s  %s\n' "${colour}" "${status}" "${reset}" \
      "${bold}" "${name}" "${reset}" "${detail//$'\n'/${cont}}"
  done
  return "${failed}"
}

#######################################
# report_tls_chain with a blank line before and after, for use at the prompt.
# Arguments:
#   Passed through to report_tls_chain
# Returns:
#   The status of report_tls_chain
#######################################
check_tls_chain() {
  local status
  echo
  report_tls_chain "$@"
  status=$?
  echo
  return "${status}"
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
path_prepend "${HOME}/.cargo/bin"  # rustup's default CARGO_HOME
path_prepend "${HOME}/.local/bin"  # pipx, uv tool and friends
if [[ -d "${HOME}/.bun" ]]; then
  export BUN_INSTALL="${HOME}/.bun"
  path_prepend "${BUN_INSTALL}/bin"
fi
path_prepend "${HOME}/.antigravity/antigravity/bin"
path_prepend /opt/nanobrew/prefix/bin
path_prepend "${HOME}/bin"  # own scripts, last call so they win over the rest
export PATH

export EDITOR='vim'

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

# Machine-specific settings that should not live in the tracked dotfiles.
# Sourced before the prompt so that, for example, `export PL_ASCII=true` on a
# terminal without a Nerd Font takes effect when pureline loads below.
[[ -r "${HOME}/.bashrc.local" ]] && source "${HOME}/.bashrc.local"

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
add_ssh_keys
setup_gpg
unlock_gpg_keys

# Aliases. GNU ls takes --color, BSD ls (macOS) takes -G.
if ls --color=auto -d / &> /dev/null; then
  alias ll='ls -ahlF --color=auto'
else
  alias ll='ls -ahlFG'
fi
alias grep='grep --color=auto'
alias agrep='grep --color=auto --exclude-dir=.git -ri'
