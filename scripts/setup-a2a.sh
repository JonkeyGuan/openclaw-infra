#!/usr/bin/env bash
# ============================================================================
# OPENCLAW A2A DEPLOYMENT (NON-INTERACTIVE)
# ============================================================================
# Deploys OpenClaw with A2A enabled, external vLLM, auto-detected MLflow.
# Fully non-interactive — all config comes from .env and CLI args.
# No Vertex AI, no Telegram.
#
# Prerequisites:
#   - Kagenti platform installed (kagenti-setup-works-with-mlflow.sh)
#   - .env with shared config (MODEL_ENDPOINT, MODEL_API_KEY)
#     Copy from env.example if not present.
#
# Usage:
#   ./scripts/setup-a2a.sh alice              # Deploy alice-openclaw
#   ./scripts/setup-a2a.sh bob                # Deploy bob-openclaw
#   ./scripts/setup-a2a.sh alice --k8s        # Vanilla Kubernetes
#   ./scripts/setup-a2a.sh alice --preserve-config
#
# Files:
#   env.example  → Template (committed to git)
#   .env          → Shared config: model endpoint, API key (git-ignored)
#   .env.alice    → Generated per-user config: prefix, secrets, namespace (git-ignored)
#   .env.bob      → Generated per-user config (git-ignored)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse args
K8S_MODE=false
PRESERVE_CONFIG=false
PREFIX_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) K8S_MODE=true; shift ;;
    --preserve-config) PRESERVE_CONFIG=true; shift ;;
    -h|--help)
      echo "Usage: $0 PREFIX [OPTIONS]"
      echo ""
      echo "Arguments:"
      echo "  PREFIX               Namespace prefix (required, e.g. alice → alice-openclaw)"
      echo ""
      echo "Options:"
      echo "  --k8s                Use kubectl instead of oc"
      echo "  --preserve-config    Always preserve live config on drift (default behavior)"
      echo "  -h, --help           Show this help"
      echo ""
      echo "Examples:"
      echo "  $0 alice             # Deploy alice-openclaw"
      echo "  $0 bob               # Deploy bob-openclaw"
      echo ""
      echo "Reads shared config from .env (copy env.example to .env first)."
      echo "Generates per-user .env.<prefix> with secrets and namespace config."
      exit 0
      ;;
    -*) shift ;;
    *) PREFIX_ARG="$1"; shift ;;
  esac
done

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

# PREFIX is required
if [ -z "$PREFIX_ARG" ]; then
  log_error "Usage: $0 PREFIX [OPTIONS]"
  log_error "  Example: $0 alice"
  exit 1
fi

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  KUBECTL="${KUBECTL:-oc}"
  command -v oc &>/dev/null && KUBECTL=oc || KUBECTL=kubectl
fi

SHARED_ENV="$REPO_ROOT/.env"
USER_ENV="$REPO_ROOT/.env.${PREFIX_ARG}"

echo ""
echo "============================================"
echo "  OpenClaw A2A Deployment: ${PREFIX_ARG}"
echo "============================================"
echo ""

# ── Load config ──────────────────────────────────────────────────────────────

