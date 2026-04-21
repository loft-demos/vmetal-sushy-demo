# Troubleshooting

---

## KVM / libvirt

### `/dev/kvm` does not exist

**Symptom**: `kvm-ok` says KVM is unavailable, or VMs fail to start with a KVM error.

#### Step 1 — check if AMD-V is already enabled (SSH-safe)

```bash
# Look for 'svm' in CPU flags — present means AMD-V is on
grep -m1 'flags' /proc/cpuinfo | tr ' ' '\n' | grep svm

# Or install cpu-checker and run kvm-ok
sudo apt-get install -y cpu-checker && kvm-ok

# Check if /dev/kvm exists
ls -la /dev/kvm
```

If `svm` appears, `kvm-ok` reports success, or `/dev/kvm` exists → AMD-V is already enabled. Skip to the next step.

#### Step 2 — if AMD-V is not enabled, you need a monitor

The MINISFORUM X1 Pro 370 has no IPMI or remote console. Plug in a monitor and keyboard:

- Press `Del` at boot to enter BIOS
- Navigate to: Advanced → AMD CBS → SVM Mode → Enabled
- Save and exit (F10)

Verify after reboot:

```bash
kvm-ok
lsmod | grep kvm_amd
```

---

### `virsh` permission denied or libvirt connection refused

**Symptoms**:
- `error: failed to connect to the hypervisor`
- `Permission denied` when running virsh commands without sudo

**Fix**: Your user is not in the `libvirt` group, or the membership hasn't taken effect.

```bash
id | grep libvirt          # check
sudo usermod -aG libvirt "$USER"
newgrp libvirt             # or log out and back in
```

Verify libvirtd is running:

```bash
sudo systemctl status libvirtd
```

---

### Sushy Tools cannot see VMs (empty Systems list)

**Symptom**: `curl http://localhost:8000/redfish/v1/Systems/` returns `{"Members": []}`.

**Causes and fixes**:

1. **libvirt URI mismatch** — sushy-tools is connecting to `qemu:///session` instead of `qemu:///system`:
   ```bash
   cat /etc/sushy-tools/emulator.conf | grep LIBVIRT_URI
   # Should be: SUSHY_EMULATOR_LIBVIRT_URI = u'qemu:///system'
   ```

2. **VMs not defined in libvirt** — run `create-vms.sh` first:
   ```bash
   sudo virsh list --all
   ```

---

### `libvirt-python` pip install fails

**Symptom**: `pip install sushy-tools libvirt-python` fails with a build error about missing headers.

**Fix**: Install `libvirt-dev` first:

```bash
sudo apt-get install -y libvirt-dev
```

`bootstrap-host.sh` does this automatically.

---

### OVMF firmware files not found during VM boot

**Symptom**: VMs fail to boot with an error about missing `OVMF_VARS.fd` or `OVMF_CODE.fd`.

**Cause**: Ubuntu 24.04 ships only the `_4M` variants (`OVMF_VARS_4M.fd`, etc.) but libvirt and sushy-tools expect the plain names.

**Fix**: Create symlinks (done automatically by `bootstrap-host.sh`):

```bash
for pair in "OVMF_VARS_4M.fd:OVMF_VARS.fd" "OVMF_CODE_4M.fd:OVMF_CODE.fd" \
            "OVMF_CODE_4M.secboot.fd:OVMF_CODE.secboot.fd" "OVMF_VARS_4M.ms.fd:OVMF_VARS.ms.fd"; do
  src="/usr/share/OVMF/${pair%%:*}"
  dst="/usr/share/OVMF/${pair##*:}"
  [[ -e "${dst}" ]] || sudo ln -s "${src}" "${dst}"
done
```

---

## Networking

### STP causing PXE timeouts

**Symptom**: VMs that PXE-boot get no DHCP response for 30+ seconds, then fail.

**Fix**: STP must be disabled on `br-provision`. `create-bridges.sh` does this automatically. Check:

```bash
cat /sys/class/net/br-provision/bridge/stp_state   # should be 0
```

To fix manually:

```bash
sudo ip link set br-provision type bridge stp_state 0
```

---

### DHCP conflicts on the provisioning network

**Symptom**: Ironic DHCP works but some VMs get IPs from the wrong server.

**Cause**: Another DHCP server is responding on `br-provision`.

