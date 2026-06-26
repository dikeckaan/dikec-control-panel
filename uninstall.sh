#!/system/bin/sh
# Dikec Control Panel kaldırma
DATA=/data/dikec
# xray + tun + adblock dnsmasq + iptables kurallarını temizle (best-effort)
[ -x /data/adb/modules/dikec-control-panel/lib/action.sh ] && \
  /data/adb/modules/dikec-control-panel/lib/action.sh xray_stop 2>/dev/null
pkill -f 'dnsmasq.*dikec' 2>/dev/null
# statusbot'u geri yükle (kullanıcı isterse)
[ -f /data/adb/modules/statusbot/disable ] && rm -f /data/adb/modules/statusbot/disable
rm -rf "$DATA"
