# API reference

The public surface is the `Ward` module plus the configuration object and the error classes. There is deliberately no bulk hash accessor: you read one secret at a time.

## Reading secrets

### `Ward["NAME"]`

Returns the context value as a frozen `String`, or `nil` when the key is absent.

```ruby
Ward["RESEND_API_KEY"] # => "re_..."
Ward["TYPO"]           # => nil
```

A name containing `:` is treated as a **vault-qualified path** outside the context and read lazily:

```ruby
Ward["commons:secrets.main.deploy.staging.API_URL"]
```

The first read runs `ward --raw get --json <path>`; the value is memoized for the life of the process. The vault must have its key available (`WARD_KEY_COMMONS` or `config.ward.keys["commons"]`), otherwise `Ward::KeyUnavailable` names the key to provide.

### `Ward.fetch("NAME")`

Like `[]`, but raises `Ward::MissingSecret` when the key is absent. The message lists the available **key names** (never values) — useful to catch typos and config drift early.

```ruby
Ward.fetch("DATABASE_URL")
```

### `Ward.secrets.NAME`

Method-style access to the same context store. Useful in ERB or when a name is not a valid constant:

```ruby
Ward.secrets.resend_api_key
```

Unknown names raise `NoMethodError` (unlike `[]`, which returns `nil`).

### `Ward.key?("NAME")` / `Ward.keys`

Presence check and key names. `keys` returns the names in the order ward emitted them; never values.

```ruby
Ward.keys # => ["DATABASE_URL", "REDIS_URL", "RESEND_API_KEY"]
```

## Lifecycle

### `Ward.booted?`

`true` after a successful load (including `on_error = :warn` with an empty store).

### `Ward.reload!`

Re-runs the boot load: re-reads the context from the vault and **clears memoized out-of-context values**. Useful in a console after rotating a secret; a running web process should restart instead.

```ruby
Ward.reload!
Ward["RESEND_API_KEY"] # fresh value
```

`reload!` respects `on_error`: with `:raise` a load failure raises; with `:warn` it logs and empties the store.

### `Ward.configure { |config| ... }`

Yields the configuration object (the same instance as `Rails.application.config.ward`). Equivalent to setting `config.ward` in an initializer.

### `Ward.reset!`

Clears the store, the boot flag and the configuration. Test helpers only.

## Errors

| Error | Raised when | Typical fix |
|---|---|---|
| `Ward::MissingContext` | `WARD_CONTEXT` / `config.ward.context` is empty | Set the scope, e.g. `secrets.main.code.production` |
| `Ward::BinaryNotFound` | No executable `ward` found, or the configured path is not executable | `bin/rails ward:install` or set `WARD_EXECUTABLE_PATH` |
| `Ward::BinaryMismatch` | The binary exists but cannot run on this host (other OS/arch) | Reinstall on this platform |
| `Ward::BinaryOutdated` | Installed ward is older than the gem requires | Upgrade (package manager, or `bin/rails ward:install`) |
| `Ward::KeyUnavailable` | A needed vault has encrypted files but no key | Provide `WARD_KEY_<VAULT>` or `config.ward.keys[<vault>]` |
| `Ward::LoadFailed` | ward exited non-zero, returned invalid JSON, or the scope resolved to nothing | Check the scope depth and `ward secrets --json <scope>` |
| `Ward::MissingSecret` | `Ward.fetch` on an absent key | Fix the name (the error lists available keys) |
| `Ward::DownloadFailed` | Network/file failure during `ward:install`/`ward:update` | Retry, check the mirror/`file://` path |
| `Ward::ChecksumMismatch` | Downloaded asset does not match `checksums.txt` | Retry; do not bypass verification |
| `Ward::UnsupportedPlatform` | OS/arch without a ward release asset | Install ward manually, set `WARD_EXECUTABLE_PATH` |

All inherit from `Ward::Error`, so `rescue Ward::Error` catches any library failure. Message bodies never contain secret values: no stdout is echoed, and stderr is sanitized and truncated.

Errors **never** include another gem's exceptions (no `Errno::*`, no `URI::*`) — those are translated.

## Semantics worth knowing

- **The context is loaded once**, at `after_initialize`. Reads after boot never touch the network or the vault (except the first lazy out-of-context read).
- **Values are strings, duplicated and frozen.** Mutating them raises `FrozenError`; copying them is your responsibility.
- **`inspect`/`to_s` are redacted**: they show key names, never values.
- **Thread safety**: reads are safe from multiple threads; lazy reads are serialized by a mutex, so concurrent first reads invoke the binary once.
- **No `to_h`**: there is no supported way to dump the whole store. That is intentional — dumping secrets is exactly the operation you do not want available by accident.

## Testing an app that uses ward

- Prefer `on_error = :warn` in `test`, and let tests fail on a missing key explicitly (`Ward.fetch("X")`).
- Use `Ward.reset!` between tests that reconfigure the gem; it clears the configuration and the store.
- Never point tests at a real vault with real secrets. Generate a throwaway project in a temp dir with `ward init` / `ward set` and fake values, or set `config.ward.bin` to a stub that emits JSON (`--raw secrets --json` → object; `--raw get --json` → `{"path","value"}`).

Example test setup:

```ruby
def setup
  Ward.reset!
  Ward.configure do |config|
    config.context = "secrets.main.code.test"
    config.dir = Rails.root
    config.bin = Rails.root.join("bin/ward") # or a stub script
  end
end

def teardown
  Ward.reset!
end
```
