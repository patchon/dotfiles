# dotfiles

Bash, git, vim, the prompt, and the terminal and editor settings I carry
between machines. Added two decades after everyone else.

## What is here

| Path | What it is |
| --- | --- |
| `.bashrc`, `.bash_profile` | Interactive shell: Homebrew, ssh-agent, gpg, history, PATH, aliases |
| `pureline`, `segments/`, `.pureline.conf` | The prompt: a pure-bash Powerline that renders without forking |
| `.config/starship.toml` | The starship theme the prompt is modelled on |
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
`./install.sh --dry-run` shows what it would do.

Then, per machine:

- **bash 4.3 or newer.** macOS ships 3.2. `brew install bash`, then
  `chsh -s /opt/homebrew/bin/bash`.
- **A Nerd Font** for the prompt glyphs, e.g. MesloLGS Nerd Font.
- **gpg on macOS.** `brew install gnupg pinentry-mac`. `.bashrc` points
  gpg-agent at pinentry-mac and records the gpg path in `~/.gitconfig.local`.
- **ssh.** `.bashrc` loads `~/.ssh/id_ed25519` into the agent. On macOS the
  passphrase is stored in the keychain after the first prompt.
- **Claude Code.** `brew install jq`, then
  `.claude/scripts/sync-claude-settings.sh apply` merges the shared settings
  into `~/.claude/settings.json`. Add `--no-plugins` to leave the plugin
  marketplaces out. `export` copies changes made in Claude Code back into the
  repo, and `diff` shows what `apply` would change.

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

## Prompt

Segment order and colours are the `PL_SEGMENTS` list in `.pureline.conf`.
`pureline theme list` shows the palettes, `pureline theme test NAME` tries
one in the current shell, and `pureline theme apply NAME` makes it the
default.
