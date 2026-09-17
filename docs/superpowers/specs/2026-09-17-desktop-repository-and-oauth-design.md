# Keco Desktop Repository and OAuth Design

## Goal

Move the Keco Studio desktop shell, platform packaging, release process, and
desktop-specific tests from `Keco-Studio/keco-studio` into the standalone
`Keco-Studio/keco-desktop` repository. Add Google sign-in for the desktop app
through a system-browser OAuth PKCE flow that returns to a loopback listener
owned by the desktop app.

## Scope

The work is delivered in two independently testable stages:

1. Repository separation and release ownership.
2. Desktop Google OAuth with an external browser and PKCE loopback callback.

The desktop repository is checked out at:

```text
/home/hetu/project/keco-desktop
```

The Web application remains at:

```text
/home/hetu/project/keco-studio
```

## Ownership Boundaries

### `Keco-Studio/keco-desktop`

This repository owns all native desktop concerns:

- Native SDK application manifest, Zig source, build graph, icon, and pinned
  Native SDK patch.
- Windows installer definition and macOS packaging configuration.
- Windows x64, macOS x64, and macOS arm64 release workflow.
- Desktop build, packaging, OAuth, and release tests.
- Desktop installation and release documentation.
- The public desktop GitHub Releases page and its installer assets.

The migrated shell contents live at the repository root rather than under a
second `desktop/` directory. It does not copy the Next.js application, its
database migrations, or Web application dependencies.

### `Keco-Studio/keco-studio`

The Web repository owns the product UI, Supabase browser client, and two narrow
desktop-auth integration surfaces: a desktop-mode login trigger and a Web
session-completion route. It does not own Native SDK source, installers,
desktop release workflows, or desktop build tests after the migration.

The existing `desktop=1` marker is retained only to switch the login button
from browser-managed OAuth to the desktop bridge command. The current
Google-login hiding behavior is removed. The ordinary Web login page continues
to call `signInWithOAuth` directly in normal browsers.

## Repository Migration

Create a clean standalone repository history rather than importing the full
Keco Studio history. The first runtime commit copies the desktop shell from
the verified source revision `4eb6acf0`, preserving the current Windows DPI,
portable CPU target, and macOS retry fixes.

Migrate these source files into the desktop repository root:

- `app.json`, `build.zig`, `build.zig.zon`, `package.json`, and
  `package-lock.json`.
- `assets/`, `src/`, `installer/`, `patches/`, `scripts/`, and `tests/`.
- The desktop README, release asset assertions, and release workflow rewritten
  for root-relative paths.

Migrate the desktop-only assertions from
`tests/unit/desktop-release-workflow-static.test.ts` into the desktop
repository. Remove the migrated workflow and assertions from the Web
repository. Desktop releases begin with `0.1.0-desktop.8` in the new repository
to distinguish them from the existing `.7` release in the old repository.

## Product Connection

The shell opens the fixed production Web origin:

```text
https://keco-studio-main.vercel.app/projects
```

The startup URL appends `?desktop=1`. The WebView navigation policy permits
only that origin. It has no filesystem permission, bundled Web frontend, or
permission to navigate to Google or Supabase Auth pages. Browser links
unrelated to the OAuth flow remain denied from the WebView.

The shell enables exactly one application-defined JavaScript bridge command:
`desktop.begin_google_oauth`. It accepts an empty object, is callable only from
`https://keco-studio-main.vercel.app`, returns only lifecycle status or a safe
error code, and exposes no filesystem, window-management, URL-navigation, or
credential APIs. It never accepts or returns a verifier, code, access token,
or refresh token.

## Desktop Google OAuth

### Security Model

The desktop app uses Authorization Code with PKCE. The desktop-mode Google
button invokes `window.zero.invoke('desktop.begin_google_oauth', {})`; its
native handler generates a cryptographic PKCE verifier, SHA-256 challenge,
state value, and an ephemeral local callback listener before opening the system
browser. It never logs, persists, or sends the verifier, authorization code,
access token, or refresh token to Keco-owned application servers.

The listener binds only to `127.0.0.1` on an operating-system-selected port.
It accepts exactly one callback before shutting down, requires an exact state
match, rejects duplicate requests, and expires after five minutes.

### Flow

