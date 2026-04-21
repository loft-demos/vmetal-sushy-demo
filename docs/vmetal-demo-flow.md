# vMetal Demo Flow

This runbook adapts the existing `vmetal-sushy-demo` repo for a vMetal demo conversation. The goal is not to fake a GPU demo. The goal is to show that vMetal + vCluster can rationalize control planes, provide self-service private clusters, and make machine lifecycle operations more automated while leaving room for non-Kubernetes consumers later.

## Demo Thesis

Lead with this:

> "What we want to prove today is that cluster lifecycle and machine lifecycle
> can be separated cleanly. vCluster gives each research team its own control
> plane, while vMetal gives the platform team a common way to provision and
> operate the underlying machines. Even without real GPUs in this environment,
> we can show the control-plane and hardware-lifecycle model that addresses the
> operational bottlenecks you described."

## What To Show Live vs. What To Position

### Show live

- Platform-managed vMetal lifecycle: `NodeProvider` -> `OSImage` ->
  `BareMetalHost` -> `NodeClaim` -> vCluster worker
- vMetal + vCluster integration for self-service private clusters
- Cloud-init and image lifecycle knobs in `manifests/platform/node-provider.yaml`
  and `manifests/platform/os-image.yaml`
- Day 2 operation: upgrade the vCluster control plane by changing a template
  parameter
- CPU-only stand-in for a long-running quant/research workload using
  [manifests/demo/quant-research-burst.yaml](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/manifests/demo/quant-research-burst.yaml)

### Position carefully, do not overclaim

- Real GPU utilization improvements
- Cross-scheduler "metascaler" across Kubernetes, Slurm, and Condor
- Full Proxmox replacement story via KubeVirt
- Provisioning a production Slurm node end-to-end from this repo alone

Use language like:

> "We can show the machine inventory and lifecycle layer today. The exact
> scheduler arbitration across Kubernetes and Slurm is a next-level integration
> conversation rather than something we should pretend is solved in this demo."

## Recommended Narrative

Map the story to pain directly:

1. They already solved Day 0 reasonably well.
2. Day 2 lifecycle and fleet operations are now the bottleneck.
3. Dedicated hardware for per-team control planes is expensive and unnecessary.
4. GPUs are the scarce resource, but the operational pattern starts one layer
   lower with machine allocation, images, and tenancy boundaries.

Then frame the demo:

1. vCluster reduces the control-plane footprint for each team.
2. vMetal makes machine provisioning and lifecycle a platform service.
3. The combination gives self-service without forcing every team to inherit the
   same Day 2 operational burden.

## Environment Staging

For a prospect demo, do not start from a blank Ubuntu host live. Pre-stage up
through Platform installation and keep the "bootstrap" part as a short narrated
walkthrough.

### Pre-stage before the call

Run or verify:

```bash
bash scripts/create-bridges.sh
bash scripts/create-vms.sh
bash scripts/install-sushy-service.sh
bash scripts/install-dnsmasq.sh
bash scripts/install-vcluster.sh
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml
kubectl get nodes
kubectl -n vcluster-platform get pods
```

Also pre-generate the baseline Ubuntu image and one alternate image:

```bash
bash scripts/cache-os-image.sh
bash scripts/cache-os-image.sh ubuntu-server
```

If you want a stronger cloud-init/image story, pre-build a role-specific image:

```bash
sudo apt-get install -y libguestfs-tools
bash scripts/build-custom-os-image.sh \
  --name ubuntu-noble-research \
  --display-name "Ubuntu 24.04 LTS (Research Tools)" \
  --packages qemu-guest-agent,curl,jq,nfs-common
```

### Best starting state for the live portion

Have these ready before the meeting:

- Platform UI reachable at `https://vcp.vdemo.local`
- `metal3-provider` not yet applied, or applied and healthy depending on how
  much waiting you want to do live
- `OSImage` manifests available locally
- `configs/vm-inventory.txt` present
- one extra unused VM available if you want to show "adding capacity"

## Demo Flow

