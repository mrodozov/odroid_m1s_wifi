#!/bin/bash
for i in $(seq 1 20); do
  ip link show wlan0 &>/dev/null && break
  sleep 1
done
ip link set wlan0 up
sleep 1
pkill -f "wpa_supplicant.*wlan0" 2>/dev/null || true
sleep 0.5
wpa_supplicant -D wext -i wlan0 -c /etc/wpa_supplicant/rodozov_22.conf -B
for i in $(seq 1 15); do
  iwconfig wlan0 2>/dev/null | grep -q "rodozov_22" && break
  sleep 1
done
dhclient wlan0
