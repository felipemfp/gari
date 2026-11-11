# gari Windows-side disk work. Same JSON-lines contract as gari.sh, category "vhdx".
#
#   vhdx.ps1 -Mode scan    -Distro Ubuntu                         sizes, no admin needed
#   vhdx.ps1 -Mode trim    -Distro Ubuntu -List <f> -Out <f>      no admin: fstrim inside the
#                                                                 distros, then write to -Out the
#                                                                 disks that still need compacting
#   vhdx.ps1 -Mode compact -Distro Ubuntu -List <f> -Log <file>   needs admin; shuts down WSL + Docker
#   vhdx.ps1 -Mode sparse  -Distro Ubuntu -Log <file>             one-time: future auto-shrink
#   vhdx.ps1 -Mode report  -Distro Ubuntu                         read-only disk report ("stat" events)
#
# Why trim first: a sparse vhdx (auto-shrink) only hands space back for blocks
# Linux discards, and online discard skips anything smaller than the 1 MB hole
# granularity, so a sparse disk still drifts above what it holds. fstrim sends
# the discards in bulk and needs no admin. What is left after that goes to
# compact, which for a sparse disk clears the sparse flag (Optimize-VHD refuses
# sparse files), compacts, and sets it again.
#
# Sizes: a sparse file's Length is its logical size, not what it takes on C:.
# Everything here measures the allocated size (GetCompressedFileSizeW).
#
# compact runs elevated (Start-Process -Verb RunAs), which has no stdout we can read,
# so it appends its events to -Log and the app tails that file.
param(
  [ValidateSet('scan', 'trim', 'compact', 'sparse', 'report', 'lib')][string]$Mode = 'lib',
  [string]$Distro = '',
  [string]$Log,
  # trim/compact: the vhdx paths the unelevated scan showed, one per line. An admin
  # account typed into UAC has its own HKCU/LOCALAPPDATA, so never rediscover there.
  [string]$List,
  # trim: where to write the paths that still need a full compaction.
  [string]$Out,
  # compact: skip sparse disks (used when the trim stage failed and never measured them).
  [switch]$NonSparseOnly
)
$ErrorActionPreference = 'Stop'

# A disk is worth a full compaction when its file holds this much more than the
# data inside it. Below that, shutting down WSL and Docker is not worth it.
$script:MinGap = 2GB
$script:MinGapRatio = 0.05
# Clearing the sparse flag fills the file's holes on C: before compaction can
# shrink it, so that much free space (plus this margin) must exist first.
$script:SparseMargin = 5GB

# Windows PowerShell 5.1 turns any native stderr line into a terminating error
# under 'Stop' (wsl.exe warns on stderr routinely); judge by exit code instead.
function Invoke-Native([scriptblock]$cmd) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $cmd 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
}

function Out-Event($obj) {
  $line = $obj | ConvertTo-Json -Compress -Depth 5
  if ($Log) { Add-Content -LiteralPath $Log -Value $line -Encoding utf8 } else { Write-Output $line }
}
function Out-Log($msg) { Out-Event ([ordered]@{ event = 'log'; category = 'vhdx'; message = $msg }) }

# ---- pure decisions (unit tested in CI by dot-sourcing with -Mode lib) -------

# Bytes compaction could return: what the file takes on disk minus what is in it.
function Get-Gap($allocated, $used) {
  if ($null -eq $used) { return $null }
  return [math]::Max([int64]0, [int64]$allocated - [int64]$used)
}

# Should this disk go through a full (disruptive, elevated) compaction?
# Unknown usage: a non-sparse disk never shrinks by itself, so yes; a sparse one
# already got its trim, so no.
function Test-NeedsCompact($allocated, $used, [bool]$sparse) {
  $gap = Get-Gap $allocated $used
  if ($null -eq $gap) { return -not $sparse }
  return ($gap -ge $script:MinGap) -and ($gap -ge [int64]$used * $script:MinGapRatio)
}