This is the recommended 25-30 minute path.

### 1. Open with the problem statement

Say:

> "You told us Day 0 isn't really the issue anymore. The issue is operating lots
> of cluster and machine life-cycles cleanly, without dedicating physical control
> plane hardware per environment."

Show:

- the architecture section in [README.md](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/README.md)
- the two template options in
  [docs/design-notes.md](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/docs/design-notes.md)

### 2. Narrate bootstrap briefly, do not dwell on it

Say:

> "This environment uses libvirt VMs and Sushy Tools as stand-ins for physical
> servers, but the control-plane workflow we're demoing is the same one you'd
> use with real Redfish-managed hardware."

Show quickly:

- `scripts/create-vms.sh`
- `scripts/start-sushy-tools.sh`
- `curl http://172.22.0.1:8000/redfish/v1/Systems/ | jq .`

This establishes the emulated hardware layer without spending the meeting on setup.

### 3. Show the machine-management layer first

Apply or inspect:

```bash
kubectl apply -f manifests/platform/os-image.yaml
kubectl apply -f manifests/platform/node-provider.yaml
kubectl get osimage
kubectl get nodeprovider metal3-provider -w
```

Talk track:

- "This is the key Day 2 separation: the platform defines machine classes,
  images, and bootstrap behavior once."
- "Teams consume templates; they don't each own their own Metal3/Ironic stack."
- "That is where dedicated control-plane hardware starts to become unnecessary:
  the tenant control plane is lightweight, and the machine lifecycle is shared."

Open:

- [manifests/platform/node-provider.yaml](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/manifests/platform/node-provider.yaml)
- [manifests/platform/os-image.yaml](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/manifests/platform/os-image.yaml)

Call out specifically:

- `vcluster.com/user-data` for cloud-init style customization
- per-node-type image selection through `vcluster.com/os-image`
- multiple node classes: `small-node`, `medium-node`, `large-node`

### 4. Register hardware and show inventory becoming consumable

Apply generated BareMetalHosts or use the manual flow:

```bash
bash hack/generate-bmh.sh | kubectl apply -f -
kubectl -n metal3-system get baremetalhosts -w
```

Talk track:

- "At this point we have machine inventory managed independent of any one team."
- "This is the point in the flow that matters for Slurm or Condor too: the
  platform knows what hardware exists, what image it should receive, and how it
  should be provisioned."

Important honesty point:

Do not say "this is already a metascaler across Kubernetes and Slurm." Say:

> "This is the shared machine lifecycle layer a metascaler would need to sit on
> top of."

### 5. Show self-service vCluster creation on top of that inventory

Use one of the two templates depending on the story you want.

#### Option A: Dynamic pool

Best when you want to emphasize self-service elasticity.

```bash
kubectl apply -f manifests/platform/vmetal-template.yaml
kubectl apply -f manifests/platform/vcluster-vmetal.yaml
kubectl get virtualclusterinstances -n p-default -w
kubectl get nodeclaims -A -w
```

#### Option B: Static mixed pool

Best when you want to mimic reserved AI/HPC capacity.

```bash
kubectl apply -f manifests/platform/vmetal-static-template.yaml
kubectl apply -f manifests/platform/vcluster-vmetal-static.yaml
kubectl get virtualclusterinstances -n p-default -w
kubectl get nodeclaims -A -w
```

Recommended angle:

- Use the static template first because it looks more like reserved
  per-team capacity.
- Then explain that dynamic mode is the path when they want to reclaim more
  shared utilization over time.

### 6. Show a research workload without GPUs

Use the CPU-only stand-in workload:

```bash
vcluster connect vmetal-static-demo -n p-default -- kubectl apply -f manifests/demo/quant-research-burst.yaml
vcluster connect vmetal-static-demo -n p-default -- kubectl get pods -o wide
vcluster connect vmetal-static-demo -n p-default -- kubectl get nodes
```

Talk track:

> "This is standing in for a long-running quant or Ray-style workload. The point
> isn't GPU math performance in this environment. The point is that we can give
> the team an isolated control plane with dedicated worker capacity and lifecycle
> management, without dedicating separate physical control-plane servers."

