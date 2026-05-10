# knowledge-base — Deployment Configuration

Kubernetes deployment for the [mcp-servers](https://github.com/jakobkolb/mcp-servers) suite and a self-hosted Obsidian vault container, wired together so AI assistants can read and write your notes and query your calendars.

Supports all Claude clients — iOS, Android, claude.ai web, Claude Code, and Claude Desktop — via OAuth 2.1 (MCP spec compliant).

---

## Architecture

```
Claude (any client)
    │
    ├─ OAuth dance ──────────────────────────► Dex  (auth.mcp.<domain>)
    │                                           ↑ GitHub login upstream
    │
    └─ POST /mcp + Bearer JWT ───────────────► nginx ingress
                                                ├── /.well-known/* ──► well-known-server (no auth)
                                                └── /               ──► oauth2-proxy (JWT validation)
                                                                         └──► MCP service
```

MCP services:
- `obsidian.mcp.<domain>` → mcp-obsidian pod (Obsidian + sidecar)
- `calendar.mcp.<domain>` → mcp-calendar pod

**Why the sidecar pattern?** The Obsidian Local REST API plugin binds only to `127.0.0.1:27124`. The mcp-obsidian server must run as a sidecar in the same pod to reach it over the shared loopback interface.

---

## Repository Layout

```
chart/
├── Chart.yaml              ← umbrella chart (mcp-obsidian, mcp-calendar, dex, oauth2-proxy)
├── values.yaml             ← all non-secret config; set global.baseDomain here
├── values.secret.yaml      ← gitignored; credentials and secrets
├── charts/
│   ├── mcp-obsidian/       ← chart for Obsidian pod + mcp-obsidian sidecar
│   └── mcp-server/         ← generic MCP server chart (used for calendar)
└── templates/
    ├── _helpers.tpl         ← hostname helpers (baseDomain → full hostnames)
    ├── ingress.yaml         ← all ingress rules; hostnames built from global.baseDomain
    ├── secrets.yaml         ← K8s Secrets created from values.secret.yaml
    └── well-known.yaml      ← RFC 9728 oauth-protected-resource server
```

---

## Configuration

### Domain

Set once in `chart/values.yaml`:

```yaml
global:
  baseDomain: mydomain.hopto.org      # all hosts become *.mcp.<baseDomain>
  authServerUrl: https://auth.mcp.mydomain.hopto.org   # must match auth.mcp.<baseDomain>
```

All MCP ingress hostnames and the well-known server are derived from `baseDomain` automatically. When changing domains, also update the `dex.config.issuer`, `dex.config.connectors[0].config.redirectURI`, and `oauth2-proxy.extraArgs.oidc-issuer-url` fields in `values.yaml` — they contain the auth URL and can't be templated because they're consumed by third-party charts.

### Secrets (`chart/values.secret.yaml`)

```yaml
global:
  secrets:
    githubClientId: ""        # GitHub OAuth App → Client ID
    githubClientSecret: ""    # GitHub OAuth App → Client Secret
    dexClientSecret: ""       # shared: Dex staticClient + oauth2-proxy (generate randomly)
    cookieSecret: ""          # oauth2-proxy cookie secret (generate randomly)

mcp-obsidian:
  mcp:
    secretEnv:
      OBSIDIAN_API_KEY: ""    # from Local REST API plugin settings (see bootstrap below)

mcp-calendar:
  configFile:
    content: |
      calendars:
        - type: icloud
          name: personal
          username: user@icloud.com
          password: ""          # app-specific password from appleid.apple.com
        - type: google
          name: work
          username: user@gmail.com
          password: ""          # app password from myaccount.google.com
        - type: nextcloud
          name: shared
          url: https://cloud.example.com
          username: alice
          password: ""
          calendar_name: ""
          verify_ssl: true
```

---

## Prerequisites

- nginx ingress controller
- cert-manager with a `letsencrypt-prod` `ClusterIssuer`
- DNS records pointing `*.mcp.<baseDomain>` to the ingress load balancer IP

### One-time secret setup

**1. Create a GitHub OAuth App**
- Homepage URL: `https://auth.mcp.<baseDomain>`
- Authorization callback URL: `https://auth.mcp.<baseDomain>/callback`

**2. Generate random secrets**
```bash
openssl rand -base64 32   # → dexClientSecret
openssl rand -base64 32   # → cookieSecret
```

**3. Fill in `chart/values.secret.yaml`** with the GitHub credentials and generated secrets.

---

## Deployment

```bash
helm repo add dex https://charts.dex-idp.io
helm repo add oauth2-proxy https://oauth2-proxy.github.io/manifests
helm repo update

helm dependency update chart/

helm upgrade --install knowledge-base chart/ \
  -f chart/values.yaml \
  -f chart/values.secret.yaml
```

### Connecting Claude clients

**Claude.ai / Claude iOS / Claude Android:**
1. Settings → Integrations → Add Custom Connector
2. Name: Obsidian, URL: `https://obsidian.mcp.<baseDomain>/mcp`
3. Advanced → OAuth Client ID: `claude-mcp`, OAuth Client Secret: `<dexClientSecret>`
4. Authenticate via GitHub
5. Repeat for Calendar (`https://calendar.mcp.<baseDomain>/mcp`)

**Claude Code / Claude Desktop:**
Add to `~/.claude/settings.json` — Claude handles the OAuth browser flow automatically:
```json
{
  "mcpServers": {
    "obsidian": { "type": "http", "url": "https://obsidian.mcp.<baseDomain>/mcp" },
    "calendar": { "type": "http", "url": "https://calendar.mcp.<baseDomain>/mcp" }
  }
}
```

---

## Obsidian API key bootstrap

The API key is generated by the Local REST API plugin on first launch. One-time setup:

1. Deploy without the API key — the mcp-obsidian sidecar will crash-loop until it's set.
2. Port-forward the KasmVNC port and open it in a browser:
   ```bash
   kubectl port-forward svc/knowledge-base-mcp-obsidian 3000:3000
   # open http://localhost:3000
   ```
3. Complete first-run Obsidian setup, install the **Local REST API** community plugin.
4. Copy the generated API key from the plugin settings panel.
5. Add it to `chart/values.secret.yaml` and redeploy.

The key is stable across pod restarts as long as the vault PVC (which includes `.obsidian/plugins/`) is preserved.

---

## Verification

```bash
# Dex OIDC discovery
curl https://auth.mcp.<baseDomain>/.well-known/openid-configuration

# RFC 9728 resource metadata — must return JSON without auth
curl https://obsidian.mcp.<baseDomain>/.well-known/oauth-protected-resource
curl https://calendar.mcp.<baseDomain>/.well-known/oauth-protected-resource

# Unauthenticated MCP request — must return 401 (Bearer challenge, not Basic)
curl -i https://obsidian.mcp.<baseDomain>/mcp
```

---

## Known Issues

See `mcp-obsidian-test-report.md` for detailed findings. Two tools in mcp-obsidian are currently broken due to upstream bugs:

| Tool | Issue |
|---|---|
| `obsidian_get_recent_periodic_notes` | Calls `/periodic/{period}/recent` which does not exist in obsidian-local-rest-api v3.6.1 |
| `obsidian_patch_content` (block type) | `Target: ^blockid` fails; plugin requires the raw ID without `^` prefix |

All other 11 tools (list, read, search, append, put, delete, get periodic note, get recent changes) work correctly.
