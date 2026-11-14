# Getting started

This guide takes an existing Rails app to "boots with its ward secrets" and ends with a verification step. Every step has a checkpoint; if one fails, jump to [troubleshooting](troubleshooting.md).

## 0. Requirements

| Requirement | Notes |
|---|---|
| Rails `>= 8.0, < 9.0` | Railtie + `after_initialize` boot |
| Ruby `>= 3.2` | Rails 8 baseline |
| `ward >= 0.4.0` | The gem consumes `ward secrets --json` and `ward get --json` |
| Linux or macOS (`amd64`/`arm64`) | Windows is not supported |

The gem pins the ward version it installs (`Ward::WARD_MIN_VERSION`). The pin is the single source of truth for `bin/rails ward:install`.

## 1. Add the gem

```ruby
# Gemfile
gem "ward-rails", github: "br4zz4/ward-rails"
```

```sh
bundle install
```

Pin a revision in `Gemfile.lock` like any git gem. When you upgrade the gem, read [the upgrade checklist](#upgrade-checklist) first — environment variable names and boot behavior have changed between revisions.

**Checkpoint:** `bundle show ward-rails` points at the revision you expect.

## 2. Install the binary before boot

```sh
bin/rails ward:install
```

This downloads the pinned release asset for **the machine running the command**, verifies its sha256 against `checksums.txt`, runs `ward version` to prove it executes, and only then installs it into `bin/ward`.

- In an image build, run it inside the build (the container's platform wins).
- Keep `bin/ward` out of git **and** out of the Docker build context:

```gitignore
# .gitignore and .dockerignore
bin/ward
```

- Already have ward installed (Homebrew, base image)? Set `WARD_EXECUTABLE_PATH=/usr/local/bin/ward` and skip this step. Alternatively keep `ward` on `PATH`.

**Checkpoint:** `bin/ward version` prints the pinned version.

## 3. Set the context

The context is the scope the app runs in, following the project convention `secrets.<module>.code.<env>`:

```sh
WARD_CONTEXT=secrets.main.code.production
```

It is read at boot. There is no default scope on purpose: a wrong guess loads the wrong secrets. If `WARD_CONTEXT` is missing and `on_error` is `:raise` (the default), boot fails with `Ward::MissingContext`.

You can also set it in code (`config.ward.context`), which is useful when the app derives it from its own environment name — but the environment variable is the recommended path.

**Checkpoint:** `echo $WARD_CONTEXT` shows the scope in the same environment the app boots from (shell, systemd unit, Kubernetes pod spec, container env — each is independent).

## 4. Point at the vault (only when it is not `Rails.root`)

The gem passes the project directory to ward as `-d`. Resolution order:

```
config.ward.dir  →  WARD_DIR  →  Rails.root  →  current directory
```

For a **multi-module repository** where the vault lives at the repo root but `Rails.root` is `modules/<name>/code`, set it explicitly:

```ruby
# config/initializers/ward.rb
Rails.application.config.ward.dir = ENV.fetch("WARD_DIR") { Rails.root.join("../..").expand_path }
```

or simply export `WARD_DIR=/path/to/repo/root` and let the default `Rails.root` be overridden. In containers, mount the vault and point `WARD_DIR` at the mount:

```yaml
environment:
  WARD_DIR: /repo
volumes:
  - ./.ward:/repo/.ward:ro
```

**Checkpoint:** `ward -d "$WARD_DIR" vaults` lists the vaults from `.ward/config.yaml`.

## 5. Make the keys available

Keys resolve exactly like the CLI: `WARD_KEY_<VAULT>` in the environment, a `.ward/<vault>.key` file, or the global `WARD_KEY`. The gem adds one option — keys configured in code, injected only into the subprocess:

```ruby
Rails.application.config.ward.keys = {
  "main" => Rails.application.credentials.ward_main_key, # String = the key
  "commons" => :WARD_KEY_COMMONS                         # Symbol = env var name, read lazily
}
```

Benefits of `config.ward.keys`: the key never has to live in the app's `ENV`, and Rails credentials are encrypted at rest. See [security](security.md#key-custody).

**Checkpoint:** `weather`-style check with the doctor:

```sh
bin/rails ward:doctor
```

Expected: `binary: ... (ward version 0.4.x)`, `scope: N key(s): ...`, `status: ok`.

## 6. Use the secrets

```ruby
Ward["RESEND_API_KEY"]        # context value, nil when absent
Ward.fetch("RESEND_API_KEY")  # raises Ward::MissingSecret, listing available names
Ward["commons:secrets.main.deploy.staging.API_URL"]  # explicit read outside the context
```

`Ward` is a store, not a proxy: the context is loaded once at boot, out-of-context reads are lazy and memoized, and nothing is written back to `ENV`. Full semantics in the [API reference](api.md).

**Checkpoint:** a console check:

```sh
bin/rails runner 'puts Ward.keys.sort.first(5)'
```

## 7. Handle steps that boot without secrets

Any command that boots the app needs a loadable context — including `assets:precompile`, `db:migrate` and `ward:*` in environments where the vault is unavailable. Three options, in order of preference:

1. **Provide the context and keys** in that build step (best: it proves the boot path in CI).
2. **Optional mode with a warning** for commands that do not need secrets:

   ```ruby
   Rails.application.config.ward.tap do |ward|
     ward.on_error = :warn if ENV["WARD_OPTIONAL"] == "1" || Rails.env.test?
   end
   ```

   Then run those commands with `WARD_OPTIONAL=1`. Do **not** sniff `ARGV` prefixes — it is fragile and hides real failures.
3. **Skip the gem entirely** for that command by not loading Rails (`bundle exec rake db:migrate` still boots; a standalone task that never initializes the app avoids it).

In test suites, `on_error = :warn` is usually the right default; tests should not depend on real secrets.

**Checkpoint:** `WARD_OPTIONAL=1 bin/rails assets:precompile` completes with a warning and an empty store.

## 8. Deploy

Copy `.ward/config.yaml` and the vault files into the image (or mount them), run `ward:install` in the build, and provide `WARD_CONTEXT` plus keys at runtime. Full recipes: [deployment](deployment.md).

## 9. Verify in the target environment

```sh
bin/rails ward:doctor
```

In production, this is the fastest way to prove that the context, binary, vault and keys all line up. Keep it in your post-deploy checklist.

## Upgrade checklist

When bumping the gem revision:

- [ ] `WARD_BIN` is gone: use `WARD_EXECUTABLE_PATH` (binary) and `WARD_DIR` (folder).
- [ ] Run `bin/rails ward:install` again if the pinned ward version changed (`Ward::WARD_MIN_VERSION`).
- [ ] Re-run the suite with the new binary; `ward:install` verifies it executes before swapping.
- [ ] Re-run `bin/rails ward:doctor` in each environment.
- [ ] Review [security](security.md) if the app keeps keys in `ENV`.

## Mental model, in one screen

```
Gemfile → ward-rails (Railtie)
boot    → after_initialize → Ward.boot!
            ├─ context?   config.ward.context | WARD_CONTEXT
            ├─ dir?       config.ward.dir | WARD_DIR | Rails.root | cwd
            ├─ binary?    config.ward.bin | WARD_EXECUTABLE_PATH | <dir>/bin/ward | PATH
            ├─ keys?      config.ward.keys | WARD_KEY_<VAULT> | .ward/<vault>.key | WARD_KEY
            └─ run        ward -d <dir> --raw secrets --json <context>
                          → frozen in-memory store (no ENV writes)

reads   → memory; "vault:path" triggers one memoized `ward get --json`
errors  → raise at boot (default) or warn + empty store (on_error = :warn)
```
