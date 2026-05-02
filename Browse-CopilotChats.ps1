<#
.SYNOPSIS
    Browse all VS Code Copilot chat sessions across every workspace,
    including orphaned workspaces whose folders have been moved or deleted.

.DESCRIPTION
    Scans %APPDATA%\Code\User\workspaceStorage for chat session JSONL files,
    extracts titles and metadata, and presents an interactive menu.
    You can view any chat as rendered Markdown, export it, or copy to clipboard.

.PARAMETER Export
    Export all chats to a single Markdown file instead of interactive mode.

.PARAMETER ExportPath
    Path for the export file. Defaults to ~\Desktop\CopilotChats_<date>.md

.EXAMPLE
    .\Browse-CopilotChats.ps1
    .\Browse-CopilotChats.ps1 -Export
    .\Browse-CopilotChats.ps1 -Export -ExportPath "$env:USERPROFILE\Desktop\all-chats.md"
#>
[CmdletBinding()]
param(
    [switch]$Export,
    [string]$ExportPath
)

# ── Config ──────────────────────────────────────────────────────────────────
$StorageRoot = Join-Path $env:APPDATA 'Code\User\workspaceStorage'

if (-not (Test-Path $StorageRoot)) {
    Write-Host "VS Code workspace storage not found at: $StorageRoot" -ForegroundColor Red
    exit 1
}

# ── Helpers ─────────────────────────────────────────────────────────────────

function Get-WorkspaceFolder {
    param([string]$HashDir)
    $wsJson = Join-Path $HashDir 'workspace.json'
    if (-not (Test-Path $wsJson)) { return '(unknown)' }
    $ws = Get-Content $wsJson -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
    $uri = if ($ws.folder) { $ws.folder } elseif ($ws.configuration) { $ws.configuration } else { return '(unknown)' }
    $decoded = [uri]::UnescapeDataString(($uri -replace 'file:///', ''))
    return $decoded
}

function Get-ChatSessions {
    param([string]$ChatDir)
    $files = Get-ChildItem $ChatDir -Filter '*.jsonl' -ErrorAction SilentlyContinue
    if (-not $files) { return @() }

    $sessions = @()
    foreach ($f in $files) {
        $title = $null
        $creationDate = $null
        $sessionId = $null
        $requestCount = 0

        # Read lines to extract metadata
        $reader = [System.IO.StreamReader]::new($f.FullName)
        $lineNum = 0
        $countFromHeader = $false
        try {
            while (($line = $reader.ReadLine()) -ne $null -and $lineNum -lt 200) {
                $lineNum++
                $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                if (-not $obj) { continue }

                if ($obj.kind -eq 0) {
                    # Header line
                    $creationDate = $obj.v.creationDate
                    $sessionId = $obj.v.sessionId
                    if ($obj.v.requests) { $requestCount = $obj.v.requests.Count; $countFromHeader = $true }
                }
                elseif ($obj.kind -eq 1 -and $obj.k -eq 'customTitle') {
                    $title = $obj.v
                    break  # Found title, stop reading
                }
                elseif ($obj.kind -eq 2 -and -not $countFromHeader) {
                    # Only count individually if header didn't supply total
                    $requestCount++
                }
            }
        }
        finally { $reader.Close() }

        # Derive a title from first user message if no customTitle
        if (-not $title) {
            $reader2 = [System.IO.StreamReader]::new($f.FullName)
            try {
                while (($line2 = $reader2.ReadLine()) -ne $null) {
                    $obj2 = $line2 | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if (-not $obj2) { continue }
                    # Try header requests array
                    if ($obj2.kind -eq 0 -and $obj2.v.requests) {
                        foreach ($req in $obj2.v.requests) {
                            $msg = if ($req.message.text) { $req.message.text } elseif ($req.message -is [string]) { $req.message } else { $null }
                            if ($msg -and $msg.Length -gt 5) {
                                $title = $msg
                                break
                            }
                        }
                        if ($title) { break }
                    }
                    # Try kind=2 request records
                    if ($obj2.kind -eq 2) {
                        $msg2 = if ($obj2.v.message.text) { $obj2.v.message.text } elseif ($obj2.v.message -is [string]) { $obj2.v.message } else { $null }
                        if ($msg2 -and $msg2.Length -gt 5) {
                            $title = $msg2
                            break
                        }
                    }
                }
            }
            finally { $reader2.Close() }
            if ($title) {
                # Clean up: take first line, remove leading slash-commands, trim
                $title = ($title -split "`n")[0].Trim()
                $title = $title -replace '^\s*/\w+\s*', ''
                $title = $title -replace '#file:\S+', ''
                $title = $title.Trim()
                if ($title.Length -gt 80) { $title = $title.Substring(0, 80) + '...' }
            }
        }

        if (-not $title) { $title = '(untitled)' }

        # Convert JS timestamp
        $dateStr = ''
        if ($creationDate) {
            $dateStr = ([DateTimeOffset]::FromUnixTimeMilliseconds($creationDate)).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
        }

        $sessions += [PSCustomObject]@{
            Title     = $title
            Date      = $dateStr
            SizeKB    = [math]::Round($f.Length / 1KB)
            Exchanges = $requestCount
            File      = $f.FullName
            SessionId = $sessionId
        }
    }
    return @($sessions | Sort-Object Date -Descending)
}

