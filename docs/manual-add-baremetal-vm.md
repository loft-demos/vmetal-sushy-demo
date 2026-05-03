# Manual CLI Runbook: Add and Remove One Bare Metal VM

This guide shows the fully manual path for adding one extra libvirt VM to the demo and registering it as a bare metal machine for vMetal/Metal3.

It intentionally does not use:

- `scripts/create-vms.sh`
- `hack/generate-bmh.sh`

Use this when you want a deterministic, CLI-only demo of "one more server was added to the pool" and you also want a clean teardown path afterward.

## Assumptions

This runbook assumes the base demo is already installed and healthy:

- `br-provision` exists on the host
- `sushy-tools` is running and reachable on `http://172.22.0.1:8000`
- the `metal3-provider` `NodeProvider` is `Ready`
- the Ubuntu image is cached locally and `manifests/platform/os-image.yaml` has
already been applied

If you need the full environment setup, follow the main flow in `README.md` through Step 8 first.

Start by pointing `kubectl` at the platform cluster:

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml
```

If you are adding this support to an already-running demo, re-apply the updated NodeProvider and template first so the medium-capacity rack-aware classes exist:

```bash
kubectl apply -f manifests/platform/node-provider.yaml
kubectl apply -f manifests/platform/vmetal-template.yaml
kubectl get nodeprovider metal3-provider -w
```

Quick health checks:

```bash
kubectl get nodeprovider metal3-provider
kubectl get nodetype
kubectl -n metal3-system get pods
curl http://172.22.0.1:8000/redfish/v1/Systems/ | jq .
```

## 1. Pick the VM name, size, MAC, and provisioning IP

Example below: add one dedicated `medium` machine to the rack-aware inventory. In this repo, `medium` is also the cleanest place to demonstrate UEFI-backed virtual bare metal without changing the default small/large flows.

```bash
export VM_NAME=vmetal-medium-1
export VM_PROFILE=medium
export VM_RACK=rack-b
export VM_VCPUS=3
export VM_RAM_MB=6144
export VM_DISK_GB=60
export VM_MAC=52:54:00:dd:00:00
export VM_IP=172.22.0.19

export VM_IMAGE_DIR=/var/lib/libvirt/images
export VM_DISK_PATH="${VM_IMAGE_DIR}/${VM_NAME}.qcow2"

export PROVISION_BRIDGE=br-provision
export PROVISION_IP=172.22.0.1
export PROVISION_GATEWAY=172.22.0.1
export PROVISION_DNS=172.22.0.1
export SUSHY_PORT=8000

