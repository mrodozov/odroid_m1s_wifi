#!/bin/sh
# Called by /etc/udev/rules.d/71-rtl8812cu-bind.rules when 0bda:c812 appears.
# Unbinds from option driver (if claimed) and binds to rtl8812cu.
DEV=$1
sleep 2
echo "${DEV}:1.0" > /sys/bus/usb/drivers/option/unbind 2>/dev/null || true
echo "${DEV}:1.0" > /sys/bus/usb/drivers/rtl8812cu/bind 2>/dev/null || true