function Read-ChatContent {
    param([string]$FilePath)
    $lines = Get-Content $FilePath
    $md = [System.Text.StringBuilder]::new()

    foreach ($line in $lines) {
        $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $obj) { continue }

        # kind=0: header
        if ($obj.kind -eq 0 -and $obj.v.requests) {
            foreach ($req in $obj.v.requests) {
                $msgText = if ($req.message.text) { $req.message.text } elseif ($req.message -is [string]) { $req.message } else { $null }
                if ($msgText) {
                    [void]$md.AppendLine("## User")
                    [void]$md.AppendLine($msgText)
                    [void]$md.AppendLine()
                }
                if ($req.response) {
                    foreach ($resp in $req.response) {
                        if ($resp.value) {
                            [void]$md.AppendLine("## Copilot")
                            [void]$md.AppendLine($resp.value)
                            [void]$md.AppendLine()
                        }
                    }
                }
            }
        }

        # kind=1 with inputState inputText (user messages logged incrementally)
        if ($obj.kind -eq 1 -and $obj.k -eq 'inputState inputText' -and $obj.v -and "$($obj.v)".Length -gt 5) {
            # These are captured in request records, skip duplicates
        }

        # kind=2: request/response pair
        if ($obj.kind -eq 2) {
            $msg2Text = if ($obj.v.message.text) { $obj.v.message.text } elseif ($obj.v.message -is [string]) { $obj.v.message } else { $null }
            if ($msg2Text) {
                [void]$md.AppendLine("## User")
                [void]$md.AppendLine($msg2Text)
                [void]$md.AppendLine()
            }
            if ($obj.v.response) {
                [void]$md.AppendLine("## Copilot")
                foreach ($part in $obj.v.response) {
                    if ($part.value) {
                        [void]$md.AppendLine($part.value)
                    }
                }
                [void]$md.AppendLine()
            }
        }
    }
    return $md.ToString()
}

# ── Scan ────────────────────────────────────────────────────────────────────
Write-Host "`n  Scanning VS Code workspace storage..." -ForegroundColor Cyan
$allWorkspaces = @()
$allChats = @()

