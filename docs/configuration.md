# Configuration

Everything is configured through `Rails.application.config.ward`, or through environment variables when you want to avoid code per environment.

```ruby
# config/initializers/ward.rb
Rails.application.config.ward.tap do |ward|
  ward.context = nil                     # default: ENV["WARD_CONTEXT"]
  ward.dir = nil                         # default: ENV["WARD_DIR"] → Rails.root → Dir.pwd
  ward.bin = nil                         # default: ENV["WARD_EXECUTABLE_PATH"] → <dir>/bin/ward → PATH
  ward.keys = nil                        # default: inherit the process environment
  ward.on_error = :raise                 # default; :warn boots with an empty store
end
```

## Settings

| Setting | Type | Default | Meaning |
|---|---|---|---|
| `context` | String | `ENV["WARD_CONTEXT"]` | Scope loaded at boot, e.g. `secrets.main.code.production`. **Required** unless `on_error = :warn`. |
| `dir` | path | `ENV["WARD_DIR"]` → `Rails.root` → `Dir.pwd` | Ward project directory, passed to the CLI as `-d`. Must contain `.ward/config.yaml`. |
| `bin` | path | `ENV["WARD_EXECUTABLE_PATH"]` → `<dir>/bin/ward` → `ward` on `PATH` | The `ward` executable. |
| `keys` | Hash | `nil` — inherit the process environment | Vault name → key source. See below. |
| `on_error` | `:raise` / `:warn` | `:raise` | What to do when the context cannot be loaded at boot. |

Precedence is always **explicit config first, then environment, then the built-in default**. The initializer runs before boot, so anything set there wins.

### Where the binary comes from

The `ward` binary is a **prerequisite**: the gem never downloads it at boot. It is resolved in this order:

| Step | Source | Typical use |
|---|---|---|
| 1 | `config.ward.bin` | Explicit path in an initializer |
| 2 | `WARD_EXECUTABLE_PATH` | Base image, bootstrap, CI |
| 3 | `<project root>/bin/ward` | **standard project-local install** (gitignored, version pinned per project) |
| 4 | `ward` on `PATH` | Machine-wide install (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`) |

Once resolved, the gem runs `ward version` **once at boot** and requires `>= #{Ward::WARD_MIN_VERSION}`. An older binary fails with `Ward::BinaryOutdated` — never with an obscure payload error.

### `keys`

| Value type | Meaning |
|---|---|
| `String` | The key material itself |
| `Symbol` | Name of an environment variable, resolved at each read (`:WARD_KEY_COMMONS` → `ENV["WARD_KEY_COMMONS"]`) |
| `Proc` | Called at each read; return the key material |

```ruby
ward.keys = {
  "main" => Rails.application.credentials.ward_main_key,
  "commons" => :WARD_KEY_COMMONS,
  "infra" => -> { Vault.read("infra/ward-key") }
}
```

Keys are injected only into the `ward` subprocess environment — they are never written to the app's `ENV`. When `keys` is `nil`, the subprocess simply inherits the process environment, so `WARD_KEY_<VAULT>` works with no configuration.

Only the keys you list are explicitly injected; a vault missing from `keys` still falls back to the normal ward resolution (`WARD_KEY_<VAULT>`, then key files). This makes partial overrides safe.

### `on_error`

| Value | Boot behavior |
|---|---|
| `:raise` (default) | Any load problem aborts the boot with a typed error and an actionable message |
| `:warn` | The problem is logged, the app boots with an **empty store**, every `Ward[...]` returns `nil` |

`:warn` exists for environments where ward is optional (test suites, build steps, or a runtime where secrets arrive through another channel). It is a footgun in production: a typo in `WARD_CONTEXT` becomes a silently empty store. Use [optional mode](patterns.md#optional-ward-with-env-fallback) deliberately and keep `ward:doctor` in the deploy checklist.

## Environment variables

| Variable | Consumed by | Meaning |
|---|---|---|
| `WARD_CONTEXT` | gem | Scope loaded at boot |
| `WARD_DIR` | gem | Ward project directory (`-d`) |
| `WARD_EXECUTABLE_PATH` | gem | Path to an existing `ward` binary |
| `WARD_KEY_<VAULT>` | ward | Per-vault encryption key (vault name uppercased) |
| `WARD_KEY` | ward | Global fallback key |
| `WARD_INSTALL_BASE_URL` | `ward:install`, `ward:update` | Alternate source: HTTP mirror or `file://` directory |
| `WARD_AI_MODE` | ward | Set to `0` to disable AI-agent detection (relevant in local terminals, see [troubleshooting](troubleshooting.md#boot-fails-only-inside-an-ai-agent-terminal)) |

`WARD_DIR` and `WARD_EXECUTABLE_PATH` are unrelated: one is a folder, the other is a file. Mixing them up produces either "not a ward project" (wrong folder) or "binary not found" (wrong file).

## Examples by scenario

**Single-module app, vault at the repo root (the common case):**

```sh
WARD_CONTEXT=secrets.main.code.production
# dir defaults to Rails.root, binary to <Rails.root>/bin/ward
```

**Multi-module repo, vault outside `Rails.root`:**

```ruby
ward.dir = ENV.fetch("WARD_DIR") { Rails.root.join("../../..").expand_path }
```

**Container with the vault mounted read-only:**

```yaml
environment:
  WARD_CONTEXT: secrets.core.code.staging
  WARD_DIR: /repo
  WARD_EXECUTABLE_PATH: /usr/local/bin/ward
volumes:
  - ./.ward:/repo/.ward:ro
```

**Keys from Rails credentials, nothing in `ENV`:**

```ruby
ward.keys = { "main" => Rails.application.credentials.ward_main_key }
ENV.delete_if { |name, _| name.start_with?("WARD_KEY_") }
```

**Optional ward (runtime gets secrets elsewhere):**

```ruby
ward.on_error = :warn if ENV["WARD_OPTIONAL"] == "1"
```

## Configuration is not reloaded

Settings are read when they are used: `context` at boot, `dir` and `bin` on each CLI invocation. Changing `ENV` at runtime is not a supported configuration path — set the variables before the process starts, or call `Ward.reload!` after changing `config.ward` in a console.

## Validation

There is no separate validation step. The gem fails where the problem is:

- missing context → `Ward::MissingContext`
- missing binary → `Ward::BinaryNotFound`
- binary for another platform → `Ward::BinaryMismatch`
- binary older than the gem requires → `Ward::BinaryOutdated`
- vault without key → `Ward::KeyUnavailable`
- bad scope, conflict, or empty result → `Ward::LoadFailed`

Each error names what to fix. `bin/rails ward:doctor` runs the same checks without raising, and prints all of them at once.