```bash
sudo ss -lnup | grep :67    # check what's listening on DHCP port
ps aux | grep dnsmasq
```

Kill any unexpected DHCP server, or change `PROVISION_CIDR` in `.env`.

---

### Provisioning bridge missing after reboot

**Symptom**: `ip link show br-provision` fails after rebooting.

**Fix**: The bridge is persisted via systemd-networkd drop-ins written by `create-bridges.sh`. Check:

```bash
ls /etc/systemd/network/ | grep br-provision
sudo systemctl restart systemd-networkd
```

If the files are missing, re-run `create-bridges.sh` — it is idempotent.

---

### VMs cannot pull container images after provisioning

**Symptom**: Pods on the bare metal node stuck in `ImagePullBackOff`. Error mentions DNS resolution timeout or connection refused to `ghcr.io`, `docker.io`, etc.

**Cause**: The NAT masquerade rule is targeting the wrong outbound interface, so traffic from the provisioning subnet (`172.22.0.0/24`) never reaches the internet.

**Diagnosis**:

```bash
# Check your actual default route interface
ip route show default
# Example: default via 192.168.50.1 dev enp197s0

# Verify the MASQUERADE rule targets that interface
sudo iptables -t nat -L POSTROUTING -n | grep 172.22
```

**Fix**: If the interface in the MASQUERADE rule doesn't match your default route interface, correct it:

```bash
# Replace OLD_IFACE and NEW_IFACE with actual values
sudo iptables -t nat -D POSTROUTING -s 172.22.0.0/24 ! -d 172.22.0.0/24 -o OLD_IFACE -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 172.22.0.0/24 ! -d 172.22.0.0/24 -o NEW_IFACE -j MASQUERADE
sudo iptables -D FORWARD -i br-provision -o OLD_IFACE -j ACCEPT
sudo iptables -D FORWARD -i OLD_IFACE -o br-provision -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -I FORWARD 1 -i br-provision -o NEW_IFACE -j ACCEPT
sudo iptables -I FORWARD 2 -i NEW_IFACE -o br-provision -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo netfilter-persistent save
```

Then update `LAN_INTERFACE` in your `.env` to the correct value so `create-bridges.sh` is right on the next run.

---

## Platform / Gateway

### `vcluster platform login` refuses `http://vcp.vdemo.local`

**Symptom**:

```text
fatal cannot log into a non https vcluster platform instance 'http://vcp.vdemo.local'
```

**Cause**: The vcluster CLI requires HTTPS for Platform logins, even when you pass `--insecure`. `--insecure` skips certificate verification; it does not allow plain HTTP.

**Fix**: Re-run `bash scripts/install-vcluster.sh` so the Gateway has the wildcard TLS certificate and HTTPS listener, then log in with:

```bash
vcluster platform login https://vcp.vdemo.local --insecure
```

If the rest of Platform is already healthy and you only need the HTTPS patch, apply just
the Gateway resources:

```bash
source .env
KC="sudo KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml kubectl"

sed "s|VDEMO_DOMAIN_PLACEHOLDER|${VDEMO_DOMAIN}|g" manifests/gateway/tls-wildcard.yaml \
  | ${KC} apply -f -

${KC} -n traefik wait --for=condition=Ready certificate/vdemo-wildcard-cert --timeout=180s

for manifest in \
  manifests/gateway/gatewayclass.yaml \
  manifests/gateway/gateway.yaml \
  manifests/gateway/httproute-http-redirect.yaml \
  manifests/gateway/httproute-vcp.yaml
do
  sed "s|VDEMO_DOMAIN_PLACEHOLDER|${VDEMO_DOMAIN}|g" "${manifest}" | ${KC} apply -f -
done
```

If that still fails, check that the certificate and Gateway are ready:

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml
kubectl -n traefik get certificate vdemo-wildcard-cert
kubectl -n traefik get gateway demo-gateway
kubectl -n traefik get httproute
```

Browsers will also warn until you trust the self-signed cert locally.

---

### Private Node agent fails with `lookup vcp.vdemo.local ... no such host`

**Symptom**: The connected-cluster or Private Node agent fails with messages like:

```text
lookup vcp.vdemo.local on 10.x.x.x:53: no such host
failed to check derp connection
```

**Cause**: The provisioned node is using a public DNS server that does not know
the local demo zone (`*.vdemo.local`). DERP relays do not help here because the
agent cannot reach the platform URL in the first place.

**Fix**: Re-run `bash scripts/install-dnsmasq.sh` after the provisioning bridge
exists so dnsmasq listens on `PROVISION_IP` (default `172.22.0.1`), then make
sure generated BareMetalHosts use that resolver:

```bash
dig +short vcp.vdemo.local @172.22.0.1

