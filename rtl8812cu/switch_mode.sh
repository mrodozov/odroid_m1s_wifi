#!/bin/sh
# Async fallback called by /etc/udev/rules.d/70-rtl8812cu-modeswitch.rules (RUN+=)
# Less reliable than early_switch.sh at boot — RUN+= fires after all rules are
# matched, by which point mtp-probe may have already blocked for 1-2s.
echo "$(date +%s.%N) switch_mode.sh started for $1" >> /tmp/switch_mode.log
usb_modeswitch -v 0x0bda -p 0x1a2b -c /etc/usb_modeswitch.d/0bda:1a2b >> /tmp/switch_mode.log 2>&1
echo "$(date +%s.%N) switch_mode.sh done exit=$?" >> /tmp/switch_mode.log
