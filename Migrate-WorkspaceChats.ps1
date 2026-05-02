#Requires -Version 5.1
<#
.SYNOPSIS
    Migrate or extract VS Code Copilot chat history when a project folder is renamed or moved.

.DESCRIPTION
    VS Code workspace storage folders are keyed by a hash of the folder URI. When a
    project folder is renamed or moved, the storage hash changes and chat history
    becomes orphaned. This script reconnects chat history to the new location by
    copying storage data between hash directories, or extracts sessions as readable
    Markdown files.

    If the new workspace hash does not exist yet (VS Code has not been opened with the
    new folder), the script opens VS Code automatically, polls until storage is
    initialised, then proceeds.

    Can be invoked directly or from the [M]/[X] options in Browse-CopilotChats.ps1.

.PARAMETER OldFolder
    The original project folder path (before rename or move).
    Provide either -OldFolder or -OldHash.

.PARAMETER OldHash
    The workspace storage hash directory name (32-character hex string).
    Visible in Browse-CopilotChats.ps1 when browsing orphaned workspaces.
    Provide either -OldFolder or -OldHash.

.PARAMETER NewFolder
    The destination project folder path to migrate chat history into.
    Required unless -ExtractOnly is specified.

.PARAMETER ExtractOnly
    Export all chat sessions from the old storage as readable Markdown files
    without modifying any workspace storage.

.PARAMETER ExtractPath
    Destination folder for extracted Markdown files.
    Defaults to <NewFolder>\RecoveredChats\, or Desktop\RecoveredChats_<date>\
    when -NewFolder is not provided.

.PARAMETER CloseAfterInit
    Close the VS Code window that was opened to initialise the new workspace hash.
    Useful for unattended/batch scenarios. Default is to leave VS Code open.

.EXAMPLE
    .\Migrate-WorkspaceChats.ps1 -OldFolder "$env:USERPROFILE\Projects\ProjectName" -NewFolder "$env:USERPROFILE\Projects\ProjectRenamed"

.EXAMPLE
    .\Migrate-WorkspaceChats.ps1 -OldHash "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4" -NewFolder "$env:USERPROFILE\Projects\ProjectRenamed"

.EXAMPLE
    .\Migrate-WorkspaceChats.ps1 -OldFolder "$env:USERPROFILE\Projects\ProjectName" -ExtractOnly

.EXAMPLE
    .\Migrate-WorkspaceChats.ps1 -OldFolder "$env:USERPROFILE\Projects\ProjectName" -ExtractOnly -ExtractPath "$env:USERPROFILE\Projects\ProjectRenamed\RecoveredChats"
#>
[CmdletBinding()]
param(
    [string]$OldFolder,
    [string]$OldHash,
    [string]$NewFolder,
    [switch]$ExtractOnly,
    [string]$ExtractPath,
    [switch]$CloseAfterInit
)

# ── Constants ────────────────────────────────────────────────────────────────
$StorageRoot = Join-Path $env:APPDATA 'Code\User\workspaceStorage'
$HashPollSecs = 30
$PollIntervalMs = 1000

# ── Validation ───────────────────────────────────────────────────────────────
if (-not (Test-Path $StorageRoot)) {
    Write-Host "VS Code workspace storage not found: $StorageRoot" -ForegroundColor Red
    exit 1
}
if (-not $OldFolder -and -not $OldHash) {
    Write-Host "Provide either -OldFolder or -OldHash." -ForegroundColor Red
    exit 1
}
if (-not $ExtractOnly -and -not $NewFolder) {
    Write-Host "Provide -NewFolder, or use -ExtractOnly to export chats without migrating." -ForegroundColor Red
    exit 1
}

# ── Helpers ──────────────────────────────────────────────────────────────────

function Get-DecodedFolderFromHashDir {
    param([string]$HashDir)
    $wsJson = Join-Path $HashDir 'workspace.json'
    if (-not (Test-Path $wsJson)) { return $null }
    try {
        $ws = Get-Content $wsJson -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $ws) { return $null }
        $uri = if ($ws.folder) { $ws.folder } elseif ($ws.configuration) { $ws.configuration } else { return $null }
        return [uri]::UnescapeDataString(($uri -replace 'file:///', ''))
    }
    catch { return $null }
}

