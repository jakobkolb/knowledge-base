# knowledge-base — Deployment Configuration

Kubernetes deployment for the [mcp-servers](https://github.com/jakobkolb/mcp-servers) suite and a self-hosted Obsidian vault container, wired together so AI assistants can read and write your notes and query your calendars.

---

## Architecture

Each MCP server gets its own subdomain under `mcp.mydomain.hopto.org`. The nginx ingress controller is the single entry point for all AI agent traffic; cert-manager issues Let's Encrypt TLS certificates per subdomain.

```
                    ┌──────────────────────────────────────────────────────────┐
                    │                    Kubernetes Cluster                     │
                    │                                                           │
  AI Agent          │  ┌────────────────────────────────────────────────────┐  │
  (Claude / other) ─┼─►│             nginx Ingress Controller               │  │
                    │  │          *.mcp.mydomain.hopto.org  (TLS)            │  │
                    │  └──────────────────┬──────────────────┬──────────────┘  │
                    │                     │                  │                  │
                    │          ┌──────────┘                  └──────────┐       │
                    │          ▼                                        ▼       │
                    │  ┌──────────────────────────────┐  ┌───────────────────────┐  │
                    │  │        obsidian pod           │  │     mcp-calendar      │  │
                    │  │  obsidian.mcp.mydomain…       │  │ calendar.mcp.mydomain…│  │
                    │  │  basic auth + TLS             │  │  basic auth + TLS     │  │
                    │  │                               │  └──────────┬────────────┘  │
                    │  │  ┌────────────────────────┐  │             │ CalDAV        │
                    │  │  │  mcp-obsidian sidecar  │  │             ▼               │
                    │  │  │  :8000 (MCP/HTTP)      │  │  iCloud / Google /          │
                    │  │  └──────────┬─────────────┘  │  Nextcloud (external)       │
                    │  │             │ REST API        │                             │
                    │  │             │ 127.0.0.1:27124 │                             │
                    │  │  ┌──────────▼─────────────┐  │                             │
                    │  │  │  Obsidian + REST plugin │  │                             │
                    │  │  │  :3000/:3001 (KasmVNC)  │  │                             │
                    │  │  └──────────┬──────────────┘  │                             │
                    │  │             │ PVC             │                             │
                    │  └────────────────────────────────┘                            │
                    │               │                                                │
                    │          vault volume                                           │
                    └────────────────────────────────────────────────────────────────┘
```

**Why the sidecar pattern?** The Obsidian Local REST API plugin binds only to `127.0.0.1:27124` — it does not listen on `0.0.0.0`. The mcp-obsidian server must therefore run as a sidecar in the same pod so it can reach the plugin over the shared loopback interface.

---

## Components

### `obsidian` pod

Two containers deployed together via the `chart/obsidian` Helm chart.

**obsidian container** — runs [linuxserver/obsidian](https://hub.docker.com/r/linuxserver/obsidian) (Obsidian desktop app in a KasmVNC container) with the [Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api) community plugin.

| Detail | Value |
|---|---|
| Image | `lscr.io/linuxserver/obsidian:latest` |
| REST API port | `27124` (HTTPS, self-signed, loopback only) |
| VNC HTTP port | `3000` (bootstrap only — kubectl port-forward) |
| VNC HTTPS port | `3001` (bootstrap only) |
| Vault path | `/config/obsidian/<vault-name>` |
| Persistence | `PersistentVolumeClaim` |

**mcp-obsidian sidecar** — runs `ghcr.io/jakobkolb/mcp-obsidian`, exposes 13 MCP tools for reading, writing, searching, and patching notes. Reaches Obsidian over `127.0.0.1:27124` (shared pod network namespace).

| Detail | Value |
|---|---|
| Image | `ghcr.io/jakobkolb/mcp-obsidian:latest` |
| MCP port | `8000` (HTTP, exposed via ingress) |
| `OBSIDIAN_HOST` | `127.0.0.1` (loopback — same pod) |
| `OBSIDIAN_PORT` | `27124` |
| `OBSIDIAN_PROTOCOL` | `https` |
| `OBSIDIAN_API_KEY` | from `obsidian.secret.yaml` → K8s Secret |

### `mcp-calendar` — Calendar MCP server

Source: `ghcr.io/jakobkolb/mcp-calendar`  
Chart: `chart/mcp-server` (vendored from jakobkolb/mcp-servers)  
Ingress host: `calendar.mcp.mydomain.hopto.org`

Unified CalDAV interface across iCloud, Google Calendar, and Nextcloud.

| Config key | Source | Value |
|---|---|---|
| `CALENDAR_CONFIG` | `env` | `/config/config.yaml` |
| calendar credentials YAML | `configFile.content` → K8s Secret → mounted file | see Secrets section |

---

## Repository Layout

```
knowledge-base/
├── README.md
├── mcp-obsidian-test-report.md        ← integration test results
├── .gitignore                         ← ignores *.secret.yaml and .claude/
└── chart/
    ├── mcp-server/                    ← vendored from jakobkolb/mcp-servers
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── _helpers.tpl
    │       ├── configmap.yaml         ← emits a Secret for configFile content
    │       ├── deployment.yaml
    │       ├── ingress.yaml
    │       ├── secret.yaml
    │       ├── service.yaml
    │       └── NOTES.txt
    ├── obsidian/                      ← chart for the obsidian pod (+ mcp-obsidian sidecar)
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── _helpers.tpl
    │       ├── deployment.yaml        ← two containers: obsidian + mcp-obsidian
    │       ├── ingress.yaml           ← routes subdomain → mcp-obsidian :8000
    │       ├── secret.yaml            ← OBSIDIAN_API_KEY
    │       ├── service.yaml
    │       ├── pvc.yaml
    │       └── NOTES.txt
    └── values/
        ├── obsidian.yaml              ← non-secret values for obsidian release
        ├── obsidian.secret.yaml       ← secret values (gitignored)
        ├── mcp-calendar.yaml          ← non-secret values for mcp-calendar release
        └── mcp-calendar.secret.yaml   ← secret values (gitignored)
```

---

## Secrets and Configuration

The pattern is:
- `values/<release>.yaml` — committed; all non-sensitive config
- `values/<release>.secret.yaml` — **gitignored**; credentials only, merged at deploy time with `-f`

### `values/obsidian.secret.yaml`

```yaml
mcp:
  secretEnv:
    OBSIDIAN_API_KEY: ""    # from Local REST API plugin settings (see bootstrap below)
```

### `values/mcp-calendar.secret.yaml`

```yaml
# Calendar credentials — stored in a K8s Secret and mounted as /config/config.yaml
configFile:
  content: |
    calendars:
      - type: icloud
        name: personal
        username: user@icloud.com
        password: ""          # iCloud app-specific password

      - type: google
        name: work
        username: user@gmail.com
        password: ""          # Google app-specific password

      - type: nextcloud
        name: shared
        url: https://cloud.example.com
        username: alice
        password: ""
        calendar_name: ""     # optional: restrict to one calendar
        verify_ssl: true
```

> **iCloud:** Generate an app-specific password at appleid.apple.com → Security → App-Specific Passwords. Use your iCloud email as `username`.
>
> **Google:** Enable 2-Step Verification, then generate a password at myaccount.google.com → Security → App passwords. Select "Other" as the app type.
>
> **Nextcloud:** Use your account password or create a dedicated app token under Settings → Security → Devices & Sessions.

### Obsidian API key bootstrap

The API key is generated by the Local REST API plugin on first launch. One-time setup:

1. Deploy the `obsidian` release (without the secret file — the sidecar will crash-loop until the key is set, which is fine).
2. Port-forward the KasmVNC port and open it in a browser:
   ```bash
   kubectl port-forward -n knowledge-base svc/obsidian 3000:3000
   # open http://localhost:3000
   ```
3. Complete first-run Obsidian setup, install and enable the Local REST API community plugin.
4. Copy the generated API key from the plugin settings panel.
5. Add it to `values/obsidian.secret.yaml` and redeploy:
   ```bash
   helm upgrade obsidian ./chart/obsidian \
     -f chart/values/obsidian.yaml \
     -f chart/values/obsidian.secret.yaml \
     --namespace knowledge-base
   ```

The key is stable across pod restarts as long as the vault PVC (which includes `.obsidian/plugins/`) is preserved.

---

## Deployment

```bash
NS=knowledge-base

# 1. Obsidian vault + mcp-obsidian sidecar (after completing API key bootstrap)
helm upgrade --install obsidian ./chart/obsidian \
  -f chart/values/obsidian.yaml \
  -f chart/values/obsidian.secret.yaml \
  --namespace $NS --create-namespace

# 2. mcp-calendar
helm upgrade --install mcp-calendar ./chart/mcp-server \
  -f chart/values/mcp-calendar.yaml \
  -f chart/values/mcp-calendar.secret.yaml \
  --namespace $NS
```

---

## Prerequisites

- nginx ingress controller
- cert-manager with a `letsencrypt-prod` `ClusterIssuer`
- `mydomain.hopto.org` DNS wildcard or explicit records pointing to the ingress load balancer IP
- Basic auth secrets created before first deploy:

```bash
# htpasswd utility from apache2-utils / httpd-tools
htpasswd -c auth mcp
kubectl create secret generic mcp-obsidian-basic-auth \
  --from-file=auth -n knowledge-base
kubectl create secret generic mcp-calendar-basic-auth \
  --from-file=auth -n knowledge-base
```

---

## Known Issues

See `mcp-obsidian-test-report.md` for detailed findings. Two tools in mcp-obsidian are currently broken due to upstream bugs:

| Tool | Issue |
|---|---|
| `obsidian_get_recent_periodic_notes` | Calls `/periodic/{period}/recent` which does not exist in obsidian-local-rest-api v3.6.1 |
| `obsidian_patch_content` (block type) | `Target: ^blockid` fails; plugin requires the raw ID without `^` prefix |

All other 11 tools (list, read, search, append, put, delete, get periodic note, get recent changes) work correctly.
