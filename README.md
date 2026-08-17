# orvex.sh

Tiny landing page served at <https://orvex.sh/>. Hosts orvex install endpoints.

## Available installers

### Omnigent (orvex build)

Installs the orvex build of Omnigent with uv, wires up PATH, and records an install ledger — the same shape as omnigent's own `scripts/install_oss.sh`.

```bash
curl -fsSL orvex.sh/install/omnigent | bash
```

Installs the **prebuilt wheels attached to a tagged release**, so it needs no Node, no pnpm, and runs no build — a few seconds rather than a few minutes. The orvex line is not on PyPI (PyPI's `omnigent` is upstream 0.9.0) and the repo is private, so the release assets stand in for the package index and `gh` supplies the authentication: you need GitHub CLI logged in to `orvexai`.

Releases are cut from **`mcp`** — that is where the agent / MCP work lands, and the release workflow refuses to build from any other branch. `orvex` is kept deliberately lean and lags those fixes.

Pin a different release, or build from a git ref instead (development — this is the path that needs Node ≥ 22, pnpm, and SSH access):

```bash
curl -fsSL orvex.sh/install/omnigent | bash -s -- --version 0.11.0
curl -fsSL orvex.sh/install/omnigent | bash -s -- --ref mcp
```

Env overrides work too, but must prefix `bash` rather than `curl` — in `VAR=x curl … | bash` the shell assigns the variable to `curl` alone and the script never sees it:

```bash
curl -fsSL orvex.sh/install/omnigent | ORVEX_OMNIGENT_VERSION=0.11.0 bash
```

See [`install/omnigent`](install/omnigent) for the script and its full env-override list.

### Orvex BMAD modules

Installs `bmad-linear` + `bmad-docmost` into the current project, applies the Linear write-suppression patch, and stages per-project override TOMLs.

```bash
curl -fsSL orvex.sh/install/bmad | bash
```

Requires Node ≥ 20.12 and SSH access to `git@github.com:orvexai/bmad-modules`.

See [`install/bmad`](install/bmad) for the script, and [orvexai/bmad-modules](https://github.com/orvexai/bmad-modules) for the modules themselves.