# Can a sparse disk be un-sparsed for compaction without filling C:?
# Un-sparsing allocates every hole: length - allocated bytes.
function Test-SparseRoom($length, $allocated, $free) {
  $holes = [math]::Max([int64]0, [int64]$length - [int64]$allocated)
  return [int64]$free -ge ($holes + $script:SparseMargin)
}

function ConvertFrom-Si([string]$s) {
  # docker prints SI sizes: 1.5GB, 12.3kB, 0B
  if ($s -notmatch '^\s*([\d.]+)\s*([kKMGT]?)B') { return 0 }
  # PowerShell hashtables ignore key case, so 'k' covers kB and KB.
  $mult = @{ '' = 1; 'k' = 1e3; 'M' = 1e6; 'G' = 1e9; 'T' = 1e12 }[$Matches[2]]
  return [int64]([double]$Matches[1] * $mult)
}

# ---- measuring ---------------------------------------------------------------

if (-not ('Gari.Native' -as [type])) {
  Add-Type -Namespace Gari -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern uint GetCompressedFileSizeW(string name, out uint high);
'@
}

# Bytes the file really takes on its volume (sparse holes excluded).
function Get-Allocated($path) {
  $high = [uint32]0
  $low = [Gari.Native]::GetCompressedFileSizeW($path, [ref]$high)
  if ($low -eq [uint32]::MaxValue -and [Runtime.InteropServices.Marshal]::GetLastWin32Error() -ne 0) {
    return (Get-Item -LiteralPath $path).Length
  }
  return ([int64]$high -shl 32) + $low
}

function Test-Sparse($path) {
  [bool]((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::SparseFile)
}

function Get-FreeBytes($path) {
  $root = [IO.Path]::GetPathRoot($path)
  return (New-Object IO.DriveInfo $root).AvailableFreeSpace
}

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
  if ($Distro) {
    $d = Get-DistroVhdx $Distro
    if ($d) { $t += [ordered]@{ name = $Distro; path = $d } } else { Out-Log "no vhdx found for distro $Distro" }
  }
  $k = Get-DockerVhdx
  if ($k) { $t += [ordered]@{ name = 'docker'; path = $k } }
  return $t
}

function Get-DockerExe {
  $c = Get-Command docker.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $f = "$env:ProgramFiles\Docker\Docker\resources\bin\docker.exe"
  if (Test-Path -LiteralPath $f) { return $f }
}

function Get-UsedBytes($name) {
  # Space actually used inside the virtual disk. For the user distro, df on its
  # root. Docker's data disk is not a distro root; `docker system df` totals are
  # the closest measure, and only while Docker Desktop runs.
  if ($name -eq 'docker') {
    $exe = Get-DockerExe
    if (-not $exe) { return $null }
    $out = Invoke-Native { & $exe system df --format '{{.Size}}' }
    if ($LASTEXITCODE -ne 0) { return $null }
    $sum = 0L
    foreach ($l in $out) { $sum += ConvertFrom-Si $l }
    return $sum
  }
  $out = Invoke-Native { wsl.exe -d $name -- df -B1 --output=used / }
  if ($LASTEXITCODE -ne 0) { return $null }
  $n = 0L
  if ([int64]::TryParse((($out | Select-Object -Last 1) -replace '\s', ''), [ref]$n)) { return $n }
  return $null
}

function Get-DiskInfo($t) {
  $len = (Get-Item -LiteralPath $t.path).Length
  $alloc = Get-Allocated $t.path
  [ordered]@{
    name = $t.name; path = $t.path; size = $len; allocated = $alloc
    used = Get-UsedBytes $t.name; sparse = Test-Sparse $t.path
  }
}

# ---- modes -------------------------------------------------------------------

