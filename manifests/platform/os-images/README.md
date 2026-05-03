# Additional OSImages

Generated `OSImage` manifests live here.

Examples:

```bash
# Default demo image: Ubuntu 24.04 minimal
bash scripts/cache-os-image.sh
kubectl apply -f manifests/platform/os-images/ubuntu-noble.yaml

# Full Ubuntu server cloud image, cached locally and exposed to Metal3
bash scripts/cache-os-image.sh ubuntu-server
kubectl apply -f manifests/platform/os-images/ubuntu-noble-server.yaml

# Custom image with extra packages baked in
sudo apt-get install -y libguestfs-tools
bash scripts/build-custom-os-image.sh \
  --name ubuntu-noble-observability \
  --display-name "Ubuntu 24.04 LTS (Observability Tools)" \
  --packages qemu-guest-agent,curl,jq,nfs-common
kubectl apply -f manifests/platform/os-images/ubuntu-noble-observability.yaml

# Bootstrap-ready worker image
# Bakes in the packages currently installed by NodeProvider user-data so first
# boot does less package work. If you use this image successfully, you can
# remove ca-certificates, curl, and htop from the NodeProvider cloud-init.
bash scripts/build-custom-os-image.sh \
  --base-preset ubuntu-server \
  --name ubuntu-noble-bootstrap \
  --display-name "Ubuntu 24.04 LTS (Bootstrap Ready)" \
  --force-ipv4 \
  --packages ca-certificates,curl,htop
kubectl apply -f manifests/platform/os-images/ubuntu-noble-bootstrap.yaml

# Slurm-oriented non-Kubernetes compute image
# This represents a non-Kubernetes compute persona, for example a machine
# intended for Slurm-managed workloads rather than a vCluster worker node.
# The Slurm packages are installed on first boot rather than during image
# customization because libguestfs networking can be unreliable on some hosts.
bash scripts/build-custom-os-image.sh \
  --base-preset ubuntu-server \
  --name ubuntu-noble-slurm-compute \
  --display-name "Ubuntu 24.04 LTS (Slurm Compute Node)" \
  --force-ipv4 \
  --enable-universe \
  --firstboot-install qemu-guest-agent,curl,jq,nfs-common,munge,slurmd,htop
kubectl apply -f manifests/platform/os-images/ubuntu-noble-slurm-compute.yaml
```

To use a different image for new machines, update the top-level `properties` block in `manifests/platform/node-provider.yaml`:

```yaml
properties:
  vcluster.com/os-image: ubuntu-noble-server
```

That `NodeProvider` mapping is the Kubernetes-worker path in this repo. For images like `ubuntu-noble-slurm-compute`, it is also fine to stop at creating and showing the `OSImage` itself when the goal is to represent a non-Kubernetes compute persona rather than a vCluster worker node.

For the worker-node path, `ubuntu-noble-bootstrap` is the image intended to replace the current cloud-init package installs (`ca-certificates`, `curl`, `htop`) in `manifests/platform/node-provider.yaml`.
