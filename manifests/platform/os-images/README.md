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
```

To use a different image for new machines, update the target node type in
`manifests/platform/node-provider.yaml`:

```yaml
properties:
  vcluster.com/os-image: ubuntu-noble-server
```
