# ward-rails documentation

`ward-rails` loads [ward](https://github.com/br4zz4/ward) secrets into a private in-memory store at boot. These pages go from first install to production troubleshooting.

| Page | Use it when |
|---|---|
| [Getting started](getting-started.md) | Adopting the gem in an existing app, or upgrading from an older revision |
| [Configuration](configuration.md) | Every setting and environment variable, with precedence rules |
| [API reference](api.md) | Reading secrets, reloading, errors, test helpers |
| [Deployment](deployment.md) | Docker, compose, Kubernetes, cloud secret stores, offline builds, rotation |
| [Security](security.md) | Threat model, key custody, ENV hygiene, what is and is not guaranteed |
| [Patterns](patterns.md) | Multi-module repos, optional ward, keys in credentials, build steps |
| [Troubleshooting](troubleshooting.md) | It booted wrong / not at all — symptom, cause, fix |

If something is off, start with:

```sh
bin/rails ward:doctor
```

It prints the resolved context, project directory, binary and keys (names only, never values), tells you how many secrets the scope resolved, and gives the fix for whatever is broken. It exits non-zero when it finds a problem, so it also works as a deployment smoke test.

Quick rules of thumb:

- `WARD_CONTEXT` is **required** (unless you deliberately run in optional mode) and must match a scope that exists at that exact depth.
- `WARD_DIR` is the **folder** containing `.ward/config.yaml`; `WARD_EXECUTABLE_PATH` is the **binary**. They are unrelated.
- The binary is installed **before boot** — normally during the image build — on the platform that will run the app.
- Secrets are **never written to `ENV`** by the gem.
