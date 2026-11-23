# Troubleshooting

## Start here

```sh
bin/rails ward:doctor
```

It prints the resolved context, project directory, binary (with `ward version`), configured keys (names only), how many secrets the scope resolved, and a `hint` for each problem. Exit code is non-zero when something is wrong, so it doubles as a smoke test.

Example of a healthy run:

```
ward-rails doctor
  ruby:        3.2.2 (arm64-darwin23)
  context:     secrets.core.code.staging
  project dir: /repo
  keys:        env=WARD_KEY_LUNETAMAGICA
  binary:      /usr/local/bin/ward (ward version 0.4.1)
  scope:       12 key(s): DATABASE_URL, REDIS_URL, RESEND_API_KEY, ...
  status:      ok
```

## Diagnosis ladder

Run from the app root, in the same environment the app boots from:

```sh
bin/rails ward:doctor                                   # whole setup at once
ward -d "$WARD_DIR" vaults                              # which vaults and paths
ward -d "$WARD_DIR" tree secrets.<module>.code.<env>    # does the scope exist at that depth?
ward -d "$WARD_DIR" secrets --json secrets.<module>.code.<env> | head -c 300
                                                        # machine output the gem consumes (values shown — careful)
```

`ward tree` is the reference for "why is my scope empty": it shows the exact depth at which values live.

## Error catalog

| Error | Meaning | Fix |
|---|---|---|
| `Ward::MissingContext` | No scope configured | Set `WARD_CONTEXT` for the app process — check the process environment, not your shell only |
| `Ward::BinaryNotFound` | No runnable `ward` found | `bin/rails ward:install`, or set `WARD_EXECUTABLE_PATH` |
| `Ward::BinaryMismatch` | Binary exists but cannot run here | Installed for another OS/arch — reinstall on this platform |
| `Ward::BinaryOutdated` | Binary is older than the gem requires | Upgrade: `brew upgrade ward`, package manager, or `bin/rails ward:install` |
| `Ward::KeyUnavailable` | A vault has encrypted files but no key | Export `WARD_KEY_<VAULT>` or add the vault to `config.ward.keys` |
| `Ward::LoadFailed` | ward exited non-zero, bad JSON, or empty scope | Check the scope depth with `ward tree`; check conflicts |
| `Ward::MissingSecret` | `Ward.fetch` on an absent name | Fix the name — the message lists available keys |
| `Ward::ChecksumMismatch` | Downloaded asset ≠ `checksums.txt` | Retry; if persistent, the release asset is wrong — do not bypass |
| `Ward::DownloadFailed` | Network/`file://` failure during install | Retry; for mirrors/offline check `WARD_INSTALL_BASE_URL` |
| `Ward::UnsupportedPlatform` | OS/arch without a release asset | Install ward manually, set `WARD_EXECUTABLE_PATH` |

## Symptom → cause → fix

### Works locally, fails in the image

Cause, in order of frequency:

1. `.ward/config.yaml` (or the vault files) not copied into the image, or excluded by `.dockerignore`.
2. `WARD_CONTEXT` set in the CI shell but not in the container environment.
3. Keys injected into CI but not into the runtime.
4. `bin/ward` copied from the developer machine (macOS binary in a Linux image) — `Ward::BinaryMismatch`.

Fix: `doctor` inside the image (`docker run --rm <image> bin/rails ward:doctor`), then compare with the list above.

### Boots, but every value is `nil`

`Ward[...]` returns `nil` and no error was raised — the store is empty. That happens when `on_error = :warn` swallowed a real problem. Run `doctor`; the scope line will show the error and the hint. Common causes: scope path does not exist at that depth, context typo, missing key.

### `assets:precompile` / `db:migrate` fails during the build

The command boots Rails, so it boots the gem. Either provide context and keys in that stage, or run it in optional mode (`WARD_OPTIONAL=1` + `ward.on_error = :warn if ENV["WARD_OPTIONAL"]`). See [deployment](deployment.md#build-steps-that-boot-the-app).

### `Exec format error`, `bad CPU type`, or `Ward::BinaryMismatch`

`bin/ward` was installed for another platform — typically a macOS binary copied into a Linux image through the build context. Reinstall inside the target build and add `bin/ward` to `.dockerignore`.

### `Ward::BinaryOutdated`

The installed `ward` is older than the version the gem requires (`Ward::WARD_MIN_VERSION`) — usually a machine-wide binary from before the `--json` output existed. Upgrade it:

```sh
brew upgrade ward                 # machine-wide (or your package manager)
bin/rails ward:install            # project-local, pinned to the gem's version
```

Then run `bin/rails ward:doctor` to confirm the version line.

### Boot fails only inside an AI agent terminal

ward refuses `--json` when it detects an AI agent (`WARD_AI_MODE=1` or markers such as `OPENCODE_*`). That protection is for agents, not for the app. Run the app with:

```sh
WARD_AI_MODE=0
```

Do not unset this protection globally on the developer machine; scope it to the app process.

### Conflict between vaults

Two vaults define the same key at the same depth; ward refuses to pick a winner. Rename or remove one value. Scope order does not break the tie.

### Scope resolves to zero secrets

`ward tree <scope>` shows where values actually live. Remember: a scope returns **only the values at that exact depth**. A value defined one level up is not inherited. Typical fix: correct the scope path (module/env), or move the value to the expected depth.

### `KeyUnavailable: vault "X" is locked`

The vault has encrypted files but no key. ward **skips** locked vaults instead of failing, so this surfaces as "scope empty" when the locked vault was the one holding the context. Provide `WARD_KEY_X` (name is uppercased) or add it to `config.ward.keys`. The error message names the env var.

### `ward:install` fails with 404

The pinned version has no asset for this platform, or the release does not exist. The message includes the asset name and the version. Check the release page; if you build offline, point `WARD_INSTALL_BASE_URL` at your mirror or `file://` directory.

### Tests fail after upgrading the gem

Environment variable names changed between revisions (notably `WARD_BIN` → `WARD_EXECUTABLE_PATH`, and the new `WARD_DIR`). Update the test harness, CI variables and compose files. Then re-run `ward:doctor` in each environment.

### `Ward["X"]` is `nil` for a key you can see in the vault

- The key is outside the context: out-of-context reads require a vault-qualified path (`"vault:secrets.module.code.env.KEY"`).
- Wrong depth: the value is not at the context's exact node.
- Stale process: the store loads at boot; restart or `Ward.reload!`.

## Support bundle

When asking for help, include — never values:

- `bin/rails ward:doctor` output (context, dir, keys names, scope count/names);
- gem revision (`Gemfile.lock`: `revision:`), `ward version`;
- Ruby and Rails versions;
- the error class and message;
- what changed recently (new env, new image, gem bump).
