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
                    │  ┌────────────────────────┐   ┌───────────────────────┐  │
                    │  │      mcp-obsidian       │   │     mcp-calendar      │  │
                    │  │ obsidian.mcp.mydomain…  │   │ calendar.mcp.mydomain…│  │
                    │  │  basic auth + TLS       │   │  basic auth + TLS     │  │
                    │  └───────────┬─────────────┘   └──────────┬────────────┘  │
                    │              │ REST API (HTTPS)            │ CalDAV        │
                    │              ▼                             ▼               │
                    │  ┌────────────────────────┐    iCloud / Google /          │
                    │  │       obsidian          │    Nextcloud (external)       │
                    │  │   ClusterIP :27124      │                               │
                    │  └───────────┬─────────────┘                              │
                    │              │ PersistentVolumeClaim                       │
                    │              ▼                                             │
                    │         vault volume                                       │
                    └──────────────────────────────────────────────────────────┘
```

The obsidian pod is **not** exposed through the ingress — it is only reachable in-cluster by mcp-obsidian.

---

## Components

### `obsidian` — Vault container

Runs [linuxserver/obsidian](https://hub.docker.com/r/linuxserver/obsidian) (Obsidian desktop app in a KasmVNC container) with the [Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api) community plugin pre-installed.

| Detail | Value |
|---|---|
| Image | `lscr.io/linuxserver/obsidian:latest` |
| REST API port | `27124` (HTTPS, self-signed cert) |
| VNC UI port | `6901` (used only during bootstrap) |
| Vault path (in-container) | `/config/obsidian/<vault-name>` |
| Persistence | `PersistentVolumeClaim` |

### `mcp-obsidian` — Obsidian MCP server

Source: `ghcr.io/jakobkolb/mcp-obsidian`  
Chart: `chart/mcp-server` (vendored from jakobkolb/mcp-servers)  
Ingress host: `obsidian.mcp.mydomain.hopto.org`

Exposes 13 tools for reading, writing, searching, and patching notes over the Obsidian Local REST API.

| Config key | Source | Value |
|---|---|---|
| `OBSIDIAN_HOST` | `env` | in-cluster service name (`obsidian`) |
| `OBSIDIAN_PORT` | `env` | `27124` |
| `OBSIDIAN_PROTOCOL` | `env` | `https` |
| `OBSIDIAN_API_KEY` | `secretEnv` → K8s Secret | see Secrets section |

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
├── .gitignore                         ← ignores *.secret.yaml
└── chart/
    ├── mcp-server/                    ← vendored from jakobkolb/mcp-servers
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── _helpers.tpl
    │       ├── configmap.yaml         ← emits a Secret for configFile content
    │       ├── deployment.yaml
    │       ├── ingress.yaml
    │       ├── secret.yaml            ← emits a Secret for secretEnv vars
    │       ├── service.yaml
    │       └── NOTES.txt
    ├── obsidian/                      ← chart for the vault container
    │   ├── Chart.yaml
    │   ├── values.yaml
    │   └── templates/
    │       ├── _helpers.tpl
    │       ├── deployment.yaml
    │       ├── service.yaml
    │       ├── pvc.yaml
    │       └── NOTES.txt
    └── values/
        ├── mcp-obsidian.yaml          ← non-secret values for mcp-obsidian release
        ├── mcp-obsidian.secret.yaml   ← secret values (gitignored)
        ├── mcp-calendar.yaml          ← non-secret values for mcp-calendar release
        └── mcp-calendar.secret.yaml   ← secret values (gitignored)
```

---

## Secrets and Configuration

The pattern is:
- `values/<release>.yaml` — committed; all non-sensitive config
- `values/<release>.secret.yaml` — **gitignored**; credentials only, merged at deploy time with `-f`

### `values/mcp-obsidian.secret.yaml`

```yaml
secretEnv:
  OBSIDIAN_API_KEY: ""        # from Local REST API plugin settings (see bootstrap below)
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

The API key is generated by the Local REST API plugin on first launch and is not known ahead of time. One-time setup:

1. Deploy the `obsidian` release first (before mcp-obsidian).
2. Port-forward or expose port `6901` and open the VNC UI in a browser.
3. Complete first-run Obsidian setup, install and enable the Local REST API community plugin.
4. Copy the generated API key from the plugin settings panel.
5. Add it to `values/mcp-obsidian.secret.yaml` and deploy mcp-obsidian.

The key is stable across pod restarts as long as the vault PVC (which includes `.obsidian/plugins/`) is preserved.

---

## Deployment

```bash
NS=knowledge-base

# 1. Obsidian vault container
helm upgrade --install obsidian ./chart/obsidian \
  --namespace $NS --create-namespace

# 2. mcp-obsidian  (after completing API key bootstrap)
helm upgrade --install mcp-obsidian ./chart/mcp-server \
  -f chart/values/mcp-obsidian.yaml \
  -f chart/values/mcp-obsidian.secret.yaml \
  --namespace $NS

# 3. mcp-calendar
helm upgrade --install mcp-calendar ./chart/mcp-server \
  -f chart/values/mcp-calendar.yaml \
  -f chart/values/mcp-calendar.secret.yaml \
  --namespace $NS
```

---

## `values/mcp-obsidian.yaml`

```yaml
image:
  repository: ghcr.io/jakobkolb/mcp-obsidian
  tag: latest

ingress:
  host: obsidian.mcp.mydomain.hopto.org
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: mcp-obsidian-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "MCP Authentication Required"

env:
  OBSIDIAN_HOST: obsidian        # in-cluster service name
  OBSIDIAN_PORT: "27124"
  OBSIDIAN_PROTOCOL: https
```

## `values/mcp-calendar.yaml`

```yaml
image:
  repository: ghcr.io/jakobkolb/mcp-calendar
  tag: latest

ingress:
  host: calendar.mcp.mydomain.hopto.org
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: mcp-calendar-basic-auth
    nginx.ingress.kubernetes.io/auth-realm: "MCP Authentication Required"

env:
  CALENDAR_CONFIG: /config/config.yaml

secretConfigFile:
  enabled: true
  mountPath: /config/config.yaml
  content: ""                    # set in mcp-calendar.secret.yaml
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