# Load shared .env
if [ -f "$SHARED_ENV" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SHARED_ENV"
  set +a
  log_success "Loaded shared config: $SHARED_ENV"
else
  log_error "Shared .env not found: $SHARED_ENV"
  log_error "Run: cp env.example .env  and fill in values"
  exit 1
fi

# Load existing per-user .env if re-running (preserves secrets)
if [ -f "$USER_ENV" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$USER_ENV"
  set +a
  log_success "Loaded existing user config: $USER_ENV"
fi

# ── Set variables ────────────────────────────────────────────────────────────

OPENCLAW_PREFIX="$PREFIX_ARG"
OPENCLAW_NAMESPACE="${PREFIX_ARG}-openclaw"
SHADOWMAN_CUSTOM_NAME="${SHADOWMAN_CUSTOM_NAME:-shadowman}"
SHADOWMAN_DISPLAY_NAME="${SHADOWMAN_DISPLAY_NAME:-Shadowman}"
A2A_ENABLED=true

# Validate shared config
if [ -z "${MODEL_API_KEY:-}" ] || [ "${MODEL_API_KEY}" = "sk-change-me" ]; then
  log_error "MODEL_API_KEY not set in $SHARED_ENV"
  exit 1
fi
if [ -z "${MODEL_ENDPOINT:-}" ]; then
  log_error "MODEL_ENDPOINT not set in $SHARED_ENV"
  exit 1
fi

log_success "Prefix: $OPENCLAW_PREFIX"
log_success "Namespace: $OPENCLAW_NAMESPACE"
log_success "Model endpoint: $MODEL_ENDPOINT"

# Auto-detect MLflow from cluster
if [ -z "${MLFLOW_TRACKING_URI:-}" ]; then
  if $KUBECTL get service mlflow-service -n mlflow &>/dev/null 2>&1; then
    MLFLOW_TRACKING_URI="http://mlflow-service.mlflow.svc.cluster.local:5000"
    log_success "MLflow auto-detected: $MLFLOW_TRACKING_URI"
  else
    MLFLOW_TRACKING_URI=""
    log_info "MLflow not found in cluster — skipping"
  fi
fi
MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-0}"

# Detect cluster domain
if [ -z "${CLUSTER_DOMAIN:-}" ]; then
  CLUSTER_DOMAIN=$($KUBECTL get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
  if [ -z "$CLUSTER_DOMAIN" ]; then
    CLUSTER_DOMAIN="apps.$($KUBECTL get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || echo "")"
    if [ "$CLUSTER_DOMAIN" = "apps." ]; then
      CLUSTER_DOMAIN=""
    fi
  fi
fi

# Generate secrets (reuse from existing .env.<prefix> if present)
_gen_secret() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
_gen_cookie() { openssl rand -base64 32 2>/dev/null | head -c 32; }
OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(_gen_secret)}"
if $K8S_MODE; then
  OPENCLAW_OAUTH_CLIENT_SECRET=""
  OPENCLAW_OAUTH_COOKIE_SECRET=""
else
  OPENCLAW_OAUTH_CLIENT_SECRET="${OPENCLAW_OAUTH_CLIENT_SECRET:-$(_gen_secret)}"
  OPENCLAW_OAUTH_COOKIE_SECRET="${OPENCLAW_OAUTH_COOKIE_SECRET:-$(_gen_cookie)}"
fi

# Keycloak defaults
KC_REALM="${KEYCLOAK_REALM:-kagenti}"
KC_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"

# Fixed: no Vertex, no Telegram
VERTEX_ENABLED=false
VERTEX_PROVIDER=""
GOOGLE_CLOUD_PROJECT=""
GOOGLE_CLOUD_LOCATION=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_ENABLED=false
TELEGRAM_ALLOW_FROM=""
A2A_PEER_NAMESPACES="${A2A_PEER_NAMESPACES:-}"

# ── Write per-user .env ─────────────────────────────────────────────────────

log_info "Writing $USER_ENV..."
cat > "$USER_ENV" <<EOF
# Generated by setup-a2a.sh for ${PREFIX_ARG} — NEVER commit
CLUSTER_DOMAIN=$CLUSTER_DOMAIN
OPENCLAW_PREFIX=$OPENCLAW_PREFIX
OPENCLAW_NAMESPACE=$OPENCLAW_NAMESPACE
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN
OPENCLAW_OAUTH_CLIENT_SECRET=$OPENCLAW_OAUTH_CLIENT_SECRET
OPENCLAW_OAUTH_COOKIE_SECRET=$OPENCLAW_OAUTH_COOKIE_SECRET
MODEL_API_KEY=$MODEL_API_KEY
MODEL_ENDPOINT=$MODEL_ENDPOINT
VERTEX_ENABLED=false
VERTEX_PROVIDER=
GOOGLE_CLOUD_PROJECT=
GOOGLE_CLOUD_LOCATION=
VERTEX_SA_JSON_PATH=
SHADOWMAN_CUSTOM_NAME=$SHADOWMAN_CUSTOM_NAME
SHADOWMAN_DISPLAY_NAME=$SHADOWMAN_DISPLAY_NAME
TELEGRAM_BOT_TOKEN=
TELEGRAM_ENABLED=false
TELEGRAM_ALLOW_FROM=
MLFLOW_TRACKING_URI=$MLFLOW_TRACKING_URI
MLFLOW_EXPERIMENT_ID=$MLFLOW_EXPERIMENT_ID
A2A_ENABLED=true
A2A_PEER_NAMESPACES=${A2A_PEER_NAMESPACES:-}
KEYCLOAK_REALM=$KC_REALM
KEYCLOAK_NAMESPACE=$KC_NAMESPACE
KEYCLOAK_URL=http://keycloak-service.${KC_NAMESPACE}.svc.cluster.local:8080
EOF
log_success "$USER_ENV written"
echo ""

# ── Model defaults ───────────────────────────────────────────────────────────

# Re-source to ensure all exports are set
set -a
# shellcheck disable=SC1091
source "$USER_ENV"
set +a

export SHADOWMAN_CUSTOM_NAME="${SHADOWMAN_CUSTOM_NAME:-shadowman}"
export SHADOWMAN_DISPLAY_NAME="${SHADOWMAN_DISPLAY_NAME:-Shadowman}"
export OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-quay.io/sallyom/openclaw:latest}"
export MODEL_ENDPOINT="${MODEL_ENDPOINT:-http://vllm.openclaw-llms.svc.cluster.local/v1}"
export MODEL_NAME="${MODEL_NAME:-deepseek-r1-distill-qwen-14b}"
export MODEL_DISPLAY_NAME="${MODEL_DISPLAY_NAME:-${MODEL_NAME}}"

