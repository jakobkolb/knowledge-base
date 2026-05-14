# knowledge-base — Deployment Configuration

Kubernetes deployment for the [mcp-servers](https://github.com/jakobkolb/mcp-servers) suite, wired together so AI assistants can query your calendars and more.

Supports all Claude clients — iOS, Android, claude.ai web, Claude Code, and Claude Desktop — via OAuth 2.1 (MCP spec compliant).

---

## Architecture

```
Claude (any client)
    │
    ├─ OAuth dance ──────────────────────────► Dex  (auth.<baseDomain>)
    │                                           ↑ GitHub login upstream
    │
    └─ POST /mcp + Bearer JWT ───────────────► nginx ingress
                                                ├── /.well-known/* ──► well-known-server (no auth)
                                                └── /mcp           ──► oauth2-proxy (JWT validation)
                                                                         └──► MCP service
```

MCP endpoints (configured via `api-gateway.mcpEndpoints`):
- `calendar.<baseDomain>` → mcp-calendar pod
- `example.<baseDomain>` → example MCP server (smoketest)
- `obsidian.<baseDomain>` → mcp-obsidian pod (with obsidian-headless sidecar for vault sync)

---

## Repository Layout

```
chart/
├── Chart.yaml              ← umbrella chart; all deps from OCI
├── values.yaml             ← all non-secret config
├── values.secret.yaml      ← gitignored; credentials and secrets
├── secrets-bootstrap.sh    ← one-time secret creation helper
└── templates/
    └── secrets.yaml        ← optional registry pull secret
```

### Subcharts (all from OCI)

| Alias | Chart | Role |
|---|---|---|
| `mcp-calendar` | `oci://ghcr.io/jakobkolb/charts/mcp-server` | Calendar MCP server |
| `mcp-example` | `oci://ghcr.io/jakobkolb/charts/mcp-server` | Smoketest MCP server |
| `mcp-obsidian` | `oci://ghcr.io/jakobkolb/charts/mcp-server` | Obsidian vault MCP server (with headless sync sidecar) |
| `api-gateway` | `oci://ghcr.io/jakobkolb/charts/api-gateway` | Dex + oauth2-proxy + well-known server + ingress |

The `api-gateway` chart is maintained at [jakobkolb/mcp-oauth-gateway](https://github.com/jakobkolb/mcp-oauth-gateway).

---

## Configuration

### Domain

Set once in `chart/values.yaml`:

```yaml
global:
  baseDomain: mcp.example.com      # MCP hosts become *.<baseDomain>; auth host becomes auth.<baseDomain>
  authServerUrl: https://auth.mcp.example.com   # must match https://auth.<baseDomain>
```

For staging, override `baseDomain` to e.g. `mcp-staging.example.com`.

### MCP endpoints

Add or remove endpoints in `chart/values.yaml`:

```yaml
api-gateway:
  mcpEndpoints:
    - subdomain: calendar
      service: mcp-calendar
    - subdomain: example
      service: mcp-example
    - subdomain: obsidian
      service: mcp-obsidian
      port: 8080     # optional — defaults to 8000 if omitted
```

Each entry gets a protected `/mcp` ingress and an unprotected `/.well-known` ingress.

### Secrets (`chart/values.secret.yaml`)

```yaml
global:
  secrets:
    githubClientId: ""        # GitHub OAuth App → Client ID
    githubClientSecret: ""    # GitHub OAuth App → Client Secret
    dexClientSecret: ""       # shared: Dex staticClient ↔ oauth2-proxy (generate randomly)
    cookieSecret: ""          # oauth2-proxy cookie secret (generate randomly)

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
```

---

## Prerequisites

- nginx ingress controller
- cert-manager with a `letsencrypt-prod` `ClusterIssuer`
- DNS wildcard record `*.<baseDomain>` pointing to the ingress load balancer IP

### One-time secret setup

**1. Create a GitHub OAuth App**
- Homepage URL: `https://auth.<baseDomain>`
- Authorization callback URL: `https://auth.<baseDomain>/callback`

**2. Generate random secrets**
```bash
openssl rand -base64 32   # → dexClientSecret
openssl rand -base64 32   # → cookieSecret
```

**3. Fill in `chart/values.secret.yaml`** with the GitHub credentials and generated secrets, or run:
```bash
bash chart/secrets-bootstrap.sh
```

---

## Deployment

```bash
helm dependency update chart/

helm upgrade --install knowledge-base chart/ \
  -f chart/values.yaml \
  -f chart/values.secret.yaml
```

### Connecting Claude clients

**Claude.ai / Claude iOS / Claude Android:**
1. Settings → Integrations → Add Custom Connector
2. Name: Calendar, URL: `https://calendar.<baseDomain>/mcp`
3. Advanced → OAuth Client ID: `claude-mcp`, OAuth Client Secret: `<dexClientSecret>`
4. Authenticate via GitHub
5. Repeat for `https://obsidian.<baseDomain>/mcp`

**Claude Code / Claude Desktop:**
Add to `~/.claude/settings.json` — Claude handles the OAuth browser flow automatically:
```json
{
  "mcpServers": {
    "calendar": { "type": "http", "url": "https://calendar.<baseDomain>/mcp" },
    "obsidian": { "type": "http", "url": "https://obsidian.<baseDomain>/mcp" }
  }
}
```

---

## Verification

```bash
# Dex OIDC discovery
curl https://auth.<baseDomain>/.well-known/openid-configuration

# RFC 9728 resource metadata — must return JSON without auth
curl https://calendar.<baseDomain>/.well-known/oauth-protected-resource
curl https://obsidian.<baseDomain>/.well-known/oauth-protected-resource

# Unauthenticated MCP request — must return 401 with Bearer challenge
curl -i https://calendar.<baseDomain>/mcp
curl -i https://obsidian.<baseDomain>/mcp
```
