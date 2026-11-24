<#
.SYNOPSIS
    Read-only inspector for GoogleUnlimited: what is uploading right now, and
    what is still waiting to be uploaded.

.DESCRIPTION
    The upload queue lives in the watcher process memory, so `GoogleUnlimited.bat
    status` cannot show it (it also only prints the last 10 successful uploads).
    This script answers the two practical questions directly:

      * which file is the watcher uploading at this moment, and how far through
        the current scan pass is it  (from the watcher heartbeat file)
      * which media files are still not in gphotos.db, grouped by watched folder
        (from a read-only disk scan compared against the database)

    Nothing is uploaded and nothing is written to the database, so it is safe to
    run at any time, with or without the watcher running.

.PARAMETER BasePath
    GoogleUnlimited folder. Defaults to the folder this script sits in.

.PARAMETER MaxList
    How many pending files to list. 0 lists everything. Default 40.

.PARAMETER Json
    Emit JSON instead of the text report.

.EXAMPLE
    .\QueueStatus.ps1

.EXAMPLE
    .\QueueStatus.ps1 -MaxList 0

.EXAMPLE
    .\QueueStatus.ps1 -Json | ConvertFrom-Json
#>
param(
    [string]$BasePath = $PSScriptRoot,
    [int]$MaxList = 40,
    [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($BasePath)) {
    $BasePath = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$BasePath = (Resolve-Path -LiteralPath $BasePath).Path

$dbFile    = Join-Path $BasePath "gphotos.db"
$stateFile = Join-Path $BasePath "watcher_state.json"
$dirsFile  = Join-Path $BasePath "watch_dirs.txt"

# Media whitelist - must match $script:EXT in WatchAndUpload.ps1, otherwise this
# report would disagree with what the watcher actually uploads.
$mediaExt = @(
    ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif", ".bmp", ".tiff", ".tif", ".avif",
    ".dng", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".rw2", ".pef", ".srw", ".raf", ".sr2",
    ".mp4", ".mov", ".mkv", ".avi", ".m4v", ".3gp", ".3g2", ".wmv", ".webm", ".mpg", ".mpeg",
    ".mts", ".m2ts", ".m2t", ".ts", ".asf", ".divx", ".mmv", ".mod", ".tod"
)

function Format-ByteSize([double]$bytes) {
    if ($bytes -ge 1GB) { return ("{0:0.0} GB" -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ("{0:0.0} MB" -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ("{0:0.0} KB" -f ($bytes / 1KB)) }
    return ("{0} B" -f [int]$bytes)
}

function Format-Duration([double]$seconds) {
    if ($seconds -le 0) { return "-" }
    $s = [int][Math]::Round($seconds)
    if ($s -lt 60) { return "${s}s" }
    if ($s -lt 3600) { return ("{0}m {1}s" -f [Math]::Floor($s / 60), ($s % 60)) }
    return ("{0}h {1}m" -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60))
}

# ---------------------------------------------------------------------
# 1. WATCHED FOLDERS (same resolution rules as the watcher)
# ---------------------------------------------------------------------
$watchDirs = New-Object 'System.Collections.Generic.List[string]'
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$candidates = @()

if ([System.IO.File]::Exists($dirsFile)) {
    foreach ($line in [System.IO.File]::ReadAllLines($dirsFile)) {
        $trimmed = $line.Trim()
        if ($trimmed -and -not $trimmed.StartsWith("#")) {
            $candidates += [Environment]::ExpandEnvironmentVariables($trimmed)
        }
    }
} else {
    $candidates = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures),
        (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) "Downloads")
    )
}

foreach ($cand in $candidates) {
    if ([string]::IsNullOrWhiteSpace($cand)) { continue }
    if (-not [System.IO.Directory]::Exists($cand)) { continue }
    $resolved = (Resolve-Path -LiteralPath $cand).Path
    if ($seen.Add($resolved)) { $watchDirs.Add($resolved) | Out-Null }
}

# ---------------------------------------------------------------------
# 2. WATCHER HEARTBEAT (written by the running watcher)
# ---------------------------------------------------------------------
$state = $null
if ([System.IO.File]::Exists($stateFile)) {
    try {
        $raw = [System.IO.File]::ReadAllText($stateFile)
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $state = $raw | ConvertFrom-Json }
    } catch { $state = $null }
}

