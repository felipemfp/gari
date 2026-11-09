# gari Windows-side disk work. Same JSON-lines contract as gari.sh, category "vhdx".
#
#   vhdx.ps1 -Mode scan    -Distro Ubuntu               sizes, no admin needed
#   vhdx.ps1 -Mode compact -Distro Ubuntu -Log <file>   needs admin; shuts down WSL + Docker Desktop
#   vhdx.ps1 -Mode sparse  -Distro Ubuntu -Log <file>   one-time: future auto-shrink for the distro
#
# compact runs elevated (Start-Process -Verb RunAs), which has no stdout we can read,
# so it appends its events to -Log and the app tails that file.
param(
  [Parameter(Mandatory)][ValidateSet('scan', 'compact', 'sparse')][string]$Mode,
  [Parameter(Mandatory)][string]$Distro,
  [string]$Log,
  # compact: the vhdx paths the unelevated scan showed, one per line. An admin
  # account typed into UAC has its own HKCU/LOCALAPPDATA, so never rediscover here.
  [string]$List
)
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 turns any native stderr line into a terminating error
# under 'Stop' (wsl.exe warns on stderr routinely); judge by exit code instead.
function Invoke-Native([scriptblock]$cmd) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $cmd 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
}

function Out-Event($obj) {
  $line = $obj | ConvertTo-Json -Compress
  if ($Log) { Add-Content -LiteralPath $Log -Value $line -Encoding utf8 } else { Write-Output $line }
}
function Out-Log($msg) { Out-Event ([ordered]@{ event = 'log'; category = 'vhdx'; message = $msg }) }

function Get-DistroVhdx($name) {
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  foreach ($k in Get-ChildItem $lxss -ErrorAction SilentlyContinue) {
    $p = Get-ItemProperty $k.PSPath
    if ($p.DistributionName -eq $name) {
      $base = $p.BasePath -replace '^\\\\\?\\', ''
      $f = Join-Path $base 'ext4.vhdx'
      if (Test-Path -LiteralPath $f) { return $f }
    }
  }
}

function Get-DockerVhdx {
  foreach ($f in @("$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx",
                   "$env:LOCALAPPDATA\Docker\wsl\data\ext4.vhdx")) {
    if (Test-Path -LiteralPath $f) { return $f }
  }
}

function Get-Targets {
  $t = @()
  $d = Get-DistroVhdx $Distro
  if ($d) { $t += [ordered]@{ name = $Distro; path = $d } } else { Out-Log "no vhdx found for distro $Distro" }
  $k = Get-DockerVhdx
  if ($k) { $t += [ordered]@{ name = 'docker'; path = $k } }
  return $t
}

function Get-UsedBytes($name) {
  # Space actually used inside the virtual disk. Unknown for docker (its data disk
  # is not a distro root), so reclaimable is only estimated for the user distro.
  if ($name -eq 'docker') { return $null }
  $out = Invoke-Native { wsl.exe -d $name -- df -B1 --output=used / }
  if ($LASTEXITCODE -ne 0) { return $null }
  $n = 0L
  if ([int64]::TryParse((($out | Select-Object -Last 1) -replace '\s', ''), [ref]$n)) { return $n }
  return $null
}