If you need a stronger angle on over-requesting:

- say that `large-node` is a stand-in for a scarce accelerator class
- explain that the same self-service boundary and machine lifecycle apply even
  when the scarce dimension is GPUs instead of CPUs

### 7. Show Day 2 operations explicitly

Edit the vCluster instance and bump the control-plane version:

```bash
# edit manifests/platform/vcluster-vmetal.yaml or
# manifests/platform/vcluster-vmetal-static.yaml
# change kubernetesVersion from v1.34.1 to v1.35.0
kubectl apply -f manifests/platform/vcluster-vmetal.yaml
# or:
# kubectl apply -f manifests/platform/vcluster-vmetal-static.yaml
kubectl get virtualclusterinstances -n p-default -w
```

Use the actual file change live if you want the audience to see how little
manual work is involved:

- [manifests/platform/vcluster-vmetal.yaml](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/manifests/platform/vcluster-vmetal.yaml)
- [manifests/platform/vcluster-vmetal-static.yaml](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/manifests/platform/vcluster-vmetal-static.yaml)

Talk track:

- "The team control plane is upgraded through a parameter change, not a bespoke
  runbook."
- "The machine lifecycle remains separately governed by the provider."
- "This is the Day 2 operational simplification we wanted to make tangible."

### 8. Close on non-Kubernetes provisioning and future scheduler alignment

Use the manual-add guide as the proof that machines can be brought under
management before they are consumed by any one cluster:

- [docs/manual-add-baremetal-vm.md](/Users/kmadel/Library/Mobile%20Documents/com~apple~CloudDocs/projects/loft-demos/vmetal-sushy-demo/docs/manual-add-baremetal-vm.md)

Say:

> "Today we're consuming these machines from a vCluster because that lets us
> show the full private-cluster path. But the hardware registration, image
> handling, and cloud-init behavior are not conceptually limited to Kubernetes as
> the final consumer."

Then pause and be precise:

> "What we are not showing today is a live Slurm handoff or a live Condor
> arbitration loop. If that's the most important next step, we should treat that
> as a follow-on design session."

## Suggested Objection Handling

### "You don't have GPUs here."

Answer:

> "Correct. We're not trying to claim GPU benchmarking or MIG-style partitioning
> from this setup. We're showing the lifecycle model around scarce nodes, tenant
> isolation, and Day 2 operations. In your environment the scarce node class
> would be GPU-backed rather than CPU-only."

### "How is this better than open-source Metal3 plus our own automation?"

Answer:

> "Open source gets you building blocks. What we're focusing on here is the
> integrated operational path around those building blocks: self-service
> templates, tenant-facing cluster creation, shared machine lifecycle
> management, Auto Nodes with Karpenter built into vCluster, and automatic
> worker-node upgrade and replacement behavior as the node pool definition
> changes. The point is not just provisioning hardware once. The point is
> having a cleaner Day 2 operating model on top of it."

### "Can this replace Proxmox?"

Answer:

> "For this demo we're concentrating on the bare-metal and private-cluster
> lifecycle problem, not claiming a full virtualization-platform replacement in
> one step. The KubeVirt path is worth exploring separately if VM consolidation
> is a primary objective."

## Recommended Command Cheat Sheet

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml

kubectl get nodeprovider metal3-provider
kubectl get osimage
kubectl -n metal3-system get baremetalhosts
kubectl get nodeclaims -A
kubectl get virtualclusterinstances -n p-default

curl http://172.22.0.1:8000/redfish/v1/Systems/ | jq .
```

## If Time Is Short

Compress to this sequence:

1. Show `NodeProvider` and `OSImage`
2. Show `BareMetalHost` inventory becoming available
3. Create the static vCluster-backed environment
4. Launch the CPU-only research workload
5. Change Kubernetes version to show Day 2 operations

That keeps the story tight around actual pain: lifecycle, tenancy, and
hardware utilization pressure.
