# RTL8812CU USB WiFi on Odroid M1S

Guide for getting the Realtek RTL8812CU (`0bda:c812`) USB WiFi adapter working
on an Odroid M1S running Ubuntu 20.04 with the `5.10.0-odroid-arm64` kernel.

The driver is not included in the kernel and must be compiled from source.
The M1S has an additional complication: the adapter presents itself as a USB
mass storage device (`0bda:1a2b`) at power-on and must be mode-switched to
WiFi mode (`0bda:c812`) before the driver can bind.

## Scripts

| Script | What it does |
|---|---|
| `install_rtl8812cu.sh` | Build driver, install all udev rules, modprobe quirk, rebuild initramfs |
| `early_switch.sh` | Called synchronously by udev (39- rule) — runs `usb_modeswitch` before any driver can bind |
| `switch_mode.sh` | Async fallback called by udev (70- rule) |
| `bind_c812.sh` | Called by udev (71- rule) when `0bda:c812` appears — unbinds `option`, binds `rtl8812cu` |

Run `install_rtl8812cu.sh` as root. Copy the helper scripts to
`/usr/local/src/rtl8812cu/` before running (the install script places the
udev rules that reference them there).

---

## Hardware

| Field | Value |
|---|---|
| Chip | Realtek RTL8812CU (identified as RTL8822C by driver) |
| USB ID — boot/disk mode | `0bda:1a2b` |
| USB ID — WiFi mode | `0bda:c812` |
| Standard | 802.11ac (AC1200), dual-band 2.4 GHz + 5 GHz |
| Board | Odroid M1S (RK3566) |
| OS | Ubuntu 20.04 LTS (Focal) |
| Kernel | `5.10.0-odroid-arm64` |
| USB port | bus 5 port 1 (`5-1`) |
| Interface | `wlan0` |

---

## Problem

The adapter ships with firmware in flash. At power-on it enumerates as a USB
mass storage device (`0bda:1a2b`) and must be mode-switched before the WiFi
driver can bind. This works fine on hot-plug (system already running), but
fails at boot due to a race between `usb-storage` and `usb_modeswitch`.

### Boot-time failure chain (before fix)

1. Device appears as `0bda:1a2b`
2. `usb-storage` binds immediately (it has a USB ID match for Realtek devices)
3. `usb-storage` performs a SCSI scan, which stalls endpoint `0x0b`
4. `usb_modeswitch` fires later but cannot send the eject sequence — endpoint
   is already stalled — and gives up
5. Device stays as `0bda:1a2b` forever until physical replug

### Fix applied

Two independent fixes work together:

**1. usb-storage IGNORE_DEVICE quirk (in initramfs)**

`/etc/modprobe.d/rtl8812cu-modeswitch.conf`:
```
options usb-storage quirks=0bda:1a2b:i
```

This must be in the initramfs (run `update-initramfs -u` after placing the
file). Without this, `usb-storage` loads early and stalls the endpoint before
any udev rule can fire.

Result: dmesg shows `usb-storage 5-1:1.0: device ignored` instead of
`USB Mass Storage device detected`.

**2. Synchronous udev PROGRAM= rule (numbered before 69-libmtp)**

`/etc/udev/rules.d/39-rtl8812cu-modeswitch.rules` uses `PROGRAM=` instead of
`RUN+=`. `PROGRAM=` runs synchronously during the parent device event (5-1),
blocking child interface events (5-1:1.0) from being processed. This prevents
`usb-storage` from binding during the mode-switch window.

The rule is numbered 39 to fire before `69-libmtp.rules`, which uses its own
synchronous `PROGRAM=mtp-probe` that would otherwise block for ~1-2 s and
allow a USB reset to stall the endpoint.

**3. usb_modeswitch service masked**

The `usb_modeswitch@.service` systemd template is masked to prevent it from
racing with `early_switch.sh` and sending SCSI eject commands to the
already-switched `0bda:c812` firmware (which crashes `wlan0`):

```bash
systemctl mask usb_modeswitch@.service
```

### Remaining boot-time issue

At boot, `usb_modeswitch` sends the ALLOW_MEDIUM_REMOVAL CBW successfully but
the CSW response read from endpoint `0x8a` fails with `error -7` (STALL). It
then reports "Device is gone" and never sends START_STOP_UNIT. The device stays
as `0bda:1a2b`.

Hot-plug works: physical replug triggers `early_switch.sh` via the 39- rule,
and the CSW read succeeds when the system is fully booted.

**Root cause**: not yet fully resolved. The endpoint stall on CSW at boot is
a firmware behavior difference between cold-boot and hot-plug.

