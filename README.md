![Multigravity](assets/multigravity-logo.jpg)

# Multigravity

**Run multiple Antigravity IDE profiles simultaneously — each with its own accounts, extensions, and settings.**

No more logging in and out. Launch as many profiles as you need, all at once.

[![GitHub repository](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/sujitagarwal/multigravity-cli)
[![GitHub profile](https://img.shields.io/badge/GitHub-Profile-lightgrey?logo=github)](https://github.com/sujitagarwal)
[![GitHub stars](https://img.shields.io/github/stars/sujitagarwal/multigravity-cli?style=social)](https://github.com/sujitagarwal/multigravity-cli/stargazers)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#install)

---

## Install

**macOS / Linux**

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sujitagarwal/multigravity-cli/main/install.sh)"
```

**Windows** — open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/sujitagarwal/multigravity-cli/main/install.ps1 | iex
```

---

## Quick Start

```bash
# Create profiles
multigravity new work
multigravity new personal

# 1. Launch in Antigravity IDE (VS Code-like IDE, default)
multigravity work
multigravity work .
multigravity work path/to/project

# 2. Launch in Antigravity 2.0 desktop app
multigravity work --app
# or
multigravity app work

# 3. Launch agy CLI in terminal (no GUI app)
multigravity agy work
# or
multigravity work --cli
# or (Windows wrapper)
agy-profile work
```

Each profile gets an automatic clickable launcher:

| Platform | Location | Launches |
|----------|----------|----------|
| macOS    | `~/Applications/Multigravity <name>.app` | Antigravity IDE |
| Windows  | Start Menu → Programs | Antigravity IDE |
| Linux    | `~/.local/share/applications/multigravity-<name>.desktop` | Antigravity IDE |

---

## Commands

### Profile Management & Launching

| Command | Description |
|---------|-------------|
| `multigravity new <name>` | Create a new full profile |
| `multigravity new <name> --shared` | Create a lightweight profile (shared extensions & settings, isolated accounts) |
| `multigravity new <name> --from <template>` | Create a profile from a saved template |
| `multigravity <name> [args]` | **Launch in Antigravity IDE** (VS Code-like IDE, default) |
| `multigravity <name> --app [args]` | **Launch in Antigravity 2.0 app** |
| `multigravity app <name> [args]` | Alias to launch in Antigravity 2.0 app |
| `multigravity agy <name> [args]` | **Launch agy CLI in terminal** (isolated credentials & history) |
| `multigravity <name> --cli [args]` | Alias to launch agy CLI in terminal |
| `multigravity list` | List all profiles |
| `multigravity status` | Show running state, type, last used, and size per profile |
| `multigravity clone <src> <dest>` | Copy an existing profile |
| `multigravity rename <old> <new>` | Rename a profile |
| `multigravity delete <name>` | Delete a profile and all its data |

### Templates

| Command | Description |
|---------|-------------|
| `multigravity template save <profile> <name>` | Save a profile as a reusable template |
| `multigravity template list` | List saved templates |
| `multigravity template delete <name>` | Remove a template |

### Backup & Transfer

| Command | Description |
|---------|-------------|
| `multigravity export <name> [path]` | Archive a profile to `.tar.gz` (`.zip` on Windows) |
| `multigravity import <archive> [name]` | Restore a profile from an archive |

### Utilities

| Command | Description |
|---------|-------------|
| `multigravity stats` | Show disk usage per profile |
| `multigravity doctor` | Diagnose your environment |
| `multigravity update` | Update Multigravity to the latest version |
| `multigravity completion` | Set up shell tab-completion |
| `multigravity help` | Show help |

---

## Shared Profiles

Full profiles are fully isolated — separate extensions, settings, and accounts. That's the default.

**Shared profiles** go lighter: they symlink extensions and settings from your main Antigravity install, isolating only the account/auth layer. Useful when you need a second account but don't want to duplicate gigabytes of extensions.

```bash
multigravity new client-x --shared
```

---

## Templates

Save a configured profile as a template, then spin up new profiles from it instantly:

```bash
# Save your ideal setup as a template
multigravity template save work base

# Create new profiles from it
multigravity new project-a --from base
multigravity new project-b --from base

# See what templates you have
multigravity template list
```

---

## Terminal `agy` Sessions

When you want to work purely in your terminal with isolated `agy` accounts/history (without opening the desktop GUI):

```bash
# Launch agy in current terminal
multigravity agy work
# or
multigravity work --cli
```

### Direct `agy <profile>` shell integration

If you'd like to type `agy <profile-name>` directly in your terminal to launch a profile:

**PowerShell (`notepad $PROFILE`):**
```powershell
function agy {
    param([Parameter(ValueFromRemainingArguments = $true)]$args)
    $base = if ($env:MULTIGRAVITY_HOME) { $env:MULTIGRAVITY_HOME } else { "$env:USERPROFILE\AntigravityProfiles" }
    if ($args.Count -gt 0 -and (Test-Path "$base\$($args[0])")) {
        multigravity agy @args
    } else {
        & (Get-Command agy.exe -CommandType Application | Select-Object -First 1 -ExpandProperty Source) @args
    }
}
```

**macOS / Linux (`~/.zshrc` or `~/.bashrc`):**
```bash
agy() {
  local base="${MULTIGRAVITY_HOME:-$HOME/AntigravityProfiles}"
  if [ -n "${1-}" ] && [ -d "$base/$1" ]; then
    multigravity agy "$@"
  else
    command agy "$@"
  fi
}
```

Now `agy work` starts the isolated `work` profile in your terminal, while normal commands like `agy --help` or `agy -c` work as usual.

---

## Environment Configuration

You can override executable locations or storage paths via environment variables:

| Variable | Description |
|----------|-------------|
| `MULTIGRAVITY_IDE` | Override Antigravity IDE (VS Code-like) executable path |
| `MULTIGRAVITY_APP` | Override Antigravity 2.0 app executable path |
| `MULTIGRAVITY_AGY` | Override `agy` CLI binary path |
| `MULTIGRAVITY_HOME` | Override profile storage root (default: `~/AntigravityProfiles`) |

---

## Shell Completion

Enable tab-completion for commands and profile names:

```bash
multigravity completion
```

Follow the instructions to add it to your `.zshrc`, `.bashrc`, or PowerShell `$PROFILE`.

---

## Uninstall

**macOS / Linux**

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sujitagarwal/multigravity-cli/main/uninstall.sh)"
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/sujitagarwal/multigravity-cli/main/uninstall.ps1 | iex
```

You'll be asked whether to remove your profile data — nothing is deleted without confirmation.

---

## Profile Name Rules

Letters, numbers, and hyphens only. Must start with a letter or number.

```
✅  work   client-a   test1
❌  -name  my_profile
```

---

## Credits

- **Windows support** — [Samin Yeasar](https://github.com/Solez-ai)
- **Linux support** — [Md Rayyan Nawaz](https://github.com/therayyanawaz)
