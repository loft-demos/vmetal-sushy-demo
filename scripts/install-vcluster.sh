#!/usr/bin/env bash
# install-vcluster.sh — install vCluster Standalone with vCluster Platform + Gateway
#
# Renders configs/vcluster.yaml from .env, runs the vCluster Standalone install,
# then applies post-install resources:
#   1. MetalLB IPAddressPool + L2Advertisement  → gives Gateway its LAN IP
#   2. Envoy GatewayClass + Gateway             → wildcard *.VDEMO_DOMAIN listener
#   3. HTTPRoute for vcp.VDEMO_DOMAIN           → routes to vcluster-platform svc
#
# Prerequisites:
#   - .env exists with VCP_LICENSE_TOKEN, VCP_LOFT_HOST, GATEWAY_IP,
#     METALLB_IP_RANGE, VDEMO_DOMAIN set
#   - Docker installed (for experimental.docker.nodes)
#   - bootstrap-host.sh has been run
#   - install-dnsmasq.sh has been run (so *.VDEMO_DOMAIN resolves on the LAN)
#
# Usage:
#   bash scripts/install-vcluster.sh
#
# To uninstall:
#   curl -sfL https://github.com/loft-sh/vcluster/releases/latest/download/install-standalone.sh \
#     | sh -s -- --reset-only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load defaults
VCLUSTER_VERSION="${VCLUSTER_VERSION:-latest}"
VCLUSTER_NAME="${VCLUSTER_NAME:-vmetal-demo}"
K8S_VERSION="${K8S_VERSION:-v1.35.1}"
VCP_PLATFORM_VERSION="${VCP_PLATFORM_VERSION:-4.8.0}"
VCP_LICENSE_TOKEN="${VCP_LICENSE_TOKEN:-}"
VCP_LOFT_HOST="${VCP_LOFT_HOST:-vcp.vdemo.local}"
VDEMO_DOMAIN="${VDEMO_DOMAIN:-vdemo.local}"
GATEWAY_IP="${GATEWAY_IP:-}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.3.2}"
VCP_DOCKER_NODE_COUNT="${VCP_DOCKER_NODE_COUNT:-2}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi

KUBECONFIG_PATH="/var/lib/vcluster/kubeconfig.yaml"
KC="sudo KUBECONFIG=${KUBECONFIG_PATH} kubectl"

