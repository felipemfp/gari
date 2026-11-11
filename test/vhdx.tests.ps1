# Unit tests for the pure decisions in scripts/vhdx.ps1, under Windows PowerShell 5.1
# (what the app runs). No Pester dependency: plain asserts, exit 1 on the first failure.
#   powershell -NoProfile -ExecutionPolicy Bypass -File test\vhdx.tests.ps1
# Failure modes covered before the code was written:
#   - a sparse disk with a big gap left alone (the "auto-shrink is on but C: stays full" bug)
#   - a tiny gap triggering a WSL + Docker shutdown for nothing
#   - un-sparsing a disk when C: cannot hold its holes (fills the drive)
#   - Length used instead of the allocated size of a sparse file
#   - docker SI sizes misparsed
$ErrorActionPreference = 'Stop'
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\..\scripts\vhdx.ps1", [ref]$null, [ref]$errs)
if ($errs) { $errs | ForEach-Object { $_.ToString() }; exit 1 }
. "$PSScriptRoot\..\scripts\vhdx.ps1" -Mode lib

$failed = 0
function Check($name, $actual, $expected) {
  if ($actual -ne $expected) { Write-Output "FAIL $name : got '$actual', expected '$expected'"; $script:failed++ }
  else { Write-Output "ok   $name" }
}

# The case from the field: sparse, 160.7 GB on disk, 146 GB inside.
Check 'sparse disk with 14.7 GB slack needs compaction' (Test-NeedsCompact 160.7GB 146GB $true) $true
Check 'sparse disk within 2 GB of its data is left alone' (Test-NeedsCompact 147GB 146GB $true) $false
Check 'gap under 5% of a big disk is left alone' (Test-NeedsCompact 505GB 500GB $false) $false
Check 'gap over both thresholds compacts' (Test-NeedsCompact 73GB 34GB $false) $true
Check 'unknown usage: non-sparse compacts (never shrinks alone)' (Test-NeedsCompact 73GB $null $false) $true
Check 'unknown usage: sparse is left to its trim' (Test-NeedsCompact 73GB $null $true) $false
Check 'gap never negative' (Get-Gap 10GB 12GB) 0
Check 'gap unknown without usage' ($null -eq (Get-Gap 10GB $null)) $true

# Un-sparsing materialises length - allocated bytes; margin 5 GB.
Check 'room: 8.4 GB holes, 99 GB free' (Test-SparseRoom 169.1GB 160.7GB 99GB) $true
Check 'no room: 8.4 GB holes, 9 GB free' (Test-SparseRoom 169.1GB 160.7GB 9GB) $false
Check 'room needs holes + margin exactly' (Test-SparseRoom 20GB 10GB 15GB) $true

Check 'si 1.099GB' (ConvertFrom-Si '1.099GB') 1099000000
Check 'si 12.3kB' (ConvertFrom-Si '12.3kB') 12300
Check 'si 0B' (ConvertFrom-Si '0B') 0
Check 'si garbage' (ConvertFrom-Si 'N/A') 0

# Allocated size of a real sparse file is below its length.
$f = Join-Path ([IO.Path]::GetTempPath()) "gari-sparse-$PID.bin"
try {
  New-Item -ItemType File -Path $f -Force | Out-Null
  fsutil sparse setflag $f | Out-Null
  $fs = [IO.File]::Open($f, 'Open', 'ReadWrite'); $fs.SetLength(64MB); $fs.Close()
  Check 'sparse file is detected' (Test-Sparse $f) $true
  Check 'allocated size ignores holes' ((Get-Allocated $f) -lt 1MB) $true
  Check 'length still reports 64 MB' ((Get-Item $f).Length) 64MB
} finally { Remove-Item $f -ErrorAction SilentlyContinue }

# Compact guards, end to end. Both must stop before Docker or WSL is touched.
function Invoke-CompactLog($list, [switch]$NonSparse) {
  $log = Join-Path ([IO.Path]::GetTempPath()) "gari-c-$PID.log"
  Remove-Item $log -ErrorAction SilentlyContinue
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$PSScriptRoot\..\scripts\vhdx.ps1",
    '-Mode', 'compact', '-Distro', 'NoSuchDistro', '-Log', $log, '-List', $list)
  if ($NonSparse) { $a += '-NonSparseOnly' }
  & powershell.exe @a | Out-Null
  $t = Get-Content -Raw $log; Remove-Item $log -ErrorAction SilentlyContinue
  return $t
}
$tmp = [IO.Path]::GetTempPath()
$vhd = Join-Path $tmp "gari-$PID.vhdx"; $lst = Join-Path $tmp "gari-$PID.txt"
try {
  New-Item -ItemType File -Path $vhd -Force | Out-Null
  fsutil sparse setflag $vhd | Out-Null
  # 15 TB of holes (NTFS caps a file near 16 TB): no drive has room to un-sparse that.
  $fs = [IO.File]::Open($vhd, 'Open', 'ReadWrite'); $fs.SetLength(15TB); $fs.Close()
  Set-Content -LiteralPath $lst -Value $vhd
  $t = Invoke-CompactLog $lst
  Check 'no room to un-sparse: says why' ($t -match 'needs .* GB free first') $true
  Check 'no room to un-sparse: nothing shut down' ($t -match 'nothing was shut down') $true
  $t = Invoke-CompactLog $lst -NonSparse
  Check 'trim failed: unmeasured sparse disk skipped' ($t -match 'not measured \(trim failed\); skipped') $true
  Check 'trim failed: nothing shut down' ($t -match 'nothing was shut down') $true
  Check 'sparse flag untouched' (Test-Sparse $vhd) $true
} finally { Remove-Item $vhd, $lst -ErrorAction SilentlyContinue }

if ($failed) { Write-Output "$failed failed"; exit 1 }
Write-Output 'all passed'
