# ward-rails

Load [ward](https://github.com/br4zz4/ward) secrets into a private in-memory store at boot. Nothing is written to `ENV`, and the app fails fast with an actionable error when the context, a key or the binary is missing.

```ruby
Ward["RESEND_API_KEY"]              # value from the app context
Ward.secrets.resend_api_key         # same, method-style
Ward.fetch("RESEND_API_KEY")        # raises Ward::MissingSecret listing available keys
Ward["commons:secrets.main.deploy.staging.TF_VAR_api_url"]  # lazy read outside the context
```

## Installation

```ruby
# Gemfile
gem "ward-rails", github: "br4zz4/ward-rails"
```

Install the pinned `ward` binary (verified against the release checksums):

```sh
bin/rails ward:install
```

Linux and macOS (`amd64`/`arm64`) are supported. The binary lands in `bin/ward` — bake it into your image build. `WARD_BIN` points at an existing binary instead (e.g. one installed via Homebrew).

## Usage

`WARD_CONTEXT` is required — it is the scope the app runs in, using the project convention:

```sh
WARD_CONTEXT=secrets.main.code.production
```

Keys resolve like ward: `WARD_KEY_<VAULT>` in the environment, or configure them explicitly:

```ruby
# config/initializers/ward.rb
Rails.application.config.ward.tap do |ward|
  ward.context = ENV["WARD_CONTEXT"]
  ward.keys = {
    "main" => Rails.application.credentials.ward_main_key, # String = the key itself
    "commons" => :WARD_KEY_COMMONS                         # Symbol = env var name
  }
  ward.bin = Rails.root.join("bin/ward") # default; WARD_BIN overrides
  ward.on_error = :raise                  # default; :warn boots with an empty store
end
```

Boot behavior:

- `WARD_CONTEXT` missing → `Ward::MissingContext`, with an example scope.
- `bin/ward` missing → `Ward::BinaryNotFound`, pointing at `bin/rails ward:install`.
- Vault without a key, conflict, or a scope that resolves to nothing → `Ward::LoadFailed` / `Ward::KeyUnavailable`, naming the vault and the key to provide.
- `on_error = :warn` downgrades all of the above to a warning and an empty store.

Change a secret? `Ward.reload!` in a console, or restart the app.

## Security

The threat model is **RCE in the app process**: a compromised process should get as little as possible.

- Secrets live in a private store — **never in `ENV`**, which every gem and child process can read.
- Stored values are frozen; `inspect` shows keys only, never values.
- Only the app context is loaded at boot. Out-of-context reads are lazy and explicit.
- Keys are injected into the `ward` subprocess only. With `config.ward.keys`, they never enter the app's `ENV`:

  ```ruby
  ward.keys = { "main" => Rails.application.credentials.ward_main_key }
  ENV.delete_if { |name, _| name.start_with?("WARD_KEY_") } # after boot
  ```

- Errors never include secret values — only exit status and a sanitized stderr.

Known limits, stated plainly: Ruby cannot zeroize memory (the GC copies strings around). Once a secret is decrypted it exists in process memory until it is garbage-collected — a memory dump after compromise can expose it. Reading lazily vs. memoizing changes little; if memory forensics is in your threat model, the answer is to decrypt outside the app process (sidecar), which is out of scope here.

TOTP secrets are always read with `--raw`: you get the original `otpauth://` value, never a generated 6-digit code. Generate codes with `ROTP` if you need them.

## Deployment checklist

- [ ] `bin/rails ward:install` runs in the image build (`bin/ward` present at runtime).
- [ ] `.ward/config.yaml` and the vault files are in the image (or mounted).
- [ ] `WARD_CONTEXT` is set for the app process.
- [ ] Vault keys are available via `WARD_KEY_<VAULT>` or `config.ward.keys`.

## Development

```sh
bundle install
bundle exec rake ward:install
bundle exec rake test
```

## License

MIT.
