# orvex.sh

Tiny landing page served at <https://orvex.sh/>. Hosts orvex install endpoints.

## Available installers

### Orvex BMAD modules

Installs `bmad-linear` + `bmad-docmost` into the current project, applies the Linear write-suppression patch, and stages per-project override TOMLs.

```bash
curl -fsSL orvex.sh/install/bmad | bash
```

Requires Node ≥ 20.12 and SSH access to `git@github.com:orvexai/bmad-modules`.

See [`install/bmad`](install/bmad) for the script, and [orvexai/bmad-modules](https://github.com/orvexai/bmad-modules) for the modules themselves.
