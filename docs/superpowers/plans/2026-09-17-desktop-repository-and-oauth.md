# Keco Desktop Repository and OAuth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Native SDK desktop shell and release pipeline into `Keco-Studio/keco-desktop`, then let its desktop login button complete Google OAuth in the system browser and establish the returned Supabase session in the existing WebView.

**Architecture:** The standalone desktop repository owns the Native SDK shell, an in-memory PKCE loopback OAuth transaction, packaging, and release validation. The Web repository keeps only a desktop-aware Google button and a client-side session-handoff route. The sole bridge command starts a synchronous native transaction from the trusted production Web origin; native code opens the browser, validates the loopback callback, exchanges the code, updates the startup source to the trusted handoff URL, and reloads the main WebView without exposing credentials through the bridge response.

**Tech Stack:** Zig 0.16, Native SDK 0.10.1, Node.js 24, GitHub Actions, Inno Setup, Next.js, React, TypeScript, Jest, Supabase Auth REST API.

## Global Constraints

- Work in matching feature branches in `/home/hetu/project/keco-desktop` and `/home/hetu/project/keco-studio`; preserve unrelated working-tree changes.
- `keco-desktop` contains desktop source at its repository root and never copies Next.js source, database migrations, or Web dependencies.
- `keco-studio` retains only the desktop login trigger and `/auth/desktop/session`; remove desktop packaging, workflow, and desktop release tests from it.
- The production Web origin is exactly `https://keco-studio-main.vercel.app`; the startup URL is `https://keco-studio-main.vercel.app/projects?desktop=1`.
- The desktop manifest grants no filesystem permission and defines exactly one application bridge command, `desktop.begin_google_oauth`, callable only by the production origin with `{}`.
- Google OAuth uses Authorization Code with PKCE, an OS-selected `127.0.0.1` port, exact state matching, one callback only, and a five-minute timeout. Never persist or log the verifier, code, access token, or refresh token.
- The system browser is used for Google and Supabase. The WebView remains restricted to the production Web origin; browser links unrelated to this flow remain denied.
- The token handoff uses a URL fragment only, immediately clears the fragment, and never places tokens in query parameters, logs, UI, telemetry, or application errors.
- Keep all newly added repository text and code comments in English.
- No database migration, Google secret, Supabase service-role key, local database, bundled frontend, telemetry redesign, auto-update work, or provider beyond Google is part of this change. The existing public Supabase anon key is a required client API key for the PKCE token endpoint and may be compiled into the desktop client; it is not a secret.
- Preserve Windows `x86_64-windows-gnu`, both PerMonitorV2 executable-manifest assignments, macOS `x86_64` and `aarch64` packages, installer checks, and macOS DMG retry cleanup.
- Release versioning starts at `0.1.0-desktop.8` in `Keco-Studio/keco-desktop`; releases are draft-verified before publishing.

---

## File Structure

| Repository | Path | Responsibility |
| --- | --- | --- |
| `keco-desktop` | `app.json` | Native capability, exact bridge-origin, and WebView navigation policy. |
| `keco-desktop` | `src/main.zig` | App state, bridge registration, source selection, and protected runtime reload. |
| `keco-desktop` | `src/oauth.zig` | PKCE generation, callback parsing, bounded transaction state, exchange request/response parsing, and secret clearing. |
| `keco-desktop` | `src/config.zig` | Fixed production Supabase origin and public anon client key used only for Auth requests. |
| `keco-desktop` | `src/runner.zig` | Existing Native SDK runner copied from the verified shell, with a small runtime-ready hook so `main.zig` can reload only its own main source. |
| `keco-desktop` | `tests/oauth.test.zig` | Pure OAuth and loopback security tests. |
| `keco-desktop` | `tests/desktop-shell-static.test.mjs` | Static contract for source URL, manifest, bridge, and build security. |
| `keco-desktop` | `.github/workflows/release-desktop.yml` | Root-relative Windows/macOS build, validation, artifact upload, and draft release. |
| `keco-studio` | `src/lib/desktopGoogleOAuth.ts` | Browser-side detection and typed one-command invocation helper. |
| `keco-studio` | `src/components/authform/AuthForm.tsx` | Select native desktop OAuth or existing browser OAuth from the same Google button. |
| `keco-studio` | `src/app/auth/desktop/session/page.tsx` | Fragment-only session establishment and retryable error screen. |
| `keco-studio` | `tests/unit/auth/desktop-google-oauth.test.ts` | Desktop bridge and ordinary-browser OAuth regression coverage. |
| `keco-studio` | `tests/unit/auth/desktop-session-handoff.test.tsx` | Handoff parsing, session call, fragment removal, and redirect coverage. |

### Task 1: Establish the Two Repository Branches and Migrate the Verified Shell