function Invoke-Scan {
  $total = 0; $count = 0
  foreach ($t in Get-Targets) {
    $i = Get-DiskInfo $t
    $gap = Get-Gap $i.allocated $i.used
    $reclaim = if ($null -ne $gap) { $gap } else { 0 }
    if ($i.sparse) {
      Out-Log ("{0} is sparse (auto-shrink): {1:N1} GB on disk for {2} GB of data" -f $i.path, ($i.allocated / 1e9),
        $(if ($null -ne $i.used) { [math]::Round($i.used / 1e9, 1) } else { '?' }))
    }
    Out-Event ([ordered]@{ event = 'item'; category = 'vhdx'; path = $i.path; bytes = $reclaim
        size = $i.size; allocated = $i.allocated; used = $i.used; sparse = $i.sparse })
    $total += $reclaim; $count++
  }
  Out-Event ([ordered]@{ event = 'done'; category = 'vhdx'; bytes = $total; count = $count })
}

function Read-List {
  if (-not ($List -and (Test-Path -LiteralPath $List))) { return @() }
  # Plain strings: Get-Content lines carry PSPath etc., which ConvertTo-Json would dump.
  return @(Get-Content -LiteralPath $List | ForEach-Object { [string]$_ } |
    Where-Object { $_ -and $_.EndsWith('.vhdx') -and (Test-Path -LiteralPath $_) })
}