# Optional override if you need a different resolver list
export PROVISION_DNS_SERVERS=172.22.0.1
bash hack/generate-bmh.sh | kubectl apply -f -
```

If `vcp.vdemo.local` resolves but public registries such as `ghcr.io` do not,
the host's dnsmasq upstream resolvers are likely wrong for your LAN. Check the
uplink DNS and pin it if needed:

```bash
resolvectl dns <LAN_INTERFACE>
echo 'UPSTREAM_DNS_SERVERS=192.168.50.1' >> .env
bash scripts/install-dnsmasq.sh
dig +short ghcr.io @172.22.0.1
```

If `vcp.vdemo.local` resolves but `resolvectl query ghcr.io` on the worker says
`No appropriate name servers or networks for name found`, the worker's
`systemd-resolved` link likely has a route-only `~vdemo.local` domain but is no
longer marked as the default DNS route for public names. Restore both settings:

```bash
iface=$(ip route show default 0.0.0.0/0 | awk 'NR==1 {print $5}')
sudo resolvectl domain "${iface}" '~vdemo.local'
sudo resolvectl default-route "${iface}" yes
resolvectl query ghcr.io
```

If the node was already provisioned with the wrong DNS settings, reprovision it
so the updated annotation is applied to the installed OS.

---

## Redfish / Sushy Tools

### BareMetalHost registration error — SSL handshake failure

**Symptom**: BareMetalHost goes to error state immediately after registration with an SSL or certificate error.

**Cause**: The BMC address uses `redfish://` which forces HTTPS, but sushy-tools serves plain HTTP.

**Fix**: Use `redfish+http://` instead:

```text
# Correct — plain HTTP
redfish+http://172.22.0.1:8000/redfish/v1/Systems/<UUID>

# Wrong — forces HTTPS
redfish://172.22.0.1:8000/redfish/v1/Systems/<UUID>
```

`hack/generate-bmh.sh` uses `redfish+http://` automatically.

---

### Redfish address format for BareMetalHost

The `spec.bmc.address` must include the full Redfish path with the VM UUID:

```text
# Correct
redfish+http://172.22.0.1:8000/redfish/v1/Systems/a1b2c3d4-...

# Wrong — missing UUID path
redfish+http://172.22.0.1:8000
```

Get the UUID:

```bash
sudo virsh domuuid vmetal-small-1
# Or check configs/vm-inventory.txt
```

---

### BMC registration fails immediately

**Checks**:

1. Sushy-tools is running and reachable:
   ```bash
   curl http://172.22.0.1:8000/redfish/v1/Systems/
   ```

2. The specific VM UUID is in the Systems list:
   ```bash
   UUID=$(sudo virsh domuuid vmetal-small-1)
   curl http://172.22.0.1:8000/redfish/v1/Systems/${UUID}/
   ```

3. BMC credentials match the Secret:
   ```bash
   kubectl -n metal3-system get secret vmetal-small-1-bmc-creds -o jsonpath='{.data.username}' | base64 -d
   ```

4. `disableCertificateVerification: true` is set in the BareMetalHost spec.

---

## Metal3 / NodeProvider

### NodeProvider DeployResourcesFailed — cert-manager CRDs missing

**Symptom**: NodeProvider shows `DeployResourcesFailed`; Metal3 Helm install logs show errors about missing `Certificate` or `Issuer` CRDs.

**Cause**: Metal3 requires cert-manager CRDs. They must be installed before the NodeProvider deploys Metal3.

**Fix**: Install cert-manager:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version v1.16.2 \
  --set crds.enabled=true
```

`configs/vcluster.yaml` includes cert-manager so it is installed automatically with `install-vcluster.sh`.

---

### dhcp-proxy Pod stuck in `ContainerCreating` — "failed to find plugin 'static'"

**Symptom**: `kubectl describe pod dhcp-proxy-0 -n metal3-system` shows:
```
failed to create pod sandbox: ... failed to find plugin "static" in path [/opt/cni/bin]
```

**Cause**: Multus requires the `static` CNI plugin from the containernetworking/plugins bundle. Ubuntu's default CNI install does not include it.

**Fix**: Install the full CNI plugins bundle (done automatically by `bootstrap-host.sh`):

```bash
CNI_PLUGINS_VERSION=v1.4.0
sudo mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" \
  | sudo tar xz -C /opt/cni/bin
