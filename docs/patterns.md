# Patterns and recipes

## Multi-module repository

The vault lives at the repo root; the Rails app is nested (`modules/<name>/code`). Point `dir` at the root and keep everything else default:

```ruby
# config/initializers/ward.rb
Rails.application.config.ward.dir = ENV.fetch("WARD_DIR") { Rails.root.join("../../..").expand_path }
```

```sh
WARD_CONTEXT=secrets.<module>.code.<env>
```

In containers, mount the vault and set `WARD_DIR` to the mount point instead of relying on relative paths — relative paths depend on how the image is laid out, mounts do not.

## Optional ward with env fallback

Some runtimes inject secrets as environment variables (cloud secret stores) while development uses ward. Keep a single, explicit fallback helper:

```ruby
# config/initializers/ward.rb
Rails.application.config.ward.on_error = :warn if ENV["WARD_OPTIONAL"] == "1"
```

```ruby
# app/lib/secret.rb
module Secret
  module_function

  # ward first; platform-injected environment second
  def fetch(name)
    Ward[name].presence || ENV[name].presence ||
      raise(KeyError, "missing secret #{name}")
  end
end
```

Guardrails, because this pattern can hide a broken ward setup forever:

- run `bin/rails ward:doctor` in the deploy pipeline of environments where ward is expected to work;
- keep the fallback in **one** place — no ad-hoc `|| ENV[...]` scattered across the app;
- log a warning (once) when the fallback is used in an environment where ward should be authoritative;
- never enable optional mode where ward is the source of truth.

## Keys in Rails credentials

Removes keys from the app environment entirely:

```ruby
# config/initializers/ward.rb
Rails.application.config.ward.tap do |ward|
  ward.keys = {
    "main" => Rails.application.credentials.ward_main_key,
    "commons" => Rails.application.credentials.ward_commons_key
  }
end

# drop anything the platform may still inject
ENV.delete_if { |name, _| name.start_with?("WARD_KEY_") }
```

The keys are injected into the `ward` subprocess only, one invocation at a time. Store them with `bin/rails credentials:edit` (or keep them in your bootstrap vault, as the project convention does).

## Partial key override

`config.ward.keys` does not have to list every vault. Omitted vaults keep the normal resolution (`WARD_KEY_<VAULT>`, then key files):

```ruby
ward.keys = { "commons" => :WARD_KEY_COMMONS } # main still resolves from .ward/main.key or WARD_KEY_MAIN
```

## Cross-vault reads

The context is loaded at boot; anything else is read on demand with a vault-qualified path:

```ruby
Ward["commons:secrets.main.deploy.staging.TF_VAR_api_url"]
```

First read costs one subprocess; the value is memoized until the process restarts (`Ward.reload!` clears it). If you need one of these values during boot, read it in an initializer — it will simply happen once, earlier.

Do not build a loop over `Ward.keys` to copy values into `ENV` or into another store: that recreates the leak surface the gem exists to avoid.

## Build steps that boot the app

`assets:precompile`, `db:migrate`, `ward:*` and friends initialize Rails. In stages without vault access, run them in optional mode:

```ruby
ward.on_error = :warn if ENV["WARD_OPTIONAL"] == "1" || Rails.env.test?
```

```dockerfile
RUN WARD_OPTIONAL=1 bin/rails assets:precompile
RUN bin/rails ward:install          # install after: nothing above needed the binary
```

Preferred alternative: provide `WARD_CONTEXT` and keys in the build — the build then exercises the same path production will.

## Development setup

`direnv` (`.envrc`, not committed):

```sh
export WARD_CONTEXT=secrets.main.code.development
export WARD_DIR="$PWD"
# only when running the app from inside an AI agent terminal
export WARD_AI_MODE=0
```

Compose: mount the vault read-only and set `WARD_DIR`/`WARD_EXECUTABLE_PATH` (see [deployment](deployment.md#local-development)).

## Test suite

- `on_error = :warn` in `test`; assert on specific keys with `Ward.fetch` so a missing key fails the test that needs it.
- Generate a throwaway vault in a temp dir with `ward init` / `ward set` and fake values; never point tests at a real vault.
- Or stub the binary: `config.ward.bin` → a script that implements `--raw secrets --json <scope>` and `--raw get --json <path>`.
- `Ward.reset!` between tests that change configuration.

## One app, multiple environments

One scope per environment (`secrets.main.code.staging`, `secrets.main.code.production`), selected by `WARD_CONTEXT`. Do not encode the environment in `dir`; the vault layout should not change between environments.

## Anti-patterns

| Anti-pattern | Why it hurts |
|---|---|
| Sniffing `ARGV` to decide `on_error` | Fragile: a new command name changes boot behavior; hides real load failures |
| Copying ward values into `ENV` | Recreates the leak surface (every gem and child process can read it) |
| Logging or reporting `Ward` values | They reach APM/log aggregation forever |
| Committing `bin/ward` or `.ward/*.key` | Wrong platform in images; leaked key |
| Bumping the gem without rerunning `ward:doctor` | Env names and behavior change between revisions |
| Using one shared context across modules | Loads secrets a module does not need |