**Files:**
- Create: `/home/hetu/project/keco-desktop/{app.json,build.zig,build.zig.zon,package.json,package-lock.json,README.md}`
- Create: `/home/hetu/project/keco-desktop/{assets,installer,patches,scripts,src,tests}/...`
- Create: `/home/hetu/project/keco-desktop/.github/workflows/release-desktop.yml`
- Modify: `/home/hetu/project/keco-studio/.gitignore` only if copied desktop outputs would otherwise become untracked
- Test: `/home/hetu/project/keco-desktop/tests/desktop-shell-static.test.mjs`

**Interfaces:**
- Consumes: desktop source only from `keco-studio` commit `4eb6acf0`.
- Produces: a root-level, independently installable Native SDK project whose `npm run check` and `zig build test` can run without the Web repository.

- [ ] **Step 1: Create isolated matching branches from the current remote bases**

```bash
git -C /home/hetu/project/keco-desktop fetch origin
git -C /home/hetu/project/keco-desktop switch -c feat/desktop-repository-oauth origin/main
git -C /home/hetu/project/keco-studio fetch origin
git -C /home/hetu/project/keco-studio switch -c feat/desktop-repository-oauth origin/main
```

Expected: both commands report the new branch; `git status --short` contains only pre-existing user changes, if any.

- [ ] **Step 2: Write a failing desktop-root contract test before copying files**

Create `tests/desktop-shell-static.test.mjs` with the root paths and baseline assertions:

```js
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (path) => readFileSync(path, 'utf8');
const main = read('src/main.zig');
const manifest = JSON.parse(read('app.json'));

assert.equal(manifest.name, 'keco-studio');
assert.equal(manifest.permissions.length, 0);
assert.equal(main.includes('https://keco-studio-main.vercel.app/projects?desktop=1'), true);
```

- [ ] **Step 3: Run the test to prove the empty repository fails**

Run: `node --test tests/desktop-shell-static.test.mjs`

Expected: FAIL with `ENOENT` for `src/main.zig`.

- [ ] **Step 4: Copy only the verified desktop shell and rewrite root-relative ownership paths**

Copy `desktop/{app.json,build.zig,build.zig.zon,package.json,package-lock.json,README.md,assets,installer,patches,scripts,src,tests}` from commit `4eb6acf0` into `/home/hetu/project/keco-desktop`. Copy the release workflow to `.github/workflows/release-desktop.yml`, then replace every `desktop/` prefix with the root-equivalent path. Preserve the three targets, package checks, `win32_manifest` assignments, `WebView2Loader.dll` assertion, installer source path, `hdiutil detach -quiet -force "$mount_point" || true`, draft release asset assertion, and final `gh release edit`.

The Windows packaging inputs become exactly:

```yaml
- run: npm ci
- run: node scripts/apply-native-sdk-patches.mjs
- run: node scripts/create-release-manifest.mjs "$env:VERSION" app.json
  shell: pwsh
- run: zig build -Dtarget=x86_64-windows-gnu -Dplatform=windows -Doptimize=ReleaseFast
```

The installer environment becomes exactly:

```powershell
Invoke-WebRequest https://go.microsoft.com/fwlink/p/?LinkId=2124703 -OutFile release/windows/WebView2Bootstrapper.exe
$env:KECO_DESKTOP_VERSION = $env:VERSION
$env:KECO_DESKTOP_SOURCE_DIR = (Resolve-Path release/windows).Path
iscc installer/KecoStudio.iss
Move-Item "installer/Output/Keco-Studio-Setup-$env:VERSION-windows-x64.exe" .
```

- [ ] **Step 5: Extend the root static test for migration invariants and run it**

Add these assertions to `tests/desktop-shell-static.test.mjs`:

```js
const build = read('build.zig');
const workflow = read('.github/workflows/release-desktop.yml');
assert.equal((build.match(/\.win32_manifest = nativeSdkPath\(b, native_sdk_path, "assets\/native-sdk\.manifest"\);/g) ?? []).length, 2);
assert.equal(workflow.includes('npm --prefix desktop ci'), false);
assert.equal(workflow.includes('zig build -Dtarget=x86_64-windows-gnu -Dplatform=windows -Doptimize=ReleaseFast'), true);
assert.equal(workflow.includes('zig build -Dtarget=x86_64-macos -Dplatform=macos -Doptimize=ReleaseFast'), true);
assert.equal(workflow.includes('zig build -Dtarget=aarch64-macos -Dplatform=macos -Doptimize=ReleaseFast'), true);
assert.equal(workflow.includes('hdiutil detach -quiet -force "$mount_point" || true'), true);
```

Run: `npm ci && npm run check && zig build test`

Expected: all checks pass using only `/home/hetu/project/keco-desktop`.

- [ ] **Step 6: Commit the independently buildable migration**

```bash
git -C /home/hetu/project/keco-desktop add app.json build.zig build.zig.zon package.json package-lock.json README.md assets installer patches scripts src tests .github/workflows/release-desktop.yml
git -C /home/hetu/project/keco-desktop commit -m "feat: establish standalone desktop shell"
```

### Task 2: Add a Testable, In-Memory OAuth Transaction Module