function Test-Sparse($path) {
  # Optimize-VHD and diskpart refuse sparse disks ("must not be sparse"). A sparse
  # distro disk (Enable auto-shrink) already hands space back on its own.
  [bool]((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::SparseFile)
}

function Invoke-Scan {
  $total = 0; $count = 0
  foreach ($t in Get-Targets) {
    if (Test-Sparse $t.path) { Out-Log "$($t.path) is sparse (auto-shrink); skipping"; continue }
    $size = (Get-Item -LiteralPath $t.path).Length
    $used = Get-UsedBytes $t.name
    $reclaim = if ($null -ne $used -and $size -gt $used) { $size - $used } else { 0 }
    Out-Event ([ordered]@{ event = 'item'; category = 'vhdx'; path = $t.path; bytes = $reclaim; size = $size; used = $used })
    $total += $reclaim; $count++
  }
  Out-Event ([ordered]@{ event = 'done'; category = 'vhdx'; bytes = $total; count = $count })
}

function Stop-Docker {
  $procs = Get-Process -Name 'Docker Desktop', 'com.docker.backend', 'com.docker.build' -ErrorAction SilentlyContinue
  if ($procs) { Out-Log 'stopping Docker Desktop'; $procs | Stop-Process -Force; Start-Sleep -Seconds 3 }
  return [bool]$procs
}

function Compress-Vhdx($path) {
  if (Get-Command Optimize-VHD -ErrorAction SilentlyContinue) {
    Optimize-VHD -Path $path -Mode Full
    return
  }
  $script = New-TemporaryFile
  @("select vdisk file=`"$path`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk') |
    Set-Content -LiteralPath $script -Encoding ascii
  try {
    $out = Invoke-Native { diskpart.exe /s $script }
    if ($LASTEXITCODE -ne 0) { throw "diskpart failed: $($out -join ' ')" }
  } finally { Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue }
}

function Invoke-Compact {
  $paths = @()
  if ($List -and (Test-Path -LiteralPath $List)) {
    $paths = @(Get-Content -LiteralPath $List | ForEach-Object { [string]$_ } |
      Where-Object { $_ -and $_.EndsWith('.vhdx') -and (Test-Path -LiteralPath $_) })
    # Plain strings: Get-Content lines carry PSPath etc., which ConvertTo-Json would dump.
    $sparse = @($paths | Where-Object { Test-Sparse $_ })
    foreach ($p in $sparse) { Out-Log "$p is sparse (auto-shrink) and cannot be compacted; skipping" }
    $paths = @($paths | Where-Object { $sparse -notcontains $_ })
  }
  if (-not $paths) {
    Out-Log 'no scanned .vhdx files to compact; nothing was shut down'
    Out-Event ([ordered]@{ event = 'done'; category = 'vhdx'; bytes = 0; count = 0 })
    return
  }
  $hadDocker = $false
  $total = 0; $count = 0
  try {
    $hadDocker = Stop-Docker
    Out-Log 'wsl --shutdown'
    Invoke-Native { wsl.exe --shutdown } | Out-Null
    Start-Sleep -Seconds 2
    foreach ($p in $paths) {
      try {
        $before = (Get-Item -LiteralPath $p).Length
        Out-Log "compacting $p ($([math]::Round($before / 1GB, 1)) GB)"
        Compress-Vhdx $p
        $freed = [math]::Max(0, $before - (Get-Item -LiteralPath $p).Length)
        Out-Event ([ordered]@{ event = 'removed'; category = 'vhdx'; path = $p; bytes = $freed })
        $total += $freed; $count++
      } catch { Out-Log "failed on ${p}: $_" }
    }
  } finally {
    # Whatever happened above, Docker Desktop comes back if we stopped it.
    if ($hadDocker) {
      $exe = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
      if (Test-Path -LiteralPath $exe) { Out-Log 'restarting Docker Desktop'; Start-Process -FilePath $exe }
    }
  }
  Out-Event ([ordered]@{ event = 'done'; category = 'vhdx'; bytes = $total; count = $count })
}

function Invoke-Sparse {
  Invoke-Native { wsl.exe --shutdown } | Out-Null
  $out = Invoke-Native { wsl.exe --manage $Distro --set-sparse true }
  Out-Log (($out | Out-String).Replace("`0", '').Trim())
  if ($LASTEXITCODE -ne 0) { throw "wsl --set-sparse failed (exit $LASTEXITCODE)" }
  Out-Event ([ordered]@{ event = 'done'; category = 'vhdx'; bytes = 0; count = 0 })
}

try {
  switch ($Mode) {
    'scan' { Invoke-Scan }
    'compact' { Invoke-Compact }
    'sparse' { Invoke-Sparse }
  }
} catch {
  Out-Log "error: $_"
  Out-Event ([ordered]@{ event = 'done'; category = 'vhdx'; bytes = 0; count = 0; error = "$_" })
  exit 1
}
