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
passphrase and keys the agent already lists, and runs `ssh-add` on the rest.

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