**Files:**
- Create: `/home/hetu/project/keco-desktop/src/oauth.zig`
- Create: `/home/hetu/project/keco-desktop/src/config.zig`
- Create: `/home/hetu/project/keco-desktop/tests/oauth.test.zig`
- Modify: `/home/hetu/project/keco-desktop/build.zig`

**Interfaces:**
- Consumes: `std.crypto.hash.sha2.Sha256`, `std.crypto.random`, a Supabase auth base URL, and the generated loopback port.
- Produces: `oauth.Transaction.init`, `oauth.Transaction.callbackUrl`, `oauth.Transaction.authorizationUrl`, `oauth.parseCallback`, `oauth.Transaction.consumeCallback`, `oauth.Transaction.clear`, and `oauth.exchangeCode`.

- [ ] **Step 1: Write failing Zig tests for the pure security boundary**

Create `tests/oauth.test.zig`:

```zig
const std = @import("std");
const oauth = @import("oauth.zig");

test "PKCE challenge is SHA-256 base64url without padding" {
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    var output: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        try oauth.pkceChallenge(verifier, &output),
    );
}

test "callback accepts one matching code and rejects replay or mismatched state" {
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");
    try std.testing.expectEqualStrings("code-a", try transaction.consumeCallback("/auth/desktop/callback?code=code-a&state=expected-state"));
    try std.testing.expectError(error.CallbackAlreadyConsumed, transaction.consumeCallback("/auth/desktop/callback?code=code-b&state=expected-state"));
}

test "callback rejects missing code and nonmatching state" {
    var transaction = oauth.Transaction.forTest("expected-state", "verifier");
    try std.testing.expectError(error.InvalidCallback, transaction.consumeCallback("/auth/desktop/callback?state=expected-state"));
    try std.testing.expectError(error.StateMismatch, transaction.consumeCallback("/auth/desktop/callback?code=code-a&state=wrong"));
}
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run: `zig test tests/oauth.test.zig -I src`

Expected: FAIL because `oauth.zig` and the module functions do not exist.

- [ ] **Step 3: Implement bounded PKCE and callback parsing**

Create `src/oauth.zig` with fixed-size secrets and an exact parser. The relevant public contract is:

```zig
pub const verifier_bytes = 96;
pub const state_bytes = 64;
pub const timeout_ns = 5 * std.time.ns_per_min;

pub const Transaction = struct {
    verifier: [verifier_bytes]u8,
    verifier_len: usize,
    state: [state_bytes]u8,
    state_len: usize,
    callback_port: u16,
    started_ns: i128,
    consumed: bool = false,

    pub fn init(port: u16, now_ns: i128) !Transaction;
    pub fn forTest(state: []const u8, verifier: []const u8) Transaction;
    pub fn callbackUrl(self: *const Transaction, buffer: []u8) ![]const u8;
    pub fn authorizationUrl(self: *const Transaction, auth_origin: []const u8, buffer: []u8) ![]const u8;
    pub fn consumeCallback(self: *Transaction, request_target: []const u8) ![]const u8;
    pub fn expired(self: *const Transaction, now_ns: i128) bool;
    pub fn clear(self: *Transaction) void;
};
```

Use `std.crypto.random.bytes` for raw values, URL-safe base64 without padding for the verifier and state, `std.crypto.hash.sha2.Sha256.hash` for the challenge, `std.mem.eql` for exact state comparison, and `@memset` in `clear`. `consumeCallback` accepts only `GET /auth/desktop/callback`, decodes percent encoding once, requires exactly one nonempty `code` and `state`, rejects repeated `code` or `state` parameters, marks `consumed` before returning the code, and does not retain the code.

- [ ] **Step 4: Add loopback listener and exchange seams with deterministic fakes**

Add these dependency-injected interfaces under the pure transaction code:

```zig
pub const BrowserOpener = *const fn (url: []const u8) anyerror!void;
pub const SessionExchange = *const fn (redirect_uri: []const u8, code: []const u8, verifier: []const u8, output: []u8) anyerror!SessionTokens;
pub const SessionTokens = struct { access_token: []const u8, refresh_token: []const u8 };

pub fn listenOnce(port: u16, expected_state: []const u8, deadline_ns: i128, clock: *const fn () i128, output: []u8) ![]const u8;
pub fn exchangeCode(auth_origin: []const u8, redirect_uri: []const u8, code: []const u8, verifier: []const u8, output: []u8) !SessionTokens;
```

Create `src/config.zig` with the existing production URL and the existing public `NEXT_PUBLIC_SUPABASE_ANON_KEY` value from the Web deployment configuration. It must export only `supabase_origin` and `supabase_anon_key`; do not add a service-role key or read environment variables at runtime. `listenOnce` binds `std.net.Address.parseIp4("127.0.0.1", 0)`, retrieves the assigned port before creating the redirect URL, accepts exactly one request, emits a fixed pending-completion or failure HTML page without credentials, closes its `Server` with `defer`, and returns `error.CallbackTimedOut` after `timeout_ns`. This request-format detail is superseded by the implemented Supabase client compatibility fix: `exchangeCode` makes a JSON HTTPS `POST` to `https://lulrcirmwwvvnupmwqcq.supabase.co/auth/v1/token?grant_type=pkce`, includes `apikey: config.supabase_anon_key` and `Authorization: Bearer <anon key>`, sends only `auth_code` and `code_verifier` (without `redirect_uri`), accepts only a JSON object containing nonempty `access_token` and `refresh_token`, and writes them only into the caller-provided buffer.

