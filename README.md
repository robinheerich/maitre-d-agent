# Maître d'Agént

*Every patron is named Claude. Maître d'Agént knows which one needs you.*

A small macOS menu-bar app for anyone running several Claude Code sessions in parallel. It shows them all in one panel, grouped by repo, with one status each: **needs you**, **working** or **idle**. It also shows the messages agents send each other.

<p align="center">
  <img src="docs/screenshot.png" width="340" alt="Maître d'Agént panel: agents grouped by repo with status, lead star and message counts">
  &nbsp;&nbsp;
  <img src="docs/screenshot-pretentious.png" width="340" alt="The same panel in pretentious mode">
</p>

## Features

- **Status at a glance**: orange means a session is waiting on you (permission prompt, question, plan approval), blue means it's working, grey means idle. The menu bar shows how many need you and how many are working.
- **Grouping**: sessions are grouped by git repo automatically, and worktrees join their main repo. Make your own groups and drag agents between them.
- **Manual order**: drag agents and groups into the order you want. The order survives restarts.
- **Lead agents**: if one agent per project coordinates the others, mark it as lead. It moves to the top with a ★ and the rest of its group fades slightly. Agents that need you never fade.
- **Agent-to-agent messages**: each agent shows how many `SendMessage` messages it sent and received in the last 24h (↑ sent ↓ received). A feed lists them; click one for the full text.
- **Jump to the session**: click an agent to bring its VS Code window forward and open its Claude tab.
- **Notifications** when an agent starts needing you.
- **Pin** the panel to keep it floating on top, or let it drop down from the menu bar.
- **Pretentious mode**: the same app, narrated by a French maître d'. Patrons wave, dine and digest, and pass notes between tables. Toggle it in the ⋯ menu.

## Requirements

- macOS 14 or later
- Apple's Command Line Tools (`xcode-select --install`). Full Xcode isn't needed.
- [Claude Code](https://claude.com/claude-code). Clicking an agent jumps to it in VS Code with the Claude Code extension; everything else works with sessions from any terminal too.

## Install

```sh
git clone https://github.com/robinheerich/maitre-d-agent.git
cd maitre-d-agent
./scripts/install.sh
```

This builds the app, copies it to `~/Applications/MaitreDAgent.app`, installs the Claude Code hooks and launches it. Because it's built on your own Mac, macOS doesn't show a Gatekeeper warning.

**The installer edits `~/.claude/settings.json`.** It adds hooks that run `~/.maitre-d-agent/hook.sh`, and it first saves a backup as `settings.json.maitre-d-agent-backup-<timestamp>`. Sessions that were already running may need a restart before they use the new hooks.

To update, `git pull` and run `./scripts/install.sh` again. To remove the app, its hooks and its data, run `./scripts/uninstall.sh`.

## How it works

Everything is read from local files. The app makes no network requests.

| What | Where it comes from |
|---|---|
| Running sessions, names, working/idle | `~/.claude/sessions/<pid>.json`, the session registry Claude Code maintains |
| Needs you | Marker files written by `~/.maitre-d-agent/hook.sh` on `PermissionRequest`, `AskUserQuestion` and `ExitPlanMode`, and removed when the session continues. Also the registry's `waiting` status. |
| Messages | `SendMessage` tool calls in the session transcripts, `~/.claude/projects/*/<session>.jsonl` |
| Groups | The git common dir of each session's working directory |

Your groups, leads, order and settings are stored in `~/.maitre-d-agent/config.json`. Leads and order are keyed by repo plus session name, so they carry over when you restart or resume a session. Giving agents names (`/rename`) makes this work best.

**Caveat:** the session registry is an undocumented Claude Code internal. If an update changes it, parsing lives in one file, [`Sources.swift`](Sources/MaitreDAgent/Sources.swift).

## Usage

- Click the menu bar icon to open the panel, and 📌 to pin it.
- Click an agent to jump to it. Right-click for lead, groups, Finder and session ID.
- Drag agents onto other agents or group headers to reorder or regroup them. Drag group headers to reorder groups, or use right-click → Move Up/Down.
- In the ⋯ menu: notifications, exact-tab jumping, launch at login, pretentious mode, and installing or removing hooks.

## Development

```sh
swift build                                        # debug build
.build/debug/MaitreDAgent --dump                   # print current sessions and recent messages
.build/debug/MaitreDAgent --snapshot out.png --dark            # render the panel with live data
.build/debug/MaitreDAgent --snapshot out.png --demo --dark     # render with demo data (README screenshots)
.build/debug/MaitreDAgent --install-hooks          # or --uninstall-hooks
```

All user-facing wording, plain and pretentious, lives in [`Copy.swift`](Sources/MaitreDAgent/Copy.swift).

## License

[MIT](LICENSE).

Maître d'Agént is an independent project and is not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.