function Find-HashByFolder {
    param([string]$FolderPath)
    $norm = $FolderPath.ToLower().TrimEnd('\', '/').Replace('\', '/')
    foreach ($d in Get-ChildItem $StorageRoot -Directory -ErrorAction SilentlyContinue) {
        $f = Get-DecodedFolderFromHashDir $d.FullName
        if ($f -and $f.ToLower().TrimEnd('\', '/').Replace('\', '/') -eq $norm) {
            return $d.Name
        }
    }
    return $null
}

function Get-ChatSessionFiles {
    param([string]$HashDir)
    $chatDir = Join-Path $HashDir 'chatSessions'
    if (-not (Test-Path $chatDir)) { return @() }
    return @(Get-ChildItem $chatDir -Filter '*.jsonl' -ErrorAction SilentlyContinue)
}

function Get-ChatTitle {
    param([string]$FilePath)
    $title = $null
    $reader = [System.IO.StreamReader]::new($FilePath)
    try {
        $n = 0
        while (($line = $reader.ReadLine()) -ne $null -and $n -lt 100) {
            $n++
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $obj) { continue }
            if ($obj.kind -eq 1 -and $obj.k -eq 'customTitle') { $title = $obj.v; break }
            if ($obj.kind -eq 0 -and $obj.v.requests) {
                foreach ($req in $obj.v.requests) {
                    $msg = if ($req.message.text) { $req.message.text }
                    elseif ($req.message -is [string]) { $req.message }
                    else { $null }
                    if ($msg -and $msg.Length -gt 5) { $title = $msg; break }
                }
                if ($title) { break }
            }
            if ($obj.kind -eq 2) {
                $msg2 = if ($obj.v.message.text) { $obj.v.message.text }
                elseif ($obj.v.message -is [string]) { $obj.v.message }
                else { $null }
                if ($msg2 -and $msg2.Length -gt 5) { $title = $msg2; break }
            }
        }
    }
    finally { $reader.Close() }

    if (-not $title) { return '(untitled)' }
    $title = ($title -split "`n")[0].Trim() -replace '^\s*/\w+\s*', '' -replace '#file:\S+', ''
    $title = $title.Trim()
    if ($title.Length -gt 60) { $title = $title.Substring(0, 60) }
    return $title
}

function Read-SessionAsMarkdown {
    param([string]$FilePath)
    $md = [System.Text.StringBuilder]::new()
    foreach ($line in (Get-Content $FilePath -ErrorAction SilentlyContinue)) {
        $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $obj) { continue }
        if ($obj.kind -eq 0 -and $obj.v.requests) {
            foreach ($req in $obj.v.requests) {
                $msg = if ($req.message.text) { $req.message.text }
                elseif ($req.message -is [string]) { $req.message }
                else { $null }
                if ($msg) { [void]$md.AppendLine("## User`n$msg`n") }
                if ($req.response) {
                    [void]$md.AppendLine('## Copilot')
                    foreach ($r in $req.response) { if ($r.value) { [void]$md.AppendLine($r.value) } }
                    [void]$md.AppendLine()
                }
            }
        }
        if ($obj.kind -eq 2) {
            $msg2 = if ($obj.v.message.text) { $obj.v.message.text }
            elseif ($obj.v.message -is [string]) { $obj.v.message }
            else { $null }
            if ($msg2) { [void]$md.AppendLine("## User`n$msg2`n") }
            if ($obj.v.response) {
                [void]$md.AppendLine('## Copilot')
                foreach ($part in $obj.v.response) { if ($part.value) { [void]$md.AppendLine($part.value) } }
                [void]$md.AppendLine()
            }
        }
    }
    return $md.ToString()
}

