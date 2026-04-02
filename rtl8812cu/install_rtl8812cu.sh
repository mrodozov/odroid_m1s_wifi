#!/bin/bash
set -e

SRC="/usr/local/src/rtl8812cu"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Step 1: Prerequisites ---
echo "==> Installing kernel headers and build tools..."
apt update
apt install -y \
  linux-kbuild-5.10 \
  linux-headers-5.10.0-odroid-arm64 \
  build-essential \
  usb-modeswitch

# --- Step 2: Driver source ---
echo "==> Downloading JasonFreeLab/rtl8812cu..."
curl -L https://github.com/JasonFreeLab/rtl8812cu/archive/refs/heads/master.tar.gz \
  -o /tmp/rtl8812cu.tar.gz
rm -rf "$SRC"
tar -xz -C /usr/local/src/ -f /tmp/rtl8812cu.tar.gz
# Extracted name may vary; pick whatever was created
EXTRACTED=$(ls -d /usr/local/src/rtl8812cu-* 2>/dev/null | head -1)
if [ -z "$EXTRACTED" ]; then
  echo "ERROR: could not find extracted rtl8812cu source under /usr/local/src/"
  exit 1
fi
mv "$EXTRACTED" "$SRC"

# --- Step 3: Build and install ---
echo "==> Building driver..."
make -j$(nproc) ARCH=arm64 -C "$SRC"

echo "==> Installing driver..."
make install ARCH=arm64 -C "$SRC"

echo "==> Loading module..."
modprobe 8812cu || true

# --- Step 4: Mode switch setup ---
echo "==> Installing usb-storage IGNORE_DEVICE quirk..."
cat > /etc/modprobe.d/rtl8812cu-modeswitch.conf << 'EOF'
options usb-storage quirks=0bda:1a2b:i
EOF

echo "==> Rebuilding initramfs (quirk must be active at early boot)..."
update-initramfs -u

echo "==> Installing usb_modeswitch config for 0bda:1a2b..."
cat > /etc/usb_modeswitch.d/0bda:1a2b << 'EOF'
DefaultVendor=0x0bda
DefaultProduct=0x1a2b
TargetVendor=0x0bda
TargetProduct=0xc812
StandardEject=1
CheckSuccess=20
EOF

echo "==> Copying helper scripts..."
cp "$SCRIPT_DIR/early_switch.sh" "$SCRIPT_DIR/switch_mode.sh" "$SCRIPT_DIR/bind_c812.sh" "$SRC/"
chmod +x "$SRC/early_switch.sh" "$SRC/switch_mode.sh" "$SRC/bind_c812.sh"

echo "==> Installing udev rules..."
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

# --- Step 5: Persistence ---
echo "==> Setting up module auto-load..."
echo "8812cu" > /etc/modules-load.d/8812cu.conf

echo "==> Masking usb_modeswitch@.service (prevents race that kills wlan0)..."
systemctl mask usb_modeswitch@.service

echo "==> Done. Reboot to verify clean boot."
echo "    Hot-plug works immediately: unplug and replug the adapter."
