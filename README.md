# Browse-CopilotChats

<!-- BADGES:START -->
[![License](https://img.shields.io/github/license/5a9awneh/Browse-CopilotChats)](LICENSE) [![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)](https://learn.microsoft.com/en-us/powershell/) [![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?logo=windows)](https://www.microsoft.com/windows) [![Last Commit](https://img.shields.io/github/last-commit/5a9awneh/Browse-CopilotChats)](https://github.com/5a9awneh/Browse-CopilotChats/commits/main) [![Human in the Loop](https://img.shields.io/badge/human--in--the--loop-%E2%9C%93-brightgreen?style=flat)](https://github.com/5a9awneh/Browse-CopilotChats)
<!-- BADGES:END -->

Browse, search, export, and recover VS Code Copilot chat history — including sessions orphaned when a project folder was renamed or moved.

---

## ✨ Features

- **Interactive browser** — lists every Copilot chat session across all workspaces, rendered inline with syntax-highlighted code blocks
- **Orphan detection** — flags workspaces whose folders no longer exist on disk, so nothing stays lost
- **Export all** — dump every session to a single dated Markdown file in one command
- **Extract** — export individual sessions from any workspace (active or orphaned) as readable `.md` files
- **Migrate** — reconnect orphaned chat history to a renamed/moved project folder; opens VS Code automatically if the new workspace hasn't been initialised yet
- No admin rights required — operates entirely within `%APPDATA%\Code\User\workspaceStorage`

---

## 📋 Requirements

- Windows 10 / 11
- PowerShell 5.1 or later (built-in)
- VS Code with the GitHub Copilot Chat extension

---

## 🚀 Usage

### Browse interactively

Double-click **`Browse-CopilotChats.bat`** or run from a terminal:

```powershell
.\Browse-CopilotChats.ps1
```

Navigate with number keys. From any chat detail view:

| Key | Action |
|-----|--------|
| `S` | Save session to a `.md` file |
| `C` | Copy full session to clipboard |
| `X` | Extract all sessions from that workspace |
| `M` | Migrate orphaned chat history to a new folder *(orphaned workspaces only)* |
| `B` | Back |

### Export everything to one file

```powershell
.\Browse-CopilotChats.ps1 -Export
.\Browse-CopilotChats.ps1 -Export -ExportPath "$env:USERPROFILE\Desktop\all-chats.md"
```

### Recover orphaned workspace chats (extract)

```powershell
.\Migrate-WorkspaceChats.ps1 -OldFolder "$env:USERPROFILE\Projects\ProjectName" -ExtractOnly
.\Migrate-WorkspaceChats.ps1 -OldHash "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4" -ExtractOnly -ExtractPath "$env:USERPROFILE\Desktop\RecoveredChats"
```

Exports each session as an individual `.md` file. Automatically adds the output folder to `.gitignore` if it's inside a Git repo.

### Migrate chats to a renamed/moved folder

```powershell
.\Migrate-WorkspaceChats.ps1 -OldFolder "$env:USERPROFILE\Projects\ProjectName" -NewFolder "$env:USERPROFILE\Projects\ProjectRenamed"
```

If VS Code hasn't been opened with the new folder yet, the script opens it automatically, waits for the workspace storage to initialise, then copies the chat data across.

---

## ⚙️ Parameters

### `Browse-CopilotChats.ps1`

| Parameter | Type | Description |
|-----------|------|-------------|
| `-Export` | Switch | Non-interactive mode — exports all sessions to a single Markdown file |
| `-ExportPath` | String | Custom output path. Defaults to `~\Desktop\CopilotChats_<date>.md` |

### `Migrate-WorkspaceChats.ps1`

| Parameter | Type | Description |
|-----------|------|-------------|
| `-OldFolder` | String | Original project folder path (before rename/move). Either this or `-OldHash` required |
| `-OldHash` | String | Workspace storage hash (32-char hex). Shown in Browse-CopilotChats when viewing orphaned workspaces |
| `-NewFolder` | String | Destination folder to migrate chat history into. Required unless `-ExtractOnly` |
| `-ExtractOnly` | Switch | Export sessions as Markdown files without touching workspace storage |
| `-ExtractPath` | String | Destination for extracted files. Defaults to `<NewFolder>\RecoveredChats\` or `Desktop\RecoveredChats_<date>\` |
| `-CloseAfterInit` | Switch | Close the VS Code window opened for hash initialisation |

---

## 🔧 How It Works

VS Code identifies each workspace by hashing its folder URI and using the hash as a storage directory name under `%APPDATA%\Code\User\workspaceStorage\`. Copilot chat sessions are stored as `.jsonl` files inside that directory. When a folder is renamed or moved, the hash changes and the old storage directory — along with all its chat history — becomes invisible to VS Code. This script finds those directories, reads the JSONL session files directly, and either extracts them as Markdown or copies them into the new workspace's storage directory.

---

## 🔀 Fork It, Extend It, Build On It

VS Code still has no built-in way to browse, recover, or migrate Copilot chat history. This tool fills that gap with plain PowerShell — no extension, no build step, no install.

The natural next step is a proper **VS Code extension**: a sidebar panel to browse sessions, one-click migration when a workspace is renamed, maybe even a "recover orphaned chats" prompt on startup. If you feel like building that, go for it — this repo is the reference implementation and the JSONL data model is all here for you to work with.

If you build on this, a shoutout or link back to the original repo is appreciated — not required, just good karma.

**Original repo:** https://github.com/5a9awneh/Browse-CopilotChats

---

## 📄 License

MIT — see [LICENSE](LICENSE).