$dirs = Get-ChildItem $StorageRoot -Directory
foreach ($d in $dirs) {
    $chatDir = Join-Path $d.FullName 'chatSessions'
    if (-not (Test-Path $chatDir)) { continue }

    $folder = Get-WorkspaceFolder $d.FullName
    $shortName = Split-Path $folder -Leaf
    $exists = if ($folder -ne '(unknown)') { Test-Path $folder } else { $false }
    $sessions = Get-ChatSessions $chatDir

    if ($sessions.Count -eq 0) { continue }

    $totalKB = ($sessions | Measure-Object -Property SizeKB -Sum).Sum

    $wsInfo = [PSCustomObject]@{
        Name     = $shortName
        Folder   = $folder
        Exists   = $exists
        Hash     = $d.Name
        Sessions = $sessions
        TotalKB  = $totalKB
    }
    $allWorkspaces += $wsInfo

    foreach ($s in $sessions) {
        $allChats += [PSCustomObject]@{
            Workspace = $shortName
            Orphaned  = -not $exists
            Hash      = $d.Name
            Folder    = $folder
            Title     = $s.Title
            Date      = $s.Date
            SizeKB    = $s.SizeKB
            Exchanges = $s.Exchanges
            File      = $s.File
        }
    }
}

$allChats = $allChats | Sort-Object Date -Descending

Write-Host "  Found $($allChats.Count) chat sessions across $($allWorkspaces.Count) workspaces.`n" -ForegroundColor Green

