# Deployment

The model in one line: **the binary and the vault are build/runtime inputs; the network is needed only when installing.**

```
prereq  → ward >= Ward::WARD_MIN_VERSION installed (bin/ward, PATH, or WARD_EXECUTABLE_PATH)
build   → bin/rails ward:install         (optional convenience: platform here, checksum verified)
image   → bin/ward + .ward/config.yaml + vault files
runtime → WARD_CONTEXT + keys → boot reads the vault locally → in-memory store
```

The gem verifies the binary at boot (`ward version`) and refuses versions below `Ward::WARD_MIN_VERSION` with `Ward::BinaryOutdated`. Installing is your choice — project-local, machine-wide, base image, or the bundled rake helper.

## Local development

Compose with the vault mounted read-only and the binary already in the dev image:

```yaml
services:
  app:
    environment:
      WARD_CONTEXT: secrets.core.code.development
      WARD_DIR: /repo                       # folder containing .ward/config.yaml
      WARD_EXECUTABLE_PATH: /usr/local/bin/ward
    volumes:
      - ./:/source
      - ./.ward:/repo/.ward:ro
```

If the binary lives in `bin/ward` instead, drop `WARD_EXECUTABLE_PATH` and let the default apply.

Outside containers, a `.envrc` (direnv) or shell profile with `WARD_CONTEXT` + `WARD_DIR` is enough. Remember `WARD_AI_MODE=0` when running the app from inside an AI agent terminal (see [troubleshooting](troubleshooting.md#boot-fails-only-inside-an-ai-agent-terminal)).

## Image build

```dockerfile
# 1. gems
COPY Gemfile Gemfile.lock ./
RUN bundle install

# 2. source + vault metadata (encrypted files; safe to copy)
COPY . .
COPY .ward .ward

# 3. install the binary INSIDE the build → correct platform asset
RUN bin/rails ward:install

# runtime
ENV WARD_CONTEXT=secrets.main.code.production
# WARD_KEY_<VAULT> from the secret store at runtime
```

Rules:

- `bin/ward` is platform-specific. It must never enter the build context from a developer machine: add it to **`.gitignore` and `.dockerignore`**.
- If you prefer a single bin directory, move it and point the gem at it:

  ```dockerfile
  RUN mv bin/ward /usr/local/bin/ward
  ENV WARD_EXECUTABLE_PATH=/usr/local/bin/ward
  ```

- `WARD_DIR` only needs to be set when `.ward/` is not at `Rails.root` (multi-module repos, mounts).

### Build steps that boot the app

`assets:precompile`, `db:migrate`, and any `bin/rails` command boot Rails — and therefore the gem. In a build stage without the vault keys, the boot fails with `Ward::KeyUnavailable` / `Ward::LoadFailed`. Options, in order of preference:

1. **Provide context and keys in the build** — the build proves the production path.
2. **Optional mode for that stage**:

   ```dockerfile
   RUN WARD_OPTIONAL=1 bin/rails assets:precompile
   ```

   with

   ```ruby
   ward.on_error = :warn if ENV["WARD_OPTIONAL"] == "1"
   ```

3. **Omit `WARD_CONTEXT`** in that stage and run with `on_error = :warn` by default there.

Note the ordering: `ward:install` must run **before** any command that boots the app if that command needs the binary. Installing it after `assets:precompile` is fine as long as the precompile runs in optional mode.

## Kubernetes / any container runtime

```yaml
env:
  - name: WARD_CONTEXT
    value: secrets.main.code.production
  - name: WARD_DIR
    value: /app                        # if .ward/ is not at Rails.root
  - name: WARD_KEY_MAIN
    valueFrom:
      secretKeyRef: { name: ward-keys, key: main }
volumeMounts:
  - name: ward-vault
    mountPath: /app/.ward
    readOnly: true
volumes:
  - name: ward-vault
    configMap:
      name: ward-vault                 # encrypted .ward files + config.yaml
```

- Vault files are age-encrypted; a ConfigMap or image layer is acceptable. `config.yaml` carries paths only.
- Keys are the sensitive part: take them from the platform secret store, never bake them into the image.
- Add `bin/rails ward:doctor` to the readiness/smoke test — it exits non-zero when the setup is broken, and prints names only.

## Cloud secret stores (hybrid mode)

Some deployments get runtime secrets from the cloud (GCP Secret Manager, AWS Parameter Store) while developers use ward locally. Keeping both is fine, but make the choice explicit:

```ruby
# config/initializers/ward.rb
ward.on_error = :warn if ENV["WARD_OPTIONAL"] == "1"
```

```ruby
# reads fall back to the platform-injected env var
def resend_api_key
  Ward["RESEND_API_KEY"].presence || ENV["RESEND_API_KEY"]
end
```

Trade-off: this is the pattern that makes a broken ward setup invisible in production. Mitigate with:

- `bin/rails ward:doctor` in the deploy pipeline (it fails loudly when ward is expected but broken);
- a single, documented fallback helper instead of ad-hoc `|| ENV[...]` everywhere;
- an alert if a fallback is used in an environment where ward should be authoritative.

If ward is the source of truth in production, do **not** enable optional mode there.

## Air-gapped and offline builds

Network is needed only by `ward:install` (build) and `ward:update` (maintainer/CI). Runtime never touches the network. Three offline options:

1. **Base image with ward installed** — `ENV WARD_EXECUTABLE_PATH=/usr/local/bin/ward`, nothing to download.
2. **Vendored release directory, `file://`** — same layout as the GitHub release:

   ```
   vendor/ward/v0.4.1/ward_linux_amd64.tar.gz
   vendor/ward/v0.4.1/checksums.txt
   ```

   ```dockerfile
   COPY vendor/ward vendor/ward
   RUN WARD_INSTALL_BASE_URL=file:///app/vendor/ward bin/rails ward:install
   ```

3. **Internal HTTP mirror** — same layout (`v<version>/ward_<os>_<arch>.tar.gz` + `checksums.txt`):

   ```sh
   WARD_INSTALL_BASE_URL=https://mirror.internal/ward bin/rails ward:install
   ```

In every mode the sha256 is verified and the binary is executed (`ward version`) before being swapped into `bin/ward`.

## Multi-arch images

Each target platform build installs its own asset:

```sh
docker buildx build --platform linux/amd64,linux/arm64 ...
```

Under emulation, the installer runs with the target platform's Ruby, so `linux_amd64` builds get the amd64 asset and `linux_arm64` builds get the arm64 one. Verification (`ward version`) runs inside the same build, catching a platform mix-up before the image ships.

## Rotation

1. Rotate the value in the vault (`ward set ...`).
2. Restart the app — or run `Ward.reload!` in a console for a one-off refresh. `reload!` re-reads the context and **clears memoized out-of-context values**.
3. Rolling restart is the safe default for web processes: the store is loaded once at boot.

Rotating a **key** additionally requires the running processes to receive the new `WARD_KEY_<VAULT>` (or updated `config.ward.keys`) — that always means restart, since the key is read per subprocess invocation.

## Deploy checklist

- [ ] `ward:install` runs in the image build (or a base image ships the binary).
- [ ] `bin/ward` is in `.gitignore` and `.dockerignore`.
- [ ] `.ward/config.yaml` and the vault files are present in the image or mounted.
- [ ] `WARD_CONTEXT` is set for the app process (not only in the CI shell).
- [ ] `WARD_DIR` is set if `.ward/` is not under `Rails.root`.
- [ ] Keys arrive via `WARD_KEY_<VAULT>` or `config.ward.keys`; never baked into the image.
- [ ] `bin/rails ward:doctor` passes in the target environment.
- [ ] Build stages that boot Rails either have ward configured or run in optional mode.
