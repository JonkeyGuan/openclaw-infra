#!/usr/bin/env bash
# ============================================================================
# KAGENTI NAMESPACE SETUP
# ============================================================================
# Creates the ConfigMaps that Kagenti AIB sidecars need in an agent namespace.
# Called automatically by setup.sh --with-a2a, or run standalone to enable A2A
# in a namespace after the fact.
#
# Usage:
#   ./scripts/setup-kagenti-ns.sh -n <namespace>              # Interactive
#   ./scripts/setup-kagenti-ns.sh -n <namespace> --k8s        # Vanilla Kubernetes
#   ./scripts/setup-kagenti-ns.sh -n <namespace> --realm nerc # Custom Keycloak realm
#   ./scripts/setup-kagenti-ns.sh -n <namespace> --keycloak-namespace my-kc
#
# What it creates:
#   - environments          — Keycloak keys for client-registration sidecar
#   - authbridge-config     — Token URL and OIDC issuer for AuthBridge ext_proc
#   - envoy-config          — Envoy proxy config for traffic interception
#   - spiffe-helper-config  — SPIFFE helper cert paths and workload API socket
#   - kagenti-enabled=true label on the namespace
#   - Privileged SCC RoleBindings (OpenShift only)
#
# These ConfigMaps are normally created by the Kagenti Helm chart via the
# agentNamespaces value, but that requires pre-declaring namespaces at install
# time. This script creates them on-demand instead.
#
# TODO: Remove once kagenti-operator reconciles these per-namespace automatically.
#       Upstream issue: https://github.com/kagenti/kagenti/issues/XXX
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse flags
K8S_MODE=false
NAMESPACE=""
KC_REALM="${KEYCLOAK_REALM:-demo}"
KC_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    --realm) KC_REALM="$2"; shift 2 ;;
    --keycloak-namespace) KC_NAMESPACE="$2"; shift 2 ;;
    --k8s) K8S_MODE=true; shift ;;
    -h|--help)
      echo "Usage: $0 -n <namespace> [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  -n, --namespace NS            Target namespace (required)"
      echo "  --realm REALM                 Keycloak realm (default: demo, or \$KEYCLOAK_REALM)"
      echo "  --keycloak-namespace NS       Keycloak namespace (default: keycloak, or \$KEYCLOAK_NAMESPACE)"
      echo "  --k8s                         Use kubectl instead of oc"
      echo "  -h, --help                    Show this help"
      exit 0
      ;;
    *) shift ;;
  esac
done

if [ -z "$NAMESPACE" ]; then
  echo "Error: --namespace is required"
  exit 1
fi

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

# Verify namespace exists
if ! $KUBECTL get namespace "$NAMESPACE" &>/dev/null; then
  log_error "Namespace $NAMESPACE does not exist"
  exit 1
fi

log_info "Setting up Kagenti AIB in namespace: $NAMESPACE"

# Internal Keycloak service URL (used by sidecars within the cluster)
KC_INTERNAL_URL="http://keycloak-service.${KC_NAMESPACE}.svc.cluster.local:8080"

# Detect Keycloak public URL (for OIDC issuer — must be reachable from outside the cluster)
KC_ROUTE=$($KUBECTL get route keycloak -n "$KC_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$KC_ROUTE" ]; then
  KC_PUBLIC_URL="https://${KC_ROUTE}"
