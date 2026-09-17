# Desktop Release

## Required configuration

Configure the `NEXT_PUBLIC_SUPABASE_ANON_KEY` Actions secret in the
`Keco-Studio/keco-desktop` repository. The release workflow supplies this
public client key to Zig with `-Dsupabase-anon-key` so the desktop shell can
exchange a PKCE authorization code with Supabase.

In Supabase Auth URL Configuration, add this redirect URL pattern:

```text
http://127.0.0.1:*/auth/desktop/callback
```

This is an Auth dashboard configuration change, not a database migration.
Do not add a service-role key or any database credentials to this repository.

## Release workflow

Run `Release Desktop Apps` manually with a version without a leading `v`.
The first standalone release version is `0.1.0-desktop.8`. The workflow builds
and validates these assets before it publishes the GitHub release:

- `Keco-Studio-Setup-<version>-windows-x64.exe`
- `Keco-Studio-<version>-macos-x64.dmg`
- `Keco-Studio-<version>-macos-arm64.dmg`

## Installation and sign-in

Windows users run the setup executable once, then launch `keco-studio.exe`
from the installed shortcut or `E:\Keco Studio\bin\keco-studio.exe` when the
installer was directed to that location. macOS users open the DMG matching
their CPU architecture and move Keco Studio to Applications.

An existing WebView session opens Projects. Google sign-in opens the system
browser, returns through the local loopback callback, and then restores the
session in the running desktop window. Cancelled or failed sign-in returns to
the desktop login page with a retryable error.
