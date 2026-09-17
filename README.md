# Keco Studio Desktop Shell

This is a Native SDK WebView application, not a second Keco Studio frontend.
It always opens the deployed product at
`https://keco-studio-main.vercel.app/projects?desktop=1`.

## Development

```bash
npm ci
npm run check
zig build run
```

`@native-sdk/cli` is locked to `0.10.1` in `package-lock.json`. The check
command verifies the manifest, applies the pinned Windows popup-blocking patch,
and checks the shell's static security contract. The popup patch intentionally
fails when Native SDK's expected Windows host source changes.

The shell has no filesystem permission, local API server, or bundled Next.js
assets. It permits one application bridge command for desktop Google sign-in,
callable only by the Keco Studio production origin.
Google authorization opens in the system browser and the returned session is
handed to the existing WebView without persistent native credential storage.

## Release requirements

Set the repository Actions secret `NEXT_PUBLIC_SUPABASE_ANON_KEY` before
running `Release Desktop Apps`. It is the public Supabase client key used for
the PKCE token exchange and is compiled into release builds only.

Supabase Auth must allow this redirect pattern before a release is published:

```text
http://127.0.0.1:*/auth/desktop/callback
```

This is a Supabase Auth dashboard setting. It does not require a database
migration. See [release documentation](docs/release.md) for the release and
installation flow.