else
  # Fallback: try to detect cluster domain
  CLUSTER_DOMAIN=$($KUBECTL get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
  if [ -n "$CLUSTER_DOMAIN" ]; then
    KC_PUBLIC_URL="https://keycloak-${KC_NAMESPACE}.${CLUSTER_DOMAIN}"
  else
    KC_PUBLIC_URL="$KC_INTERNAL_URL"
    log_warn "Could not detect Keycloak public URL — using in-cluster URL"
  fi
fi

# Read Keycloak admin credentials from the RHBK operator secret
KC_ADMIN_USER=$($KUBECTL get secret keycloak-initial-admin -n "$KC_NAMESPACE" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d) || KC_ADMIN_USER="admin"
KC_ADMIN_PASS=$($KUBECTL get secret keycloak-initial-admin -n "$KC_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || KC_ADMIN_PASS="admin"

log_info "Keycloak: realm=$KC_REALM namespace=$KC_NAMESPACE"

# 1. environments — Keycloak keys for client-registration sidecar
#
# ⚠️  SECURITY NOTE: Admin credentials are stored in a ConfigMap (not a Secret).
# The kagenti-webhook's client-registration sidecar hardcodes configMapKeyRef for
# KEYCLOAK_ADMIN_USERNAME and KEYCLOAK_ADMIN_PASSWORD — there is no secretKeyRef
# support yet. This is a known upstream issue:
# https://github.com/kagenti/kagenti-extensions/blob/main/kagenti-webhook/internal/webhook/injector/container_builder.go#L136-#L155
$KUBECTL create configmap environments -n "$NAMESPACE" \
  --from-literal=KEYCLOAK_REALM="$KC_REALM" \
  --from-literal=KEYCLOAK_URL="$KC_INTERNAL_URL" \
  --from-literal=KEYCLOAK_ADMIN_USERNAME="$KC_ADMIN_USER" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PASS" \
  --from-literal=KEYCLOAK_TOKEN_EXCHANGE_ENABLED=true \
  --from-literal=KEYCLOAK_CLIENT_REGISTRATION_ENABLED=true \
  --from-literal=SPIRE_ENABLED=true \
  --dry-run=client -o yaml | $KUBECTL apply -f -
log_success "  environments (Keycloak user: $KC_ADMIN_USER)"

# 2. authbridge-config — token endpoint and issuer for AuthBridge ext_proc
$KUBECTL create configmap authbridge-config -n "$NAMESPACE" \
  --from-literal=TOKEN_URL="${KC_INTERNAL_URL}/realms/${KC_REALM}/protocol/openid-connect/token" \
  --from-literal=ISSUER="${KC_PUBLIC_URL}/realms/${KC_REALM}" \
  --from-literal=TARGET_AUDIENCE=auth-target \
  --from-literal=TARGET_SCOPES="openid auth-target-aud" \
  --from-literal=KEYCLOAK_URL="$KC_INTERNAL_URL" \
  --from-literal=KEYCLOAK_REALM="$KC_REALM" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
log_success "  authbridge-config (issuer: ${KC_PUBLIC_URL}/realms/${KC_REALM})"

# 3. envoy-config — Envoy proxy config for outbound/inbound traffic interception
ENVOY_TMP=$(mktemp)
cat > "$ENVOY_TMP" <<'ENVOY_EOF'
admin:
  address:
    socket_address: { protocol: TCP, address: 127.0.0.1, port_value: 9901 }

static_resources:
  listeners:
  - name: outbound_listener
    address:
      socket_address: { protocol: TCP, address: 0.0.0.0, port_value: 15123 }
    listener_filters:
    - name: envoy.filters.listener.original_dst
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst
    - name: envoy.filters.listener.tls_inspector
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.listener.tls_inspector.v3.TlsInspector
    filter_chains:
    - filter_chain_match: { transport_protocol: tls }
      filters:
      - name: envoy.filters.network.tcp_proxy
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.tcp_proxy.v3.TcpProxy
          stat_prefix: outbound_tls_passthrough
          cluster: original_destination
    - filter_chain_match: { transport_protocol: raw_buffer }
      filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: outbound_http
          codec_type: AUTO
          route_config:
            name: outbound_routes
            virtual_hosts:
            - name: catch_all
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route: { cluster: original_destination }
          http_filters:
          - name: envoy.filters.http.ext_proc
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
              grpc_service:
                envoy_grpc: { cluster_name: ext_proc_cluster }
                timeout: 30s
              processing_mode:
                request_header_mode: SEND
                response_header_mode: SKIP
                request_body_mode: NONE
                response_body_mode: NONE
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  - name: inbound_listener
    address:
      socket_address: { protocol: TCP, address: 0.0.0.0, port_value: 15124 }
    listener_filters:
    - name: envoy.filters.listener.original_dst
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.listener.original_dst.v3.OriginalDst
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: inbound_http
          codec_type: AUTO
          route_config:
            name: inbound_routes
            virtual_hosts:
            - name: local_app
              domains: ["*"]
              request_headers_to_add:
              - header: { key: "x-authbridge-direction", value: "inbound" }
                append: false
              routes:
              - match: { prefix: "/" }
                route: { cluster: original_destination }
          http_filters:
          - name: envoy.filters.http.ext_proc
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
              grpc_service:
                envoy_grpc: { cluster_name: ext_proc_cluster }
                timeout: 30s
              processing_mode:
                request_header_mode: SEND
                response_header_mode: SKIP
                request_body_mode: NONE
                response_body_mode: NONE
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: original_destination
    connect_timeout: 30s
    type: ORIGINAL_DST
    lb_policy: CLUSTER_PROVIDED
    original_dst_lb_config: { use_http_header: false }
  - name: ext_proc_cluster
    connect_timeout: 5s
    type: STATIC
    lb_policy: ROUND_ROBIN
    http2_protocol_options: {}
    load_assignment:
      cluster_name: ext_proc_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 9090 }
ENVOY_EOF
$KUBECTL create configmap envoy-config -n "$NAMESPACE" \
  --from-file=envoy.yaml="$ENVOY_TMP" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f "$ENVOY_TMP"
log_success "  envoy-config"

# 4. spiffe-helper-config — SPIFFE helper sidecar cert paths and socket
HELPER_TMP=$(mktemp)
cat > "$HELPER_TMP" <<'HELPER_EOF'
agent_address = "/spiffe-workload-api/spire-agent.sock"
cmd = ""
cmd_args = ""
svid_file_name = "/opt/svid.pem"
svid_key_file_name = "/opt/svid_key.pem"
svid_bundle_file_name = "/opt/svid_bundle.pem"
jwt_svids = [{jwt_audience="kagenti", jwt_svid_file_name="/opt/jwt_svid.token"}]
jwt_svid_file_mode = 0644
include_federated_domains = true
HELPER_EOF
$KUBECTL create configmap spiffe-helper-config -n "$NAMESPACE" \
  --from-file=helper.conf="$HELPER_TMP" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
rm -f "$HELPER_TMP"
log_success "  spiffe-helper-config"

# OpenShift: grant privileged SCC to default and pipeline SAs
# (needed for proxy-init iptables and envoy runAsUser)
if ! $K8S_MODE; then
  $KUBECTL create rolebinding default-privileged-scc \
    --clusterrole=system:openshift:scc:privileged \
    --serviceaccount="${NAMESPACE}:default" \
    -n "$NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f - 2>/dev/null || true
  $KUBECTL create rolebinding pipeline-privileged-scc \
    --clusterrole=system:openshift:scc:privileged \
    --serviceaccount="${NAMESPACE}:pipeline" \
    -n "$NAMESPACE" --dry-run=client -o yaml | $KUBECTL apply -f - 2>/dev/null || true
  log_success "  SCC RoleBindings (privileged for default + pipeline SAs)"
fi

# 5. keycloak-admin-secret — Keycloak admin credentials for client-registration sidecar
# The kagenti chart only creates this for namespaces listed in agentNamespaces[].
# Since we use the namespace controller path (agentNamespaces=[]), we create it here.
$KUBECTL create secret generic keycloak-admin-secret -n "$NAMESPACE" \
  --from-literal=KEYCLOAK_ADMIN_USERNAME="$KC_ADMIN_USER" \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD="$KC_ADMIN_PASS" \
  --dry-run=client -o yaml | $KUBECTL apply -f -
log_success "  keycloak-admin-secret"

# Label namespace for webhook injection (AFTER ConfigMaps exist, to avoid race
# with Kagenti controller that auto-creates ConfigMaps on label detection)
$KUBECTL label namespace "$NAMESPACE" kagenti-enabled=true --overwrite > /dev/null
log_success "Namespace labeled (kagenti-enabled=true)"

# Re-patch authbridge-config after labeling — the Kagenti namespace controller
# reconciles ConfigMaps on label detection and may overwrite our additions
# (KEYCLOAK_URL, KEYCLOAK_REALM) that the client-registration sidecar needs.
sleep 3
$KUBECTL patch configmap authbridge-config -n "$NAMESPACE" --type merge \
  -p "{\"data\":{\"KEYCLOAK_URL\":\"$KC_INTERNAL_URL\",\"KEYCLOAK_REALM\":\"$KC_REALM\"}}" > /dev/null 2>&1 || true
log_success "  authbridge-config patched (KEYCLOAK_URL, KEYCLOAK_REALM)"

log_success "Kagenti AIB ready in $NAMESPACE"