```

---

## BareMetalHost does not progress past `registering`

**Symptom**: BareMetalHost stuck in `registering`.

**Checks**:

- Metal3/Ironic may not be fully deployed yet. Check NodeProvider status:
  ```bash
  kubectl get nodeprovider metal3-provider
  kubectl get pods -n metal3-system
  ```
- Ironic may not be able to reach the Redfish endpoint. Verify sushy-tools is running and reachable from within the cluster.

---

## BareMetalHost inspection fails

**Symptom**: Host reaches `inspecting` then goes to error.

**Checks**:

- VM NIC is connected to `br-provision`:
  ```bash
  sudo virsh domiflist vmetal-small-1
  ```

- `bootMACAddress` in the BareMetalHost matches the VM NIC MAC exactly:
  ```bash
  sudo virsh domiflist vmetal-small-1 | awk '/br-provision/ {print $5}'
  ```

- Confirm Ironic DHCP is running and attached to the provisioning bridge. Check NodeProvider events and Ironic pod logs:
  ```bash
  kubectl logs -n metal3-system -l app=ironic -c ironic --tail=50
  ```

---

### DHCP proxy refusing to respond — missing IP annotation

**Symptom**: Ironic inspection starts (VM boots IPA ramdisk) but the VM never gets an IP and times out. Logs show:
```
missing metal3.vcluster.com/ip-address annotation
```

**Cause**: The vCP DHCP proxy does static IP assignment based on the `metal3.vcluster.com/ip-address` annotation on the BareMetalHost. Without it, DHCP requests are dropped.

**Fix**: Ensure `hack/generate-bmh.sh` is used to generate BareMetalHost manifests — it adds all required annotations automatically:

```yaml
annotations:
  metal3.vcluster.com/ip-address: "172.22.0.11/24"
  metal3.vcluster.com/gateway: "172.22.0.1"
  metal3.vcluster.com/dns-servers: "172.22.0.1"
```

---

## BareMetalHost provisioning fails — no suitable device

**Symptom**: BareMetalHost stuck in `provisioning error`:
```
No suitable device found for hints {'name': '== /dev/sda'}
```

**Cause**: KVM/QEMU VMs use virtio block devices (`/dev/vda`), but Metal3 defaults to looking for `/dev/sda`.

**Fix**: Set `rootDeviceHints` in the BareMetalHost spec:

```yaml
spec:
  rootDeviceHints:
    deviceName: /dev/vda
```

`hack/generate-bmh.sh` sets this automatically.

To patch an existing BareMetalHost:

```bash
kubectl patch bmh vmetal-small-1 -n metal3-system \
  --type merge -p '{"spec":{"rootDeviceHints":{"deviceName":"/dev/vda"}}}'
```

---

## IPA ramdisk cannot reach OS image URL — DNS resolution failure

**Symptom**: BareMetalHost stuck in `provisioning error`:
```
NameResolutionError: Failed to resolve 'cloud-images.ubuntu.com' ([Errno -2] Name or service not known)
```

**Cause**: The IPA ramdisk running inside the provisioning VM is isolated on the provisioning bridge (`172.22.0.0/24`) with no DNS or internet access. It cannot reach external URLs.

**Fix**: Serve the OS image locally on `172.22.0.1:9000` using `cache-os-image.sh`:

```bash
bash scripts/cache-os-image.sh
kubectl apply -f manifests/platform/os-image.yaml   # updates URL to http://172.22.0.1:9000/...
```

Then re-trigger provisioning by deleting the failed NodeClaim (vCP will recreate it):

```bash
kubectl get nodeclaims -A   # find the NodeClaim name and namespace
kubectl delete nodeclaim <name> -n <namespace>
```

---

## Group membership requiring re-login

After `bootstrap-host.sh` adds your user to `libvirt` and `kvm`, the change does not take effect in the current shell:

```bash
newgrp libvirt   # or log out and back in
id | grep libvirt
```

Scripts that call `virsh` or `virt-install` without `sudo` will fail until the group membership is active.
