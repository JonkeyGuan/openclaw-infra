#!/usr/bin/env bash
# ============================================================================
# KAGENTI PLATFORM TEARDOWN
# ============================================================================
# Reverses everything installed by kagenti-setup-works-with-mlflow.sh:
#   - Helm releases: kagenti, mcp-gateway, kagenti-deps
#   - Kagenti namespace controller
#   - Shared trust cert-manager resources (ClusterIssuers, Certificates, cacerts)
#   - Cluster-scoped resources (SCC, ClusterRoles, ClusterRoleBindings)
#   - Namespaces: kagenti-system, mcp-system, mlflow, keycloak, istio-cni, istio-system, istio-ztunnel
#   - MLflow (standalone, deployed by deploy-mlflow.sh)
#
# Does NOT remove:
#   - cert-manager operator (shared infrastructure, may be used by other workloads)
#   - OVN gateway patch (safe to leave, reverting risks disruption)
#   - user-workload-monitoring config
#
# Usage:
#   ./scripts/kagenti-teardown-works-with-mlflow.sh              # Interactive
#   ./scripts/kagenti-teardown-works-with-mlflow.sh --force       # Skip confirmations
#   ./scripts/kagenti-teardown-works-with-mlflow.sh --dry-run     # Show what would be done
# ============================================================================

set -euo pipefail

FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--force] [--dry-run]"
      echo ""
      echo "Options:"
      echo "  --force     Skip confirmations"
      echo "  --dry-run   Show commands without executing"
      echo "  -h, --help  Show this help"
      exit 0
      ;;
    *) shift ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

run_cmd() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

confirm() {
  if $FORCE || $DRY_RUN; then return 0; fi
  local msg="$1"
  read -p "$(echo -e "${YELLOW}?${NC} ${msg} [y/N] ")" answer
  [[ "$answer" =~ ^[Yy] ]]
}

# Check for kubectl/oc
if command -v oc &>/dev/null; then
  KUBECTL=oc
elif command -v kubectl &>/dev/null; then
  KUBECTL=kubectl
else
  log_error "Neither oc nor kubectl found in PATH"
  exit 1
fi

if ! $KUBECTL cluster-info &>/dev/null 2>&1; then
  log_error "Cannot connect to cluster. Run 'oc login' first."
  exit 1
fi
log_success "Connected to cluster"

echo ""
echo "============================================"
echo "  Kagenti Platform Teardown"
echo "============================================"
echo ""
log_warn "This will remove the entire Kagenti stack + standalone MLflow:"
echo "  - Helm releases: kagenti, mcp-gateway, kagenti-deps"
echo "  - Standalone MLflow (deploy-mlflow.sh)"
echo "  - Shared trust resources (ClusterIssuers, Certificates, cacerts)"
echo "  - Cluster-scoped resources (SCC, ClusterRoles)"
echo "  - Namespaces: kagenti-system, mcp-system, mlflow, keycloak,"
echo "    istio-cni, istio-system, istio-ztunnel, zero-trust-workload-identity-manager"
echo ""

if ! confirm "Proceed with teardown?"; then
  echo "Aborted."
  exit 0
fi
echo ""

# ============================================================================
# Step 1: Uninstall Helm releases (reverse order)
# ============================================================================
log_info "Step 1: Uninstall Helm releases"

for release_ns in "kagenti:kagenti-system" "mcp-gateway:mcp-system" "kagenti-deps:kagenti-system"; do
  release="${release_ns%%:*}"
  ns="${release_ns##*:}"
  if helm status "$release" -n "$ns" &>/dev/null 2>&1; then
    log_info "Uninstalling $release from $ns..."
    run_cmd helm uninstall "$release" -n "$ns" --timeout 5m || log_warn "helm uninstall $release failed (continuing)"
    log_success "$release uninstalled"
  else
    log_info "$release not found in $ns — skipping"
  fi
done
echo ""

# ============================================================================
# Step 2: Clean up Kagenti namespace controller
# ============================================================================
log_info "Step 2: Clean up Kagenti namespace controller"

if $KUBECTL get deployment kagenti-namespace-controller -n kagenti-system &>/dev/null 2>&1; then
  run_cmd $KUBECTL delete deployment kagenti-namespace-controller -n kagenti-system --ignore-not-found
  log_success "Kagenti namespace controller deleted"
else
  log_info "Namespace controller not found — skipping"
fi
echo ""

# ============================================================================
# Step 3: Clean up shared trust resources
# ============================================================================
log_info "Step 3: Clean up shared trust resources"