---

## Step 1 — Prerequisites

```bash
apt update
apt install -y \
  linux-kbuild-5.10 \
  linux-headers-5.10.0-odroid-arm64 \
  build-essential \
  usb-modeswitch
```

---

## Step 2 — Driver Source

Use `JasonFreeLab/rtl8812cu`:

```bash
curl -L https://github.com/JasonFreeLab/rtl8812cu/archive/refs/heads/master.tar.gz \
  -o /tmp/rtl8812cu.tar.gz
tar -xz -C /usr/local/src/ -f /tmp/rtl8812cu.tar.gz
mv /usr/local/src/rtl8812cu-5.15.0.1 /usr/local/src/rtl8812cu
```

> The extracted directory name may vary. Adjust `mv` accordingly.

### USB ID note

`0bda:c812` is listed in the driver USB ID table as `RTL8822C`. Correct and expected.

---

## Step 3 — Build and Install

```bash
make -j$(nproc) ARCH=arm64 -C /usr/local/src/rtl8812cu
make install ARCH=arm64 -C /usr/local/src/rtl8812cu
```

> Patches applied on Odroid C5 (5.15 backported cfg80211 APIs) are **not**
> needed on the M1S 5.10 kernel. Build should succeed without them.

---

## Step 4 — Mode Switch Setup

```bash
# usb-storage quirk — prevents endpoint stall at boot
cat > /etc/modprobe.d/rtl8812cu-modeswitch.conf << 'EOF'
options usb-storage quirks=0bda:1a2b:i
EOF

# Rebuild initramfs so quirk is active before usb-storage loads
update-initramfs -u

# usb_modeswitch config for 0bda:1a2b
cat > /etc/usb_modeswitch.d/0bda:1a2b << 'EOF'
DefaultVendor=0x0bda
DefaultProduct=0x1a2b
TargetVendor=0x0bda
TargetProduct=0xc812
StandardEject=1
CheckSuccess=20
EOF

# Copy helper scripts
cp early_switch.sh switch_mode.sh bind_c812.sh /usr/local/src/rtl8812cu/
chmod +x /usr/local/src/rtl8812cu/early_switch.sh \
         /usr/local/src/rtl8812cu/switch_mode.sh \
         /usr/local/src/rtl8812cu/bind_c812.sh

# udev rules
cat > /etc/udev/rules.d/39-rtl8812cu-modeswitch.rules << 'EOF'
# Run mode switch synchronously for RTL8812CU DISK device
# PROGRAM= blocks event processing, keeping usb-storage from binding to the interface
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="1a2b", PROGRAM="/usr/local/src/rtl8812cu/early_switch.sh %k"
EOF

cat > /etc/udev/rules.d/70-rtl8812cu-modeswitch.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="1a2b", RUN+="/usr/local/src/rtl8812cu/switch_mode.sh %k"
EOF

cat > /etc/udev/rules.d/71-rtl8812cu-bind.rules << 'EOF'
# Rebind RTL8812CU from option to rtl8812cu after mode switch
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="c812", RUN+="/usr/local/src/rtl8812cu/bind_c812.sh %k"
EOF

cat > /etc/udev/rules.d/99-rtl8812cu-power.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="c812", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="c812", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
EOF

udevadm control --reload-rules

# Mask the modeswitch service — it races with early_switch.sh and kills wlan0
systemctl mask usb_modeswitch@.service
```

---

## Step 5 — Persistence

```bash
echo "8812cu" > /etc/modules-load.d/8812cu.conf
```

The driver loads at ~34 s on boot (loaded by `modules-load.d`, no module alias
for `0bda:1a2b`). NetworkManager connects automatically if a profile exists:

```bash
nmcli dev wifi connect "SSID" password "PASSWORD" ifname wlan0
```

---

## Verification

```bash
lsusb | grep 0bda          # should show 0bda:c812 after switch
ip link show wlan0
nmcli dev status
journalctl -b | grep -i "rtl8812cu\|modeswitch\|wlan0"
cat /var/log/rtl8812cu-switch.log
```

Expected dmesg at clean boot (with quirk active):
```
[    3.69] usb 5-1: New USB device found, idVendor=0bda, idProduct=1a2b
[    4.99] usb-storage 5-1:1.0: USB Mass Storage device detected
[    5.01] usb-storage 5-1:1.0: device ignored
[   34.29] 8812cu: loading out-of-tree module taints kernel.
[   44.66] usbcore: registered new interface driver rtl8812cu
```

Hot-plug after boot works reliably: plug in → `early_switch.sh` switches device
→ `wlan0` appears → NetworkManager connects.
