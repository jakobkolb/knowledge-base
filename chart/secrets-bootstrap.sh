#!/usr/bin/env bash
# Bootstrap script: pre-create all Kubernetes secrets required by the chart
# when deployed via ArgoCD (global.createSecrets: false).
#
# Fill in the values below, then run once per namespace before the first sync:
#   chmod +x secrets-bootstrap.sh && ./secrets-bootstrap.sh
#
# The script is idempotent — re-running it updates existing secrets.

set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
RELEASE="${RELEASE:-kb}"            # must match the Helm release name in ArgoCD

# ── Fill in real values here ─────────────────────────────────────────────────
GITHUB_CLIENT_ID=""
GITHUB_CLIENT_SECRET=""
DEX_CLIENT_SECRET=""        # shared between Dex staticClient and oauth2-proxy
COOKIE_SECRET=""            # random 32+ chars: openssl rand -base64 32
OBSIDIAN_API_KEY=""

# Registry credentials (leave blank to skip)
REGISTRY_SERVER="ghcr.io"
REGISTRY_USERNAME=""
REGISTRY_PASSWORD=""        # personal access token with read:packages

# Calendar config — heredoc, indented 2 spaces
CALENDAR_CONFIG=$(cat <<'YAML'
calendars:
  - type: icloud
    name: personal
    username: user@icloud.com
    password: ""
YAML
)
# ── End of values ─────────────────────────────────────────────────────────────

kubectl -n "$NAMESPACE" create secret generic dex-github-client \
  --from-literal=GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
  --from-literal=GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic dex-static-client \
  --from-literal=DEX_CLIENT_SECRET="$DEX_CLIENT_SECRET" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic oauth2-proxy \
  --from-literal=client-id="claude-mcp" \
  --from-literal=client-secret="$DEX_CLIENT_SECRET" \
  --from-literal=cookie-secret="$COOKIE_SECRET" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic "${RELEASE}-mcp-obsidian-mcp-secrets" \
  --from-literal=OBSIDIAN_API_KEY="$OBSIDIAN_API_KEY" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic "${RELEASE}-mcp-calendar-config" \
  --from-literal=config.yaml="$CALENDAR_CONFIG" \
  --save-config --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "$REGISTRY_USERNAME" ]]; then
  kubectl -n "$NAMESPACE" create secret docker-registry registry-creds \
    --docker-server="$REGISTRY_SERVER" \
    --docker-username="$REGISTRY_USERNAME" \
    --docker-password="$REGISTRY_PASSWORD" \
    --save-config --dry-run=client -o yaml | kubectl apply -f -
fi

echo "Done. Secrets created in namespace '$NAMESPACE'."
