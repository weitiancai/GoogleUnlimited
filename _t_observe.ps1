# 观测重试 flush 的实际行为：每 30s 触发一次，但 Invoke-Upload 同步阻塞
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $Base 'Modules\PSSQLite\PSSQLite.psd1') -Force
$db = Join-Path $Base 'gphotos.db'

Write-Host '--- retry_queue 的 last_attempt 分布（是否在推进）---'
1..4 | ForEach-Object {
    $rows = Invoke-SqliteQuery -Database $db -Query 'SELECT path, attempts, last_attempt FROM retry_queue'
    $newest = ($rows | Sort-Object last_attempt -Descending | Select-Object -First 1).last_attempt
    $oldest = ($rows | Sort-Object last_attempt | Select-Object -First 1).last_attempt
    $attempts = ($rows | Group-Object attempts | ForEach-Object { "a$($_.Name)=$($_.Count)" }) -join ' '
    Write-Host ("  [{0}] count={1}  newest_attempt={2}  oldest={3}  {4}" -f (Get-Date -Format 'HH:mm:ss'), $rows.Count, $newest, $oldest, $attempts)
    Start-Sleep -Seconds 35
}
