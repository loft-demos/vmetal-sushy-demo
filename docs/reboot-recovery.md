# Host Reboot Recovery

Short runbook for the most common "host rebooted and `https://vcp.vdemo.local`
is gone" failure chain on the MINISFORUM demo host.

Use this in order. Each step narrows the next one.

---

## 1. Verify the host-side bridge and DNS

On the Ubuntu host:

```bash
ip route show default
ip -4 addr show enp197s0
ip addr show br-provision
sudo systemctl status dnsmasq --no-pager
```

Healthy state:

- `enp197s0` has the expected LAN IP from `.env`
- `br-provision` exists and shows `172.22.0.1/24`
- `dnsmasq` is `active (running)`

If `br-provision` exists but has no `172.22.0.1/24`, recover it first:

```bash
bash scripts/create-bridges.sh
sudo systemctl restart dnsmasq
```

If you need an immediate one-shot repair before rerunning the script:

```bash
sudo ip addr add 172.22.0.1/24 dev br-provision
sudo ip link set br-provision up
sudo systemctl restart dnsmasq
```

Then verify DNS directly:

```bash
dig +short vcp.vdemo.local @192.168.50.61
dig +short vcp.vdemo.local @172.22.0.1
```

Both should return `192.168.50.200`.

---

## 2. Check whether ingress is alive by IP

On the Ubuntu host:

```bash
curl -k -I https://192.168.50.200
```

Interpretation:

- If this returns HTTP headers, Platform ingress is up and only hostname
  resolution is left to fix on the client.
- If this fails to connect, continue with the cluster checks below.

---

## 3. Check the cluster ingress path

```bash
export KUBECONFIG=/var/lib/vcluster/kubeconfig.yaml

kubectl get nodes
kubectl -n metallb-system get pods
kubectl -n traefik get pods,svc,endpoints -o wide
kubectl -n vcluster-platform get pods -o wide
kubectl get pods -A | rg 'metallb|traefik|multus|metal3|loft|private-nodes'
```

Healthy state:

- `metallb-controller` and `metallb-speaker` are `Running`
- `traefik` is `Running`
- `service/traefik` still owns `192.168.50.200`
- `endpoints/traefik` is not empty
- the `loft` pod is `Running`

If old pods are stuck in `Unknown`, force-delete them after the underlying CNI
problem is fixed:

```bash
kubectl delete pod -n traefik -l app.kubernetes.io/name=traefik --force --grace-period=0
kubectl delete pod -n metallb-system -l component=controller --force --grace-period=0
kubectl delete pod -n vcluster-platform -l app=loft --force --grace-period=0
kubectl delete pod -n metal3-system -l app=multus --force --grace-period=0
```

---

## 4. Recover Multus and Metal3 if pod sandboxes are timing out

Typical symptom in `journalctl -u kubelet`:

```text
plugin type="multus-shim" name="multus-cni-network" failed (add): CmdAdd (shim): timed out waiting for the condition
```

First, make sure the host still has the required CNI binaries:

```bash
sudo ls -1 /opt/cni/bin
sudo ls -1 /etc/cni/net.d
```

If `/opt/cni/bin` is missing or does not contain `static`, reinstall the CNI
plugin bundle:

```bash
CNI_PLUGINS_VERSION=v1.4.0
sudo mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" \
  | sudo tar xz -C /opt/cni/bin
```

If `kube-multus-ds-*` is stuck in `Init:Error` even though `multus-shim` and
`passthru` already exist on the host, patch the init container to skip the copy
when the host binaries are already installed:

```bash
kubectl patch ds kube-multus-ds -n metal3-system --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/initContainers/0/command","value":["sh","-c","test -x /host/opt/cni/bin/multus-shim && test -x /host/opt/cni/bin/passthru && exit 0; cp /usr/src/multus-cni/bin/multus-shim /host/opt/cni/bin/multus-shim && cp /usr/src/multus-cni/bin/passthru /host/opt/cni/bin/passthru"]}]'
```

If kubelet and containerd are already wedged from repeated sandbox failures:

```bash
sudo systemctl stop kubelet
sudo systemctl restart containerd
sudo systemctl start kubelet
```

Then recreate the affected pods:

```bash
kubectl delete pod -n metal3-system -l app=multus --force --grace-period=0
kubectl delete pod -n metal3-system dhcp-proxy-0 --force --grace-period=0
kubectl delete pod -n metal3-system metal3-0 --force --grace-period=0
kubectl delete pod -n metallb-system -l component=controller --force --grace-period=0
kubectl delete pod -n traefik -l app.kubernetes.io/name=traefik --force --grace-period=0
kubectl delete pod -n vcluster-platform -l app=loft --force --grace-period=0
```

Watch until these are healthy again:

```bash
kubectl get pods -A | rg 'metallb|traefik|multus|metal3|loft|private-nodes'
kubectl -n traefik get endpoints traefik
```

---

## 5. Recheck the client side

From your Mac:

```bash
bash hack/setup-mac-dns.sh status
dig +short vcp.vdemo.local
curl -k -I https://vcp.vdemo.local
```

If the resolver is stale, refresh it:

```bash
bash hack/setup-mac-dns.sh lan
```

---

## Expected end state

At the end of recovery, these should all work:

```bash
dig +short vcp.vdemo.local
curl -k -I https://192.168.50.200
curl -k -I https://vcp.vdemo.local
kubectl -n traefik get endpoints traefik
kubectl -n vcluster-platform get pods
```
