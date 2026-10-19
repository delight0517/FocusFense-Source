# Quick check: force_installed policies present (delete button should be locked).
$extId = 'popjkofklmidngceakpcokopghehjngo'
$ok = 0
$fail = 0
foreach ($root in @(
    'HKCU:\SOFTWARE\Policies\Google\Chrome',
    'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
  )) {
  $fl = (Get-ItemProperty -LiteralPath (Join-Path $root 'ExtensionInstallForcelist') -ErrorAction SilentlyContinue).'1'
  $es = (Get-ItemProperty -LiteralPath $root -ErrorAction SilentlyContinue).ExtensionSettings
  if ($fl -match $extId -and $es -match 'force_installed') {
    Write-Host "[OK] $root forcelist+ExtensionSettings" -ForegroundColor Green
    $ok++
  } else {
    Write-Host "[FAIL] $root fl=$fl es=$($null -ne $es)" -ForegroundColor Red
    $fail++
  }
}
$ff = (Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Mozilla\Firefox' -ErrorAction SilentlyContinue).ExtensionSettings
if ($ff -match 'force_installed') {
  Write-Host '[OK] Firefox ExtensionSettings' -ForegroundColor Green
  $ok++
} else {
  Write-Host '[FAIL] Firefox ExtensionSettings' -ForegroundColor Red
  $fail++
}
$bl = Get-ItemProperty 'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist' -ErrorAction SilentlyContinue
$cnt = @($bl.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }).Count
$yt = ($bl.'23' -match 'youtube') -or ($cnt -gt 0)
Write-Host "[INFO] URLBlocklist entries=$cnt youtube_patterns=$yt"
exit $(if ($fail -eq 0) { 0 } else { 1 })