log()  { echo "[install-vcluster] $*"; }
die()  { echo "[install-vcluster] ERROR: $*" >&2; exit 1; }
warn() { echo "[install-vcluster] WARNING: $*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -z "${VCP_LICENSE_TOKEN}" ]]  && die "VCP_LICENSE_TOKEN is not set in .env"
[[ -z "${VCP_LOFT_HOST}" ]]      && die "VCP_LOFT_HOST is not set in .env (e.g. vcp.vdemo.local)"
[[ -z "${GATEWAY_IP}" ]]         && die "GATEWAY_IP is not set in .env"
[[ -z "${METALLB_IP_RANGE}" ]]   && die "METALLB_IP_RANGE is not set in .env"
[[ -z "${VDEMO_DOMAIN}" ]]       && die "VDEMO_DOMAIN is not set in .env"

command -v docker  &>/dev/null || die "Docker is required for experimental.docker.nodes"
command -v curl    &>/dev/null || die "curl is required"
command -v python3 &>/dev/null || die "python3 is required for template rendering"

# ---------------------------------------------------------------------------
# Render vcluster.yaml
# ---------------------------------------------------------------------------
DOCKER_NODES_YAML=""
for i in $(seq 1 "${VCP_DOCKER_NODE_COUNT}"); do
  DOCKER_NODES_YAML+="      - name: node-${i}"$'\n'
done
DOCKER_NODES_YAML="${DOCKER_NODES_YAML%$'\n'}"

TEMPLATE="${REPO_ROOT}/configs/vcluster.yaml"
RENDERED="/tmp/vmetal-vcluster-rendered.yaml"

log "Rendering vcluster.yaml..."

sed \
  -e "s|__K8S_VERSION__|${K8S_VERSION}|g" \
  -e "s|__VCP_PLATFORM_VERSION__|${VCP_PLATFORM_VERSION}|g" \
  -e "s|__VCP_LICENSE_TOKEN__|${VCP_LICENSE_TOKEN}|g" \
  -e "s|__VCP_LOFT_HOST__|${VCP_LOFT_HOST}|g" \
  -e "s|__METALLB_IP_RANGE__|${METALLB_IP_RANGE}|g" \
  -e "s|__ENVOY_GATEWAY_VERSION__|${ENVOY_GATEWAY_VERSION}|g" \
  "${TEMPLATE}" > "${RENDERED}"

python3 - <<PYEOF
with open("${RENDERED}", "r") as f:
    content = f.read()
content = content.replace("      - name: node-placeholder", """${DOCKER_NODES_YAML}""")
with open("${RENDERED}", "w") as f:
    f.write(content)
PYEOF

log "Rendered config: ${RENDERED}"

# ---------------------------------------------------------------------------
# Run install
# ---------------------------------------------------------------------------
if [[ "${VCLUSTER_VERSION}" == "latest" ]]; then
  INSTALL_URL="https://github.com/loft-sh/vcluster/releases/latest/download/install-standalone.sh"
else
  INSTALL_URL="https://github.com/loft-sh/vcluster/releases/download/${VCLUSTER_VERSION}/install-standalone.sh"
fi

echo ""
echo "====================================================================="
echo " Installing vCluster Standalone + vCluster Platform"
echo " K8s          : ${K8S_VERSION}"
echo " Platform     : ${VCP_PLATFORM_VERSION} → ${VCP_LOFT_HOST}"
echo " Gateway      : Envoy ${ENVOY_GATEWAY_VERSION} (*.${VDEMO_DOMAIN} → ${GATEWAY_IP})"
echo " Docker nodes : ${VCP_DOCKER_NODE_COUNT}"
echo "====================================================================="
echo ""

curl -sfL "${INSTALL_URL}" | sh -s -- \
  --vcluster-name "${VCLUSTER_NAME}" \
  --config "${RENDERED}"

log "Standalone install complete. Applying post-install resources..."

# ---------------------------------------------------------------------------
# Helper: wait for a CRD to exist
# ---------------------------------------------------------------------------
wait_for_crd() {
  local crd="$1"
  local max=30
  for i in $(seq 1 "${max}"); do
    ${KC} get crd "${crd}" &>/dev/null && return 0
    [[ "${i}" -eq "${max}" ]] && die "CRD ${crd} not ready after ${max} attempts"
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# 1. MetalLB CRs
# ---------------------------------------------------------------------------
log "Waiting for MetalLB CRDs..."
wait_for_crd "ipaddresspools.metallb.io"

log "Applying MetalLB pool: ${METALLB_IP_RANGE}"
${KC} apply -f - <<EOF
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: demo-pool
  namespace: metallb-system
spec:
  addresses:
    - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: demo-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - demo-pool
EOF

# ---------------------------------------------------------------------------
# 2. GatewayClass + Gateway
# ---------------------------------------------------------------------------
log "Waiting for Gateway API CRDs (installed by Envoy Gateway)..."
wait_for_crd "gatewayclasses.gateway.networking.k8s.io"

log "Applying GatewayClass and Gateway (*.${VDEMO_DOMAIN})..."

# Substitute VDEMO_DOMAIN into the manifests before applying
for manifest in \
  "${REPO_ROOT}/manifests/gateway/gatewayclass.yaml" \
  "${REPO_ROOT}/manifests/gateway/gateway.yaml" \
  "${REPO_ROOT}/manifests/gateway/httproute-vcp.yaml"
do
  sed "s|VDEMO_DOMAIN_PLACEHOLDER|${VDEMO_DOMAIN}|g" "${manifest}" \
    | ${KC} apply -f -
done

# ---------------------------------------------------------------------------
# 3. Wait for Gateway to get its external IP from MetalLB
# ---------------------------------------------------------------------------
log "Waiting for Gateway to receive IP ${GATEWAY_IP} from MetalLB..."
for i in $(seq 1 30); do
  gw_ip=$(${KC} -n envoy-gateway-system get svc \
    -l "gateway.envoyproxy.io/owning-gateway-name=demo-gateway" \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ "${gw_ip}" == "${GATEWAY_IP}" ]]; then
    log "Gateway IP confirmed: ${gw_ip}"
    break
  fi
  [[ "${i}" -eq 30 ]] && warn "Gateway did not receive IP after 60s — check MetalLB and Envoy Gateway pods"
  sleep 2
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "--- Nodes ---"
${KC} get nodes 2>/dev/null || warn "kubectl not yet ready"

echo ""
echo "--- Gateway ---"
${KC} -n envoy-gateway-system get gateway demo-gateway 2>/dev/null || true

echo ""
echo "--- Platform pods (may still be starting) ---"
${KC} -n vcluster-platform get pods 2>/dev/null || true

echo ""
echo "====================================================================="
echo " Done."
echo ""
echo " Export kubeconfig:"
echo "   export KUBECONFIG=${KUBECONFIG_PATH}"
echo ""
echo " Watch Platform pods:"
echo "   kubectl -n vcluster-platform get pods -w"
echo ""
echo " Mac DNS setup (if not done yet):"
echo "   bash hack/setup-mac-dns.sh"
echo ""
echo " Platform UI (once pods are ready):"
echo "   http://${VCP_LOFT_HOST}"
echo "====================================================================="
