# orvex.sh

Tiny landing page served at <https://orvex.sh/>. Hosts orvex install endpoints.

## Available installers

### Omnigent (orvex build)

Installs the orvex build of Omnigent from `orvexai/omnigent` with uv, wires up PATH, and records an install ledger.

```bash
curl -fsSL orvex.sh/install/omnigent | bash
```

Always a source build — the orvex line is not on PyPI (PyPI's `omnigent` is upstream 0.9.0), so Node ≥ 22 and pnpm are required to build the web UI. Pass `--skip-web-ui` to install without it and drop both requirements. Also needs SSH access to `git@github.com:orvexai/omnigent`.

Defaults to the `orvex` branch; override with `ORVEX_OMNIGENT_REF`:

```bash
ORVEX_OMNIGENT_REF=mcp curl -fsSL orvex.sh/install/omnigent | bash
```

See [`install/omnigent`](install/omnigent) for the script and its full env-override list.

### Orvex BMAD modules

Installs `bmad-linear` + `bmad-docmost` into the current project, applies the Linear write-suppression patch, and stages per-project override TOMLs.

```bash
curl -fsSL orvex.sh/install/bmad | bash
```

Requires Node ≥ 20.12 and SSH access to `git@github.com:orvexai/bmad-modules`.

See [`install/bmad`](install/bmad) for the script, and [orvexai/bmad-modules](https://github.com/orvexai/bmad-modules) for the modules themselves.