# ── Export Mode ─────────────────────────────────────────────────────────────
if ($Export) {
    if (-not $ExportPath) {
        $ExportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "CopilotChats_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# All Copilot Chat Sessions")
    [void]$sb.AppendLine("Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$sb.AppendLine("Total: $($allChats.Count) sessions from $($allWorkspaces.Count) workspaces")
    [void]$sb.AppendLine()

    $i = 0
    foreach ($chat in $allChats) {
        $i++
        $orphanTag = if ($chat.Orphaned) { ' [ORPHANED]' } else { '' }
        [void]$sb.AppendLine("---")
        [void]$sb.AppendLine("# Chat $i`: $($chat.Title)")
        [void]$sb.AppendLine("**Workspace:** $($chat.Workspace)$orphanTag | **Date:** $($chat.Date) | **Size:** $($chat.SizeKB)KB")
        [void]$sb.AppendLine()
        $content = Read-ChatContent $chat.File
        if ($content) { [void]$sb.AppendLine($content) }
        [void]$sb.AppendLine()
    }

    $sb.ToString() | Out-File $ExportPath -Encoding utf8
    Write-Host "Exported to: $ExportPath" -ForegroundColor Green
    Write-Host "File size: $([math]::Round((Get-Item $ExportPath).Length / 1MB, 1)) MB" -ForegroundColor Gray
    exit 0
}

# ── Interactive Mode ────────────────────────────────────────────────────────

function Show-WorkspaceList {
    Write-Host "`n  +==============================================================+" -ForegroundColor Cyan
    Write-Host "  |          VS Code Copilot Chat Browser                       |" -ForegroundColor Cyan
    Write-Host "  +==============================================================+`n" -ForegroundColor Cyan

    $i = 0
    foreach ($ws in ($allWorkspaces | Sort-Object { $_.Sessions[0].Date } -Descending)) {
        $i++
        $status = if ($ws.Exists) { '  ' } else { '! ' }
        $color = if ($ws.Exists) { 'White' } else { 'DarkYellow' }
        Write-Host "  [$i] " -NoNewline -ForegroundColor Yellow
        Write-Host "$status$($ws.Name)" -NoNewline -ForegroundColor $color
        $chatCount = @($ws.Sessions).Count
        Write-Host "  `($chatCount chats, $($ws.TotalKB)KB`)" -ForegroundColor DarkGray
    }

    Write-Host "`n  [A] " -NoNewline -ForegroundColor Yellow
    Write-Host "All chats (flat list sorted by date)" -ForegroundColor White
    Write-Host "  [E] " -NoNewline -ForegroundColor Yellow
    Write-Host "Export all to Markdown" -ForegroundColor White
    Write-Host "  [Q] " -NoNewline -ForegroundColor Yellow
    Write-Host "Quit" -ForegroundColor White
    Write-Host
}

function Show-ChatList {
    param([PSCustomObject[]]$Chats, [string]$Header)

    Write-Host "`n  $Header" -ForegroundColor Cyan
    Write-Host "  $('-' * $Header.Length)" -ForegroundColor DarkGray

    $i = 0
    foreach ($c in $Chats) {
        $i++
        $orphanTag = if ($c.Orphaned) { ' [orphaned]' } else { '' }
        Write-Host "  [$i] " -NoNewline -ForegroundColor Yellow
        Write-Host "$($c.Date)  " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($c.Title)" -NoNewline -ForegroundColor White
        Write-Host "  `($($c.SizeKB)KB`)$orphanTag" -ForegroundColor DarkGray
    }

    Write-Host "`n  [B] Back  [Q] Quit" -ForegroundColor DarkGray
    Write-Host
}

function Show-ChatDetail {
    param([PSCustomObject]$Chat)

    Write-Host "`n  Loading chat: $($Chat.Title)..." -ForegroundColor Cyan
    $content = Read-ChatContent $Chat.File

    if (-not $content -or $content.Trim().Length -eq 0) {
        Write-Host '  (Chat has no readable content -- may be stored in state.vscdb)' -ForegroundColor DarkYellow
        return
    }

    # Display with basic formatting
    $lines = $content -split "`n"
    foreach ($line in $lines) {
        if ($line -match '^## User') {
            Write-Host "`n  -- USER --------------------------------------------------" -ForegroundColor Green
        }
        elseif ($line -match '^## Copilot') {
            Write-Host "`n  -- COPILOT -----------------------------------------------" -ForegroundColor Cyan
        }
        elseif ($line -match '^```') {
            Write-Host "  $line" -ForegroundColor DarkYellow
        }
        else {
            Write-Host "  $line" -ForegroundColor Gray
        }
    }

    Write-Host "`n  -------------------------------------------------------------" -ForegroundColor DarkGray
    if ($Chat.Orphaned) {
        Write-Host "  [S] Save  [C] Copy  [X] Extract workspace  [M] Migrate to folder  [B] Back" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  [S] Save  [C] Copy  [X] Extract workspace  [B] Back" -ForegroundColor DarkGray
    }
    Write-Host

    $migratePath = Join-Path $PSScriptRoot 'Migrate-WorkspaceChats.ps1'

    while ($true) {
        $action = Read-Host '  Action'
        switch ($action.ToUpper()) {
            'S' {
                $safeName = ($Chat.Title -replace '[^\w\s-]', '' -replace '\s+', '_')
                if ($safeName.Length -gt 50) { $safeName = $safeName.Substring(0, 50) }
                $savePath = Join-Path ([Environment]::GetFolderPath('Desktop')) "$safeName.md"
                $content | Out-File $savePath -Encoding utf8
                Write-Host "  Saved to: $savePath" -ForegroundColor Green
                return
            }
            'C' {
                $content | Set-Clipboard
                Write-Host "  Copied to clipboard." -ForegroundColor Green
                return
            }
            'X' {
                $xPath = Read-Host '  Extract all workspace chats to folder (Enter for Desktop\RecoveredChats)'
                if (-not $xPath) { $xPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'RecoveredChats' }
                if (Test-Path $migratePath) {
                    & $migratePath -OldHash $Chat.Hash -ExtractOnly -ExtractPath $xPath
                }
                else {
                    Write-Host "  Migrate-WorkspaceChats.ps1 not found alongside this script." -ForegroundColor Red
                }
                return
            }
            'M' {
                if (-not $Chat.Orphaned) {
                    Write-Host "  Workspace folder still exists; use [X] to extract instead." -ForegroundColor DarkYellow
                    continue
                }
                $newDir = Read-Host '  Enter new project folder path'
                if (-not $newDir) { continue }
                if (Test-Path $migratePath) {
                    & $migratePath -OldHash $Chat.Hash -OldFolder $Chat.Folder -NewFolder $newDir
                }
                else {
                    Write-Host "  Migrate-WorkspaceChats.ps1 not found alongside this script." -ForegroundColor Red
                }
                return
            }
            'B' { return }
            'Q' { exit 0 }
        }
    }
}

# ── Main Loop ───────────────────────────────────────────────────────────────
$sortedWorkspaces = $allWorkspaces | Sort-Object { $_.Sessions[0].Date } -Descending

while ($true) {
    Show-WorkspaceList

    $choice = Read-Host '  Select'
    if (-not $choice) { continue }

    switch ($choice.ToUpper()) {
        'Q' { exit 0 }
        'A' {
            # Flat list of all chats
            while ($true) {
                Show-ChatList -Chats $allChats -Header "All Chats `($($allChats.Count) total`)"
                $pick = Read-Host '  Select chat #'
                if ($pick -eq 'B' -or $pick -eq 'b') { break }
                if ($pick -eq 'Q' -or $pick -eq 'q') { exit 0 }
                $idx = 0
                if ([int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $allChats.Count) {
                    Show-ChatDetail $allChats[$idx - 1]
                }
            }
        }
        'E' {
            $ePath = Join-Path ([Environment]::GetFolderPath('Desktop')) "CopilotChats_$(Get-Date -Format 'yyyyMMdd_HHmmss').md"
            Write-Host "`n  Exporting all chats..." -ForegroundColor Cyan
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("# All Copilot Chat Sessions")
            [void]$sb.AppendLine("Exported: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
            [void]$sb.AppendLine("Total: $($allChats.Count) sessions from $($allWorkspaces.Count) workspaces`n")
            $ci = 0
            foreach ($chat in $allChats) {
                $ci++
                $orphanTag = if ($chat.Orphaned) { ' [ORPHANED]' } else { '' }
                [void]$sb.AppendLine("---")
                [void]$sb.AppendLine("# Chat $ci`: $($chat.Title)")
                [void]$sb.AppendLine("**Workspace:** $($chat.Workspace)$orphanTag | **Date:** $($chat.Date) | **Size:** $($chat.SizeKB)KB`n")
                $content = Read-ChatContent $chat.File
                if ($content) { [void]$sb.AppendLine($content) }
                [void]$sb.AppendLine()
            }
            $sb.ToString() | Out-File $ePath -Encoding utf8
            Write-Host "  Exported to: $ePath" -ForegroundColor Green
            Write-Host "  File size: $([math]::Round((Get-Item $ePath).Length / 1MB, 1)) MB" -ForegroundColor Gray
            Write-Host "  Press Enter to continue..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
        default {
            $idx = 0
            if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $sortedWorkspaces.Count) {
                $ws = $sortedWorkspaces[$idx - 1]
                $wChats = $ws.Sessions | ForEach-Object {
                    [PSCustomObject]@{
                        Workspace = $ws.Name
                        Orphaned  = -not $ws.Exists
                        Hash      = $ws.Hash
                        Folder    = $ws.Folder
                        Title     = $_.Title
                        Date      = $_.Date
                        SizeKB    = $_.SizeKB
                        Exchanges = $_.Exchanges
                        File      = $_.File
                    }
                }
                while ($true) {
                    $statusTag = if ($ws.Exists) { '' } else { ' [ORPHANED]' }
                    Show-ChatList -Chats $wChats -Header "$($ws.Name)$statusTag `($($wChats.Count) chats`)"
                    $pick = Read-Host '  Select chat #'
                    if ($pick -eq 'B' -or $pick -eq 'b') { break }
                    if ($pick -eq 'Q' -or $pick -eq 'q') { exit 0 }
                    $cidx = 0
                    if ([int]::TryParse($pick, [ref]$cidx) -and $cidx -ge 1 -and $cidx -le $wChats.Count) {
                        Show-ChatDetail $wChats[$cidx - 1]
                    }
                }
            }
        }
    }
}