# Unelevated. Runs fstrim in the distro that owns each listed disk, reports what
# that returned, and writes the disks that still need compacting to -Out.
function Invoke-Trim {
  $paths = Read-List
  $targets = @(Get-Targets)
  $need = @()
  $total = 0; $count = 0
  foreach ($p in $paths) {
    $t = $targets | Where-Object { $_.path -eq $p } | Select-Object -First 1
    $name = if ($t) { $t.name } elseif ($p -like '*\Docker\*') { 'docker' } else { $Distro }
    $wslName = if ($name -eq 'docker') { 'docker-desktop' } else { $name }
    $before = Get-Allocated $p
    if (Test-Sparse $p) {
      # Only a sparse file shrinks from a trim; a non-sparse one waits for compact.
      Out-Log "fstrim in $wslName"
      $o = Invoke-Native { wsl.exe -d $wslName -u root -- fstrim -av }
      if ($LASTEXITCODE -ne 0) { Out-Log "fstrim in $wslName failed: $(($o | Out-String).Replace("`0", '').Trim())" }
      Start-Sleep -Seconds 2
      $freed = [math]::Max([int64]0, $before - (Get-Allocated $p))
      if ($freed -gt 0) {
        Out-Event ([ordered]@{ event = 'removed'; category = 'vhdx'; path = $p; bytes = $freed })
        $total += $freed; $count++
      }
    }
    $alloc = Get-Allocated $p
    $used = Get-UsedBytes $name
    $needs = Test-NeedsCompact $alloc $used (Test-Sparse $p)
    # No room to un-sparse means compact would refuse it: do not ask for admin for that.
    if ($needs -and (Test-Sparse $p) -and -not (Test-CanUnsparse $p)) { $needs = $false }
    if ($needs) {
      $need += $p
      $gap = Get-Gap $alloc $used
      Out-Log ("{0}: {1} still reclaimable, needs a full compaction" -f $p,
        $(if ($null -ne $gap) { "{0:N1} GB" -f ($gap / 1e9) } else { 'unknown amount' }))
    } else {
      Out-Log "${p}: trimmed, no full compaction needed"
    }
  }
  # No BOM: PS 5.1's -Encoding utf8 adds one, and an "empty" list must be empty.
  if ($Out) { [IO.File]::WriteAllText($Out, ($need -join "`n"), (New-Object Text.UTF8Encoding $false)) }
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

function Set-SparseFlag($path, [bool]$on) {
  $o = Invoke-Native { fsutil.exe sparse setflag $path $(if ($on) { 1 } else { 0 }) }
  if ($LASTEXITCODE -ne 0) { throw "fsutil sparse setflag failed: $(($o | Out-String).Trim())" }
}

# Room to un-sparse this disk right now (free space is read live, so a disk
# un-sparsed earlier in the same run counts against the next one).
function Test-CanUnsparse($p) {
  $len = (Get-Item -LiteralPath $p).Length
  $alloc = Get-Allocated $p
  $free = Get-FreeBytes $p
  if (Test-SparseRoom $len $alloc $free) { return $true }
  Out-Log ("{0} is sparse; compacting it needs {1:N1} GB free first and only {2:N1} GB is. Free space elsewhere and run again." -f
    $p, (([math]::Max([int64]0, $len - $alloc) + $script:SparseMargin) / 1e9), ($free / 1e9))
  return $false
}

function Invoke-Compact {
  $paths = Read-List
  if ($NonSparseOnly) {
    # Fallback after a failed trim: a sparse disk's gap was never measured, so
    # it is not worth un-sparsing blind.
    foreach ($p in @($paths | Where-Object { Test-Sparse $_ })) { Out-Log "${p}: sparse and not measured (trim failed); skipped" }
    $paths = @($paths | Where-Object { -not (Test-Sparse $_) })
  }
  # A sparse disk must be un-sparsed to compact, which first fills its holes.
  # Skip it, before anything is shut down, when C: has no room for that.
  $paths = @($paths | Where-Object { (-not (Test-Sparse $_)) -or (Test-CanUnsparse $_) })
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
    $sparseFailed = $false
    foreach ($p in $paths) {
      $wasSparse = Test-Sparse $p
      if ($wasSparse) {
        # A failed sparse compaction leaves its holes filled (re-sparsing only sets
        # the flag; the space comes back on the next trim). Never stack a second.
        if ($sparseFailed) { Out-Log "${p}: skipped, an earlier sparse compaction failed"; continue }
        if (-not (Test-CanUnsparse $p)) { continue }
      }
      $unsparsed = $false
      try {
        $before = Get-Allocated $p
        Out-Log ("compacting {0} ({1:N1} GB on disk{2})" -f $p, ($before / 1e9), $(if ($wasSparse) { ', sparse' } else { '' }))
        if ($wasSparse) { Set-SparseFlag $p $false; $unsparsed = $true }
        Compress-Vhdx $p
        $freed = [math]::Max([int64]0, $before - (Get-Allocated $p))
        Out-Event ([ordered]@{ event = 'removed'; category = 'vhdx'; path = $p; bytes = $freed })
        $total += $freed; $count++
      } catch {
        Out-Log "failed on ${p}: $_"
        if ($unsparsed) {
          $sparseFailed = $true
          Out-Log "${p}: its free space stays allocated on C: until the next trim; run Clean with Compact again once WSL is back"
        }
      } finally {
        # Auto-shrink stays on whatever happened.
        if ($wasSparse) {
          try { Set-SparseFlag $p $true } catch { Out-Log "could not turn auto-shrink back on for ${p}: $_ (re-enable it from gari)" }
        }
      }
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

# ---- report ------------------------------------------------------------------

function Out-Stat($section, $label, $bytes, $data) {
  Out-Event ([ordered]@{ event = 'stat'; category = 'report-win'; section = $section
      label = [string]$label; bytes = [int64]$bytes; data = $data })
}

# Cloud-only OneDrive files report their full Length but take nothing on disk.
$script:CloudOnly = 0x400000 -bor 0x40000 -bor 0x1000  # recall on data access | recall on open | offline

# One walk of the profile: totals per top folder, per AppData\Local|Roaming child,
# and every file over 500 MB. Junctions are not followed (AppData has loops).
function Measure-Profile($root) {
  $top = @{}; $app = @{}; $big = New-Object System.Collections.Generic.List[object]
  $stack = New-Object System.Collections.Generic.Stack[object]
  foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
    if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $stack.Push(@($d.FullName, $d.Name, $null))
  }
  $local = Join-Path $root 'AppData\Local'; $roaming = Join-Path $root 'AppData\Roaming'
  while ($stack.Count) {
    $dir, $topName, $appName = $stack.Pop()
    try {
      foreach ($e in ([IO.DirectoryInfo]$dir).EnumerateFileSystemInfos()) {
        if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($e -is [IO.DirectoryInfo]) {
          $an = $appName
          if ($dir -eq $local -or $dir -eq $roaming) { $an = $e.FullName }
          $stack.Push(@($e.FullName, $topName, $an))
          continue
        }
        if ([int]$e.Attributes -band $script:CloudOnly) { continue }
        $n = $e.Length
        $top[$topName] = [int64]$top[$topName] + $n
        if ($appName) { $app[$appName] = [int64]$app[$appName] + $n }
        # Virtual disks have their own section; listing them here double counts.
        if ($n -gt 500MB -and $e.Extension -ne '.vhdx') { $big.Add($e) }
      }
    } catch { }
  }
  return @{ top = $top; app = $app; big = $big }
}

function Get-FolderBytes($path) {
  if (-not (Test-Path -LiteralPath $path)) { return 0 }
  $sum = 0L
  try {
    foreach ($f in ([IO.DirectoryInfo]$path).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $sum += $f.Length }
  } catch { }
  return $sum
}

function Invoke-Report {
  foreach ($d in [IO.DriveInfo]::GetDrives()) {
    if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
    Out-Stat 'win-drive' $d.Name.TrimEnd('\') ($d.TotalSize - $d.TotalFreeSpace) ([ordered]@{ size = $d.TotalSize; free = $d.AvailableFreeSpace })
  }
  foreach ($t in Get-Targets) {
    $i = Get-DiskInfo $t
    Out-Stat 'vhdx' $i.name $i.allocated ([ordered]@{ path = $i.path; size = $i.size; used = $i.used; sparse = $i.sparse })
  }

  $m = Measure-Profile $env:USERPROFILE
  $m.top.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 |
    ForEach-Object { Out-Stat 'win-profile' $_.Key $_.Value $null }
  $m.app.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15 |
    ForEach-Object { Out-Stat 'win-appdata' ($_.Key.Substring($env:USERPROFILE.Length + 1)) $_.Value $null }
  $now = Get-Date
  $m.big | Sort-Object Length -Descending | Select-Object -First 20 | ForEach-Object {
    Out-Stat 'win-big' $_.FullName $_.Length ([ordered]@{ age_days = [int]($now - $_.LastWriteTime).TotalDays })
  }

  foreach ($p in @("$env:WINDIR\SoftwareDistribution\Download", $env:TEMP, "$env:WINDIR\Temp")) {
    Out-Stat 'win-system' $p (Get-FolderBytes $p) $null
  }

  $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  Get-ItemProperty $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
    Sort-Object { [int64]$_.EstimatedSize } -Descending | Select-Object -First 60 | ForEach-Object {
      Out-Stat 'win-programs' $_.DisplayName ([int64]$_.EstimatedSize * 1KB) ([ordered]@{
          installed = [string]$_.InstallDate; version = [string]$_.DisplayVersion; publisher = [string]$_.Publisher })
    }
  Out-Event ([ordered]@{ event = 'done'; category = 'report-win'; bytes = 0; count = 0 })
}

if ($Mode -eq 'lib') { return }   # dot-sourced for tests: functions only
try {
  switch ($Mode) {
    'scan' { Invoke-Scan }
    'trim' { Invoke-Trim }
    'compact' { Invoke-Compact }
    'sparse' { Invoke-Sparse }
    'report' { Invoke-Report }
  }
} catch {
  $cat = if ($Mode -eq 'report') { 'report-win' } else { 'vhdx' }
  Out-Event ([ordered]@{ event = 'log'; category = $cat; message = "error: $_" })
  Out-Event ([ordered]@{ event = 'done'; category = $cat; bytes = 0; count = 0; error = "$_" })
  exit 1
}
