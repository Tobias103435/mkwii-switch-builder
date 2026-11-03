# unpack.ps1 - the first-run step of MKWii-Builder.cmd: takes the base64 payload
# out of the .cmd that is running, writes it as a zip, and unpacks the tooling
# into the folder that holds the .cmd. ASCII only; runs on the PowerShell that
# ships with Windows 10/11, no modules beyond the .NET compression types.
$ErrorActionPreference = 'Stop'
# Progress and Write-Host records become CLIXML noise when the caller redirects
# stdout (the tests do that), so every line goes through the real console stream.
function Say([string]$text) { [Console]::WriteLine($text) }
$ProgressPreference = 'SilentlyContinue'
# The calling batch sets MKW_SRC / MKW_ROOT / MKW_MARK before running this:
# -EncodedCommand accepts no extra arguments ("a command is already specified"),
# so environment is the only usable way to pass paths.
$src = $env:MKW_SRC
$root = $env:MKW_ROOT
$mark = $env:MKW_MARK
if (-not $src -or -not $root -or -not $mark) {
  Say '  this script only runs from MKWii-Builder.cmd (MKW_SRC/MKW_ROOT/MKW_MARK are not set)'
  exit 1
}
$beginLine = 'rem ==== ' + $mark + ' ===='
$endLine = 'rem ==== ' + $mark + '-END ===='
$lines = [IO.File]::ReadAllText($src) -split "`r?`n"
$start = [Array]::IndexOf($lines, $beginLine)
$stop = [Array]::IndexOf($lines, $endLine)
if ($start -lt 0 -or $stop -lt 0 -or $stop -le $start) {
  Say '  payload markers not found in this file - is it the complete builder?'
  exit 1
}
$b64 = ($lines[($start + 1)..($stop - 1)] | ForEach-Object { $_ -replace '^rem ', '' }) -join ''
try {
  $bytes = [Convert]::FromBase64String($b64)
} catch {
  Say '  the embedded package is damaged (it did not decode); take a fresh copy of the file'
  exit 1
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipPath = Join-Path $env:TEMP ('mkw-builder-' + [Guid]::NewGuid().ToString('N') + '.zip')
$work = Join-Path $env:TEMP ('mkw-builder-' + [Guid]::NewGuid().ToString('N'))
[IO.File]::WriteAllBytes($zipPath, $bytes)
try {
  [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $work)
  $inner = Join-Path $work 'WiiCompiled-Switch-builder'
  if (-not (Test-Path $inner)) { $inner = $work }
  Copy-Item -Path (Join-Path $inner '*') -Destination $root -Recurse -Force
  $count = (Get-ChildItem -Path $inner -Recurse -File).Count
  Say ('  unpacked ' + $count + ' tooling files into ' + $root)
} catch {
  Say ('  unpacking failed: ' + $_.Exception.Message)
  exit 1
} finally {
  Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
  Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