# MLflow TLS
export MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URI:-}"
export MLFLOW_EXPERIMENT_ID="${MLFLOW_EXPERIMENT_ID:-0}"
if [[ "${MLFLOW_TRACKING_URI:-}" =~ ^https:// ]]; then
  export MLFLOW_TLS_INSECURE="false"
else
  export MLFLOW_TLS_INSECURE="true"
fi

# Agent model: always use the model from .env (local provider)
export DEFAULT_AGENT_MODEL="local/${MODEL_NAME}"

log_success "Default agent model: $DEFAULT_AGENT_MODEL"
echo ""

# ── Template processing ─────────────────────────────────────────────────────

log_info "Running envsubst on templates..."

# Explicit variable list to protect {agentId} and other non-env placeholders
ENVSUBST_VARS='${CLUSTER_DOMAIN} ${OPENCLAW_PREFIX} ${OPENCLAW_NAMESPACE} ${OPENCLAW_GATEWAY_TOKEN} ${OPENCLAW_OAUTH_CLIENT_SECRET} ${OPENCLAW_OAUTH_COOKIE_SECRET} ${MODEL_API_KEY} ${SHADOWMAN_CUSTOM_NAME} ${SHADOWMAN_DISPLAY_NAME} ${MODEL_ENDPOINT} ${MODEL_NAME} ${MODEL_DISPLAY_NAME} ${DEFAULT_AGENT_MODEL} ${GOOGLE_CLOUD_PROJECT} ${GOOGLE_CLOUD_LOCATION} ${TELEGRAM_ALLOW_FROM} ${MLFLOW_TRACKING_URI} ${MLFLOW_EXPERIMENT_ID} ${MLFLOW_TLS_INSECURE} ${OPENCLAW_IMAGE}'

GENERATED_DIR="$REPO_ROOT/generated"
rm -rf "$GENERATED_DIR"
mkdir -p "$GENERATED_DIR"

# Copy static files (preserving directory structure, excluding templates)
rsync -a --exclude='*.envsubst' "$REPO_ROOT/agents/" "$GENERATED_DIR/agents/"
rsync -a --exclude='*.envsubst' "$REPO_ROOT/platform/" "$GENERATED_DIR/platform/"

# Process .envsubst templates into generated/
for tpl in $(find "$REPO_ROOT/agents" "$REPO_ROOT/platform" -name '*.envsubst'); do
  rel="${tpl#$REPO_ROOT/}"
  out="$GENERATED_DIR/${rel%.envsubst}"
  mkdir -p "$(dirname "$out")"
  envsubst "$ENVSUBST_VARS" < "$tpl" > "$out"
  log_success "Generated $(basename "$out")"
done
echo ""

# Strip Telegram channel config (always disabled in A2A mode)
for cfg in "$GENERATED_DIR/agents/openclaw/overlays"/*/config-patch.yaml; do
  if [ -f "$cfg" ]; then
    python3 -c "
import json, sys
with open('$cfg') as f:
    lines = f.readlines()
json_start = next(i for i, l in enumerate(lines) if l.strip().startswith('{'))
json_end = next(i for i in range(len(lines)-1, -1, -1) if lines[i].strip().startswith('}'))
prefix = lines[:json_start]
suffix = lines[json_end+1:]
blob = json.loads(''.join(lines[json_start:json_end+1]))
blob.pop('channels', None)
blob.get('settings', {}).pop('channels', None)
indent = len(lines[json_start]) - len(lines[json_start].lstrip())
formatted = json.dumps(blob, indent=2)
indented = '\n'.join(' ' * indent + l for l in formatted.splitlines()) + '\n'
with open('$cfg', 'w') as f:
    f.writelines(prefix + [indented] + suffix)
" 2>/dev/null && log_success "Stripped Telegram config (disabled)" || true
  fi
done

# ── Select overlay ───────────────────────────────────────────────────────────

if $K8S_MODE; then
  OPENCLAW_OVERLAY="$GENERATED_DIR/agents/openclaw/overlays/k8s"
else
  OPENCLAW_OVERLAY="$GENERATED_DIR/agents/openclaw/overlays/openshift"
fi

# A2A is always enabled — Kagenti webhook injects AIB sidecars at admission time
log_info "A2A enabled — Kagenti webhook will inject AIB sidecars at admission time"
echo ""

# ── Create namespace ─────────────────────────────────────────────────────────

log_info "Creating namespace..."
$KUBECTL create namespace "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f - > /dev/null
$KUBECTL annotate namespace "$OPENCLAW_NAMESPACE" \
  "openclaw.dev/owner=$OPENCLAW_PREFIX" \
  "openclaw.dev/agent-name=$SHADOWMAN_DISPLAY_NAME" \
  "openclaw.dev/agent-id=${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}" \
  --overwrite > /dev/null
log_success "Namespace created: $OPENCLAW_NAMESPACE (owner: $OPENCLAW_PREFIX, agent: $SHADOWMAN_DISPLAY_NAME)"
echo ""

# ── Kagenti namespace setup ─────────────────────────────────────────────────

NS_ARGS=(-n "$OPENCLAW_NAMESPACE" --realm "$KC_REALM" --keycloak-namespace "$KC_NAMESPACE")
if $K8S_MODE; then NS_ARGS+=(--k8s); fi
"$SCRIPT_DIR/setup-kagenti-ns.sh" "${NS_ARGS[@]}"
echo ""

# ── OpenShift cluster-scoped resources ───────────────────────────────────────

if $K8S_MODE; then
  log_info "Skipping OAuthClient and SCC (not needed in Kubernetes mode)"
  echo ""
else
  # SCC + RBAC for AuthBridge sidecars
  log_info "Applying AuthBridge SCC and RBAC grant..."
  if oc apply -f "$GENERATED_DIR/platform/auth-identity-bridge/openclaw-scc.yaml" 2>/dev/null && \
     oc apply -f "$GENERATED_DIR/platform/overlays/openshift/scc-rbac.yaml" 2>/dev/null; then
    log_success "SCC openclaw-authbridge applied and granted"
  else
    log_warn "Could not apply SCC (requires cluster-admin permissions)"
    log_warn "Ask your cluster admin to run:"
    echo "    oc apply -f $GENERATED_DIR/platform/auth-identity-bridge/openclaw-scc.yaml"
    echo "    oc apply -f $GENERATED_DIR/platform/overlays/openshift/scc-rbac.yaml"
  fi

  # OAuthClient
  log_info "Creating OAuthClient..."
  if oc apply -f "$GENERATED_DIR/platform/overlays/openshift/oauthclient.yaml" 2>/dev/null; then
    log_success "OpenClaw OAuthClient created"
  else
    log_warn "Could not create OpenClaw OAuthClient (requires cluster-admin permissions)"
    log_warn "Ask your cluster admin to run:"
    echo "    oc apply -f $GENERATED_DIR/platform/overlays/openshift/oauthclient.yaml"
  fi
  echo ""
fi

# ── Config drift detection ───────────────────────────────────────────────────

_SAVED_CONFIG=""
_LIVE_CONFIG=$($KUBECTL get configmap openclaw-config -n "$OPENCLAW_NAMESPACE" \
  -o jsonpath='{.data.openclaw\.json}' 2>/dev/null) || true

if [ -n "$_LIVE_CONFIG" ]; then
  _NEW_CONFIG=$(python3 -c "
import re, sys
with open('$OPENCLAW_OVERLAY/config-patch.yaml') as f:
    content = f.read()
match = re.search(r'openclaw\.json:\s*\|\s*\n((?:\s+.*\n?)*)', content)
if not match:
    sys.exit(1)
lines = match.group(1).rstrip().split('\n')
indent = len(lines[0]) - len(lines[0].lstrip())
print('\n'.join(l[indent:] for l in lines))
" 2>/dev/null) || true

  if [ -n "$_NEW_CONFIG" ]; then
    _HAS_DRIFT=$(python3 -c "
import json, sys
try:
    live = json.loads(sys.argv[1])
    new = json.loads(sys.argv[2])
    sys.exit(0 if live == new else 1)
except:
    sys.exit(1)
" "$_LIVE_CONFIG" "$_NEW_CONFIG" 2>/dev/null; echo $?)

    if [ "$_HAS_DRIFT" = "1" ]; then
      # Non-interactive: always preserve live config
      log_info "Config drift detected — preserving live config"
      _SAVED_CONFIG="$_LIVE_CONFIG"
      echo ""
    fi
  fi
fi

# ── OTEL sidecar (before deployment so webhook injects on first pod) ─────────

OTEL_SIDECAR_TEMPLATE="$REPO_ROOT/platform/observability/openclaw-otel-sidecar.yaml.envsubst"
if [ -f "$OTEL_SIDECAR_TEMPLATE" ]; then
  OTEL_COLLECTOR_ENDPOINT="otel-collector.kagenti-system.svc.cluster.local:4317"
  export OTEL_COLLECTOR_ENDPOINT OPENCLAW_NAMESPACE MLFLOW_TRACKING_URI MLFLOW_TLS_INSECURE

  OTEL_YAML="$GENERATED_DIR/platform/observability/openclaw-otel-sidecar.yaml"
  mkdir -p "$(dirname "$OTEL_YAML")"
  envsubst '${OPENCLAW_NAMESPACE} ${OTEL_COLLECTOR_ENDPOINT} ${MLFLOW_TRACKING_URI} ${MLFLOW_EXPERIMENT_ID} ${MLFLOW_TLS_INSECURE}' < "$OTEL_SIDECAR_TEMPLATE" > "$OTEL_YAML"

  log_info "Deploying OTEL sidecar collector..."
  if $KUBECTL apply -f "$OTEL_YAML"; then
    log_success "OTEL sidecar deployed (→ $OTEL_COLLECTOR_ENDPOINT)"
  else
    log_warn "OTEL sidecar deployment failed — OpenTelemetry Operator may not be installed"
    log_warn "  Install it, then run: scripts/deploy-otelcollector.sh --env-file $USER_ENV"
  fi
else
  log_warn "OTEL sidecar template not found — skipping"
fi
echo ""

# ── Deploy OpenClaw ──────────────────────────────────────────────────────────

log_info "Deploying OpenClaw Gateway..."
log_info "  A2A:     enabled (Kagenti AIB)"
log_info "  Security: ResourceQuota, PDB, read-only filesystem, health probes"
$KUBECTL apply -k "$OPENCLAW_OVERLAY"
log_success "OpenClaw deployed"

# Restore saved config after kustomize apply
if [ -n "$_SAVED_CONFIG" ]; then
  log_info "Restoring preserved config to ConfigMap..."
  $KUBECTL create configmap openclaw-config \
    --from-literal="openclaw.json=$_SAVED_CONFIG" \
    -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f -
  log_success "Live config restored"
fi
echo ""

# ── Default agent + skills ───────────────────────────────────────────────────

log_info "Setting up default agent (${SHADOWMAN_DISPLAY_NAME})..."

# Apply shadowman agent ConfigMap
SHADOWMAN_YAML="$GENERATED_DIR/agents/openclaw/agents/shadowman/shadowman-base.yaml"
if [ -f "$SHADOWMAN_YAML" ]; then
  $KUBECTL apply -f "$SHADOWMAN_YAML"
  log_success "Default agent ConfigMap deployed"
else
  log_warn "shadowman-base.yaml not found"
fi

# A2A skill ConfigMap + peer auto-discovery
log_info "Installing A2A skill..."

# Build peer table: self + auto-discovered openclaw namespaces
A2A_PEER_TABLE="    | ${OPENCLAW_PREFIX} | ${OPENCLAW_NAMESPACE} | http://openclaw.${OPENCLAW_NAMESPACE}.svc.cluster.local:8080 |"

# Auto-discover other openclaw namespaces (annotated by setup-a2a.sh or setup-agents.sh)
DISCOVERED_PEERS=$($KUBECTL get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.openclaw\.dev/agent-name}{"\n"}{end}' 2>/dev/null \
  | grep -v "^${OPENCLAW_NAMESPACE}	" \
  | awk -F'\t' '$2 != "" {print $1}' || true)
if [ -n "$DISCOVERED_PEERS" ]; then
  while IFS= read -r ns; do
    [ -z "$ns" ] && continue
    owner="${ns%-openclaw}"
    A2A_PEER_TABLE="${A2A_PEER_TABLE}
    | ${owner} | ${ns} | http://openclaw.${ns}.svc.cluster.local:8080 |"
    log_success "  Discovered peer: ${owner} (${ns})"
  done <<< "$DISCOVERED_PEERS"
fi

# Also include manually specified peers (A2A_PEER_NAMESPACES env var)
if [ -n "${A2A_PEER_NAMESPACES:-}" ]; then
  IFS=',' read -ra PEERS <<< "$A2A_PEER_NAMESPACES"
  for ns in "${PEERS[@]}"; do
    ns=$(echo "$ns" | xargs)
    [ -z "$ns" ] && continue
    # Skip if already discovered
    echo "$A2A_PEER_TABLE" | grep -q "$ns" && continue
    owner="${ns%-openclaw}"
    A2A_PEER_TABLE="${A2A_PEER_TABLE}
    | ${owner} | ${ns} | http://openclaw.${ns}.svc.cluster.local:8080 |"
  done
fi

SKILL_MD="$REPO_ROOT/agents/openclaw/skills/a2a/SKILL.md"
if [ -f "$SKILL_MD" ]; then
  $KUBECTL create configmap a2a-skill \
    --from-file=SKILL.md="$SKILL_MD" \
    -n "$OPENCLAW_NAMESPACE" --dry-run=client -o yaml \
    | $KUBECTL apply -f -
  log_success "A2A skill ConfigMap deployed"
fi

# ── Wait for pod + install workspace files ───────────────────────────────────
# Following add-agent.sh pattern: use deployment/openclaw instead of pod name

log_info "Waiting for OpenClaw pod to start..."
if $KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s 2>/dev/null; then
  WORKSPACE="/home/node/.openclaw/workspace-${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME}"
  $KUBECTL exec deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- mkdir -p "$WORKSPACE"

  for key in AGENTS.md agent.json SOUL.md IDENTITY.md TOOLS.md USER.md HEARTBEAT.md MEMORY.md; do
    VALUE=$($KUBECTL get configmap shadowman-agent -n "$OPENCLAW_NAMESPACE" -o jsonpath="{.data.${key//./\\.}}" 2>/dev/null) || true
    if [ -n "$VALUE" ]; then
      echo "$VALUE" | $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
        sh -c "cat > ${WORKSPACE}/${key}"
    fi
  done
  log_success "Agent workspace files installed (${SHADOWMAN_DISPLAY_NAME})"

  # Inject A2A peer table into MEMORY.md
  if [ -n "${A2A_PEER_TABLE:-}" ]; then
    echo "$A2A_PEER_TABLE" | $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
      sh -c "
        python3 -c \"
import sys
content = open('${WORKSPACE}/MEMORY.md').read()
rows = sys.stdin.read().strip()
content = content.replace('|-------|-----------|-------------|', '|-------|-----------|-------------|\n' + rows)
open('${WORKSPACE}/MEMORY.md', 'w').write(content)
\" 2>/dev/null || true"
    PEER_COUNT=$(echo "$A2A_PEER_TABLE" | grep -c '|' || true)
    log_success "A2A peer table seeded in MEMORY.md (${PEER_COUNT} peers)"
  fi

  # Install A2A skill into workspace
  if [ -f "$SKILL_MD" ]; then
    $KUBECTL get configmap a2a-skill -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.data.SKILL\.md}' | \
      $KUBECTL exec -i deployment/openclaw -n "$OPENCLAW_NAMESPACE" -c gateway -- \
        sh -c 'mkdir -p /home/node/.openclaw/skills/a2a && cat > /home/node/.openclaw/skills/a2a/SKILL.md'
    log_success "A2A skill installed into workspace"
  fi

  # Restart to load agent config
  $KUBECTL rollout restart deployment/openclaw -n "$OPENCLAW_NAMESPACE"
  $KUBECTL rollout status deployment/openclaw -n "$OPENCLAW_NAMESPACE" --timeout=300s 2>/dev/null
  log_success "OpenClaw restarted with default agent"

  # ── Cross-seed: update existing instances' peer tables ────────────────────
  # When deploying bob, alice needs to learn about bob too.
  # Scan for other openclaw namespaces and inject this instance into their MEMORY.md.
  if [ -n "$DISCOVERED_PEERS" ]; then
    log_info "Cross-seeding peer tables on existing instances..."
    NEW_PEER_ROW="    | ${OPENCLAW_PREFIX} | ${OPENCLAW_NAMESPACE} | http://openclaw.${OPENCLAW_NAMESPACE}.svc.cluster.local:8080 |"
    while IFS= read -r peer_ns; do
      [ -z "$peer_ns" ] && continue
      peer_owner="${peer_ns%-openclaw}"
      # Derive the peer's agent name from namespace annotation
      PEER_AGENT_NAME=$($KUBECTL get namespace "$peer_ns" -o jsonpath='{.metadata.annotations.openclaw\.dev/agent-id}' 2>/dev/null || echo "")
      if [ -z "$PEER_AGENT_NAME" ]; then
        PEER_AGENT_NAME="${peer_owner}_shadowman"
      fi
      PEER_WORKSPACE="/home/node/.openclaw/workspace-${PEER_AGENT_NAME}"
      # Check if peer pod is running and inject our row into their MEMORY.md
      if $KUBECTL rollout status deployment/openclaw -n "$peer_ns" --timeout=10s 2>/dev/null; then
        echo "$NEW_PEER_ROW" | $KUBECTL exec -i deployment/openclaw -n "$peer_ns" -c gateway -- \
          sh -c "
            python3 -c \"
import sys
import glob
row = sys.stdin.read().strip()
for md in glob.glob('/home/node/.openclaw/workspace-*/MEMORY.md'):
    content = open(md).read()
    if '${OPENCLAW_NAMESPACE}' in content:
        continue
    if '|-------|-----------|-------------|' in content:
        content = content.replace('|-------|-----------|-------------|', '|-------|-----------|-------------|\n' + row)
        open(md, 'w').write(content)
\" 2>/dev/null || true"
        log_success "  ${peer_owner} ← knows about ${OPENCLAW_PREFIX}"
      else
        log_warn "  ${peer_owner} pod not running — peer table not updated"
      fi
    done <<< "$DISCOVERED_PEERS"
  fi
else
  log_warn "Pod not ready yet — run setup-agents.sh after pod starts"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Deployment Complete: ${PREFIX_ARG}"
echo "============================================"
echo ""

if $K8S_MODE; then
  echo "Access (use port-forward):"
  echo "  kubectl port-forward svc/openclaw 18789:18789 -n $OPENCLAW_NAMESPACE"
  echo ""
  echo "Then open:"
  echo "  OpenClaw Gateway:    http://localhost:18789"
  echo ""
else
  OPENCLAW_ROUTE=$($KUBECTL get route openclaw -n "$OPENCLAW_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [ -n "$OPENCLAW_ROUTE" ]; then
    echo "Access URL:"
    echo "  OpenClaw Gateway:  https://${OPENCLAW_ROUTE}"
    echo ""
  fi
fi

echo "Credentials:"
echo "  Gateway Token:     $OPENCLAW_GATEWAY_TOKEN"
echo ""
echo "Agent:               ${SHADOWMAN_DISPLAY_NAME} (${OPENCLAW_PREFIX}_${SHADOWMAN_CUSTOM_NAME})"
echo "Model:               $DEFAULT_AGENT_MODEL"
echo "A2A:                 enabled"
echo "Config:              $USER_ENV"
echo ""

log_success "Setup complete!"
echo ""