# Certificates
for item in "istio-cacerts-openshift-gateway:openshift-ingress" "istio-cacerts-default:istio-system" "istio-mesh-root-ca:cert-manager"; do
  name="${item%%:*}"
  ns="${item##*:}"
  if $KUBECTL get certificate "$name" -n "$ns" &>/dev/null 2>&1; then
    run_cmd $KUBECTL delete certificate "$name" -n "$ns" --ignore-not-found
    log_success "Certificate $name deleted from $ns"
  fi
done

# ClusterIssuers
for issuer in istio-mesh-ca istio-mesh-root-selfsigned; do
  if $KUBECTL get clusterissuer "$issuer" &>/dev/null 2>&1; then
    run_cmd $KUBECTL delete clusterissuer "$issuer" --ignore-not-found
    log_success "ClusterIssuer $issuer deleted"
  fi
done

# Cacerts secrets
for item in "cacerts:istio-system" "cacerts:openshift-ingress"; do
  name="${item%%:*}"
  ns="${item##*:}"
  if $KUBECTL get secret "$name" -n "$ns" &>/dev/null 2>&1; then
    run_cmd $KUBECTL delete secret "$name" -n "$ns" --ignore-not-found
    log_success "Secret $name deleted from $ns"
  fi
done

# Cert secrets created by cert-manager
for item in "istio-mesh-root-ca-secret:cert-manager" "istio-cacerts-default-cert:istio-system" "istio-cacerts-og-cert:openshift-ingress"; do
  name="${item%%:*}"
  ns="${item##*:}"
  if $KUBECTL get secret "$name" -n "$ns" &>/dev/null 2>&1; then
    run_cmd $KUBECTL delete secret "$name" -n "$ns" --ignore-not-found
    log_success "Secret $name deleted from $ns"
  fi
done

# otel-ingress-ca ConfigMap
if $KUBECTL get configmap otel-ingress-ca -n kagenti-system &>/dev/null 2>&1; then
  run_cmd $KUBECTL delete configmap otel-ingress-ca -n kagenti-system --ignore-not-found
  log_success "ConfigMap otel-ingress-ca deleted"
fi
echo ""

# ============================================================================
# Step 4: Clean up cluster-scoped resources
# ============================================================================
log_info "Step 4: Clean up cluster-scoped resources"

for item in \
  "securitycontextconstraints:kagenti-authbridge" \
  "clusterrole:system:openshift:scc:kagenti-authbridge" \
  "clusterrolebinding:system:openshift:scc:kagenti-authbridge" \
  "clusterrole:kagenti-manager-role" \
  "clusterrole:kagenti-backend"
do
  kind="${item%%:*}"
  name="${item#*:}"
  if $KUBECTL get "$kind" "$name" &>/dev/null 2>&1; then
    run_cmd $KUBECTL delete "$kind" "$name" --ignore-not-found
    log_success "$kind/$name deleted"
  fi
done
echo ""

# ============================================================================
# Step 5: Delete namespaces
# ============================================================================
log_info "Step 5: Delete namespaces"

_force_delete_ns() {
  local ns="$1" tries=0
  local phase
  phase=$($KUBECTL get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$phase" = "NotFound" ]; then return 0; fi

  run_cmd $KUBECTL delete namespace "$ns" --timeout=60s 2>/dev/null || true

  # If stuck terminating, strip finalizers
  tries=0
  while $KUBECTL get ns "$ns" &>/dev/null 2>&1; do
    if $DRY_RUN; then return 0; fi
    $KUBECTL get ns "$ns" -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; json.dump(d,sys.stdout)" \
      | $KUBECTL replace --raw "/api/v1/namespaces/$ns/finalize" -f - >/dev/null 2>&1 || true
    tries=$((tries + 1))
    if [ $tries -ge 30 ]; then
      log_warn "$ns still stuck in Terminating after 30s"
      return 1
    fi
    sleep 1
  done
  return 0
}

for ns in kagenti-system mcp-system mlflow keycloak istio-cni istio-system istio-ztunnel zero-trust-workload-identity-manager; do
  if $KUBECTL get namespace "$ns" &>/dev/null 2>&1; then
    log_info "Deleting namespace $ns..."
    if _force_delete_ns "$ns"; then
      log_success "Namespace $ns deleted"
    fi
  else
    log_info "Namespace $ns not found — skipping"
  fi
done
echo ""

# ============================================================================
# Done
# ============================================================================
echo "============================================"
echo "  Kagenti platform teardown complete"
echo ""
echo "  Not removed (shared infrastructure):"
echo "    - cert-manager operator subscription"
echo "    - OVN gateway routing patch"
echo "    - cluster-monitoring-config changes"
echo ""
echo "  To also remove cert-manager:"
echo "    $KUBECTL delete subscription openshift-cert-manager-operator -n cert-manager-operator"
echo "    $KUBECTL delete namespace cert-manager-operator cert-manager"
echo "============================================"
echo ""