- [ ] **Step 5: Run the focused tests and full desktop test suite**

Run: `zig test tests/oauth.test.zig -I src && zig build test && npm run check`

Expected: PASS. Add tests for two different generated states, loopback `127.0.0.1` URL construction, timeout, and `clear` zeroing the arrays before accepting this step.

- [ ] **Step 6: Commit the OAuth module**

```bash
git -C /home/hetu/project/keco-desktop add src/oauth.zig src/config.zig tests/oauth.test.zig build.zig
git -C /home/hetu/project/keco-desktop commit -m "feat: add PKCE loopback transaction"
```

### Task 3: Register the Sole Bridge Command and Reload the Trusted Handoff Source

**Files:**
- Modify: `/home/hetu/project/keco-desktop/app.json`
- Modify: `/home/hetu/project/keco-desktop/src/main.zig`
- Modify: `/home/hetu/project/keco-desktop/src/runner.zig`
- Modify: `/home/hetu/project/keco-desktop/build.zig`
- Modify: `/home/hetu/project/keco-desktop/tests/desktop-shell-static.test.mjs`
- Test: `/home/hetu/project/keco-desktop/tests/oauth.test.zig`

**Interfaces:**
- Consumes: `oauth.Transaction`, `oauth.listenOnce`, `oauth.exchangeCode`, `native_sdk.BridgeDispatcher`, and `runner.RunOptions.runtime_ready`.
- Produces: `desktop.begin_google_oauth` with an empty-object payload, `App.startGoogleOAuth`, and a runtime-ready hook that permits only `App` to call `runtime.reloadWindows(app.app())`.

- [ ] **Step 1: Extend the static test with the intended default-deny contract**

Add assertions before changing the manifest:

```js
assert.deepEqual(manifest.permissions, []);
assert.deepEqual(manifest.capabilities, ['webview', 'js_bridge', 'open_url']);
assert.deepEqual(manifest.bridge.commands, [{
  name: 'desktop.begin_google_oauth',
  origins: ['https://keco-studio-main.vercel.app'],
}]);
assert.deepEqual(manifest.security.navigation.allowed_origins, ['https://keco-studio-main.vercel.app']);
assert.deepEqual(manifest.security.navigation.external_links, {
  action: 'open_system_browser',
  allowed_urls: ['https://lulrcirmwwvvnupmwqcq.supabase.co/auth/v1/authorize*'],
});
assert.equal(main.includes('desktop.begin_google_oauth'), true);
assert.equal(main.includes('std.debug.print'), false);
```

- [ ] **Step 2: Run the static test to verify it fails against the no-bridge shell**

Run: `node --test tests/desktop-shell-static.test.mjs`

Expected: FAIL because `js_bridge`, `open_url`, and the bridge policy do not exist.

- [ ] **Step 3: Add the manifest's exact capabilities and browser allowlist**

Replace the manifest capability and security fragment with:

```json
"permissions": [],
"capabilities": ["webview", "js_bridge", "open_url"],
"bridge": {
  "commands": [{
    "name": "desktop.begin_google_oauth",
    "origins": ["https://keco-studio-main.vercel.app"]
  }]
},
"security": {
  "navigation": {
    "allowed_origins": ["https://keco-studio-main.vercel.app"],
    "external_links": {
      "action": "open_system_browser",
      "allowed_urls": ["https://lulrcirmwwvvnupmwqcq.supabase.co/auth/v1/authorize*"]
    }
  }
}
```

Do not allow Google, Supabase token endpoints, loopback URLs, wildcard WebView origins, or any builtin bridge command in `app.json`.

- [ ] **Step 4: Add the runner runtime-ready seam and the native bridge handler**

Add this field to `runner.RunOptions`:

```zig
runtime_ready: ?*const fn (context: *anyopaque, runtime: *native_sdk.Runtime) void = null,
runtime_context: ?*anyopaque = null,
```

Immediately after every `native_sdk.Runtime.initAt(runtime, ...)` in `runNull`, `runMacos`, `runLinux`, and `runWindows`, call the hook when both fields are non-null:

```zig
if (options.runtime_ready) |ready| ready(options.runtime_context orelse unreachable, runtime);
```

In `src/main.zig`, keep the `*native_sdk.Runtime` only while `runner.runWithOptions` owns the process. Register one handler and policy:

