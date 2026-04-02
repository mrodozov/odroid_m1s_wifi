#!/bin/sh
# Called synchronously by /etc/udev/rules.d/39-rtl8812cu-modeswitch.rules
# PROGRAM= in udev runs this before child interface events are processed,
# preventing usb-storage from binding to 0bda:1a2b during the switch.
DEV=$1
logger -t rtl8812cu-switch "early_switch.sh started for $DEV"
/usr/sbin/usb_modeswitch -v 0x0bda -p 0x1a2b -c /etc/usb_modeswitch.d/0bda:1a2b > /var/log/rtl8812cu-switch.log 2>&1
EXIT=$?
logger -t rtl8812cu-switch "usb_modeswitch exit=$EXIT for $DEV"
echo ok