export BMC_USERNAME=admin
export BMC_PASSWORD=password
export OVMF_CODE_PATH=/usr/share/OVMF/OVMF_CODE.secboot.fd
export OVMF_VARS_PATH=/usr/share/OVMF/OVMF_VARS.fd
```

Notes:

- The stock demo already uses `172.22.0.11` through `172.22.0.18`.
- `172.22.0.1` is the host bridge IP and `172.22.0.2` is the DHCP VIP.
- `172.22.0.19+` is a safe place to start for manually added hosts.
- The physical labels must match one of the pool selectors in
`manifests/platform/node-provider-customer-topology.yaml`.
- The recommended model is `topology.vcluster.com/*` for placement and
`inventory.vcluster.com/*` for hardware shape.
- For a large node, use `VM_PROFILE=large` and the matching large VM sizing.

## 2. Create the VM disk and define the libvirt VM

Make sure the name is not already in use:

```bash
if sudo virsh dominfo "${VM_NAME}" >/dev/null 2>&1; then
  echo "Domain already exists: ${VM_NAME}"
fi
```

If that prints `Domain already exists`, pick a different `VM_NAME` or clean up the old one first.

Create the disk:

```bash
sudo mkdir -p "${VM_IMAGE_DIR}"
sudo qemu-img create -f qcow2 "${VM_DISK_PATH}" "${VM_DISK_GB}G"
```

Define the VM:

```bash
sudo virt-install \
  --name "${VM_NAME}" \
  --vcpus "${VM_VCPUS}" \
  --memory "${VM_RAM_MB}" \
  --disk "path=${VM_DISK_PATH},format=qcow2,bus=virtio" \
  --network "bridge:${PROVISION_BRIDGE},model=virtio,mac=${VM_MAC}" \
  --boot "network,hd,menu=off,loader=${OVMF_CODE_PATH},loader.readonly=yes,loader.type=pflash,loader.secure=no,nvram.template=${OVMF_VARS_PATH}" \
  --os-variant "ubuntu24.04" \
  --graphics "none" \
  --console "pty,target_type=serial" \
  --noautoconsole \
  --import \
  --noreboot
```

Why these flags matter:

- `--boot network,hd` makes PXE happen first so Ironic can provision the disk
- `loader=...` and `nvram.template=...` make this VM a UEFI guest instead of a BIOS guest
- `bus=virtio` means the disk appears as `/dev/vda` in the guest
- `--noreboot` leaves power control to Metal3/Ironic through Redfish

Verify the domain exists:

```bash
sudo virsh list --all
```

## 3. Get the UUID and verify that Sushy sees the new VM

Fetch the libvirt UUID:

```bash
export VM_UUID="$(sudo virsh domuuid "${VM_NAME}")"
echo "${VM_UUID}"
```

Confirm the provisioning NIC MAC:

```bash
sudo virsh domiflist "${VM_NAME}"
```

Verify the Redfish endpoint for this exact VM:

```bash
curl "http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems/${VM_UUID}/" | jq .
```

If that curl fails, stop here and fix `sushy-tools` before creating Kubernetes resources.

## 4. Create the BMC credentials Secret

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${VM_NAME}-bmc-creds
  namespace: metal3-system
  labels:
    environment.metal3.io: baremetal
type: Opaque
stringData:
  username: ${BMC_USERNAME}
  password: ${BMC_PASSWORD}
EOF
```

Verify:

```bash
kubectl -n metal3-system get secret "${VM_NAME}-bmc-creds"
```

## 5. Create the BareMetalHost manually

For this Sushy/vMetal demo, use the normal Metal3 inspection flow. In testing, forcing `inspect.metal3.io: disabled` caused hosts to get stuck in `preparing`, so it is not the default here.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${VM_NAME}
  namespace: metal3-system
  labels:
    demo: vmetal
    topology.vcluster.com/az: us-va-blacksburg-dc1
    topology.vcluster.com/row: row-1
    topology.vcluster.com/rack: ${VM_RACK}
    inventory.vcluster.com/size: ${VM_PROFILE}
    inventory.vcluster.com/accelerator: cpu-only
  annotations:
    metal3.vcluster.com/ip-address: "${VM_IP}/24"
    metal3.vcluster.com/gateway: "${PROVISION_GATEWAY}"
    metal3.vcluster.com/dns-servers: "${PROVISION_DNS}"
spec:
  online: true
  automatedCleaningMode: metadata
  bmc:
    address: redfish+http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems/${VM_UUID}
    credentialsName: ${VM_NAME}-bmc-creds
    disableCertificateVerification: true
  bootMACAddress: "${VM_MAC}"
  rootDeviceHints:
    deviceName: /dev/vda
EOF
```

#### Add via UI:

- Name: vmetal-medium-1
- BMC Credentials
  - Address: redfish+http://172.22.0.1:8000/redfish/v1/Systems/2b034cba-c55c-4a41-b60b-3662644c53c1
  - Username: admin
  - Password: password
- Boot MAC Address: 52:54:00:dd:00:00
- IP: 172.22.0.19/24
- Gateway: 172.22.0.1
- DNS Servers: 172.22.0.1

After creating the BareMetalHost in the UI, add the rack labels manually. The UI does not currently expose arbitrary BareMetalHost labels, but the `NodeProvider` selectors require them for capacity matching:

```bash
kubectl -n metal3-system label baremetalhost "${VM_NAME}" \
  demo=vmetal \
  topology.vcluster.com/az=us-va-blacksburg-dc1 \
  topology.vcluster.com/row=row-1 \
  topology.vcluster.com/rack="${VM_RACK}" \
  inventory.vcluster.com/size="${VM_PROFILE}" \
  inventory.vcluster.com/accelerator=cpu-only \
  --overwrite
```

The UI path also does not expose `rootDeviceHints`, which this demo needs so Ironic writes the image to the virtio disk presented as `/dev/vda`:

```bash
kubectl -n metal3-system patch baremetalhost "${VM_NAME}" --type merge -p \
  '{"spec":{"rootDeviceHints":{"deviceName":"/dev/vda"}}}'
```

Important details:

- Use `redfish+http://`, not `redfish://`
- The `address` must include the full `/redfish/v1/Systems/<UUID>` path
- The `metal3.vcluster.com/ip-address` annotation is required by the DHCP proxy
- `/dev/vda` is required because these KVM guests use virtio disks

## 6. Watch the host register and become available

```bash
kubectl -n metal3-system get baremetalhost "${VM_NAME}" -w
```

Expected state flow:

- `registering`
- `inspecting`
- `available`

In this environment, a few minutes in `inspecting` is expected. The repo's baseline demo notes that hosts can take around 5 minutes to reach `available`.

If you already created the host with `inspect.metal3.io: disabled` and it is stuck in `preparing`, delete and recreate just the `BareMetalHost` without that annotation:

```bash
kubectl patch bmh "${VM_NAME}" -n metal3-system \
  --type merge -p '{"spec":{"automatedCleaningMode":"disabled","online":false}}'
kubectl delete baremetalhost "${VM_NAME}" -n metal3-system
# wait for deletion to finish, then re-apply the BareMetalHost manifest above
```

The VM and BMC Secret can stay in place.

Helpful spot checks:

```bash
kubectl -n metal3-system describe baremetalhost "${VM_NAME}"
kubectl logs -n metal3-system -l app=metal3 -c ironic --tail=50
```

## 7. Optional: demo firmware settings through Metal3

Once the host is `available`, Metal3 should create a matching `HostFirmwareSettings` and `FirmwareSchema` resource for it. This is the cleanest moment to demonstrate firmware management because the host is not yet claimed by any workload.

Inspect the firmware resources:

```bash
kubectl get hostfirmwaresettings "${VM_NAME}" -n metal3-system -o yaml
kubectl get firmwareschema schema-f229959d -n metal3-system -o yaml
```

In this emulator-backed environment, `ProcTurboMode` is the most compelling CPU-adjacent writable setting for a live demo. It is not a GPU-specific BIOS option, but it demonstrates the same workflow you would use on real hardware for settings such as SR-IOV or other vendor-specific firmware knobs when the BMC exposes them.

Recommended live demo change:

```bash
kubectl patch hostfirmwaresettings "${VM_NAME}" -n metal3-system --type merge -p '
spec:
  settings:
    ProcTurboMode: Disabled
'
```

Watch the change apply:

```bash
kubectl get hostfirmwaresettings "${VM_NAME}" -n metal3-system -w
kubectl get baremetalhost "${VM_NAME}" -n metal3-system -w
```

Expected behavior:

- `ChangeDetected` flips while Metal3/Ironic applies the requested setting
- the host may move through a short `preparing` cycle and reboot
- `status.settings.ProcTurboMode` eventually updates to `Disabled`

Confirm the result from both Kubernetes and Redfish:

```bash
kubectl get hostfirmwaresettings "${VM_NAME}" -n metal3-system -o yaml
curl "http://${PROVISION_IP}:${SUSHY_PORT}/redfish/v1/Systems/${VM_UUID}/BIOS" | jq .
```

Safe fallback:

```bash
kubectl patch hostfirmwaresettings "${VM_NAME}" -n metal3-system --type merge -p '
spec:
  settings:
    QuietBoot: false
'
```

Use `QuietBoot` if you want a lower-risk firmware change that is less likely to interfere with boot behavior. Avoid using `BootMode` live unless you are comfortable risking a failed reprovisioning cycle, and avoid `NumCores` or `SecureBootStatus` because they are marked read-only in this schema.

## 8. Have vCluster Platform claim and provision it

Once the host is `available`, it is ready for any matching `NodeClaim`.

In this repo:

- `topology.vcluster.com/rack: rack-a` and `topology.vcluster.com/rack: rack-b` place hosts into the two simulated racks
- `inventory.vcluster.com/size: small|medium|large` places hosts into the intended size class
- the dedicated medium-capacity path is a good fit for a UEFI-focused demo host

The important behavior is:

- adding the `BareMetalHost` makes the machine available to the pool
- actual provisioning starts only when vCluster Platform needs a matching node

For the most repeatable CLI demo, add the host first, wait for `available`, and then create or recreate a vCluster that can consume a medium-capacity host:

```bash
kubectl apply -f manifests/platform/vmetal-static-template.yaml

cat <<EOF | kubectl apply -f -
apiVersion: management.loft.sh/v1
kind: VirtualClusterInstance
metadata:
  name: static-medium-tenant
  namespace: p-default
spec:
  owner:
    user: admin
  templateRef:
    name: vmetal-static-template
  clusterRef:
    cluster: loft-cluster
  parameters: |
    kubernetesVersion: v1.34.7
    smallNodeCount: "0"
    mediumNodeCount: "1"
    largeNodeCount: "0"
    rackSelector: ""
EOF
```

Watch the claim and provisioning flow:

```bash
kubectl get nodeclaims -A -w
kubectl -n metal3-system get baremetalhost "${VM_NAME}" -w
```

Expected host state flow after claim:

- `available`
- `provisioning`
- `provisioned`

Note:

- If other `available` hosts already match the same selector, vCluster Platform
may claim one of those instead of this new VM.
- If you need this exact VM to be the one that gets claimed in a demo, make it
the only `available` host with that label set before recreating the vCluster.

## 9. Cleanup the VM and Kubernetes resources

If this VM never moved past `available`, you can skip straight to deleting the `BareMetalHost`, Secret, and libvirt VM.

### If the VM was claimed by a NodeClaim

For the dedicated `medium` demo vCluster from the previous step, the cleanest repeatable reset is:

```bash
kubectl delete virtualclusterinstance static-medium-tenant -n p-default
kubectl get nodeclaims -A -w
```

Wait until the claim is gone and the host is no longer in use before deleting the `BareMetalHost`.

### Delete the Secret and BareMetalHost

```bash
kubectl delete baremetalhost "${VM_NAME}" -n metal3-system
kubectl delete secret "${VM_NAME}-bmc-creds" -n metal3-system
```

Verify:

```bash
kubectl -n metal3-system get baremetalhost
kubectl -n metal3-system get secret
```

### Remove the libvirt VM and disk

```bash
sudo virsh destroy "${VM_NAME}" 2>/dev/null || true
sudo virsh undefine "${VM_NAME}" --nvram 2>/dev/null || sudo virsh undefine "${VM_NAME}"
sudo rm -f "${VM_DISK_PATH}"
```

Verify:

```bash
sudo virsh list --all
test ! -f "${VM_DISK_PATH}" && echo "disk removed"
```

## Repeatability notes

- Reuse the same `VM_NAME`, `VM_MAC`, and `VM_IP` each time if you want a stable
demo story.
- Finish the cleanup before reusing the same name, MAC, or provisioning IP.
- Do not add this VM to `configs/vm-inventory.txt` unless you later want
`hack/generate-bmh.sh` to manage it too.
- If you want a full environment reset, use `docs/local-instructions.md` and
`scripts/reset-demo.sh`.
