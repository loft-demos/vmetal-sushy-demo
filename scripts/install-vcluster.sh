#!/usr/bin/env bash
# install-vcluster.sh — install vCluster Standalone with vCluster Platform + HTTPS Gateway
#
# Renders configs/vcluster.yaml from .env, runs the vCluster Standalone install,
# then applies post-install resources:
#   1. MetalLB IPAddressPool + L2Advertisement  → gives Gateway its LAN IP
#   2. cert-manager Issuer + Certificate        → wildcard TLS for *.VDEMO_DOMAIN
#   3. GatewayClass + Gateway                   → wildcard HTTP+HTTPS listeners
#   4. HTTP redirect + HTTPS route for Platform → vcp.VDEMO_DOMAIN
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
TRAEFIK_VERSION="${TRAEFIK_VERSION:-39.0.6}"
IMAGE_CACHE_DIR="${IMAGE_CACHE_DIR:-/srv/os-images}"

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

command -v curl    &>/dev/null || die "curl is required"

# ---------------------------------------------------------------------------
# Render vcluster.yaml
# ---------------------------------------------------------------------------
TEMPLATE="${REPO_ROOT}/configs/vcluster.yaml"
RENDERED="/tmp/vmetal-vcluster-rendered.yaml"

log "Rendering vcluster.yaml..."

sed \
  -e "s|__K8S_VERSION__|${K8S_VERSION}|g" \
  -e "s|__VCP_PLATFORM_VERSION__|${VCP_PLATFORM_VERSION}|g" \
  -e "s|__VCP_LICENSE_TOKEN__|${VCP_LICENSE_TOKEN}|g" \
  -e "s|__VCP_LOFT_HOST__|${VCP_LOFT_HOST}|g" \
  -e "s|__METALLB_IP_RANGE__|${METALLB_IP_RANGE}|g" \
  -e "s|__TRAEFIK_VERSION__|${TRAEFIK_VERSION}|g" \
  "${TEMPLATE}" > "${RENDERED}"

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
echo " Gateway      : Traefik ${TRAEFIK_VERSION} (*.${VDEMO_DOMAIN} → ${GATEWAY_IP}, HTTPS)"
echo "====================================================================="
echo ""

curl -sfL "${INSTALL_URL}" | sudo sh -s -- \
  --vcluster-name "${VCLUSTER_NAME}" \
  --config "${RENDERED}"

log "Standalone install complete. Applying post-install resources..."