```zig
const bridge_policies = [_]native_sdk.BridgeCommandPolicy{.{
    .name = "desktop.begin_google_oauth",
    .origins = &.{"https://keco-studio-main.vercel.app"},
}};

fn beginGoogleOAuth(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) ![]const u8 {
    const self: *App = @ptrCast(@alignCast(context));
    if (!std.mem.eql(u8, invocation.request.payload, "{}")) return error.InvalidPayload;
    try self.startGoogleOAuth();
    return std.fmt.bufPrint(output, "{{\"status\":\"completed\"}}", .{});
}
```

`startGoogleOAuth` must reject a second active transaction, bind before making the authorization URL, call `runtime.openExternalUrl` with only the precomputed Supabase authorize URL, wait at most five minutes for a validated callback, exchange it, build `https://keco-studio-main.vercel.app/auth/desktop/session#access_token=<percent-encoded>&refresh_token=<percent-encoded>`, set the app's next `WebViewSource`, and call `runtime.reloadWindows(self.app())`. Use `defer transaction.clear()` and wipe the token buffer after the reload call. Do not put credentials in the bridge result, `std.debug.print`, errors, URL query, state fields, or persistent storage.

- [ ] **Step 5: Add Native SDK integration tests that run without a browser**

Add tests proving the handler rejects `null`, `{"anything":true}`, simultaneous calls, a mismatched callback, and a late callback; verify a successful fake exchange calls the injected browser opener once and creates a handoff URL only in a local mutable buffer. Use a fake `BrowserOpener`, fake `SessionExchange`, and a fake `reload` callback, then assert all secret buffers are zero after the callback returns.

Run: `zig build test && node --test tests/desktop-shell-static.test.mjs && npm run check`

Expected: PASS.

- [ ] **Step 6: Commit the native auth capability**

```bash
git -C /home/hetu/project/keco-desktop add app.json src/main.zig src/runner.zig build.zig tests
git -C /home/hetu/project/keco-desktop commit -m "feat: start Google OAuth from desktop"
```

### Task 4: Complete Root-Level Release Ownership and Installation Documentation

**Files:**
- Modify: `/home/hetu/project/keco-desktop/.github/workflows/release-desktop.yml`
- Modify: `/home/hetu/project/keco-desktop/tests/desktop-shell-static.test.mjs`
- Modify: `/home/hetu/project/keco-desktop/README.md`
- Create: `/home/hetu/project/keco-desktop/docs/release.md`

**Interfaces:**
- Consumes: repository-root scripts and package output names.
- Produces: one manual GitHub workflow that creates a draft release in `Keco-Studio/keco-desktop` only after three validated assets exist.

- [ ] **Step 1: Write failing release-contract assertions**

Add assertions that the workflow has no `desktop/` path, retains all three upload paths, and stages release `v${VERSION}` only after downloads:

```js
assert.equal(workflow.includes('desktop/'), false);
assert.equal(workflow.includes('Keco-Studio-Setup-${{ inputs.version }}-windows-x64.exe'), true);
assert.equal(workflow.includes('Keco-Studio-${{ inputs.version }}-macos-x64.dmg'), true);
assert.equal(workflow.includes('Keco-Studio-${{ inputs.version }}-macos-arm64.dmg'), true);
assert.equal(workflow.includes('gh release create "v${VERSION}" --draft'), true);
assert.equal(workflow.includes('assert-release-assets.mjs "$VERSION" --names-file release-asset-names.txt'), true);
assert.equal(workflow.includes('gh release edit "v${VERSION}" --draft=false'), true);
```

- [ ] **Step 2: Run the release contract before its root-path rewrite**

Run: `node --test tests/desktop-shell-static.test.mjs`

Expected: FAIL while any old `desktop/` prefix remains.

- [ ] **Step 3: Finish the root-relative workflow and release documentation**

Set release version input description to `Release version without a leading v, starting with 0.1.0-desktop.8`. Ensure the release job invokes:

```bash
node scripts/assert-release-assets.mjs "$VERSION" --names-file release-asset-names.txt
gh release create "v${VERSION}" --draft Keco-Studio-Setup-"${VERSION}"-windows-x64.exe Keco-Studio-"${VERSION}"-macos-x64.dmg Keco-Studio-"${VERSION}"-macos-arm64.dmg --title "Keco Studio ${VERSION}"
gh release view "v${VERSION}" --json assets --jq '.assets[].name' > release-asset-names.txt
node scripts/assert-release-assets.mjs "$VERSION" --names-file release-asset-names.txt
gh release edit "v${VERSION}" --draft=false
```

Document that Windows users install `Keco-Studio-Setup-<version>-windows-x64.exe` once, then launch `keco-studio.exe` via its shortcut or installed location; existing WebView sessions open projects, and Google authentication opens the system browser then returns to the running desktop window. Document the required Supabase Auth redirect URL as `http://127.0.0.1:*/auth/desktop/callback` and explicitly state this is an Auth dashboard setting, not a migration.

- [ ] **Step 4: Run full desktop verification and commit**

