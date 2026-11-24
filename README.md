# dotfiles

Bash, git, vim, the prompt, and the terminal and editor settings I carry
between machines. Added two decades after everyone else.

## What is here

| Path | What it is |
| --- | --- |
| `.bashrc`, `.bash_profile` | Interactive shell: Homebrew, ssh-agent, gpg, history, PATH, aliases |
| `pureline`, `segments/`, `.pureline.conf` | The prompt: a pure-bash Powerline that renders without forking |
| `.gitconfig` | Git defaults. Host-specific settings go in `~/.gitconfig.local` |
| `.vimrc`, `.vim/` | Vim, with the badwolf colour scheme |
| `.config/ghostty/config` | Ghostty terminal |
| `.config/zed/` | Zed editor settings and keymap |
| `.claude/` | Claude Code: shared settings, the status line, and the script that syncs them |
| `install.sh` | Links all of the above into `$HOME` |
| `tests/` | Tests for the ssh-agent functions of `.bashrc` |

## Install

```
git clone git@github.com:patchon/dotfiles.git ~/dotfiles
~/dotfiles/install.sh
```

The script is safe to run again. Anything already in the way is moved to
`<name>.bak-<timestamp>`. `.bashrc` expects the repo at `~/dotfiles`.
`./install.sh --dry-run` shows what it would do, and `--no-claude` leaves
out everything under `.claude/` on machines that do not run Claude Code.

Then, per machine:

- **bash 4.3 or newer.** macOS ships 3.2. `brew install bash`, then
  `chsh -s /opt/homebrew/bin/bash`.
- **A Nerd Font** for the prompt glyphs, e.g. MesloLGS Nerd Font.
- **gpg on macOS.** `brew install gnupg pinentry-mac`. `.bashrc` points
  gpg-agent at pinentry-mac and records the gpg path in `~/.gitconfig.local`.
- **ssh.** `.bashrc` loads every passphrase-protected key in `~/.ssh` into the
  agent. On macOS the passphrases are stored in the keychain after the first
  prompt.
- **gpg.** `.bashrc` unlocks every passphrase-protected secret key the agent
  does not already hold, the same way it loads ssh keys, and sets the agent's
  cache to 400 days so an unlocked key survives until the agent is restarted.
  See below.
- **Claude Code.** `brew install jq`, then
  `.claude/scripts/sync-claude-settings.sh apply` merges the shared settings
  into `~/.claude/settings.json`. Add `--no-plugins` to leave the plugin
  marketplaces out. `export` copies changes made in Claude Code back into the
  repo, and `diff` shows what `apply` would change.

## Keys at shell start

`.bashrc` unlocks ssh and gpg keys the same way, next to each other at the
bottom of the file: look at what the agent already holds, and ask only for
what is missing.

For ssh that is `add_ssh_keys`, which walks `~/.ssh`, skips keys with no
passphrase and keys the agent already holds, and runs `ssh-add` on the rest.
On GNOME, `SSH_AUTH_SOCK` is gcr-ssh-agent, a wrapper that lists every key
with a `.pub` in `~/.ssh` whether it holds it or not and loads one through its
own dialog the first time ssh needs it. So the check asks the ssh-agent behind
the wrapper, on the sibling `.ssh` socket, and those keys are added at shell
start like everywhere else.

Only the desktop session is handed that `SSH_AUTH_SOCK`: gcr-ssh-agent runs
under the user's systemd, and a shell that sshd starts gets no agent at all.
`setup_ssh_agent` therefore looks for the gcr sockets under `XDG_RUNTIME_DIR`
before it starts a private agent, and picks the `.ssh` one, so that a key the
agent does not hold yet is asked for in the terminal and not in a dialog on a
screen the remote shell cannot see. Keys unlocked at the desk are then already
there when logging in over ssh, and the other way round.

