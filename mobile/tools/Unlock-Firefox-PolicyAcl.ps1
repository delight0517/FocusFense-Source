$ErrorActionPreference = 'Continue'

param(
  [string] $TargetSid = ''
)

$sid = if ($TargetSid) {
  $TargetSid
} else {
  [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
$targetRel = 'SOFTWARE\Policies\Mozilla\Firefox'
$target = "Registry::HKEY_USERS\$sid\$targetRel"
$log = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\firefox_acl_unlock.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

function L($m) {
  $line = "$(Get-Date -Format o) $m"
  Add-Content -Path $log -Value $line
  Write-Output $line
}

L "Firefox ACL unlock start sid=$sid target=$target"

if (-not (Test-Path -LiteralPath $target)) {
  New-Item -Path $target -Force | Out-Null
}

try {
  $acl = Get-Acl -LiteralPath $target
  $acl.SetOwner([System.Security.Principal.NTAccount]'Administrators')
  Set-Acl -LiteralPath $target -AclObject $acl
  L 'owner set to Administrators'
} catch {
  L "owner set failed: $($_.Exception.Message)"
}

try {
  $acl = Get-Acl -LiteralPath $target
  $user = New-Object System.Security.Principal.SecurityIdentifier($sid)
  $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
    $user,
    'FullControl',
    'ContainerInherit,ObjectInherit',
    'None',
    'Allow'
  )
  $acl.SetAccessRule($rule)
  Set-Acl -LiteralPath $target -AclObject $acl
  L "FullControl granted to $user"
} catch {
  L "grant failed: $($_.Exception.Message)"
}

try {
  Set-ItemProperty -LiteralPath $target -Name '_SixVPNProbe' -Value 'ok' -Type String -Force -ErrorAction Stop
  Remove-ItemProperty -LiteralPath $target -Name '_SixVPNProbe' -Force -ErrorAction SilentlyContinue
  L 'probe write OK'
  exit 0
} catch {
  L "probe write failed: $($_.Exception.Message)"
  exit 1
}