Run: `npm ci && npm run check && zig build test && node --test tests/desktop-shell-static.test.mjs`

Expected: PASS.

```bash
git -C /home/hetu/project/keco-desktop add .github/workflows/release-desktop.yml tests/desktop-shell-static.test.mjs README.md docs/release.md
git -C /home/hetu/project/keco-desktop commit -m "docs: document desktop releases and OAuth setup"
```

### Task 5: Add Web-Side Desktop Bridge Invocation Without Changing Browser OAuth

**Files:**
- Create: `/home/hetu/project/keco-studio/src/lib/desktopGoogleOAuth.ts`
- Modify: `/home/hetu/project/keco-studio/src/components/authform/AuthForm.tsx`
- Modify: `/home/hetu/project/keco-studio/tests/unit/auth/desktop-mode.test.ts`
- Create: `/home/hetu/project/keco-studio/tests/unit/auth/desktop-google-oauth.test.ts`

**Interfaces:**
- Consumes: `isDesktopModeSearch`, `isDesktopModeSession`, `window.zero.invoke`, existing `supabase.auth.signInWithOAuth`.
- Produces: `beginDesktopGoogleOAuth(): Promise<void>` and a single Google button that selects its safe backend based on desktop mode.

- [ ] **Step 1: Write failing helper tests for the bridge shape**

Create `tests/unit/auth/desktop-google-oauth.test.ts`:

```ts
import { beginDesktopGoogleOAuth } from '@/lib/desktopGoogleOAuth';

it('invokes only the desktop Google command with an empty object', async () => {
  const invoke = jest.fn().mockResolvedValue({ status: 'completed' });
  Object.defineProperty(window, 'zero', { configurable: true, value: { invoke } });
  await beginDesktopGoogleOAuth();
  expect(invoke).toHaveBeenCalledWith('desktop.begin_google_oauth', {});
});

it('fails safely when the Native SDK bridge is absent', async () => {
  Object.defineProperty(window, 'zero', { configurable: true, value: undefined });
  await expect(beginDesktopGoogleOAuth()).rejects.toThrow('Desktop sign-in is unavailable');
});
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `npm test -- --runInBand tests/unit/auth/desktop-google-oauth.test.ts`

Expected: FAIL because the helper does not exist.

- [ ] **Step 3: Implement the typed, narrow bridge helper**

Create `src/lib/desktopGoogleOAuth.ts`:

```ts
type DesktopBridge = {
  invoke(command: 'desktop.begin_google_oauth', payload: Record<string, never>): Promise<{ status: 'completed' }>;
};

declare global {
  interface Window { zero?: DesktopBridge; }
}

export async function beginDesktopGoogleOAuth(): Promise<void> {
  const bridge = window.zero;
  if (!bridge) throw new Error('Desktop sign-in is unavailable. Please restart Keco Studio.');
  await bridge.invoke('desktop.begin_google_oauth', {});
}
```

Do not add generic bridge wrappers, credential types, URL arguments, navigation helpers, or browser fallbacks to this module.

- [ ] **Step 4: Select the helper only for confirmed desktop mode in `AuthForm.tsx`**

Modify `handleGoogleLogin` so its first branch is:

```ts
if (isDesktopMode) {
  await beginDesktopGoogleOAuth();
  return;
}
```

Retain the existing `supabase.auth.signInWithOAuth({ provider: 'google', ... })` branch unchanged for normal browsers. Render the exact same Google button and divider once when `isDesktopMode !== null`; delete the text `Google login is unavailable in desktop mode`. Keep `googleLoading` true during the native call and show its caught safe error through the existing error element so retrying the button starts a new transaction.

- [ ] **Step 5: Update regression tests and run them**

Replace the old assertion that desktop suppresses Google with assertions that `AuthForm.tsx` imports `beginDesktopGoogleOAuth`, tests `if (isDesktopMode)`, and still contains `supabase.auth.signInWithOAuth`. Run:

```bash
npm test -- --runInBand tests/unit/auth/desktop-google-oauth.test.ts tests/unit/auth/desktop-mode.test.ts
npm run lint
npm run build
```

Expected: all commands pass.

- [ ] **Step 6: Commit the Web login trigger**

```bash
git -C /home/hetu/project/keco-studio add src/lib/desktopGoogleOAuth.ts src/components/authform/AuthForm.tsx tests/unit/auth/desktop-mode.test.ts tests/unit/auth/desktop-google-oauth.test.ts
git -C /home/hetu/project/keco-studio commit -m "feat: start desktop Google sign-in"
```

### Task 6: Establish the Fragment-Only Desktop Session Handoff

**Files:**
- Create: `/home/hetu/project/keco-studio/src/lib/desktopSessionHandoff.ts`
- Create: `/home/hetu/project/keco-studio/src/app/auth/desktop/session/page.tsx`
- Create: `/home/hetu/project/keco-studio/tests/unit/auth/desktop-session-handoff.test.tsx`

**Interfaces:**
- Consumes: `window.location.hash`, `supabase.auth.setSession({ access_token, refresh_token })`, `router.replace`.
- Produces: `parseDesktopSessionHash(hash): DesktopSession | null` and the `/auth/desktop/session` client route.

- [ ] **Step 1: Write failing tests for parsing and successful handoff**

Create `tests/unit/auth/desktop-session-handoff.test.tsx` with these core checks:

```ts
import { parseDesktopSessionHash } from '@/lib/desktopSessionHandoff';

