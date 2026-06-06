#!/usr/bin/env bash
# ============================================================================
# MLFLOW DEPLOYMENT
# ============================================================================
# Deploys MLflow Tracking Server into the mlflow namespace.
# Can be run standalone or called from setup.sh.
#
# Usage:
#   ./scripts/deploy-mlflow.sh                         # Interactive
#   ./scripts/deploy-mlflow.sh --env-file path/to/.env # Use specific .env
#   ./scripts/deploy-mlflow.sh --k8s                   # Use kubectl (skip Route)
#
# This deploys:
#   - mlflow namespace
#   - MLflow Tracking Server (Deployment + Service + PVC)
#   - OpenShift Route for external UI access (unless --k8s)
#
# The OTEL sidecar collectors export traces to:
#   http://mlflow-service.mlflow.svc.cluster.local:5000
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Parse flags
K8S_MODE=false
ENV_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s) K8S_MODE=true; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --env-file PATH   Use a specific .env file (default: .env)"
      echo "  --k8s             Use kubectl instead of oc (skip Route)"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    *) shift ;;
  esac
done
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if $K8S_MODE; then
  KUBECTL="kubectl"
else
  if command -v oc &>/dev/null; then
    KUBECTL="oc"
  else
    KUBECTL="kubectl"
  fi
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

GENERATED_DIR="$REPO_ROOT/generated"
MLFLOW_DIR="$REPO_ROOT/platform/observability/mlflow"
ROUTE_TEMPLATE="$MLFLOW_DIR/mlflow-route.yaml.envsubst"
ROUTE_YAML="$GENERATED_DIR/platform/observability/mlflow/mlflow-route.yaml"

echo ""
echo "============================================"
echo "  MLflow Tracking Server Deployment"
echo "============================================"
echo ""

# Load .env if it exists
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
  log_success "Loaded $ENV_FILE"
fi

# Deploy via kustomize
log_info "Deploying MLflow (namespace, PVC, deployment, service)..."
if $KUBECTL apply -k "$MLFLOW_DIR"; then
  log_success "MLflow base resources deployed"
else
  log_error "Failed to deploy MLflow"
  exit 1
fi

# Deploy OpenShift Route (not for --k8s)
if ! $K8S_MODE && [ -f "$ROUTE_TEMPLATE" ]; then
  if [ -z "${CLUSTER_DOMAIN:-}" ]; then
    CLUSTER_DOMAIN=$($KUBECTL get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    if [ -z "$CLUSTER_DOMAIN" ]; then
      CLUSTER_DOMAIN="apps.$($KUBECTL get dns cluster -o jsonpath='{.spec.baseDomain}' 2>/dev/null || echo "")"
      if [ "$CLUSTER_DOMAIN" = "apps." ]; then
        CLUSTER_DOMAIN=""
      fi
    fi
    if [ -z "$CLUSTER_DOMAIN" ]; then
      read -p "  Cluster domain (e.g. apps.example.com): " CLUSTER_DOMAIN
    fi
  fi

  if [ -n "$CLUSTER_DOMAIN" ]; then
    export CLUSTER_DOMAIN
    mkdir -p "$(dirname "$ROUTE_YAML")"
    envsubst '${CLUSTER_DOMAIN}' < "$ROUTE_TEMPLATE" > "$ROUTE_YAML"
    if $KUBECTL apply -f "$ROUTE_YAML"; then
      log_success "Route: mlflow.${CLUSTER_DOMAIN}"
    else
      log_warn "Failed to create Route (non-fatal)"
    fi
  else
    log_warn "Skipping Route — no cluster domain detected"
  fi
fi

# Wait for rollout
log_info "Waiting for MLflow to be ready..."
if $KUBECTL rollout status deployment/mlflow-deployment -n mlflow --timeout=300s 2>/dev/null; then
  log_success "MLflow is running"
else
  log_warn "MLflow not ready yet — check pod status: $KUBECTL get pods -n mlflow"
fi

echo ""
echo "============================================"
echo "  MLflow Tracking Server Ready"
echo ""
echo "  In-cluster:  http://mlflow-service.mlflow.svc.cluster.local:5000"
if ! $K8S_MODE && [ -n "${CLUSTER_DOMAIN:-}" ]; then
echo "  External:    https://mlflow.${CLUSTER_DOMAIN}"
fi
echo "  Namespace:   mlflow"
echo ""
echo "  Port-forward for local access:"
echo "    $KUBECTL port-forward svc/mlflow-service 5000:5000 -n mlflow"
echo "============================================"
echo ""