function Add-ToGitignore {
    param([string]$DestPath)
    $root = $DestPath
    $gitRoot = $null
    while ($root -and $root -ne (Split-Path $root -Parent)) {
        if (Test-Path (Join-Path $root '.git')) { $gitRoot = $root; break }
        $root = Split-Path $root -Parent
    }
    if (-not $gitRoot) { return }

    $gitignore = Join-Path $gitRoot '.gitignore'
    $relPath = $DestPath.Substring($gitRoot.Length).TrimStart('\', '/').Replace('\', '/') + '/'
    $existing = if (Test-Path $gitignore) { Get-Content $gitignore -ErrorAction SilentlyContinue } else { @() }
    if ($existing -contains $relPath) { return }

    "`n# Recovered chat extracts`n$relPath" | Add-Content $gitignore
    Write-Host "  Added '$relPath' to .gitignore" -ForegroundColor DarkGray
}

function Invoke-Extract {
    param([string]$OldHashDir, [string]$DestPath)
    $files = Get-ChatSessionFiles $OldHashDir
    if ($files.Count -eq 0) {
        Write-Host "  No chat sessions found in storage." -ForegroundColor DarkYellow
        return
    }
    if (-not (Test-Path $DestPath)) {
        New-Item -ItemType Directory -Path $DestPath -Force | Out-Null
    }
    Write-Host "  Extracting $($files.Count) session(s) to: $DestPath" -ForegroundColor Cyan
    $n = 0
    foreach ($f in $files) {
        $title = Get-ChatTitle $f.FullName
        $safe = ($title -replace '[^\w\s\-]', '' -replace '\s+', '_').Trim()
        if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
        if (-not $safe) { $safe = $f.BaseName }
        $outPath = Join-Path $DestPath "$safe.md"
        $i = 1
        while (Test-Path $outPath) { $outPath = Join-Path $DestPath "${safe}_$i.md"; $i++ }
        $content = Read-SessionAsMarkdown $f.FullName
        if ($content.Trim()) {
            $content | Out-File $outPath -Encoding utf8
            $n++
            Write-Host "  + $([System.IO.Path]::GetFileName($outPath))" -ForegroundColor DarkGray
        }
    }
    Write-Host "  Exported $n file(s)." -ForegroundColor Green
    Add-ToGitignore -DestPath $DestPath
}

function Invoke-Migrate {
    param([string]$OldHashDir, [string]$NewHashDir)
    foreach ($dir in @('chatSessions', 'chatEditingSessions', 'GitHub.copilot-chat')) {
        $src = Join-Path $OldHashDir $dir
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $NewHashDir $dir) -Recurse -Force
            Write-Host "  Copied $dir" -ForegroundColor DarkGray
        }
    }
    foreach ($file in @('state.vscdb', 'state.vscdb.backup')) {
        $src = Join-Path $OldHashDir $file
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $NewHashDir $file) -Force
            Write-Host "  Copied $file" -ForegroundColor DarkGray
        }
    }
}

