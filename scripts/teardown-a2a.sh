#!/usr/bin/env bash
# ============================================================================
# OPENCLAW A2A TEARDOWN
# ============================================================================
# Removes the OpenClaw deployment installed by setup-a2a.sh / setup.sh --with-a2a.
# Reads .env for namespace. Does NOT remove Kagenti platform or MLflow.
#
# Usage:
#   ./scripts/teardown-a2a.sh                      # Interactive (confirm)
#   ./scripts/teardown-a2a.sh --force               # Skip confirmation
#   ./scripts/teardown-a2a.sh --k8s                 # Vanilla Kubernetes
#   ./scripts/teardown-a2a.sh --env-file path/.env  # Custom .env
#   ./scripts/teardown-a2a.sh --delete-env          # Also delete .env
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
FORCE=false
DELETE_ENV=false
ENV_FILE=""
PREFIX_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) K8S_MODE=true; shift ;;
    --force) FORCE=true; shift ;;
    --delete-env) DELETE_ENV=true; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [PREFIX] [OPTIONS]"
      echo ""
      echo "Arguments:"
      echo "  PREFIX            Namespace prefix (e.g. bob → bob-openclaw)"
      echo ""
      echo "Options:"
      echo "  --force           Skip confirmation"
      echo "  --k8s             Use kubectl instead of oc"
      echo "  --env-file PATH   Use a specific .env file (default: .env)"
      echo "  --delete-env      Also delete .env file"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    -*) shift ;;
    *) PREFIX_ARG="$1"; shift ;;
  esac
done
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  KUBECTL="${KUBECTL:-oc}"
  command -v oc &>/dev/null && KUBECTL=oc || KUBECTL=kubectl
fi

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

echo ""
echo "============================================"
echo "  OpenClaw A2A Teardown"
echo "============================================"
echo ""

# Determine prefix and load per-user .env.<prefix>
if [ -n "$PREFIX_ARG" ]; then
  OPENCLAW_PREFIX="$PREFIX_ARG"
  OPENCLAW_NAMESPACE="${PREFIX_ARG}-openclaw"
  USER_ENV="$REPO_ROOT/.env.${PREFIX_ARG}"
  if [ -f "$USER_ENV" ]; then
    set -a
    source "$USER_ENV"
    set +a
    log_success "Loaded $USER_ENV"
    # Re-apply prefix (in case .env file had a different one)
    OPENCLAW_PREFIX="$PREFIX_ARG"
    OPENCLAW_NAMESPACE="${PREFIX_ARG}-openclaw"
  fi