$stateAge = -1
if ($state -and $state.updated_at) {
    try { $stateAge = [int]([DateTime]::Now - [DateTime]::Parse([string]$state.updated_at)).TotalSeconds } catch { $stateAge = -1 }
}

$pidAlive = $false
if ($state -and $state.pid) {
    $pidAlive = $null -ne (Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue)
}

# The instance mutex is the authoritative "is the watcher running" signal
$mutexHeld = $false
try {
    $cleanBase = $BasePath.ToLower().Replace("\", "_").Replace(":", "").Replace(" ", "_")
    $m = [System.Threading.Mutex]::OpenExisting("Local\GoogleUnlimited_Watcher_" + $cleanBase)
    if ($m) { $m.Dispose(); $mutexHeld = $true }
} catch { $mutexHeld = $false }

$watcherRunning = $mutexHeld -or ($pidAlive -and $stateAge -ge 0 -and $stateAge -le 300)

$current = $null
if ($watcherRunning -and $state -and $state.current_file) {
    $elapsed = -1
    if ($state.current_started) {
        try { $elapsed = [int]([DateTime]::Now - [DateTime]::Parse([string]$state.current_started)).TotalSeconds } catch {}
    }
    $current = [pscustomobject]@{
        File       = [string]$state.current_file
        Path       = [string]$state.current_path
        Size       = [long]$state.current_size
        Started    = [string]$state.current_started
        ElapsedSec = $elapsed
    }
}

$progress = $null
if ($watcherRunning -and $state -and [int]$state.total -gt 0) {
    $left = if ($null -ne $state.queue_remaining -and [int]$state.queue_remaining -ge 0) {
        [int]$state.queue_remaining
    } else {
        [Math]::Max(0, [int]$state.total - [int]$state.index)
    }
    $progress = [pscustomobject]@{
        Index     = [int]$state.index
        Total     = [int]$state.total
        Remaining = $left
        Phase     = [string]$state.phase
    }
}

# ---------------------------------------------------------------------
# 3. DATABASE (read-only)
# ---------------------------------------------------------------------
if (-not [System.IO.File]::Exists($dbFile)) {
    Write-Host "ERROR: database not found: $dbFile" -ForegroundColor Red
    exit 1
}

if (-not (Get-Module -Name PSSQLite)) {
    foreach ($mp in @(
        (Join-Path $BasePath "Modules\PSSQLite\PSSQLite.psd1"),
        (Join-Path $env:USERPROFILE "Documents\PowerShell\Modules\PSSQLite\PSSQLite.psd1"),
        (Join-Path $env:USERPROFILE "Documents\WindowsPowerShell\Modules\PSSQLite\PSSQLite.psd1")
    )) {
        if ([System.IO.File]::Exists($mp)) {
            Import-Module -Name $mp -ErrorAction Stop
            break
        }
    }
}
if (-not (Get-Command -Name Invoke-SqliteQuery -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: SQLite module (Modules\PSSQLite) could not be loaded." -ForegroundColor Red
    exit 1
}

$recordedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$recordedPairs = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$uploadedTotal = 0
$recentUploads = @()

try {
    $rows = Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT path, file_name, file_size FROM uploads"
    foreach ($r in $rows) {
        if ($r.path) { $null = $recordedPaths.Add([string]$r.path) }
        if ($r.file_name -and $r.file_size) { $null = $recordedPairs.Add("$($r.file_name)|$($r.file_size)") }
    }
    $uploadedTotal = $recordedPaths.Count
    $recentUploads = @(Invoke-SqliteQuery -DataSource $dbFile `
        -Query "SELECT path, uploaded_at FROM uploads ORDER BY uploaded_at DESC LIMIT 20")
} catch {
    Write-Host "WARN: could not read the uploads table: $_" -ForegroundColor Yellow
}

$retries = @()
$recentErrors = @()
try {
    $retries = @(Invoke-SqliteQuery -DataSource $dbFile -Query "SELECT path, attempts, last_attempt FROM retry_queue ORDER BY last_attempt DESC")
} catch {}
try {
    $recentErrors = @(Invoke-SqliteQuery -DataSource $dbFile `
        -Query "SELECT timestamp, level, message FROM logs WHERE level IN ('WARN','ERROR') ORDER BY id DESC LIMIT 5")
} catch {}

# Average upload interval from the most recent successes (used for the ETA)
# Gaps longer than 90s mean the watcher was idle/stopped in between, so they
# are discarded instead of inflating the estimate.
$avgSeconds = 0
if ($recentUploads.Count -ge 4) {
    $times = @()
    foreach ($u in $recentUploads) {
        if ($u.uploaded_at) {
            try { $times += [DateTime]::Parse([string]$u.uploaded_at) } catch {}
        }
    }
    $times = @($times | Sort-Object)
    $gaps = @()
    for ($k = 1; $k -lt $times.Count; $k++) {
        $gap = ($times[$k] - $times[$k - 1]).TotalSeconds
        if ($gap -gt 0 -and $gap -le 90) { $gaps += $gap }
    }
    if ($gaps.Count -ge 3) {
        $avgSeconds = ($gaps | Measure-Object -Average).Average
    }
}

# ---------------------------------------------------------------------
# 4. PENDING FILES (disk vs database, read-only)
# ---------------------------------------------------------------------
$pending = New-Object 'System.Collections.Generic.List[object]'
# The file being uploaded right now is not in the database yet - it belongs in
# the "Uploading Now" line, not in the waiting list.
$currentPath = if ($current) { [string]$current.Path } else { "" }
foreach ($dir in $watchDirs) {
    if (-not [System.IO.Directory]::Exists($dir)) { continue }
    try {
        $files = Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $mediaExt -contains $_.Extension.ToLower() }
        foreach ($f in $files) {
            if ($recordedPaths.Contains($f.FullName)) { continue }
            if ($currentPath -and $f.FullName.Equals($currentPath, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            # Same name+size already uploaded: compare content before reporting it
            if ($recordedPairs.Contains("$($f.Name)|$($f.Length)")) {
                $hash = $null
                try { $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLower() } catch {}
                if (-not $hash) { continue }
                $same = Invoke-SqliteQuery -DataSource $dbFile `
                    -Query "SELECT 1 FROM uploads WHERE content_hash = @h LIMIT 1" `
                    -SqlParameters @{ h = $hash }
                if ($same) { continue }
            }
            $pending.Add([pscustomobject]@{
                Path  = $f.FullName
                Name  = $f.Name
                Size  = [long]$f.Length
                Dir   = $dir
                MTime = $f.LastWriteTime
            })
        }
    } catch {}
}

$pendingBytes = 0.0
foreach ($p in $pending) { $pendingBytes += $p.Size }
$eta = if ($avgSeconds -gt 0) { $pending.Count * $avgSeconds } else { 0 }

# ---------------------------------------------------------------------
# 5. OUTPUT
# ---------------------------------------------------------------------
if ($Json) {
    $payload = [ordered]@{
        watcher_running  = $watcherRunning
        heartbt_age_sec  = $stateAge
        phase            = if ($watcherRunning -and $state) { [string]$state.phase } else { "" }
        pid              = if ($state) { [int]$state.pid } else { 0 }
        current          = $current
        progress         = $progress
        uploaded_total   = $uploadedTotal
        pending_total    = $pending.Count
        pending_bytes    = $pendingBytes
        avg_seconds_file = [Math]::Round($avgSeconds, 1)
        eta_seconds      = [Math]::Round($eta, 0)
        retries          = $retries
        pending          = $pending
    }
    $payload | ConvertTo-Json -Depth 5
    return
}

$line = "=========================================================="
Write-Host $line -ForegroundColor Cyan
Write-Host "  *  Google Photos Sync - Upload Queue Inspector" -ForegroundColor Green
Write-Host "  Database: $dbFile" -ForegroundColor Gray
Write-Host $line -ForegroundColor Cyan

if ($watchDirs.Count -eq 0) {
    Write-Host "  Watched Folders: NONE (watch_dirs.txt missing or empty)" -ForegroundColor Red
} else {
    Write-Host "  Watched Folders:" -ForegroundColor DarkCyan
    foreach ($d in $watchDirs) { Write-Host "    -> $d" -ForegroundColor Gray }
}

Write-Host ""
if ($watcherRunning) {
    $hb = if ($stateAge -ge 0) { "heartbeat ${stateAge}s ago" } else { "no heartbeat" }
    $pidText = if ($state -and $state.pid) { "pid $($state.pid)" } else { "pid unknown" }
    Write-Host "  Watcher      : RUNNING ($pidText, $hb)" -ForegroundColor Green
} else {
    Write-Host "  Watcher      : STOPPED - nothing will be uploaded until it is started" -ForegroundColor DarkGray
}

if ($current) {
    $elapsedText = if ($current.ElapsedSec -ge 0) { "$($current.ElapsedSec)s elapsed" } else { "started $($current.Started)" }
    Write-Host "  Uploading Now: $($current.File)  ($(Format-ByteSize $current.Size), $elapsedText)" -ForegroundColor Yellow
    Write-Host "                 $($current.Path)" -ForegroundColor DarkGray
} elseif ($watcherRunning) {
    $phaseText = if ($state -and [string]$state.phase -eq "scanning") { "scanning folders, first upload not started yet" } else { "idle, waiting for new files" }
    Write-Host "  Uploading Now: (none - $phaseText)" -ForegroundColor DarkGray
}

if ($progress) {
    Write-Host "  Progress     : $($progress.Index) / $($progress.Total) in this scan pass ($($progress.Remaining) left)" -ForegroundColor Gray
}

Write-Host ""
if ($pending.Count -eq 0) {
    Write-Host "  Pending      : 0 - everything in the watched folders is already uploaded." -ForegroundColor Green
} else {
    $etaText = if ($eta -gt 0) { "  ETA ~$(Format-Duration $eta) at $(Format-Duration $avgSeconds)/file" } else { "" }
    Write-Host "  Pending      : $($pending.Count) file(s), $(Format-ByteSize $pendingBytes)$etaText" -ForegroundColor Yellow

    foreach ($dir in $watchDirs) {
        $bucket = @($pending | Where-Object { $_.Dir -eq $dir })
        if ($bucket.Count -eq 0) { continue }
        $bucketBytes = 0.0
        foreach ($b in $bucket) { $bucketBytes += $b.Size }
        Write-Host ("    {0}  ->  {1} file(s), {2}" -f $dir, $bucket.Count, (Format-ByteSize $bucketBytes)) -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Waiting files (in queue order):" -ForegroundColor Cyan
    $limit = if ($MaxList -le 0) { $pending.Count } else { $MaxList }
    $i = 0
    foreach ($p in $pending) {
        if ($i -ge $limit) { break }
        $i++
        Write-Host ("   {0,4}. {1,10}  {2}" -f $i, (Format-ByteSize $p.Size), $p.Path) -ForegroundColor Gray
    }
    if ($pending.Count -gt $limit) {
        Write-Host "        ... and $($pending.Count - $limit) more (run with -MaxList 0 to list all)" -ForegroundColor DarkGray
    }
}

if ($retries.Count -gt 0) {
    Write-Host ""
    Write-Host "  Retry Queue  : $($retries.Count) file(s) failed earlier and will be retried" -ForegroundColor DarkYellow
    foreach ($r in $retries) {
        Write-Host "    $(Split-Path -Leaf $r.path) (attempt $($r.attempts), last $($r.last_attempt))" -ForegroundColor DarkYellow
    }
} else {
    Write-Host ""
    Write-Host "  Retry Queue  : empty" -ForegroundColor Green
}

if ($recentErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "  Recent Warnings / Errors:" -ForegroundColor DarkYellow
    foreach ($e in $recentErrors) {
        Write-Host "    [$($e.timestamp)] $([string]$e.message)" -ForegroundColor DarkYellow
    }
}

Write-Host ""
$lastText = if ($recentUploads.Count -gt 0) { "last success $($recentUploads[0].uploaded_at)" } else { "no uploads recorded yet" }
Write-Host "  Uploaded     : $uploadedTotal file(s) in database, $lastText" -ForegroundColor Gray
Write-Host $line -ForegroundColor Cyan