it('accepts only a nonempty access and refresh token from the fragment', () => {
  expect(parseDesktopSessionHash('#access_token=a&refresh_token=r')).toEqual({ accessToken: 'a', refreshToken: 'r' });
  expect(parseDesktopSessionHash('#access_token=a')).toBeNull();
  expect(parseDesktopSessionHash('?access_token=a&refresh_token=r')).toBeNull();
});

it('sets the session, removes the fragment, and replaces projects', async () => {
  // Render the route with mocked useSupabase and useRouter.
  // Assert setSession receives { access_token: 'a', refresh_token: 'r' }.
  // Assert history.replaceState receives a URL without '#'.
  // Assert router.replace('/projects') is called.
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npm test -- --runInBand tests/unit/auth/desktop-session-handoff.test.tsx`

Expected: FAIL because the helper and route do not exist.

- [ ] **Step 3: Implement parsing with no query fallback or token reporting**

Create `src/lib/desktopSessionHandoff.ts`:

```ts
export type DesktopSession = { accessToken: string; refreshToken: string };

export function parseDesktopSessionHash(hash: string): DesktopSession | null {
  if (!hash.startsWith('#')) return null;
  const values = new URLSearchParams(hash.slice(1));
  const accessToken = values.get('access_token');
  const refreshToken = values.get('refresh_token');
  if (!accessToken || !refreshToken) return null;
  return { accessToken, refreshToken };
}
```

- [ ] **Step 4: Implement the client route with a retryable failure state**

Create `src/app/auth/desktop/session/page.tsx` as a client component. In one guarded effect, parse `window.location.hash`; if invalid, set `error` to `Unable to complete desktop sign-in.`. On valid data, call:

```ts
const { error } = await supabase.auth.setSession({
  access_token: session.accessToken,
  refresh_token: session.refreshToken,
});
history.replaceState(null, '', `${window.location.pathname}${window.location.search}`);
if (error) { setError('Unable to complete desktop sign-in.'); return; }
router.replace('/projects');
```

Clear the fragment in a `finally` block after `setSession` settles, never interpolate token strings into errors, and render only a short completion state or a button that calls `window.location.replace('/?desktop=1')` for retry. Do not reuse `/auth/callback/page.tsx`, which is for browser-managed PKCE cookies.

- [ ] **Step 5: Run focused and full Web verification**

Run:

```bash
npm test -- --runInBand tests/unit/auth/desktop-session-handoff.test.tsx tests/unit/auth/desktop-google-oauth.test.ts tests/unit/auth/desktop-mode.test.ts
npm run lint
npm run build
```

Expected: PASS, with no test assertions or source strings that expose a token value.

- [ ] **Step 6: Commit the session handoff**

```bash
git -C /home/hetu/project/keco-studio add src/lib/desktopSessionHandoff.ts src/app/auth/desktop/session/page.tsx tests/unit/auth/desktop-session-handoff.test.tsx
git -C /home/hetu/project/keco-studio commit -m "feat: complete desktop OAuth sessions"
```

### Task 7: Remove Migrated Web Ownership and Verify the Complete Delivery

**Files:**
- Delete: `/home/hetu/project/keco-studio/desktop/`
- Delete: `/home/hetu/project/keco-studio/.github/workflows/release-desktop.yml`
- Delete: `/home/hetu/project/keco-studio/tests/unit/desktop-release-workflow-static.test.ts`
- Modify: `/home/hetu/project/keco-studio/README.md` only if it links to the removed workflow or desktop directory
- Modify: `/home/hetu/project/keco-desktop/README.md`

**Interfaces:**
- Consumes: committed standalone shell and passing Web auth integration.
- Produces: clear ownership, clean Web test configuration, two reviewable branches, and evidence for release configuration.

- [ ] **Step 1: Write a failing ownership regression test in the Web repository**

Create or extend a small static test with:

```ts
expect(existsSync(path.join(process.cwd(), 'desktop'))).toBe(false);
expect(existsSync(path.join(process.cwd(), '.github/workflows/release-desktop.yml'))).toBe(false);
expect(existsSync(path.join(process.cwd(), 'tests/unit/desktop-release-workflow-static.test.ts'))).toBe(false);
```

- [ ] **Step 2: Run it before deletion**

Run: `npm test -- --runInBand tests/unit/auth/desktop-ownership.test.ts`

Expected: FAIL because the legacy desktop paths still exist.

- [ ] **Step 3: Delete only the migrated ownership files and update links**

Remove the exact three targets above after confirming their desktop equivalents exist in `/home/hetu/project/keco-desktop`. Do not delete `src/lib/desktopMode.ts`, `src/components/desktop/DesktopModeMarker.tsx`, the bridge helper, or the handoff route. Update any stale Web README link to point to `https://github.com/Keco-Studio/keco-desktop`.

- [ ] **Step 4: Run complete automated verification**

Run:

```bash
git -C /home/hetu/project/keco-desktop diff --check
git -C /home/hetu/project/keco-desktop status --short
npm --prefix /home/hetu/project/keco-desktop run check
zig build test
node --test tests/desktop-shell-static.test.mjs
npm --prefix /home/hetu/project/keco-studio test -- --runInBand tests/unit/auth/desktop-ownership.test.ts tests/unit/auth/desktop-mode.test.ts tests/unit/auth/desktop-google-oauth.test.ts tests/unit/auth/desktop-session-handoff.test.tsx
npm --prefix /home/hetu/project/keco-studio run lint
npm --prefix /home/hetu/project/keco-studio run build
```

Run the `zig build` and `node --test` commands with `/home/hetu/project/keco-desktop` as the working directory. Expected: every command exits 0.

- [ ] **Step 5: Commit, push, request review, and prepare normal PRs**

```bash
git -C /home/hetu/project/keco-studio add -A
git -C /home/hetu/project/keco-studio commit -m "chore: move desktop release ownership"
git -C /home/hetu/project/keco-desktop push -u origin feat/desktop-repository-oauth
git -C /home/hetu/project/keco-studio push -u origin feat/desktop-repository-oauth
```

Open two PRs, one per repository, with the Web PR depending on the desktop repository PR. Request review only after the test evidence is attached; merge desktop ownership first, then the Web cleanup.

### Task 8: Configure Auth and Perform Release-Grade Manual Acceptance

**Files:**
- Modify: Supabase Auth dashboard Redirect URLs
- Modify: GitHub Actions workflow run and GitHub Release in `Keco-Studio/keco-desktop`
- Test: clean Windows and macOS installations

**Interfaces:**
- Consumes: published Web route and desktop release workflow.
- Produces: configured redirect authorization and manual evidence that installed artifacts support the intended login journey.

- [ ] **Step 1: Configure the required Supabase redirect URL before release**

In Supabase Dashboard, open Authentication, URL Configuration, and add exactly:

```text
http://127.0.0.1:*/auth/desktop/callback
```

Confirm the UI accepts the port wildcard. If Supabase does not support it, stop release publication and record the dashboard validation result; do not replace it with a broad public redirect or add a database migration.

- [ ] **Step 2: Run the new repository workflow with the first independent version**

Use Actions `Release Desktop Apps`, input `0.1.0-desktop.8`, and require each matrix job to pass its built-in executable/DMG architecture checks and the release job's three-asset assertion before publishing.

- [ ] **Step 3: Validate the Windows installer and installed application**

On a clean Windows account or VM, install `Keco-Studio-Setup-0.1.0-desktop.8-windows-x64.exe`, then double-click the installed `keco-studio.exe`. Confirm a pre-existing WebView session reaches `/projects`. After clearing only the WebView session, click Google login, complete an existing Google account in the default browser, confirm the browser returns to the loopback listener, and confirm the desktop WebView reaches `/projects`. Repeat by canceling the Google page and verify the login page shows a retryable error without a session.

- [ ] **Step 4: Validate both macOS architectures**

Install each matching DMG on Intel and Apple Silicon hardware, repeat the existing-session, successful Google, canceled Google, and second-launch checks from the Windows step, and ensure no WebView navigation opens Google directly.

- [ ] **Step 5: Record evidence and publish only after all gates pass**

Attach workflow URLs, installer artifact checksums, platform/manual acceptance results, and Supabase redirect confirmation to the release notes. Publish only when the desktop and Web PRs are merged in the specified order and all manual cases have passed.

## Plan Self-Review

**Spec coverage:** Repository ownership and root migration are Tasks 1, 4, and 7. The exact one-command bridge, origin policy, no-filesystem posture, fixed product origin, system browser, PKCE state/timeout/one-shot listener, code exchange, credential clearing, and main WebView handoff are Tasks 2 and 3. Web login and session completion are Tasks 5 and 6. Platform packaging, historical Windows/macOS protections, release version, redirect configuration, no migration, and installed-app acceptance are Tasks 4 and 8.

**Placeholder scan:** The plan contains no prohibited placeholder markers or unspecified test steps. Dashboard acceptance is deliberately explicit because it is an external configuration gate, not source code.

**Type consistency:** `desktop.begin_google_oauth` is the only command name throughout. The Web helper returns `Promise<void>` and the native response is intentionally opaque. `DesktopSession` maps `accessToken` and `refreshToken` to Supabase's `access_token` and `refresh_token`. OAuth APIs consistently call the fixed `Transaction` methods listed in Task 2.