function Open-VSCodeAndWaitForHash {
    param([string]$FolderPath)
    $codeCmd = Get-Command 'code' -ErrorAction SilentlyContinue
    if (-not $codeCmd) {
        Write-Host "  'code' is not in PATH. Open VS Code manually with:" -ForegroundColor DarkYellow
        Write-Host "    code `"$FolderPath`"" -ForegroundColor White
        Write-Host "  Wait for it to fully load, then re-run this script." -ForegroundColor DarkYellow
        return $null
    }

    Write-Host "  Opening VS Code to initialise workspace storage..." -ForegroundColor Cyan
    $beforeIds = @(Get-Process 'Code' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    Start-Process $env:ComSpec -ArgumentList "/c `"`"$($codeCmd.Source)`" `"$FolderPath`"`"" -WindowStyle Hidden

    Write-Host "  Polling for workspace hash (timeout: ${HashPollSecs}s)..." -ForegroundColor DarkGray
    $elapsed = 0
    $hash = $null
    while ($elapsed -lt $HashPollSecs -and -not $hash) {
        Start-Sleep -Milliseconds $PollIntervalMs
        $elapsed += ($PollIntervalMs / 1000)
        $hash = Find-HashByFolder $FolderPath
    }

    if (-not $hash) {
        Write-Host "  Timed out waiting for VS Code to create the workspace hash." -ForegroundColor Red
        Write-Host "  Ensure VS Code fully loads the folder, then re-run." -ForegroundColor DarkYellow
        return $null
    }

    Write-Host "  Hash initialised: $hash" -ForegroundColor Green

    if ($CloseAfterInit) {
        $newIds = @(Get-Process 'Code' -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -notin $beforeIds } |
            Select-Object -ExpandProperty Id)
        foreach ($id in $newIds) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        if ($newIds.Count -gt 0) { Write-Host "  VS Code closed (-CloseAfterInit)." -ForegroundColor DarkGray }
    }

    return $hash
}

# ── Header ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '  VS Code Chat Migration' -ForegroundColor Cyan
Write-Host '  ─────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

# ── Resolve old hash ─────────────────────────────────────────────────────────
$resolvedOldHash = $null

if ($OldHash) {
    $resolvedOldHash = $OldHash
    Write-Host "  Old hash (provided): $resolvedOldHash" -ForegroundColor White
}
else {
    Write-Host "  Locating storage hash for: $OldFolder" -ForegroundColor DarkGray
    $resolvedOldHash = Find-HashByFolder $OldFolder
    if (-not $resolvedOldHash) {
        Write-Host "  No workspace storage found for: $OldFolder" -ForegroundColor Red
        Write-Host "  VS Code may never have been opened with this folder path." -ForegroundColor DarkYellow
        exit 1
    }
    Write-Host "  Old hash: $resolvedOldHash" -ForegroundColor White
}

$oldHashDir = Join-Path $StorageRoot $resolvedOldHash
if (-not (Test-Path $oldHashDir)) {
    Write-Host "  Storage directory not found: $oldHashDir" -ForegroundColor Red
    exit 1
}

$chatFiles = Get-ChatSessionFiles $oldHashDir
if ($chatFiles.Count -eq 0) {
    Write-Host "  No chat sessions found in old storage. Nothing to do." -ForegroundColor DarkYellow
    exit 0
}
Write-Host "  Found $($chatFiles.Count) chat session(s)." -ForegroundColor Green

# ── Extract-only path ────────────────────────────────────────────────────────
if ($ExtractOnly) {
    if (-not $ExtractPath) {
        $ExtractPath = if ($NewFolder) {
            Join-Path $NewFolder 'RecoveredChats'
        }
        else {
            Join-Path ([Environment]::GetFolderPath('Desktop')) "RecoveredChats_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        }
    }
    Write-Host ''
    Invoke-Extract -OldHashDir $oldHashDir -DestPath $ExtractPath
    Write-Host ''
    Write-Host '  Done.' -ForegroundColor Green
    exit 0
}

# ── Resolve new hash ─────────────────────────────────────────────────────────
Write-Host "  Target folder: $NewFolder" -ForegroundColor White

if (-not (Test-Path $NewFolder)) {
    Write-Host ''
    Write-Host "  Target folder does not exist." -ForegroundColor DarkYellow
    $ans = Read-Host "  Create '$NewFolder'? [Y/N]"
    if ($ans -notmatch '^[Yy]') { Write-Host '  Aborted.' -ForegroundColor Red; exit 1 }
    New-Item -ItemType Directory -Path $NewFolder -Force | Out-Null
    Write-Host "  Created: $NewFolder" -ForegroundColor Green
}

Write-Host "  Searching for new workspace hash..." -ForegroundColor DarkGray
$resolvedNewHash = Find-HashByFolder $NewFolder

if (-not $resolvedNewHash) {
    Write-Host "  No workspace hash found for new folder — opening VS Code to initialise." -ForegroundColor DarkYellow
    Write-Host ''
    $resolvedNewHash = Open-VSCodeAndWaitForHash -FolderPath $NewFolder
    if (-not $resolvedNewHash) { exit 1 }
}
else {
    Write-Host "  New hash: $resolvedNewHash" -ForegroundColor White
}

$newHashDir = Join-Path $StorageRoot $resolvedNewHash

# ── Confirm and migrate ──────────────────────────────────────────────────────
Write-Host ''
Write-Host '  Ready to migrate:' -ForegroundColor Cyan
Write-Host "    From : $resolvedOldHash" -ForegroundColor DarkGray
Write-Host "    To   : $resolvedNewHash" -ForegroundColor DarkGray
Write-Host "    Chats: $($chatFiles.Count)" -ForegroundColor DarkGray
Write-Host ''
$confirm = Read-Host '  Proceed? [Y/N]'
if ($confirm -notmatch '^[Yy]') { Write-Host '  Aborted.' -ForegroundColor DarkYellow; exit 0 }

Write-Host ''
Invoke-Migrate -OldHashDir $oldHashDir -NewHashDir $newHashDir

Write-Host ''
Write-Host '  Migration complete.' -ForegroundColor Green
Write-Host "  Open VS Code with: $NewFolder" -ForegroundColor White
Write-Host '  Chat history should appear in the Copilot panel.' -ForegroundColor DarkGray
Write-Host ''
