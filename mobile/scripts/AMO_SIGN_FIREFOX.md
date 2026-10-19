# Firefox AMO signing (production)

Release Firefox only trusts Mozilla-signed extensions for `force_installed`.

1. Install Node.js if `npx` is not available.
2. Create an AMO API JWT at https://addons.mozilla.org/developers/addons/api/key/
3. Run the signing helper from the repo root:

```powershell
$env:AMO_JWT_ISSUER = "user:..."
$env:AMO_JWT_SECRET = "..."
powershell -NoProfile -ExecutionPolicy Bypass -File mobile\scripts\Sign-Firefox-AMO.ps1
```

The helper runs `web-ext sign --channel=unlisted`, then copies the newest
signed `.xpi` to:

`mobile/assets/browser_extensions/firefox/sixvpn_blocker_signed.xpi`

4. Rebuild the app. Windows setup automatically prefers the signed XPI.

Do not commit AMO credentials. Keep them in environment variables or pass them
only for the current signing command.
