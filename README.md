# ward-rails

Load [ward](https://github.com/br4zz4/ward) secrets into a private in-memory store at boot.

```ruby
Ward["RESEND_API_KEY"]                                      # value from the app context
Ward.secrets.resend_api_key                                 # same, method-style
Ward["commons:secrets.main.deploy.staging.TF_VAR_api_url"]  # explicit read outside the context
```

**Why not env vars?** The app context is loaded once, at boot, into a private frozen store — **nothing is written to `ENV`**. `ENV` is readable by every gem, every child process and most error reporters; that is the cheapest leak path when a process is compromised. Here the leaked surface is a store whose `inspect` shows keys only, and whose values are never echoed in errors.

The app fails fast, with an actionable message, when the context, a vault key or the `ward` binary is missing.

```sh
bin/rails ward:doctor   # prints the resolved setup (names only, never values) and flags problems
```

## Documentation

| Page | Use it when |
|---|---|
| [Getting started](docs/getting-started.md) | Adopting the gem, or upgrading from an older revision |
| [Configuration](docs/configuration.md) | Settings, env vars, precedence, per-scenario examples |
| [API reference](docs/api.md) | Reading secrets, reload, errors, test helpers |
| [Deployment](docs/deployment.md) | Docker, Kubernetes, cloud secret stores, offline builds, rotation |
| [Security](docs/security.md) | Threat model, key custody, ENV hygiene, limits |
| [Patterns](docs/patterns.md) | Multi-module repos, optional ward, keys in credentials, build steps |
| [Troubleshooting](docs/troubleshooting.md) | Symptom → cause → fix, error catalog |

## Requirements

- Rails `>= 8.0, < 9.0`, Ruby `>= 3.2`
- `ward >= v0.4.0` **installed** — installation is a prerequisite; the gem verifies the version at boot
- Linux or macOS, `amd64`/`arm64`

## Installation

```ruby
# Gemfile
gem "ward-rails", github: "br4zz4/ward-rails"
```

**Prerequisite: install ward on the machine that runs the app.** The gem resolves it in this order:

| Location | Use |
|---|---|
| `config.ward.bin` | explicit path |
| `WARD_EXECUTABLE_PATH` | base image, bootstrap, CI |
| `<project root>/bin/ward` | **standard** project-local install (gitignored, pinned per project) |
| `ward` on `PATH` | machine-wide (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`) |

The gem ships an optional helper for the project-local case — it downloads the pinned asset, verifies sha256 and executes it (`ward version`) before installing:

```sh
bin/rails ward:install
```

Bake it into the image during the build — boot never downloads anything. At boot, `ward version` is checked against `Ward::WARD_MIN_VERSION`; an older binary fails with `Ward::BinaryOutdated`.

- Project directory (passed as `-d`): `config.ward.dir` → `WARD_DIR` → `Rails.root` → current directory.
- `WARD_DIR` is the **folder**; `WARD_EXECUTABLE_PATH` is the **binary**.

## How it works

```
boot
 ├─ initializer: config.ward.dir defaults to Rails.root
 ├─ after_initialize → Ward.boot!
 │    ├─ WARD_CONTEXT missing?        → Ward::MissingContext
 │    ├─ binary missing (or too old)?            → Ward::BinaryNotFound
 │    ├─ ward -d <dir> --raw secrets --json <context>
 │    │    └─ exit != 0 / locked vault / empty scope → KeyUnavailable | LoadFailed
 │    └─ values frozen into Ward::Store
 └─ reads: memory only

Ward["vault:path"] (outside the context)
 └─ ward -d <dir> --raw get --json <path>   # once, then memoized for the process
```

Exactly **one subprocess at boot**. Out-of-context reads cost one subprocess each, the first time.

The gem reads the same `.ward/config.yaml` ward uses: `dir` is passed as `-d`, so vault paths, merges and key resolution behave exactly like the CLI.

## Configuration

`config/initializers/ward.rb`:

```ruby
Rails.application.config.ward.tap do |ward|
  ward.context = ENV["WARD_CONTEXT"]
  ward.keys = {
    "main" => Rails.application.credentials.ward_main_key, # String: the key itself
    "commons" => :WARD_KEY_COMMONS                         # Symbol: env var name, read lazily
  }
  ward.bin = Rails.root.join("bin/ward") # default; WARD_EXECUTABLE_PATH overrides
  ward.on_error = :raise                  # default; :warn boots with an empty store
end
```

| Setting | Default | Accepted |
|---|---|---|
| `context` | `ENV["WARD_CONTEXT"]` | scope string, e.g. `secrets.main.code.production` (**required**) |
| `keys` | `nil` — inherit the process environment | `Hash`: vault name → `String` (key), `Symbol` (env var name), `Proc` (callable) |
| `bin` | `<project root>/bin/ward`, then `ward` on `PATH` | path; `WARD_EXECUTABLE_PATH` is checked before the default |
| `on_error` | `:raise` | `:raise` or `:warn` |
| `dir` | `WARD_DIR`, then `Rails.root`, then the current directory | path to the ward project root |

With `keys = nil`, the subprocess inherits the process environment, so `WARD_KEY_<VAULT>` works with no configuration.

### Environment variables

| Variable | Meaning |
|---|---|
| `WARD_CONTEXT` | Scope the app runs in — **required** (unless `config.ward.context` is set) |
| `WARD_DIR` | Ward project root, passed to the CLI as `-d` (default: `Rails.root`, then the current directory) |
| `WARD_EXECUTABLE_PATH` | Path to an existing `ward` binary (default: `<project root>/bin/ward`, then `ward` on `PATH`) |
| `WARD_KEY_<VAULT>` | Vault encryption keys (one per vault; `config.ward.keys` replaces this) |
| `WARD_INSTALL_BASE_URL` | Alternate install source for `ward:install` — HTTP mirror or `file://` directory |
| `WARD_AI_MODE` | Set to `0` to stop ward from treating a terminal as an AI agent (see Troubleshooting) |

## API reference

| Call | Behavior |
|---|---|
| `Ward["NAME"]` | Context value; `nil` when absent. A name containing `:` is read lazily as a vault-qualified path (`"commons:secrets.main.deploy.staging.X"`), then memoized. |
| `Ward.secrets.NAME` | Method-style access to the same context value (`nil` when absent). |
| `Ward.fetch("NAME")` | Context value, or raises `Ward::MissingSecret` listing the available **key names** (never values). |
| `Ward.key?("NAME")` / `Ward.keys` | Presence check / key names. |
| `Ward.reload!` | Re-reads the context from the vault. Use it in a console; there is no automatic reload in dev. |
| `Ward.booted?` | `true` after a successful boot. |
| `Ward.configure { \|config\| ... }` | Mutates the configuration (same object as `Rails.application.config.ward`). |
| `Ward.reset!` | Clears store and configuration — test helpers only. |

Values are strings, duplicated and frozen. There is deliberately **no bulk hash accessor**: you read one secret at a time.

## Scopes and context

Contexts follow the project convention `<module>` → `code` → `<env>`:

```
secrets.main.code.production
secrets.<module>.code.<env>
```

A scope resolves **only the values at that exact node** — ancestors are not inherited, and same-name values across vaults collide (ward refuses to pick a winner). For anything outside the app context, read it explicitly with the vault qualifier:

```ruby
Ward["commons:secrets.main.deploy.staging.TF_VAR_api_url"]
```

That works as long as the vault's key is available (`WARD_KEY_COMMONS`, or `config.ward.keys["commons"]`). Missing key → `Ward::KeyUnavailable`, naming the vault and the env var to provide.

## Errors

| Error | When | Fix |
|---|---|---|
| `Ward::MissingContext` | `WARD_CONTEXT` empty/absent | Set it for the app process (`WARD_CONTEXT=secrets.main.code.production`) |
| `Ward::BinaryNotFound` | No executable `ward` found | `bin/rails ward:install`, or set `WARD_EXECUTABLE_PATH` |
| `Ward::BinaryMismatch` | `bin/ward` exists but the OS cannot run it (built for another OS/arch) | Run `bin/rails ward:install` on this platform — never copy the binary across platforms |
| `Ward::BinaryOutdated` | Installed ward is older than `Ward::WARD_MIN_VERSION` | Upgrade it (package manager, `brew upgrade ward`, or `bin/rails ward:install`) |
| `Ward::KeyUnavailable` | A needed vault has no key | Provide `WARD_KEY_<VAULT>` or `config.ward.keys[<vault>]` |
| `Ward::LoadFailed` | ward exited non-zero, bad JSON, or the scope resolved to nothing | Check the scope path and `ward secrets --json <scope>` output |
| `Ward::MissingSecret` | `Ward.fetch` on an absent key | Fix the name (the error lists available keys) |
| `Ward::ChecksumMismatch` | Downloaded binary does not match `checksums.txt` | Retry; if it persists, the release asset is wrong — do not bypass |
| `Ward::DownloadFailed` | Network/HTTP failure during `ward:install` | Retry with network access; or copy an existing binary and set `WARD_EXECUTABLE_PATH` |
| `Ward::UnsupportedPlatform` | OS/arch without a ward release asset | Install ward manually and set `WARD_EXECUTABLE_PATH` |

`on_error = :warn` downgrades boot-time errors (`MissingContext`, `BinaryNotFound`, `KeyUnavailable`, `LoadFailed`) to a logged warning and an empty store. Errors never include secret values — only exit status and a sanitized stderr line.

## Security

Threat model: **RCE in the app process**. A compromised process should get as little as possible.

What the gem does:

- Secrets live in a private store — **never in `ENV`**, which every gem and child process can read.
- Values are frozen; `inspect`/`to_s` show keys only; error messages carry no values.
- Only the app context is loaded at boot. Everything else is explicit and lazy.
- Keys are injected into the `ward` subprocess only. With `config.ward.keys`, keep them out of the app environment entirely:

  ```ruby
  # config/initializers/ward.rb
  ward.keys = { "main" => Rails.application.credentials.ward_main_key }
  ENV.delete_if { |name, _| name.start_with?("WARD_KEY_") }
  ```

  Rails credentials are a good home for the keys: encrypted at rest, decrypted by Rails itself.

Do not:

- copy loaded secrets back into `ENV` for convenience;
- log `Ward.keys` values or `Ward.secrets` contents;
- pass keys on the command line — the gem never does; they travel via the subprocess environment only.

Known limits, stated plainly: Ruby cannot zeroize memory — the GC copies strings and no API erases them. Once a secret is decrypted it exists in process memory until collected, so a memory dump after compromise can expose it. Lazy vs. memoized reads change little; if memory forensics is in your threat model, decrypt outside the app process (sidecar). That is out of scope here.

TOTP secrets are always read with `--raw`: you get the original `otpauth://` value, never a generated 6-digit code. Use `ROTP` in the app if you need codes.

## Deployment

The binary is **platform-specific and resolved when the command runs**, so a macOS developer and a Linux production app each install their own asset:

```
dev (macOS)            bin/rails ward:install  → bin/ward (darwin_arm64, gitignored, never committed)
image build (Linux)    bin/rails ward:install  → bin/ward (linux_amd64, inside the container)
```

`bin/ward` is gitignored by default. Keep it that way, and keep it out of the Docker build context so a developer's macOS binary can never be copied into a Linux image:

```gitignore
# .gitignore and .dockerignore
bin/ward
```

```dockerfile
COPY .ward .ward
RUN bin/rails ward:install   # runs inside the image → downloads the Linux asset
ENV WARD_CONTEXT=secrets.main.code.production
# WARD_KEY_MAIN / WARD_KEY_COMMONS from the secret store at runtime
```

Multi-arch builds (`docker buildx --platform linux/amd64,linux/arm64`) work per target: the installer runs inside each platform build and picks `linux_amd64` or `linux_arm64` accordingly. `ward:install` verifies the downloaded binary actually executes (`ward version`) before finishing, and boot raises `Ward::BinaryMismatch` if `bin/ward` cannot run on the host — so a stray cross-platform binary fails loudly, never silently.

Checklist:

- [ ] `bin/rails ward:install` runs in the image build (`bin/ward` exists at runtime).
- [ ] `bin/ward` is in `.gitignore` **and** `.dockerignore` (never commit or copy it across platforms).
- [ ] `.ward/config.yaml` and the vault files are in the image (or mounted).
- [ ] `WARD_CONTEXT` is set for the app process.
- [ ] Vault keys are available via `WARD_KEY_<VAULT>` or `config.ward.keys`.
- [ ] Rotation path defined: update the vault, then restart (or run `Ward.reload!`).

## Troubleshooting

**`Ward::MissingContext` on boot** — `WARD_CONTEXT` is not set for this process. Check `env | grep WARD_CONTEXT` in the exact context the app starts (systemd/K8s/Docker each have their own environment).

**`Ward::BinaryNotFound`** — run `bin/rails ward:install`; in images, verify the build step ran and `bin/ward` survived `.dockerignore`.

**`Ward::BinaryMismatch`, or `Exec format error` / `bad CPU type` in logs** — `bin/ward` was installed on another OS/arch (typically a developer's macOS binary copied into a Linux image through the build context). Run `bin/rails ward:install` inside the target platform or image build, and add `bin/ward` to `.dockerignore`. Never commit the binary.

**`Ward::KeyUnavailable: vault "commons" is locked`** — the vault has encrypted files but no key. Export `WARD_KEY_COMMONS` (value from `ward init`/bootstrap) or add it to `config.ward.keys`. Note that ward **skips** a vault without its key rather than failing — the gem turns "context came back empty" into an error on purpose.

**`Ward::LoadFailed: no secrets resolved for scope ...`** — the scope path does not exist at that depth. Run `ward secrets --json <context>` in the project root to compare. Remember: parent values are not inherited into a deeper scope.

**Conflict error** — two vaults define the same key at the same depth; ward refuses to choose. Rename or remove one value — scope order does not break the tie.

**`Ward::ChecksumMismatch`** — the downloaded asset does not match `checksums.txt`. Do not bypass verification; retry, and if it persists the release is broken (check the ward release page).

**App boot fails only inside an AI agent terminal** — ward refuses `--json` when it detects AI mode (`WARD_AI_MODE=1` or agent env markers like `OPENCODE_*`). That protection is for agents, not for the app: run the app with `WARD_AI_MODE=0`.

**Secret changed but the app still serves the old value** — the store is loaded once. Run `Ward.reload!` (console) or restart the process.

**`Ward["X"]` returns `nil`** — check `Ward.keys`; out-of-context keys need the vault-qualified path (`"vault:path"`), not a bare name.

## Keeping the pin current

`WARD_MIN_VERSION` is the single source of truth for the binary `ward:install` downloads. It moves forward automatically:

- **`rake ward:update`** — queries the latest ward release, rewrites `WARD_MIN_VERSION`, downloads and installs that binary. `WARD_VERSION=0.4.1 bundle exec rake ward:update` targets a specific release. It only runs inside this gem's source tree, only accepts stable `x.y.z`, and **never downgrades**: if the latest release is older than the pin, it reports up to date and changes nothing.
- **`.github/workflows/ward-version.yml`** — runs weekly, on `workflow_dispatch`, and on the `ward-release` repository dispatch sent by the ward release pipeline. It bumps, runs the whole suite against the new binary, and opens a PR with only `lib/ward/version.rb` changed.
- **Ward release hook** — ward's `release.yml` sends that dispatch after goreleaser publishes. It needs a fine-grained token (Contents: read/write on `ward-rails`) stored as the `WARD_RAILS_DISPATCH_TOKEN` secret in the ward repo; without it the step is skipped.

Upgrade flow in an app: bump the gem (new pin) → `bin/rails ward:install` → deploy. Never bump without the suite green — the workflow enforces it.

## Offline and air-gapped builds

Network is needed **only** by `ward:install` (build time) and `ward:update` (maintainer/CI). At runtime the app never touches the network: boot reads the local `.ward` files and executes the local `bin/ward`.

Three ways to build an image without network:

**1. Base image with ward already installed** — nothing to download; resolve via `PATH` or `WARD_EXECUTABLE_PATH`:

```dockerfile
FROM your-registry/ruby-with-ward:3.4
ENV WARD_EXECUTABLE_PATH=/usr/local/bin/ward
```

**2. Vendored release directory, installed from `file://`** — same layout as the GitHub release:

```
vendor/ward/v0.4.0/ward_linux_amd64.tar.gz
vendor/ward/v0.4.0/checksums.txt
```

```dockerfile
COPY vendor/ward vendor/ward
RUN WARD_INSTALL_BASE_URL=file:///app/vendor/ward bundle exec rake ward:install
```

**3. Internal HTTP mirror** — same layout (`v<version>/ward_<os>_<arch>.tar.gz` + `checksums.txt`):

```sh
WARD_INSTALL_BASE_URL=https://mirror.internal/ward bundle exec rake ward:install
```

In every case the sha256 is still verified against `checksums.txt`, and the binary must actually run (`ward version`) before it is swapped into `bin/ward` — an offline install is no less strict than an online one.

## Development

```sh
bundle install
bundle exec rake ward:install   # or: export WARD_EXECUTABLE_PATH=$(which ward)
bundle exec rake test
```

The suite uses a real `ward` binary (resolved from `WARD_EXECUTABLE_PATH`, `bin/ward`, then `PATH`) and generates throwaway vaults in temp dirs with fake values.

## License

MIT.