A private agent that is already running comes first, before GNOME's. It was
started where there was no desktop to ask: after a boot and before anyone
signed in, when gcr-ssh-agent is not up yet. A tmux server started then, and
whatever runs in it, holds on to that agent, so a shell on the desktop joins it
rather than unlock the same key a second time in GNOME's agent, where what
started at boot would never see it. Where no private agent runs, nothing
changes. An agent that is neither of the two, a forwarded one or launchd's on
macOS, is kept whatever else runs.

An ssh-agent that is killed leaves its socket behind, and gcr-ssh-agent cannot
start another one while that file is there, though the wrapper itself goes on
answering. `wake_gcr_ssh_agent` notices a `.ssh` socket that nothing listens
on, removes it and asks the wrapper again, which starts a new agent; a shell
on the desktop does the same. If no agent comes back, the shell gets the
private one.

Shells that start at the same moment take turns at replacing a dead agent or
starting the private one: the second would otherwise remove the socket the
first had just put an agent on. `with_lock_on` does that with an `flock` on
the directory the socket is in, which leaves nothing behind, and a shell that
has waited ten seconds for it goes ahead anyway. Where there is no `flock`, as
on macOS, nothing is locked.

`tests/ssh_agent_test.sh` runs these cases against real agents, in a `HOME` of
their own under `/tmp`, and `tests/ssh_agent_test.sh together` only those whose
name has that word in it.

For gpg it is `unlock_gpg_keys`. There is no `ssh-add` for gpg: the agent
reads a private key only when some operation needs it, so the function makes
one up per key, a throwaway signature or a decrypt of something it just
encrypted, and discards the result. What it is really after is the side
effect, pinentry asking for the passphrase.

Two details are worth knowing when this misbehaves:

- gpg-agent caches the passphrase, not the key, and forgets it by default
  600 seconds after the last use. `setup_gpg` writes `default-cache-ttl` and
  `max-cache-ttl` of 400 days into `gpg-agent.conf`, under `GNUPGHOME` when
  that is set and `~/.gnupg` otherwise, so it behaves
  like ssh-agent, which never forgets. That file is only written when a value
  differs, because applying it reloads the agent and a reload flushes every
  cached passphrase.
- `gpg-connect-agent 'keyinfo --list' /bye` shows what the agent holds. The
  sixth field after the keygrip is 1 when the passphrase is cached and `-`
  when it is not, and the next one is `P` for a key behind a passphrase. A
  key can be usable while showing `-`: unlocking one key also lets its
  siblings through, without recording them under their own keygrip.

## Host-specific git settings

`.gitconfig` ends with `[include] path = ~/.gitconfig.local`, so that file
overrides anything in the shared config and is never committed. Typical
content:

```
[gpg]
  program = /usr/bin/gpg
[diff]
  tool = p4merge
[merge]
  tool = p4merge
[mergetool]
  prompt = false
  keepBackup = false
```

`git config --file` indents every entry it writes with a tab and has no
option for anything else, so `setup_gpg` re-indents the file with two spaces
afterwards, matching `.gitconfig`. It only rewrites a file that still holds a
leading tab, and only leading tabs are touched, so a tab inside a value such
as an alias survives.

## Prompt

Segment order and colours are the `PL_SEGMENTS` list in `.pureline.conf`.
`pureline theme list` shows the palettes, `pureline theme test NAME` tries
one in the current shell, and `pureline theme apply NAME` makes it the
default.

### Terminals without a Nerd Font

On a terminal that cannot draw the icons (PuTTY without a Nerd Font, a bare
Linux console), set `PL_ASCII=true` and the prompt falls back to plain-text
separators and symbols, keeping the same segments, colours and layout.
pureline turns this on by itself for the Linux console (`TERM=linux`) and for
non-UTF-8 locales; `PL_ASCII=false` forces the Nerd Font glyphs back on, and
`PL_ASCII=true` forces the plain set on.

Set it per machine in `~/.bashrc.local`, which `.bashrc` sources before the
prompt loads and which is never committed:

```
echo 'export PL_ASCII=true' >> ~/.bashrc.local
```

`~/.bashrc.local` is the shell counterpart of `~/.gitconfig.local`: the place
for host-specific settings that should not live in the tracked files.
