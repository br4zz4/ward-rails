# Security

## Threat model

The gem is designed for **RCE in the app process**: an attacker who can execute code inside the app should get as little as possible, and should not be handed secrets by the gem's own design choices.

This is not a defense against memory forensics after compromise — see [limits](#limits-stated-plainly).

## What the gem guarantees

| Guarantee | How |
|---|---|
| Secrets are never written to `ENV` | The store is a private object; the gem never assigns to `ENV` |
| Keys never enter the app's `ENV` when configured in code | `config.ward.keys` injects them into the `ward` subprocess only |
| Values are not printed by accident | Frozen strings; `inspect`/`to_s` show key names only; there is no `to_h` |
| Errors never echo values | Only exit status and a sanitized stderr line; stdout is never embedded |
| No shell interpolation | The CLI runs via `Open3.capture3` with an argv array — no shell, no injection |
| No lazy downloads at boot | The binary is installed explicitly by `ward:install`; boot never fetches code |
| Supply-chain checks | Pinned version; sha256 verified against `checksums.txt`; binary executed (`ward version`) before being installed |
| Wrong-platform binaries fail loudly | Magic-byte check at load (`Mach-O` vs `ELF`), atomic install after verification |
| Only the context is loaded eagerly | Out-of-context reads are explicit and memoized |

## Key custody

Three ways to provide keys, with different exposure:

| Place | Exposure | Recommended when |
|---|---|---|
| `config.ward.keys` (String from Rails credentials or a KMS call) | Key lives in the credentials object / in memory; injected per subprocess | **Default choice** for Rails apps |
| `WARD_KEY_<VAULT>` in the process environment | Readable by every gem and child process, visible in `/proc/<pid>/environ` | Platform secret store injects env vars |
| `.ward/<vault>.key` file | Readable by the process user and anyone with the file | Local development |

If keys come from `config.ward.keys`, remove any leftovers from the environment after boot:

```ruby
# config/initializers/ward.rb
Rails.application.config.ward.keys = { "main" => Rails.application.credentials.ward_main_key }
ENV.delete_if { |name, _| name.start_with?("WARD_KEY_") }
```

Rails credentials are a good home for vault keys: encrypted at rest, committed as `.yml.enc`, decrypted by Rails with `RAILS_MASTER_KEY` — the same custody you already have for the app's other secrets.

Never:

- pass a key on a command line (visible in `ps`);
- log `config.ward.keys`, the vault key file content, or `Ward` values;
- bake keys into the image (mount or inject at runtime).

## Operational hygiene

- **Logs and APM**: do not log `Ward[...]` values. The store's redacted `inspect` protects you from accidental `puts Ward.secrets`, but a direct interpolation of the value does not.
- **Error reporting**: exceptions carry sanitized stderr only. When adding your own wrapper errors, keep values out of messages.
- **Subprocess environment**: the `ward` child inherits the app environment plus configured keys. Keep unrelated secrets out of `ENV`, or the child inherits them too.
- **Doctor output** contains key **names** and counts — safe to paste into incidents and CI logs. It never prints values.
- **TOTP**: values are always read with `--raw` (the `otpauth://` original), never a generated code. Generate codes in-process if needed (`ROTP`), which also avoids a static code being cached.

## Rotation

- **Secret rotation**: change the vault, then restart the process (or `Ward.reload!` in a console). Memoized out-of-context values are cleared by `reload!`.
- **Key rotation**: `ward rotate-key` in the project, distribute the new key to the environments, restart. A process holding the old key keeps working until restart; plan the window.

## Limits, stated plainly

- **Ruby cannot zeroize memory.** The GC copies strings; no API erases them. Once decrypted, a secret exists in process memory until collected. A memory dump taken after compromise can expose it.
- **Memoized reads extend the window.** Lazy out-of-context reads stay in memory for the process lifetime. Lazy vs. always-fresh changes little (both leave copies behind); memoization was chosen to avoid an extra subprocess per read.
- **If memory forensics is in your threat model**, the answer is architectural: decrypt outside the app process (a sidecar or a short-lived helper that hands the app only what it needs). That is out of scope for this gem.
- **The app can always read what it is allowed to read.** A compromised process can call the same APIs you can. The gem's job is to minimize what is loaded, where it lives, and how easily it leaks by accident — not to enforce authorization inside a compromised process.

## Checklist

- [ ] Keys come from credentials or a secret store, not the image and not the repo.
- [ ] `WARD_KEY_*` is not left in the app `ENV` when configured via `config.ward.keys`.
- [ ] No secret values in logs, metrics labels, traces, or error messages.
- [ ] `bin/rails ward:doctor` is part of the deploy smoke test (names only in output).
- [ ] Rotation runbook exists for values **and** keys.
- [ ] Optional mode (`on_error = :warn`) is not enabled where ward is the source of truth.