# ---------------------------------------------------------------------------
# Helper: wait for a CRD to exist
# ---------------------------------------------------------------------------
wait_for_crd() {
  local crd="$1"
  local max=90   # 90 × 2s = 3 minutes — enough for image pulls on first install
  for i in $(seq 1 "${max}"); do
    ${KC} get crd "${crd}" &>/dev/null && return 0
    [[ "${i}" -eq "${max}" ]] && die "CRD ${crd} not ready after ${max} attempts"
    log "Waiting for CRD ${crd}... (${i}/${max})"
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# Helper: wait for a deployment to have at least 1 ready replica
# ---------------------------------------------------------------------------
wait_for_deployment() {
  local ns="$1"
  local deploy="$2"
  local max=90
  for i in $(seq 1 "${max}"); do
    ready=$(${KC} -n "${ns}" get deployment "${deploy}" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    [[ "${ready}" =~ ^[1-9] ]] && return 0
    [[ "${i}" -eq "${max}" ]] && die "Deployment ${ns}/${deploy} not ready after ${max} attempts"
    log "Waiting for deployment ${ns}/${deploy}... (${i}/${max})"
    sleep 2
  done
}

# Wait for a service to have at least one ready endpoint (webhook is truly ready)
wait_for_endpoints() {
  local ns="$1"
  local svc="$2"
  local max=90
  for i in $(seq 1 "${max}"); do
    ep=$(${KC} -n "${ns}" get endpoints "${svc}" \
      -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    [[ -n "${ep}" ]] && return 0
    [[ "${i}" -eq "${max}" ]] && die "Endpoints for ${ns}/${svc} not ready after ${max} attempts"
    log "Waiting for endpoints ${ns}/${svc}... (${i}/${max})"
    sleep 2
  done
}

# ---------------------------------------------------------------------------
# 1. MetalLB CRs
# ---------------------------------------------------------------------------
log "Waiting for MetalLB CRDs..."
wait_for_crd "ipaddresspools.metallb.io"

log "Waiting for MetalLB webhook to be ready..."
wait_for_deployment "metallb-system" "metallb-controller"
wait_for_endpoints "metallb-system" "metallb-webhook-service"

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
# 2. Wildcard TLS certificate for the Gateway
# ---------------------------------------------------------------------------
log "Waiting for cert-manager CRDs..."
wait_for_crd "issuers.cert-manager.io"
wait_for_crd "certificates.cert-manager.io"

log "Waiting for cert-manager controller and webhook..."
wait_for_deployment "cert-manager" "cert-manager"
wait_for_deployment "cert-manager" "cert-manager-webhook"
wait_for_endpoints "cert-manager" "cert-manager-webhook"

log "Applying self-signed wildcard TLS for *.${VDEMO_DOMAIN}..."
sed "s|VDEMO_DOMAIN_PLACEHOLDER|${VDEMO_DOMAIN}|g" \
  "${REPO_ROOT}/manifests/gateway/tls-wildcard.yaml" \
  | ${KC} apply -f -

log "Waiting for wildcard certificate to become Ready..."
${KC} -n traefik wait --for=condition=Ready certificate/vdemo-wildcard-cert --timeout=180s

log "Publishing platform certificate for Private Node trust bootstrap..."
sudo mkdir -p "${IMAGE_CACHE_DIR}"
${KC} -n traefik get secret vdemo-wildcard-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | sudo tee "${IMAGE_CACHE_DIR}/vdemo-platform.crt" > /dev/null
sudo chmod 0644 "${IMAGE_CACHE_DIR}/vdemo-platform.crt"

# ---------------------------------------------------------------------------
# 3. GatewayClass + Gateway + HTTPRoute resources
# ---------------------------------------------------------------------------
log "Waiting for Gateway API CRDs (installed by Traefik)..."
wait_for_crd "gatewayclasses.gateway.networking.k8s.io"

log "Waiting for Traefik controller..."
wait_for_deployment "traefik" "traefik"

log "Applying GatewayClass and Gateway (*.${VDEMO_DOMAIN})..."

# Substitute VDEMO_DOMAIN into the manifests before applying
for manifest in \
  "${REPO_ROOT}/manifests/gateway/gatewayclass.yaml" \
  "${REPO_ROOT}/manifests/gateway/gateway.yaml" \
  "${REPO_ROOT}/manifests/gateway/httproute-http-redirect.yaml" \
  "${REPO_ROOT}/manifests/gateway/httproute-vcp.yaml"
do
  sed "s|VDEMO_DOMAIN_PLACEHOLDER|${VDEMO_DOMAIN}|g" "${manifest}" \
    | ${KC} apply -f -
done

# ---------------------------------------------------------------------------
# 4. Wait for Gateway to get its external IP from MetalLB
# ---------------------------------------------------------------------------
log "Waiting for Gateway to receive IP ${GATEWAY_IP} from MetalLB..."
for i in $(seq 1 30); do
  gw_ip=$(${KC} -n traefik get svc traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ "${gw_ip}" == "${GATEWAY_IP}" ]]; then
    log "Gateway IP confirmed: ${gw_ip}"
    break
  fi
  [[ "${i}" -eq 30 ]] && warn "Gateway did not receive IP after 60s — check MetalLB and Traefik pods"
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
${KC} -n traefik get gateway demo-gateway 2>/dev/null || true

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
echo "   https://${VCP_LOFT_HOST}"
echo ""
echo " CLI login (self-signed cert):"
echo "   vcluster platform login https://${VCP_LOFT_HOST} --insecure"
echo "====================================================================="