elif [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
  log_success "Loaded $ENV_FILE"
fi

# Determine namespace
if [ -z "${OPENCLAW_NAMESPACE:-}" ]; then
  if [ -n "${OPENCLAW_PREFIX:-}" ]; then
    OPENCLAW_NAMESPACE="${OPENCLAW_PREFIX}-openclaw"
  else
    log_error "Usage: $0 PREFIX [OPTIONS]  (e.g. $0 bob --force)"
    exit 1
  fi
fi

A2A_ENABLED="${A2A_ENABLED:-true}"

echo ""
log_warn "This will remove:"
echo "  - All resources in namespace: $OPENCLAW_NAMESPACE"
echo "  - Cluster-scoped OAuthClient and A2A ClusterRoleBindings"
echo ""
log_info "NOT removed: Kagenti platform, MLflow, .env (unless --delete-env)"
echo ""

if ! $FORCE; then
  read -p "$(echo -e "${YELLOW}?${NC} Proceed? [y/N] ")" answer
  if [[ ! "$answer" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
  fi
fi
echo ""

# Step 1: A2A cluster-scoped cleanup
if [ "$A2A_ENABLED" = "true" ] && ! $K8S_MODE; then
  log_info "Removing A2A SCC ClusterRoleBinding..."
  $KUBECTL delete clusterrolebinding "openclaw-authbridge-scc-${OPENCLAW_NAMESPACE}" 2>/dev/null && \
    log_success "ClusterRoleBinding deleted" || \
    log_info "ClusterRoleBinding not found — skipping"
fi

# OpenShift OAuthClient
if ! $K8S_MODE; then
  log_info "Removing OAuthClient..."
  $KUBECTL delete oauthclient "$OPENCLAW_NAMESPACE" 2>/dev/null && \
    log_success "OAuthClient $OPENCLAW_NAMESPACE deleted" || \
    log_info "OAuthClient not found — skipping"
fi
echo ""

# Step 2: Delete namespace resources then namespace
if ! $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
  log_warn "Namespace $OPENCLAW_NAMESPACE does not exist — skipping"
else
  log_info "Deleting resources in $OPENCLAW_NAMESPACE..."

  $KUBECTL delete all --all -n "$OPENCLAW_NAMESPACE" --timeout=60s 2>/dev/null || true
  $KUBECTL delete jobs,cronjobs --all -n "$OPENCLAW_NAMESPACE" --timeout=30s 2>/dev/null || true
  $KUBECTL delete configmaps,secrets --all -n "$OPENCLAW_NAMESPACE" --timeout=30s 2>/dev/null || true
  $KUBECTL delete serviceaccounts,roles,rolebindings --all -n "$OPENCLAW_NAMESPACE" --timeout=30s 2>/dev/null || true
  $KUBECTL delete pvc --all -n "$OPENCLAW_NAMESPACE" --timeout=60s 2>/dev/null || true
  $KUBECTL delete networkpolicies,poddisruptionbudgets,resourcequotas --all -n "$OPENCLAW_NAMESPACE" --timeout=30s 2>/dev/null || true
  if ! $K8S_MODE; then
    $KUBECTL delete routes --all -n "$OPENCLAW_NAMESPACE" --timeout=30s 2>/dev/null || true
  fi
  # OTEL collector resource (if OTel Operator is installed)
  $KUBECTL delete opentelemetrycollectors --all -n "$OPENCLAW_NAMESPACE" --timeout=30s 2>/dev/null || true

  log_success "Resources deleted"

  log_info "Deleting namespace $OPENCLAW_NAMESPACE..."
  if $KUBECTL delete namespace "$OPENCLAW_NAMESPACE" --timeout=60s 2>/dev/null; then
    log_success "Namespace $OPENCLAW_NAMESPACE deleted"
  else
    log_warn "Namespace deletion timed out — removing finalizers..."
    $KUBECTL get namespace "$OPENCLAW_NAMESPACE" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; json.dump(d,sys.stdout)" \
      | $KUBECTL replace --raw "/api/v1/namespaces/$OPENCLAW_NAMESPACE/finalize" -f - >/dev/null 2>&1 || true
    sleep 3
    if $KUBECTL get namespace "$OPENCLAW_NAMESPACE" &>/dev/null; then
      log_warn "Namespace still exists — may need manual cleanup"
    else
      log_success "Namespace deleted (finalizers stripped)"
    fi
  fi
fi
echo ""

# Step 3: Clean up generated/
if [ -d "$REPO_ROOT/generated" ]; then
  rm -rf "$REPO_ROOT/generated"
  log_success "Removed generated/ directory"
fi

# Step 4: Optionally delete .env
if $DELETE_ENV && [ -f "$ENV_FILE" ]; then
  rm "$ENV_FILE"
  log_success "Deleted $ENV_FILE"
elif [ -f "$ENV_FILE" ]; then
  log_info ".env kept (use --delete-env to remove)"
fi

echo ""
echo "============================================"
echo "  OpenClaw teardown complete"
echo ""
echo "  Preserved:"
echo "    - Kagenti platform (kagenti-system)"
echo "    - MLflow (mlflow namespace)"
echo "    - .env $(if $DELETE_ENV; then echo "(deleted)"; else echo "(kept for re-deploy)"; fi)"
echo ""
echo "  To redeploy: ./scripts/setup-a2a.sh"
echo "============================================"
echo ""
