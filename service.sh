#!/system/bin/sh
MODDIR=${0%/*}
DATA=/data/dikec
LOG="$DATA/logs/service.log"
mkdir -p "$DATA/logs"

. /data/adb/modules/bin-utils/lib/common.sh
CA=$(find_ca_bundle) && export SSL_CERT_FILE="$CA"
export PATH=/data/adb/modules/bin-utils/system/bin:$PATH

log_line "service.sh start"

# bin-utils supervisor_loop GERÇEK imzası (teyit edildi, common.sh:149):
#   supervisor_loop <komut-string> [gecikme=10] [rotate_bytes=524288]
#   - arg1 doğrudan `sh -c "$cmd"` ile çalışır (İSİM ARGÜMANI YOK)
#   - fonksiyon kendisi `( while...; ) &` ile fork eder → ekstra `&`/subshell SARMA
#   - $LOG env değişkenini okur; her servis için ayrı log vermek üzere çağrı-öncesi prefix
# Web panel (busybox httpd) — kalıcı, çok hafif
LOG="$DATA/logs/httpd.log" supervisor_loop "$MODDIR/www/start-httpd.sh" 15

# Telegram bot — token + chat_id bekler (bot.sh kendi bekler)
LOG="$DATA/logs/bot.log" supervisor_loop "$MODDIR/bot/bot.sh" 15

# xray ve adblock: cihaz başladığında iptables ve ağ kurallarının Android (netd)
# tarafından ezilmesini önlemek için boot işleminin tamamlanmasını bekle.
(
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 2
    done
    # Ağ servislerinin (netd/cellular) tam yerleşmesi için ek süre
    sleep 30

    # xray yalnızca kullanıcı etkinleştirmişse (route mode'a göre tun0/tproxy)
    if [ "$(cat "$DATA/conf/xray_enabled" 2>/dev/null)" = "1" ]; then
        "$MODDIR/lib/action.sh" xray_start >> "$DATA/logs/service.log" 2>&1
    fi

    # adblock: kullanıcı açık bıraktıysa boot'ta geri aç (on/off kararı kalıcı olsun)
    if [ "$(cat "$DATA/conf/adblock_enabled" 2>/dev/null)" = "1" ]; then
        "$MODDIR/lib/action.sh" adblock_enable >> "$DATA/logs/service.log" 2>&1
    fi
) &

# Kullanıcının panel/bot'tan DURDURDUĞU entegrasyonlar (tor/ssh/tailscale) boot'ta
# kendi modüllerince tekrar başlatılır; kullanıcının "durdur" kararı kalıcı olsun
# diye, diğer modüller başladıktan ~40 sn sonra flag'li olanları tekrar durdur.
(
    sleep 40
    . "$MODDIR/lib/core/env.sh" 2>/dev/null
    . "$MODDIR/lib/core/integrations.sh" 2>/dev/null
    intg_enforce_off >> "$DATA/logs/service.log" 2>&1
) &
