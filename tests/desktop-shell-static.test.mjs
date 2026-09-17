import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const desktopRoot = path.resolve(import.meta.dirname, '..');
const read = (relativePath) => readFileSync(path.join(desktopRoot, relativePath), 'utf8');

test('desktop manifest has one narrow remote WebView and OAuth bridge surface', () => {
  const manifest = JSON.parse(read('app.json'));

  assert.deepEqual(manifest.platforms, ['macos', 'windows']);
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
  assert.deepEqual(manifest.windows, [{
    label: 'main', title: 'Keco Studio', width: 1280, height: 800, restore_state: true,
  }]);
});

test('desktop shell opens the fixed production URL with one narrow OAuth bridge command', () => {
  const source = read('src/main.zig');

  assert.match(source, /https:\/\/keco-studio-main\.vercel\.app\/projects\?desktop=1/);
  assert.match(source, /desktop\.begin_google_oauth/);
  assert.match(source, /native_sdk\.bridge\.AsyncHandler/);
  assert.match(source, /\{\\"status\\":\\"started\\"\}/);
  assert.match(source, /\.async_registry\s*=\s*\.\{\s*\.handlers\s*=\s*&self\.bridge_handlers\s*\}/);
  assert.match(source, /self\.finished\.store\(true, \.release\);\s*self\.wake\.wake\(\) catch \{\};/);
  assert.match(source, /defer @memset\(&handoff_url, 0\);/);
  assert.match(source, /oauth\.exchangeCodeWithTimeout\(/);
  assert.match(read('src/oauth.zig'), /select\.concurrent\(\.deadline, exchangeDeadlineTask, \.\{io\}\);/);
  assert.doesNotMatch(source, /native_sdk\.bridge\.Handler/);
  assert.doesNotMatch(source, /window\.zero|frontend\/|productionSource|std\.debug\.print/);
});

test('desktop OAuth preserves a worker failure category for runtime diagnostics', () => {
  const source = read('src/main.zig');

  assert.match(source, /failure: anyerror,/);
  assert.match(source, /self\.outcome = \.\{ \.failure = err \};/);
  assert.match(source, /runtime\.recordDispatchError\("oauth", err\);/);
});

test('loopback callback describes pending completion instead of claiming sign-in success', () => {
  const source = read('src/oauth.zig');

  assert.match(source, /Finishing sign-in/);
  assert.doesNotMatch(source, /You can return to Keco Studio/);
});

test('desktop dependencies and popup patch are pinned to Native SDK 0.10.1', () => {
  const packageJson = JSON.parse(read('package.json'));
  const patch = read('patches/native-sdk-0.10.1-popup-block.patch');

  assert.equal(packageJson.devDependencies['@native-sdk/cli'], '0.10.1');
  assert.match(patch, /add_NewWindowRequested/);
  assert.match(patch, /ICoreWebView2NewWindowRequestedEventArgs/);
  assert.match(patch, /put_Handled\(TRUE\)/);
});

test('desktop build package fingerprint matches the Native SDK template for keco_studio', () => {
  assert.match(read('build.zig.zon'), /\.fingerprint = 0x6ded5f995a707070,/);
});

test('desktop release workflow is owned at the repository root', () => {
  const workflow = read('.github/workflows/release-desktop.yml');
  const build = read('build.zig');

  assert.doesNotMatch(workflow, /desktop\//);
  assert.match(workflow, /zig build -Dtarget=x86_64-windows-gnu -Dplatform=windows -Doptimize=ReleaseFast/);
  assert.match(workflow, /zig build -Dtarget=x86_64-macos -Dplatform=macos -Doptimize=ReleaseFast/);
  assert.match(workflow, /zig build -Dtarget=aarch64-macos -Dplatform=macos -Doptimize=ReleaseFast/);
  assert.match(workflow, /hdiutil detach -quiet -force "\$mount_point" \|\| true/);
  assert.equal((build.match(/\.win32_manifest = nativeSdkPath\(b, native_sdk_path, "assets\/native-sdk\.manifest"\);/g) ?? []).length, 2);
  assert.match(workflow, /-Dsupabase-anon-key="\$\{\{ secrets\.NEXT_PUBLIC_SUPABASE_ANON_KEY \}\}"/);
});
