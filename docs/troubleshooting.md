# Troubleshooting

## KVM / libvirt

### `/dev/kvm` does not exist

**Symptom**: `kvm-ok` says KVM is unavailable, or VMs fail to start with a KVM error.

#### Step 1 — check if AMD-V is already enabled (SSH-safe)

Run this before assuming you need a monitor:

```bash
# Look for 'svm' in CPU flags — present means AMD-V is on
grep -m1 'flags' /proc/cpuinfo | tr ' ' '\n' | grep svm

# Or install cpu-checker and run kvm-ok
sudo apt-get install -y cpu-checker && kvm-ok

# Check if /dev/kvm exists
ls -la /dev/kvm
```

If `svm` appears, `kvm-ok` reports success, or `/dev/kvm` exists → AMD-V is already enabled. No monitor needed; skip to the next step.

#### Step 2 — if AMD-V is not enabled, you need a monitor

The MINISFORUM X1 Pro 370 has no IPMI or remote console. You will need to temporarily plug in a monitor and keyboard to enter BIOS:

- Press `Del` at boot to enter BIOS
- Navigate to: Advanced → AMD CBS → SVM Mode → Enabled
- Save and exit (F10)

After this one-time change, the machine can be used SSH-only again.

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

**Fix**: Your user is not in the `libvirt` group, or the group membership has not taken effect.

```bash
# Check group membership
id | grep libvirt

# If missing, add and re-login
sudo usermod -aG libvirt "$USER"
# Then log out and back in, or:
newgrp libvirt
```

Also verify libvirtd is running:

```bash
sudo systemctl status libvirtd
sudo systemctl start libvirtd
```

---

### Sushy Tools cannot see VMs (empty Systems list)

**Symptom**: `curl http://localhost:8000/redfish/v1/Systems/` returns `{"Members": []}`.

**Causes and fixes**:

1. **libvirt URI mismatch** — sushy-tools is connecting to `qemu:///session` (per-user) instead of `qemu:///system` (system-wide).

   ```bash
   # Check the running config
   cat /etc/sushy-tools/emulator.conf | grep LIBVIRT_URI
   # Should be: SUSHY_EMULATOR_LIBVIRT_URI = u'qemu:///system'
   ```

2. **sushy-tools running as non-root** — `qemu:///system` requires root or libvirt group access.
   - If running via `start-sushy-tools.sh`, the script uses `sudo` — check that sudo is available.
   - If running as a systemd service, `User=root` is set in the unit file.

3. **VMs not defined in libvirt** — run `create-vms.sh` first.

   ```bash
   sudo virsh list --all
   ```

---

### `libvirt-python` pip install fails

**Symptom**: `pip install sushy-tools libvirt-python` fails with a build error about missing headers.

**Fix**: Install `libvirt-dev`:

```bash
sudo apt-get install -y libvirt-dev
```

Then retry the pip install inside the venv.

---

## Networking

### STP causing PXE timeouts

**Symptom**: VMs that PXE-boot get no DHCP response for 30+ seconds, then fail.

**Fix**: STP must be disabled on `br-provision`. `create-bridges.sh` does this automatically, but check:

```bash
cat /sys/class/net/br-provision/bridge/stp_state
# Should output: 0
```

To fix manually:

```bash
sudo nmcli conn modify br-provision bridge.stp no
sudo nmcli conn up br-provision
```

---

### DHCP conflicts on the provisioning network

**Symptom**: Ironic DHCP works but some VMs get IPs from the wrong server; provisioning fails partway through.

**Cause**: Another DHCP server is responding on `br-provision`. Common culprits:

- The libvirt default network (`virbr0`) if it shares the same subnet — unlikely with `172.22.0.0/24` but check.
- A lingering dnsmasq process.

```bash
# Check what's listening on UDP 67 (DHCP server)
sudo ss -lnup | grep :67

# List running dnsmasq instances
ps aux | grep dnsmasq
```

Kill any unexpected DHCP servers, or change the provisioning subnet in `.env`.

---

### Provisioning bridge missing after reboot

**Symptom**: `ip link show br-provision` fails after rebooting the host.

**Fix**: The bridge connection may not be set to autoconnect in NetworkManager.

```bash
sudo nmcli conn modify br-provision connection.autoconnect yes
sudo nmcli conn up br-provision
```

---

## Redfish / Sushy Tools

### Redfish address format for BareMetalHost

The `spec.bmc.address` must include the full Redfish path including the VM UUID:

```text
# Correct
redfish://172.22.0.1:8000/redfish/v1/Systems/a1b2c3d4-...

# Wrong — missing UUID path
redfish://172.22.0.1:8000
```

Get the UUID with:

```bash
sudo virsh domuuid vmetal-small-1
```

Or check `configs/vm-inventory.txt` (written by `create-vms.sh`).

---

### BMC registration fails immediately

**Symptom**: BareMetalHost goes to error state right after registration.

**Checks**:

1. Verify sushy-tools is running and the endpoint is reachable from the host:

   ```bash
   curl http://172.22.0.1:8000/redfish/v1/Systems/
   ```

2. Verify the specific VM UUID is present in the Systems list:

   ```bash
   UUID=$(sudo virsh domuuid vmetal-small-1)
   curl http://172.22.0.1:8000/redfish/v1/Systems/${UUID}/
   ```

3. Check BMC credentials match what is in the Secret:

   ```bash
   kubectl -n metal3-system get secret vmetal-small-1-bmc-creds -o jsonpath='{.data.username}' | base64 -d
   ```

4. Confirm `disableCertificateVerification: true` is set (required for plain HTTP).

---

## BareMetalHost does not progress past `registering`

**Symptom**: BareMetalHost is stuck in `registering` state.

**Checks**:

- Ironic may not have network access to the Redfish endpoint. Verify the Ironic pod can reach `172.22.0.1:8000` from inside the cluster.
- The Metal3 provider may not be fully deployed yet. Check NodeProvider status in the platform.

---

## BareMetalHost inspection fails

**Symptom**: Host reaches `inspecting` but then goes to error.

**Checks**:

- Verify the VM NIC is connected to `br-provision`:

  ```bash
  sudo virsh domiflist vmetal-small-1
  # Should show bridge br-provision
  ```

- Verify `bootMACAddress` in the BareMetalHost matches the VM NIC MAC exactly:

  ```bash
  sudo virsh domiflist vmetal-small-1 | awk '/br-provision/ {print $5}'
  ```

- Confirm Ironic DHCP is running and attached to the provisioning bridge. Check NodeProvider events and the Ironic pod logs.

---

## Group membership requiring re-login

After `bootstrap-host.sh` adds your user to the `libvirt` and `kvm` groups, the change does not take effect in the current shell session. You must either:

```bash
# Option 1: Log out and back in
exit

# Option 2: Start a new shell with the new group
newgrp libvirt

# Option 3: Verify the groups are active
id | grep libvirt
```

Scripts that call `virsh` or `virt-install` without `sudo` will fail until the group membership is active.
