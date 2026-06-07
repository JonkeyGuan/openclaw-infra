#!/usr/bin/env bash
# ============================================================================
# FIX: Load nft_redir kernel module on OpenShift worker nodes
# ============================================================================
# Kagenti's proxy-init uses iptables-nft REDIRECT rules, which require the
# nft_redir kernel module. On RHCOS nodes this module is present but not
# loaded by default, causing proxy-init to crash with:
#
#   iptables v1.8.11 (nf_tables): RULE_APPEND failed (No such file or directory)
#
# This script applies a MachineConfig that loads the required kernel modules
# at boot time. Worker nodes will reboot one by one (MCO rolling update).
#
# Usage:
#   ./scripts/fix-nft-redir.sh              # Apply MachineConfig
#   ./scripts/fix-nft-redir.sh --dry-run    # Show manifest without applying
#   ./scripts/fix-nft-redir.sh --status     # Check rollout status
#   ./scripts/fix-nft-redir.sh --remove     # Remove MachineConfig
#
# Time: ~5-10 minutes per worker node (rolling reboot)
# ============================================================================

set -euo pipefail

DRY_RUN=false
STATUS_ONLY=false
REMOVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --status) STATUS_ONLY=true; shift ;;
    --remove) REMOVE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run|--status|--remove]"
      echo ""
      echo "Options:"
      echo "  --dry-run   Show MachineConfig without applying"
      echo "  --status    Check MCO rollout status"
      echo "  --remove    Remove MachineConfig (triggers node reboot)"
      echo "  -h, --help  Show this help"
      exit 0
      ;;
    *) shift ;;
  esac
done

KUBECTL="${KUBECTL:-oc}"
command -v oc &>/dev/null && KUBECTL=oc || KUBECTL=kubectl

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}→${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warn()    { echo -e "${YELLOW}⚠${NC} $1"; }
log_error()   { echo -e "${RED}✗${NC} $1"; }

MC_NAME="99-worker-load-nft-redir"

# --status: just show MCO rollout status
if $STATUS_ONLY; then
  echo ""
  log_info "MachineConfig status:"
  $KUBECTL get machineconfig "$MC_NAME" 2>/dev/null && echo "" || log_warn "MachineConfig $MC_NAME not found"
  echo ""
  log_info "MachineConfigPool worker status:"
  $KUBECTL get machineconfigpool worker 2>&1
  echo ""
  log_info "Node status:"
  $KUBECTL get nodes -o wide 2>&1
  exit 0
fi

# --remove: delete MachineConfig
if $REMOVE; then
  echo ""
  log_warn "Removing MachineConfig $MC_NAME (will trigger node reboots)"
  read -p "$(echo -e "${YELLOW}?${NC} Proceed? [y/N] ")" answer
  if [[ ! "$answer" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
  fi
  $KUBECTL delete machineconfig "$MC_NAME" 2>/dev/null && \
    log_success "MachineConfig $MC_NAME removed" || \
    log_warn "MachineConfig $MC_NAME not found"
  exit 0
fi

# Generate MachineConfig manifest
MANIFEST=$(cat <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-load-nft-redir
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - path: /etc/modules-load.d/nft-redir.conf
        mode: 0644
        overwrite: true
        contents:
          source: data:,nft_redir%0Anf_nat%0Axt_REDIRECT%0Axt_mark
EOF
)

echo ""
echo "============================================"
echo "  Fix: Load nft_redir kernel module"
echo "============================================"
echo ""

if $DRY_RUN; then
  log_info "MachineConfig manifest (dry-run):"
  echo ""
  echo "$MANIFEST"
  echo ""
  log_info "To apply: $0 (without --dry-run)"
  exit 0
fi

# Check if already applied
if $KUBECTL get machineconfig "$MC_NAME" &>/dev/null 2>&1; then
  log_success "MachineConfig $MC_NAME already exists"
  log_info "Check status: $0 --status"
  exit 0
fi

# Count worker nodes
WORKER_COUNT=$($KUBECTL get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null | wc -l | tr -d ' ')

log_warn "This will:"
echo "  - Apply MachineConfig to load nft_redir, nf_nat, xt_REDIRECT, xt_mark"
echo "  - Trigger rolling reboot of $WORKER_COUNT worker nodes"
echo "  - Take ~5-10 minutes per node"
echo ""

read -p "$(echo -e "${YELLOW}?${NC} Proceed? [y/N] ")" answer
if [[ ! "$answer" =~ ^[Yy] ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

log_info "Applying MachineConfig..."
echo "$MANIFEST" | $KUBECTL apply -f -
log_success "MachineConfig $MC_NAME applied"
echo ""

log_info "MCO will now reboot worker nodes one by one."
log_info "Monitor progress:"
echo "  $0 --status"
echo "  oc get nodes -w"
echo "  oc get machineconfigpool worker -w"
echo ""
log_info "After all nodes are updated, redeploy OpenClaw:"
echo "  ./scripts/teardown-a2a.sh --force"
echo "  ./scripts/setup-a2a.sh"
echo ""