```text
Desktop app
  -> Web login button invokes desktop.begin_google_oauth with no payload
  -> generate verifier, challenge, state, and loopback URL
  -> create Supabase Google OAuth authorization URL with PKCE
  -> open authorization URL in the default system browser
  -> Google authorization and Supabase callback
  -> browser redirects to 127.0.0.1 callback with code and state
  -> desktop verifies state and exchanges code using the verifier
  -> desktop WebView opens the Keco session handoff route with tokens in URL fragment
  -> handoff route calls supabase.auth.setSession and redirects to /projects
```

The authorization URL uses Supabase's production auth origin and specifies the
exact generated loopback URL as `redirectTo`. On a successful exchange, native
code navigates the startup WebView to the handoff route. The fragment used for
the WebView handoff is never included in an HTTP request, browser referrer,
server log, or analytics event. The handoff page immediately replaces the
fragment with a clean history entry after it has established the session.

### Web Session Handoff

`keco-studio` adds a client-only `/auth/desktop/session` route. It reads only
the expected token fields from `window.location.hash`, calls
`supabase.auth.setSession`, clears the fragment with `history.replaceState`, and
routes to `/projects`. It renders a retryable failure state when token parsing
or session establishment fails. It must not expose token values in UI,
telemetry, logs, errors, or query parameters.

The login trigger and handoff route are the only desktop-aware product code that
remains in the Web repository. They are authentication integration surfaces,
not desktop shell or release concerns.

### Production Auth Configuration

Before release, configure Supabase Auth Redirect URLs with this exact loopback
pattern:

```text
http://127.0.0.1:*/auth/desktop/callback
```

The Google OAuth provider remains configured in Supabase. No Google client
secret, Supabase service-role key, or new database object is required in the
desktop repository. This is an Auth dashboard configuration change, not a
database migration.

## Failure Handling

The desktop login surface must present a retry action for each of these states:

- The local listener cannot bind to loopback.
- The system browser cannot be opened.
- The user cancels or declines Google authorization.
- The callback arrives after five minutes.
- The callback state is missing or does not exactly match.
- The authorization code exchange fails.
- The WebView session handoff fails.

Each failure closes the listener and discards the in-memory verifier, state,
code, and token values. Existing email/password sign-in continues to work in
the embedded WebView.

## Release and Installation

The new repository's manual release workflow builds all three artifacts before
publishing one draft-verified GitHub Release:

- `Keco-Studio-Setup-<version>-windows-x64.exe`
- `Keco-Studio-<version>-macos-x64.dmg`
- `Keco-Studio-<version>-macos-arm64.dmg`

The workflow preserves the existing Windows GNU portable target, Windows
Per-Monitor V2 DPI manifest, macOS architecture checks, Windows installer
checks, and resilient macOS DMG retry behavior. The final release is published
from `Keco-Studio/keco-desktop` only after all three artifacts pass validation.

Users install the Windows executable once, then open the product by double
clicking `keco-studio.exe` or its installed shortcut. Existing authenticated
WebView sessions open directly to projects. A first-time Google sign-in opens
the default browser and returns automatically to the running desktop window.

## Testing and Acceptance Criteria

### Desktop Repository

- Static tests verify the production origin, narrow navigation allowlist,
  exact single-command bridge policy, zero filesystem permission, and platform
  build targets.
- Unit tests cover PKCE challenge generation, cryptographically random state,
  loopback URL construction, exact callback parsing, state mismatch rejection,
  duplicate callback rejection, listener timeout, and credential clearing.
- Release tests verify Windows x64, macOS x64, and macOS arm64 packages and
  asset names.
- Windows validation confirms the released executable embeds `PerMonitorV2`
  and reports `PROCESS_PER_MONITOR_DPI_AWARE`.

### Web Repository

- Unit tests cover valid fragment token parsing, invalid/missing token failure,
  `setSession` invocation, fragment removal, and redirect to `/projects`.
- Regression tests confirm `desktop=1` invokes only the exact
  `desktop.begin_google_oauth` bridge command while normal browsers retain the
  existing direct Google OAuth behavior.

### Manual Acceptance

- On Windows and macOS, a clean installed application can start Google sign-in
  from the login screen, opens the default browser, completes an existing
  Google account login, returns to the desktop window, and reaches `/projects`.
- A canceled or expired browser login returns the desktop application to a
  retryable login state without creating a session.
- A second application launch reuses an existing authenticated WebView session.

## Non-Goals

- No bundled Next.js frontend, local database, service-role credential, or
  bridge command other than `desktop.begin_google_oauth`.
- No support for providers other than Google in this delivery.
- No automatic application updates, telemetry redesign, or changes to Web
  product features unrelated to authentication handoff.
- No database migration.
