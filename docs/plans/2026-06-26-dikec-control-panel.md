# Dikec Control Panel — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ZTE F50 (Android 13, arm64, Magisk) için xray binary'leri ile çalışan, web panel + Telegram bot + SMS merkezini tek ortak backend üzerinde birleştiren `dikec-control-panel` Magisk mega-modülünü inşa etmek.

**Architecture:** Tüm cihaz mantığı `lib/core/*.sh`'ta tek kaynak; bot (`bot/bot.sh`) ve web (`www/api.cgi`) ikisi de `lib/action.sh <verb> [json] → JSON` dispatcher'ı üzerinden çağırır. xray + hev-socks5-tunnel binary'leri; yönlendirme tun0 (vpn-gateway uyumlu) veya tproxy. statusbot içeri alınır + emekliye ayrılır; AdGuard Home kaldırılıp panel-native dnsmasq sinkhole ile değiştirilir.

**Tech Stack:** bash (bin-utils statik bash), busybox httpd + bash CGI, jq, sendat (AT), xray-core arm64, hev-socks5-tunnel, /system/bin/dnsmasq, iptables/ip, Magisk module API.

## Global Constraints

- **Cihaz:** ZTE F50 / MU300, Android 13, `arm64-v8a`, Magisk, Toybox userspace, ~1.4 GB RAM (boşta ~40 MB). transport_id seri: `324950664950`.
- **Sert bağımlılık:** `bin-utils` v1.3.0+ (`/data/adb/modules/bin-utils/lib/common.sh`, ve bin/bash,busybox,curl,jq,sendat,wget, /system/etc/cacert.pem). customize.sh'ta kontrol et (adguardhome deseni).
- **Go binary'leri:** `SSL_CERT_FILE` = `find_ca_bundle` çıktısı export edilmeli (xray geo/abonelik fetch).
- **Modül id:** `dikec-control-panel`. Modül adı: `Dikec Control Panel`. Author: `dikeckaan`.
- **Runtime veri kökü:** `/data/dikec/` (config/log/sms/xray). Modül kökü: `/data/adb/modules/dikec-control-panel/`.
- **Kaynak disiplini:** Yeni kalıcı daemon YOK; periyodik iş tek bot poll döngüsünde; CGI istek-ömürlü; 15s cold cache; log_rotate 512 KB; xray yalnızca enabled iken.
- **Dispatcher sözleşmesi:** `action.sh` her zaman TEK satır JSON yazar: başarı `{"ok":true,...}`, hata `{"ok":false,"err":"<mesaj>"}`. JSON üretimi `jq -n` ile.
- **Log:** bin-utils `log_line`/`log_rotate`; her bileşen `LOG=/data/dikec/logs/<ad>.log`.
- **Dil:** kod/yorum İngilizce-TR karışık mevcut ekosistemle uyumlu; kullanıcı-yüzü TR. i18n statusbot `lang/<code>.sh` deseni.
- **Referans kaynaklar (port için, mevcut):** `/tmp/zte-g5-cpe-xray/rootfs/usr/bin/{xray-import,sms-control,vpn-watchdog,vpn-curl,adblock-update}`, `/tmp/zte-g5-cpe-xray/rootfs/www_xray2/{api.cgi,app.js}`, `magisk-modules/statusbot/bot/bot.sh`, `magisk-modules/{adguardhome,vpn-gateway,sms-cmd,cell-tools,bin-utils}`.

**Test modeli:** Bu cihaz-üstü bash projesi; "test" = modülü cihaza `adb push` edip `su -c` ile `action.sh <verb>` çağırmak ve JSON çıktıyı `jq` ile doğrulamak. Her task sonunda somut bir `adb ... | jq` doğrulama komutu ve beklenen çıktı verilir. Geliştirme makinesinde `bash -n` (syntax) ve `shellcheck` (varsa) ön-kontrol.

**Yardımcı kısaltma (tüm verify komutlarında):** `S=324950664950`; `DEV=/data/adb/modules/dikec-control-panel`; push helper:
```bash
push(){ adb -s $S push "$1" "$2" >/dev/null && adb -s $S shell su -c "chmod ${3:-0755} $2"; }
run(){ adb -s $S shell su -c "$1"; }
```

---

## Phase 1 — İskele & paketleme temeli

### Task 1: Modül iskeleti + module.prop + META-INF

**Files:**
- Create: `module.prop`
- Create: `META-INF/com/google/android/update-binary` (standart Magisk installer — bin-utils'tan kopyala)
- Create: `META-INF/com/google/android/updater-script` (tek satır `#MAGISK`)
- Create: `.gitignore` (zaten var: `*.zip`, `.DS_Store`, `/dist/`)

**Interfaces:**
- Produces: modül kimliği `id=dikec-control-panel`, kök `$MODPATH`/`/data/adb/modules/dikec-control-panel`.

- [ ] **Step 1: module.prop yaz**
```
id=dikec-control-panel
name=Dikec Control Panel
version=v0.1.0
versionCode=1
author=dikeckaan
description=F50 icin xray binary tabanli kontrol paneli: web + Telegram bot + SMS merkezi, tek ortak backend. statusbot'u icerir, AdGuard Home yerine hafif dnsmasq adblock. bin-utils gerektirir.
updateJson=https://raw.githubusercontent.com/dikeckaan/dikec-control-panel/main/update.json
```

- [ ] **Step 2: META-INF'i mevcut bir modülden kopyala (kanonik Magisk installer)**
```bash
cd /Users/kaandikec/f50-remote-adb/magisk-modules/dikec-control-panel
mkdir -p META-INF/com/google/android
cp ../bin-utils/META-INF/com/google/android/update-binary META-INF/com/google/android/
printf '#MAGISK\n' > META-INF/com/google/android/updater-script
```

- [ ] **Step 3: Doğrula (yapı + module.prop parse)**
```bash
test -f module.prop && grep -q '^id=dikec-control-panel$' module.prop && echo OK-prop
test -f META-INF/com/google/android/update-binary && echo OK-installer
```
Expected: `OK-prop` ve `OK-installer`.

- [ ] **Step 4: Commit**
```bash
git add -A && git commit -m "feat: modül iskeleti + module.prop + META-INF"
```

---

### Task 2: customize.sh — bağımlılık kontrolü, göç, izinler

**Files:**
- Create: `customize.sh`

**Interfaces:**
- Consumes: bin-utils `lib/common.sh`. Magisk `$MODPATH`, `ui_print`, `abort`, `set_perm`, `set_perm_recursive`.
- Produces: `/data/dikec/` ağacı; `/data/statusbot/*` → `/data/dikec/*` göçü; statusbot + adguardhome disable.

- [ ] **Step 1: customize.sh yaz**
```sh
#!/system/bin/sh
# Dikec Control Panel kurulum betiği.

# --- bin-utils sert bağımlılığı (adguardhome deseni) ---
if [ ! -r /data/adb/modules/bin-utils/lib/common.sh ] \
   && [ ! -r /data/adb/modules_update/bin-utils/lib/common.sh ]; then
    ui_print " "
    ui_print "  ❌ bin-utils v1.3.0+ gerekli (lib/common.sh sağlar)."
    ui_print "     Önce kur:  /install_module bin-utils"
    abort "  Eksik bağımlılık: bin-utils"
fi

DATA=/data/dikec
mkdir -p "$DATA"/xray/profiles "$DATA"/conf "$DATA"/sms "$DATA"/logs "$DATA"/adblock

# --- statusbot config göçü (varsa, üzerine yazma) ---
SB=/data/statusbot
if [ -d "$SB" ]; then
    ui_print "  → statusbot ayarları taşınıyor (/data/dikec)"
    for f in token chat_id lang quiet_hours.conf heartbeat.conf schedules.txt zte_password geo_api_key; do
        [ -f "$SB/$f" ] && [ ! -f "$DATA/$f" ] && cp -a "$SB/$f" "$DATA/$f"
    done
fi

# --- statusbot'u emekliye ayır (çakışan bot çalışmasın) ---
if [ -d /data/adb/modules/statusbot ]; then
    ui_print "  → statusbot devre dışı bırakılıyor (bu modül onu kapsar)"
    touch /data/adb/modules/statusbot/disable
fi

# --- AdGuard Home'u kaldır (panel-native adblock devralır) ---
if [ -d /data/adb/modules/adguardhome ]; then
    ui_print "  → AdGuard Home devre dışı bırakılıyor (hafif dnsmasq adblock kullanılacak)"
    touch /data/adb/modules/adguardhome/disable
    touch /data/adb/modules/adguardhome/remove
fi

# --- panel token (yoksa üret) ---
[ -f "$DATA/conf/panel_token" ] || tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 32 > "$DATA/conf/panel_token"
[ -s "$DATA/conf/route_mode" ] || echo tun0 > "$DATA/conf/route_mode"
[ -s "$DATA/conf/lan_expose" ] || echo 0 > "$DATA/conf/lan_expose"

# --- izinler ---
set_perm_recursive "$MODPATH" 0 0 0755 0644
for x in xray hev-socks5-tunnel; do
    [ -f "$MODPATH/system/bin/$x" ] && set_perm "$MODPATH/system/bin/$x" 0 0 0755
done
find "$MODPATH/lib" "$MODPATH/bot" "$MODPATH/www" -name '*.sh' -o -name '*.cgi' 2>/dev/null | while read -r f; do
    set_perm "$f" 0 0 0755
done

ui_print " "
ui_print "  ✅ Dikec Control Panel kuruldu. Reboot sonrası:"
ui_print "     • Bot token/chat_id: /data/dikec/{token,chat_id}"
ui_print "     • Panel: http://127.0.0.1:8088 (adb forward / tünel)"
```

- [ ] **Step 2: Syntax kontrol**
```bash
bash -n customize.sh && echo OK-syntax
```
Expected: `OK-syntax`.

- [ ] **Step 3: Commit**
```bash
git add customize.sh && git commit -m "feat: customize.sh — bağımlılık, statusbot/AGH göçü, izinler"
```

---

### Task 3: service.sh + uninstall.sh (supervisor iskeleti)

**Files:**
- Create: `service.sh`
- Create: `uninstall.sh`

**Interfaces:**
- Consumes: bin-utils `common.sh` (`log_line`, `log_rotate`, `find_ca_bundle`, `supervisor_loop`). `lib/core/xray.sh` (`xray_is_enabled`, `xray_start`) — Phase 3'te dolar; bu task'ta stub güvenli çağrı.
- Produces: boot'ta httpd + bot başlatır; xray yalnızca `enabled`.

- [ ] **Step 1: service.sh yaz (geç-başlangıç supervisor)**
```sh
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

# xray yalnızca kullanıcı etkinleştirmişse (route mode'a göre tun0/tproxy)
if [ "$(cat "$DATA/conf/xray_enabled" 2>/dev/null)" = "1" ]; then
    "$MODDIR/lib/action.sh" xray_start >> "$DATA/logs/service.log" 2>&1
fi
```

- [ ] **Step 2: uninstall.sh yaz**
```sh
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
```

- [ ] **Step 3: Syntax kontrol**
```bash
bash -n service.sh && bash -n uninstall.sh && echo OK
```
Expected: `OK`.

- [ ] **Step 4: Commit**
```bash
git add service.sh uninstall.sh && git commit -m "feat: service.sh supervisor + uninstall.sh"
```

---

## Phase 2 — Ortak çekirdek (`lib/core`) + dispatcher

> Bu fazın deliverable'ı: cihazda `action.sh <verb>` çağrılınca geçerli JSON dönen, sistem/AT/SMS temel verb'leri. Bot ve panel bunun üzerine oturur.

### Task 4: `lib/core/env.sh` — ortam, yollar, bin keşfi, JSON yardımcıları

**Files:**
- Create: `lib/core/env.sh`

**Interfaces:**
- Produces: `$DCP_DATA`, `$DCP_MOD`, `$CURL`, `$JQ`, `$SENDAT`, `$BB`; fonksiyonlar `j_ok()`, `j_err()`, `cfg_get <dosya> <default>`, `cfg_set <dosya> <değer>`, `dcp_log <mesaj>`.

- [ ] **Step 1: env.sh yaz**
```sh
#!/system/bin/sh
# Ortak ortam — her lib/core/*.sh ve action.sh bunu source eder.
DCP_MOD=/data/adb/modules/dikec-control-panel
DCP_DATA=/data/dikec
BU=/data/adb/modules/bin-utils
export PATH="$BU/system/bin:$PATH"
[ -r "$BU/lib/common.sh" ] && . "$BU/lib/common.sh"

CURL="$BU/system/bin/curl"; JQ="$BU/system/bin/jq"
SENDAT="$BU/system/bin/sendat"; BB="$BU/system/bin/busybox"
CA=$(find_ca_bundle 2>/dev/null); export SSL_CERT_FILE="$CA"
LOG="$DCP_DATA/logs/core.log"

dcp_log(){ LOG="$DCP_DATA/logs/core.log" log_line "$*"; }

# JSON çıktı sözleşmesi — tek satır
j_ok(){  "$JQ" -nc --argjson d "${1:-{}}" '{ok:true} + $d'; }
j_err(){ "$JQ" -nc --arg e "$1" '{ok:false, err:$e}'; }

cfg_get(){ cat "$DCP_DATA/conf/$1" 2>/dev/null || printf '%s' "$2"; }
cfg_set(){ mkdir -p "$DCP_DATA/conf"; printf '%s' "$2" > "$DCP_DATA/conf/$1"; }
```

- [ ] **Step 2: Doğrula (j_ok/j_err geçerli JSON)**
```bash
push lib/core/env.sh $DEV/lib/core/env.sh
run ". $DEV/lib/core/env.sh; j_ok '{\"x\":1}'; j_err 'boom'" | jq -c .
```
Expected: iki satır geçerli JSON: `{"ok":true,"x":1}` ve `{"ok":false,"err":"boom"}`.

- [ ] **Step 3: Commit**
```bash
git add lib/core/env.sh && git commit -m "feat: lib/core/env.sh — ortam + JSON sözleşmesi"
```

---

### Task 5: `lib/core/system.sh` — sistem durumu (+15s cold cache)

**Files:**
- Create: `lib/core/system.sh`

**Interfaces:**
- Consumes: `env.sh`.
- Produces: `sys_status_json()` → `{model,uptime_s,mem_used_mb,mem_total_mb,cpu_pct,temp_c,load1}`; `sys_throughput_json(iface)`; `sys_clients_json()`. Cache: `$DCP_DATA/conf/.cold_cache` (15s TTL).

- [ ] **Step 1: system.sh yaz** (statusbot'taki /status, /mem, /temp, /load, /traffic mantığını süzerek; kaynaklar: `/proc/uptime`, `/proc/meminfo`, `/proc/loadavg`, `/sys/class/thermal/thermal_zone*/temp`, `/proc/net/dev`, `getprop ro.product.model`)
```sh
#!/system/bin/sh
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"

_temp_c(){ for z in /sys/class/thermal/thermal_zone*/temp; do v=$(cat "$z" 2>/dev/null); [ "$v" -gt 1000 ] 2>/dev/null && { echo $((v/1000)); return; }; done; echo 0; }
_mem(){ awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d %d",(t-a)/1024,t/1024}' /proc/meminfo; }
_cpu_pct(){ awk '{u=$2+$4;t=$2+$4+$5}NR==1{print int((u)/(t)*100)}' /proc/stat 2>/dev/null; }

sys_status_json(){
    cache="$DCP_DATA/conf/.cold_cache"
    if [ -f "$cache" ] && [ "$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null||echo 0) ))" -lt 15 ]; then
        cat "$cache"; return; fi
    read -r mu mt <<EOF
$(_mem)
EOF
    up=$(awk '{print int($1)}' /proc/uptime)
    out=$("$JQ" -nc --arg model "$(getprop ro.product.model)" --argjson up "$up" \
        --argjson mu "${mu:-0}" --argjson mt "${mt:-0}" --argjson temp "$(_temp_c)" \
        --arg load1 "$(awk '{print $1}' /proc/loadavg)" \
        '{model:$model,uptime_s:$up,mem_used_mb:$mu,mem_total_mb:$mt,temp_c:$temp,load1:$load1}')
    echo "$out" | tee "$cache"
}

sys_throughput_json(){ i="${1:-rmnet_data0}"; awk -v i="$i:" '$1==i{print $2" "$10}' /proc/net/dev | \
    "$JQ" -Rnc 'input | split(" ") | {rx_bytes:(.[0]//"0"|tonumber), tx_bytes:(.[1]//"0"|tonumber)}' 2>/dev/null || echo '{}'; }
```

- [ ] **Step 2: Doğrula**
```bash
push lib/core/env.sh $DEV/lib/core/env.sh; push lib/core/system.sh $DEV/lib/core/system.sh
run ". $DEV/lib/core/system.sh; sys_status_json" | jq -e '.mem_total_mb>500 and .uptime_s>0' && echo OK
```
Expected: cihaz model/uptime/mem dolu JSON; `OK`.

- [ ] **Step 3: Commit** `git add lib/core/system.sh && git commit -m "feat: lib/core/system.sh — durum + cold cache"`

---

### Task 6: `lib/core/at.sh` — sendat AT sarmalayıcıları

**Files:**
- Create: `lib/core/at.sh`

**Interfaces:**
- Consumes: `env.sh` (`$SENDAT`).
- Produces: `at_raw(cmd, slot=0)`; `at_signal_json()` → `{csq,rssi_dbm,rsrp,rsrq}`; `at_cellinfo_json()` → `{operator,nettype,imei,iccid,imsi,phone}`; `at_airplane(on|off)`.

- [ ] **Step 1: at.sh yaz** (statusbot `at_cmd` + cellinfo/signal mantığı; `AT+CSQ`,`AT+CESQ`,`AT+COPS?`,`AT+CGSN`,`AT+CCID`,`AT+CIMI`,`AT+CNUM`,`AT+CFUN`)
```sh
#!/system/bin/sh
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"
at_raw(){ [ -x "$SENDAT" ] || return 1; "$SENDAT" -c "$1" -n "${2:-0}" 2>/dev/null | tr -d '\r\0' | sed 's/OK$//' | head -c 600; }
at_signal_json(){
    csq=$(at_raw 'AT+CSQ' | sed -nE 's/.*\+CSQ: ([0-9]+).*/\1/p')
    rssi=$([ -n "$csq" ] && [ "$csq" -lt 99 ] 2>/dev/null && echo $((csq*2-113)) || echo 0)
    esq=$(at_raw 'AT+CESQ')
    rsrp=$(echo "$esq" | sed -nE 's/.*\+CESQ: [0-9]+,[0-9]+,[0-9]+,[0-9]+,([0-9]+),.*/\1/p')
    rsrq=$(echo "$esq" | sed -nE 's/.*\+CESQ: [0-9]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+,([0-9]+).*/\1/p')
    "$JQ" -nc --argjson csq "${csq:-0}" --argjson rssi "${rssi:-0}" \
        --arg rsrp "${rsrp:-}" --arg rsrq "${rsrq:-}" \
        '{csq:$csq,rssi_dbm:$rssi,rsrp:$rsrp,rsrq:$rsrq}'
}
at_cellinfo_json(){
    op=$(at_raw 'AT+COPS?' | sed -nE 's/.*"([^"]+)".*/\1/p')
    imei=$(at_raw 'AT+CGSN' | tr -dc '0-9' | head -c 15)
    iccid=$(at_raw 'AT+CCID' | sed -nE 's/.*: ?([0-9A-Fa-f]+).*/\1/p')
    imsi=$(at_raw 'AT+CIMI' | tr -dc '0-9' | head -c 15)
    "$JQ" -nc --arg op "$op" --arg imei "$imei" --arg iccid "$iccid" --arg imsi "$imsi" \
        '{operator:$op,imei:$imei,iccid:$iccid,imsi:$imsi}'
}
at_airplane(){ case "$1" in on) at_raw 'AT+CFUN=4';; off) at_raw 'AT+CFUN=1';; esac; }
```

- [ ] **Step 2: Doğrula (gerçek modem)**
```bash
push lib/core/at.sh $DEV/lib/core/at.sh
run ". $DEV/lib/core/at.sh; at_cellinfo_json" | jq -e '.imei|length==15' && echo OK-IMEI
run ". $DEV/lib/core/at.sh; at_signal_json" | jq -e '.csq>=0'
```
Expected: 15 haneli IMEI → `OK-IMEI`; sinyal JSON.

- [ ] **Step 3: Commit** `git add lib/core/at.sh && git commit -m "feat: lib/core/at.sh — AT sinyal/cellinfo/airplane"`

---

### Task 7: `lib/core/sms.sh` — oku/gönder/sil

**Files:**
- Create: `lib/core/sms.sh`

**Interfaces:**
- Consumes: `env.sh`, `at.sh`. Mekanizma: okuma `content query content://sms/inbox` (sms-cmd modülü kanıtlı), gönderme `AT+CMGS`, silme `content delete`.
- Produces: `sms_list_json(limit=20)` → `{messages:[{id,address,body,date_ms,read}]}`; `sms_send(to, text)` → 0/1; `sms_delete(id)`.

- [ ] **Step 1: sms.sh yaz** (okuma parse'ı sms-cmd/poller.sh lines 164-194 deseninden; gönderme `AT+CMGS="<no>"\r<text>\x1A`)
```sh
#!/system/bin/sh
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"
sms_list_json(){
    n="${1:-20}"
    content query --uri content://sms/inbox --projection _id:address:body:date:read --sort 'date DESC' 2>/dev/null \
    | head -n "$n" \
    | while IFS= read -r line; do
        id=$(echo "$line"   | sed -nE 's/.*_id=([0-9]+).*/\1/p')
        ad=$(echo "$line"   | sed -nE 's/.*address=([^,]*), body=.*/\1/p')
        bd=$(echo "$line"   | sed -nE 's/.*body=(.*), date=.*/\1/p')
        dt=$(echo "$line"   | sed -nE 's/.*date=([0-9]+).*/\1/p')
        rd=$(echo "$line"   | sed -nE 's/.*read=([0-9]+).*/\1/p')
        "$JQ" -nc --arg id "$id" --arg ad "$ad" --arg bd "$bd" --argjson dt "${dt:-0}" --argjson rd "${rd:-0}" \
            '{id:$id,address:$ad,body:$bd,date_ms:$dt,read:$rd}'
      done | "$JQ" -sc '{messages:.}'
}
sms_send(){ to="$1"; text=$(printf '%s' "$2" | head -c 140)
    payload=$(printf 'AT+CMGS="%s"\r\n%s\x1A' "$to" "$text")
    "$SENDAT" -c "$payload" -n 0 >/dev/null 2>&1; }
sms_delete(){ content delete --uri content://sms/inbox --where "_id=$1" 2>/dev/null; }
```

- [ ] **Step 2: Doğrula (gelen kutusu okuma)**
```bash
push lib/core/sms.sh $DEV/lib/core/sms.sh
run ". $DEV/lib/core/sms.sh; sms_list_json 5" | jq -e '.messages|type=="array"' && echo OK
```
Expected: `{messages:[...]}` geçerli; `OK`. (Gönderme testi Task 13'te uzaktan-komut ile.)

- [ ] **Step 3: Commit** `git add lib/core/sms.sh && git commit -m "feat: lib/core/sms.sh — oku/gönder/sil"`

---

### Task 8: `lib/action.sh` — dispatcher

**Files:**
- Create: `lib/action.sh`

**Interfaces:**
- Consumes: tüm `lib/core/*.sh`.
- Produces: `action.sh <verb> [json-arg]` → tek satır JSON. Bu task'ta verb'ler: `status`, `signal`, `cellinfo`, `sms_list`, `airplane`. Sonraki fazlar verb ekler.

- [ ] **Step 1: action.sh yaz**
```sh
#!/system/bin/sh
D="${0%/lib/action.sh}"; [ -d "$D/lib" ] || D=/data/adb/modules/dikec-control-panel
. "$D/lib/core/env.sh"
. "$D/lib/core/system.sh"; . "$D/lib/core/at.sh"; . "$D/lib/core/sms.sh"
VERB="$1"; ARG="$2"
case "$VERB" in
  status)    j_ok "$(sys_status_json)";;
  signal)    j_ok "$(at_signal_json)";;
  cellinfo)  j_ok "$(at_cellinfo_json)";;
  sms_list)  j_ok "$(sms_list_json "${ARG:-20}")";;
  airplane)  at_airplane "$ARG" && j_ok '{}' || j_err "airplane $ARG başarısız";;
  *)         j_err "bilinmeyen verb: $VERB";;
esac
```
> Not: `j_ok "$(sys_status_json)"` — sys_status_json zaten JSON nesnesi döndürür; `j_ok` onu `{ok:true}` ile birleştirir.

- [ ] **Step 2: Doğrula (uçtan uca dispatcher)**
```bash
push lib/action.sh $DEV/lib/action.sh
for v in status signal cellinfo "sms_list 3"; do run "$DEV/lib/action.sh $v" | jq -e '.ok==true' >/dev/null && echo "OK $v"; done
run "$DEV/lib/action.sh nope" | jq -e '.ok==false' >/dev/null && echo OK-err
```
Expected: `OK status`,`OK signal`,`OK cellinfo`,`OK sms_list 3`,`OK-err`.

- [ ] **Step 3: Commit** `git add lib/action.sh && git commit -m "feat: lib/action.sh dispatcher — status/signal/cellinfo/sms_list/airplane"`

---

## Phase 3 — Xray motoru + yönlendirme + import

### Task 9: xray + hev-socks5-tunnel binary'leri + config şablonu

**Files:**
- Create: `system/bin/xray` (arm64 statik — indir)
- Create: `system/bin/hev-socks5-tunnel` (arm64 statik — indir)
- Create: `xray/config.tpl.json`
- Create: `xray/assets/{geoip.dat,geosite.dat}` (xray release'ten)

**Interfaces:**
- Produces: `$DCP_MOD/system/bin/xray`, `hev-socks5-tunnel`; şablon socks-in `127.0.0.1:10808` + outbound iskeleti `__OUTBOUND__` placeholder.

- [ ] **Step 1: Binary'leri indir (arm64) ve doğrula**
```bash
cd /Users/kaandikec/f50-remote-adb/magisk-modules/dikec-control-panel
mkdir -p system/bin xray/assets
# Xray-core arm64 (Xray-linux-arm64-v8a.zip)
curl -fsSL -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip
unzip -o /tmp/xray.zip xray geoip.dat geosite.dat -d /tmp/xrayx
cp /tmp/xrayx/xray system/bin/xray
cp /tmp/xrayx/geoip.dat /tmp/xrayx/geosite.dat xray/assets/
# hev-socks5-tunnel arm64 statik
curl -fsSL -o system/bin/hev-socks5-tunnel \
  https://github.com/heiher/hev-socks5-tunnel/releases/latest/download/hev-socks5-tunnel-linux-arm64
file system/bin/xray | grep -q 'ARM aarch64' && echo OK-xray
```
Expected: `OK-xray` (ELF arm64). hev binary boyutu > 0.

- [ ] **Step 2: config.tpl.json yaz** (tun0 modu için socks-in + dns; outbound `__OUTBOUND__` import ile doldurulur — zte config.json + xray-import iskeletinden uyarlı)
```json
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag":"socks-in","listen":"127.0.0.1","port":10808,"protocol":"socks",
     "settings":{"udp":true},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}
  ],
  "outbounds": [ __OUTBOUND__,
    {"tag":"direct","protocol":"freedom"},
    {"tag":"block","protocol":"blackhole"}
  ],
  "routing": {"domainStrategy":"AsIs","rules":[
    {"type":"field","ip":["geoip:private"],"outboundTag":"direct"}
  ]}
}
```

- [ ] **Step 3: Doğrula (cihazda xray çalışıyor mu)**
```bash
push system/bin/xray $DEV/system/bin/xray
run "$DEV/system/bin/xray version" | head -1
```
Expected: `Xray <sürüm>` satırı.

- [ ] **Step 4: Commit** (binary'ler .gitignore'a takılmaz; LFS yoksa zip dışı tutulur — burada repoya ekliyoruz)
```bash
git add -f system/bin/xray system/bin/hev-socks5-tunnel xray/config.tpl.json xray/assets
git commit -m "feat: xray + hev-socks5-tunnel binary'leri + config şablonu"
```

---

### Task 10: `lib/core/profiles.sh` — vmess/vless/trojan + abonelik import

**Files:**
- Create: `lib/core/profiles.sh`
- Reference (port): `/tmp/zte-g5-cpe-xray/rootfs/usr/bin/xray-import`

**Interfaces:**
- Consumes: `env.sh`, `xray/config.tpl.json`.
- Produces: `prof_import_link(uri)` → profil dosyası `$DCP_DATA/xray/profiles/config-<ad>.json`, JSON `{name,protocol,server,port}`; `prof_import_sub(url)` → `{imported:N,failed:M}`; `prof_list_json()`; `prof_switch(name)`; `prof_active()`.

- [ ] **Step 1: profiles.sh yaz — xray-import portu**
  - `/tmp/zte-g5-cpe-xray/rootfs/usr/bin/xray-import` (1-166) MANTIĞINI taşı: `build_stream()` (tcp/ws/http/grpc/kcp + tls/reality/none), vmess (base64→JSON: add/port/id/aid/scy/net/tls/sni/host/path/alpn/fp), vless (`vless://uuid@host:port?query#name` + flow/encryption), trojan (`trojan://pass@host:port?query#name`).
  - **F50 adaptasyonu:** zte şablonu dokodemo/tproxy inbound'lu; bunun yerine `xray/config.tpl.json`'daki **socks-in** şablonuna `__OUTBOUND__` enjekte et (tun0 modu). tproxy modunda dokodemo şablonu kullanılır (Task 11). Doğrulama: `$DCP_MOD/system/bin/xray run -test -config <dosya>`.
  - `prof_import_sub`: `fetch_url` (curl --max-time 20, max 200KB) → base64 değilse satır listesi; URL-safe base64 decode (`-_`→`+/`) → `^(vmess|vless|trojan)://` filtrele → her biri için `prof_import_link`.
  - Profil adı: URI fragment (#name) → yoksa host ilk 12 alfanümerik; sanitize `[A-Za-z0-9._-]`, max 40; `config-<ad>.json`.

- [ ] **Step 2: Doğrula (gerçek bir vless/trojan linki ile — test linki kullan)**
```bash
push lib/core/profiles.sh $DEV/lib/core/profiles.sh
run ". $DEV/lib/core/profiles.sh; prof_import_link 'vless://11111111-1111-1111-1111-111111111111@example.com:443?security=tls&sni=example.com&type=ws&path=%2Fws#testprof'" | jq -e '.protocol=="vless" and .server=="example.com"' && echo OK-import
run "$DEV/system/bin/xray run -test -config $DCP_DATA/xray/profiles/config-testprof.json && echo VALID"
```
Expected: `OK-import`; xray config testi `VALID`.

- [ ] **Step 3: Commit** `git add lib/core/profiles.sh && git commit -m "feat: profiles.sh — vmess/vless/trojan + abonelik import (xray-import portu)"`

---

### Task 11: `lib/core/routing.sh` + `lib/core/xray.sh` — tun0/tproxy + supervisor

**Files:**
- Create: `lib/core/routing.sh`
- Create: `lib/core/xray.sh`
- Reference: vpn-gateway `service.sh` (tun0 bekler), zte `tproxy.sh` (TPROXY).

**Interfaces:**
- Consumes: `env.sh`, `profiles.sh`. `route_mode` = `cfg_get route_mode tun0`.
- Produces: `xray_start()`, `xray_stop()`, `xray_status_json()`; `route_apply(mode)`, `route_clear()`; `bypass_add(ip)`, `bypass_del(ip)`.
  - **tun0 modu:** xray (socks 10808) başlat → `hev-socks5-tunnel` config (`tun0`, socks5 127.0.0.1:10808) ile tun0'ı ayağa kaldır → vpn-gateway kuralları LAN→tun0 taşır (vpn-gateway kurulu değilse uyar). `route_apply tun0`: tun0 link/route, ip rule.
  - **tproxy modu:** xray dokodemo-door config + iptables TPROXY/mangle (zte tproxy.sh portu).

- [ ] **Step 1: xray.sh + routing.sh yaz** (hev config üret: `tunnel: {name: tun0, mtu: 8500}`, `socks5: {address:127.0.0.1, port:10808, udp:'udp'}`; xray supervisor pid `/data/dikec/xray/xray.pid`)

- [ ] **Step 2: Doğrula (tun0 modu — gerçek tünel + IP değişimi)**
```bash
push -r lib/core $DEV/lib/core  # tüm core
run "echo 1 > $DCP_DATA/conf/xray_enabled; $DEV/lib/action.sh prof_switch testprof; $DEV/lib/action.sh xray_start"
run "$DEV/lib/action.sh xray_status" | jq -e '.running==true'
run "ip addr show tun0 2>/dev/null | grep -q tun0 && echo TUN-OK"
```
Expected: xray çalışıyor; `TUN-OK`. (Gerçek bir profil ile çıkış IP testi: `curl --socks5 127.0.0.1:10808 ifconfig.me`.)

- [ ] **Step 3: Commit** `git add lib/core/xray.sh lib/core/routing.sh && git commit -m "feat: xray.sh + routing.sh — tun0/tproxy yönlendirme, bypass"`

---

### Task 12: action.sh'a xray/profil/route verb'lerini ekle

**Files:**
- Modify: `lib/action.sh`

**Interfaces:**
- Produces: yeni verb'ler: `xray_start`,`xray_stop`,`xray_status`,`prof_list`,`prof_switch <ad>`,`prof_import <uri>`,`prof_import_sub <url>`,`prof_probe <ad>`,`route_mode <tun0|tproxy>`,`bypass_add <ip>`,`bypass_del <ip>`.

- [ ] **Step 1: action.sh case bloğunu genişlet** (profiles.sh, xray.sh, routing.sh source et; her verb ilgili fonksiyonu çağırıp `j_ok`/`j_err` döner)
- [ ] **Step 2: Doğrula**
```bash
push lib/action.sh $DEV/lib/action.sh
run "$DEV/lib/action.sh prof_list" | jq -e '.ok==true and (.profiles|type=="array")'
run "$DEV/lib/action.sh route_mode tproxy" | jq -e '.ok==true'; run "cat $DCP_DATA/conf/route_mode"
```
Expected: profil listesi; route_mode `tproxy` yazıldı.
- [ ] **Step 3: Commit** `git commit -am "feat: action.sh — xray/profil/route verb'leri"`

---

## Phase 4 — SMS uzaktan-komut + adblock

### Task 13: `lib/core/sms_cmd.sh` — SMS uzaktan-komut motoru

**Files:**
- Create: `lib/core/sms_cmd.sh`
- Reference (port): `/tmp/zte-g5-cpe-xray/rootfs/usr/bin/sms-control`

**Interfaces:**
- Consumes: `env.sh`, `sms.sh`, `action.sh` verb'leri.
- Produces: `smscmd_poll()` (yeni SMS'leri işle, son ts `$DCP_DATA/sms/last_ts`); `smscmd_handle(addr, body)`. Config `$DCP_DATA/conf/sms-control.conf`: `SMS_ENABLED, SMS_SECRET, SMS_ALLOW (virgül), SMS_REPLY`. Komutlar: `durum`, `vpn ac|kapat|yeniden|<profil>`, `vpn import <link>`, `ip`, `reboot`, `wifi on|off`, `locate`, `panic`. Auth: whitelist + secret + allow-list + rate-limit (max 2/dk). Gelen → Telegram forward (`notify.sh`).

- [ ] **Step 1: sms_cmd.sh yaz** (sms-control lines 64-149 auth/komut mantığı; SMS I/O `sms.sh` ile; `<SECRET> <komut>` parse; reply `sms_send`)
- [ ] **Step 2: Doğrula (kontrollü: kendine test komutu)**
```bash
push lib/core/sms_cmd.sh $DEV/lib/core/sms_cmd.sh
run "printf 'SMS_ENABLED=1\nSMS_SECRET=gizli42\nSMS_REPLY=true\n' > $DCP_DATA/conf/sms-control.conf"
run ". $DEV/lib/core/sms_cmd.sh; smscmd_handle '+900000000000' 'gizli42 durum'" | jq -e '.ok==true' && echo OK-cmd
run ". $DEV/lib/core/sms_cmd.sh; smscmd_handle '+900000000000' 'yanlis durum'" | jq -e '.ok==false' && echo OK-reject
```
Expected: doğru secret → `OK-cmd`; yanlış secret reddedilir → `OK-reject`.
- [ ] **Step 3: Commit** `git add lib/core/sms_cmd.sh && git commit -m "feat: sms_cmd.sh — SMS uzaktan-komut (sms-control portu)"`

---

### Task 14: `lib/core/adblock.sh` — dnsmasq sinkhole

**Files:**
- Create: `lib/core/adblock.sh`
- Create: `xray/dnsmasq-adblock.conf` (şablon)
- Reference (port): `/tmp/zte-g5-cpe-xray/rootfs/usr/bin/adblock-update`

**Interfaces:**
- Consumes: `env.sh`. `/system/bin/dnsmasq` (cihazda mevcut).
- Produces: `adblock_enable()` (ikinci dnsmasq `127.0.0.1:5354` + iptables PREROUTING REDIRECT br0:53→5354); `adblock_disable()`; `adblock_update()` (listeleri çek/parse → `$DCP_DATA/adblock/hosts`, `kill -HUP`); `adblock_status_json()` → `{enabled,domains,running}`.
  - dnsmasq başlat: `dnsmasq --no-daemon --port=5354 --listen-address=127.0.0.1 --addn-hosts=$DCP_DATA/adblock/hosts --server=127.0.0.1#53 --pid-file=$DCP_DATA/adblock/dnsmasq.pid --conf-file=/dev/null` (supervisor altında, `dikec` etiketiyle).
  - iptables: `iptables -t nat -I PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 5354` (+tcp). Çıkışta sil.
  - `adblock-update` portu: preset listeler (stevenblack/hagezi/adaby) + özel URL + whitelist; hosts/`||domain^`/plain parse → `0.0.0.0 domain` satırları; dedup.

- [ ] **Step 1: adblock.sh + şablon yaz**
- [ ] **Step 2: Doğrula (sinkhole çalışıyor mu)**
```bash
push lib/core/adblock.sh $DEV/lib/core/adblock.sh
run "printf '0.0.0.0 ads.example.test\n' > $DCP_DATA/adblock/hosts; . $DEV/lib/core/adblock.sh; adblock_enable"
run "nslookup ads.example.test 127.0.0.1 -port=5354 2>/dev/null | grep -q '0.0.0.0' && echo SINK-OK"
run ". $DEV/lib/core/adblock.sh; adblock_status_json" | jq -e '.running==true'
```
Expected: bloklu domain `0.0.0.0` → `SINK-OK`; status running.
- [ ] **Step 3: Commit** `git add lib/core/adblock.sh xray/dnsmasq-adblock.conf && git commit -m "feat: adblock.sh — dnsmasq sinkhole + iptables redirect"`

---

### Task 15: `lib/core/notify.sh` + `integrations.sh` + action.sh verb'leri

**Files:**
- Create: `lib/core/notify.sh`
- Create: `lib/core/integrations.sh`
- Modify: `lib/action.sh`

**Interfaces:**
- notify.sh: `tg_notify(text)` (token/chat `/data/dikec`), `sms_notify(to,text)`.
- integrations.sh: `intg_tailscale(sub)`, `intg_tor(sub)`, `intg_ssh(sub)`, `intg_adguard_removed_note()` — statusbot entegrasyon mantığı taşınır (tailscale-control/tor-relay/dropbear-ssh modülleri).
- action.sh verb'leri: `sms_send`,`sms_delete`,`smscmd_get`,`smscmd_set`,`adblock_*`,`tailscale`,`tor`,`ssh`,`notify_test`.

- [ ] **Step 1: notify.sh + integrations.sh yaz; action.sh genişlet**
- [ ] **Step 2: Doğrula**
```bash
push -r lib $DEV/lib
run "$DEV/lib/action.sh adblock_status" | jq -e '.ok==true'
run "$DEV/lib/action.sh smscmd_get" | jq -e '.ok==true'
```
Expected: ikisi de `ok:true`.
- [ ] **Step 3: Commit** `git commit -am "feat: notify + integrations + action.sh genişletme"`

---

## Phase 5 — Telegram bot (statusbot refactor + emeklilik)

### Task 16: bot.sh'ı lib/core üzerine taşı + yeni verb'ler

**Files:**
- Create: `bot/bot.sh` (statusbot `bot/bot.sh`'tan türet)
- Create: `bot/lang/<code>.sh` (statusbot lang/ kopyala)
- Reference: `magisk-modules/statusbot/bot/bot.sh` (5195 satır), `service.sh`.

**Interfaces:**
- Consumes: `lib/action.sh` (cihaz işlevleri artık buradan), `notify.sh`, long-poll altyapısı.
- Produces: çalışan bot; token/chat_id `/data/dikec`; `poll_*` fonksiyonları (heartbeat/schedules/sms_forward/tasks) tek döngüde; yeni komutlar `/xray`, `/import`, `/route`, gelişmiş `/sms_*`.

- [ ] **Step 1: bot.sh'ı kopyala ve refactor et**
  - `magisk-modules/statusbot/bot/bot.sh`'ı kopyala. Cihaz-işlevi yapan handler'ları (`/status`,`/signal`,`/cellinfo`,`/sms_*`,`/at`...) **doğrudan AT/proc çağırmak yerine** `"$DCP_MOD/lib/action.sh" <verb>` çağırıp JSON'u biçimleyecek şekilde değiştir (DRY: tek kaynak). Yol değişkenlerini `/data/statusbot`→`/data/dikec`, modül kökü→`dikec-control-panel` güncelle.
  - Yeni handler'lar: `/xray on|off|status|route tun0|tproxy`, `/import <link|sub>`, `/profiles`, `/probe`.
  - `poll_sms_forward` → `smscmd_poll` çağırsın (sms_cmd.sh).
- [ ] **Step 2: Doğrula (bot ayağa kalkıyor + bir komut)**
```bash
push -r bot $DEV/bot
run "echo '$TEST_TOKEN' > $DCP_DATA/token; echo '$TEST_CHAT' > $DCP_DATA/chat_id"   # test bot
run "$DEV/bot/bot.sh & sleep 8; grep -q 'long-poll\\|started' $DCP_DATA/logs/bot.log && echo BOT-OK; pkill -f bot.sh"
```
Expected: bot logu başladığını gösterir → `BOT-OK`. (Telegram'dan `/status` → panelle aynı JSON kaynaklı yanıt.)
- [ ] **Step 3: Commit** `git add -A bot && git commit -m "feat: bot.sh — statusbot refactor, action.sh üzerinden, xray/SMS komutları"`

---

## Phase 6 — Web panel

### Task 17: busybox httpd + api.cgi (dispatcher köprüsü) + auth

**Files:**
- Create: `www/httpd.conf`
- Create: `www/start-httpd.sh`
- Create: `www/api.cgi`
- Create: `www/auth.inc`

**Interfaces:**
- Consumes: `lib/action.sh`, `conf/{panel_token,lan_expose}`.
- Produces: `GET/POST /cgi-bin/api?verb=<v>` → action.sh JSON; localhost default bind, `lan_expose=1` ise `0.0.0.0` + basic-auth.

- [ ] **Step 1: start-httpd.sh** (lan_expose'a göre bind: `busybox httpd -p 127.0.0.1:8088 -h $DCP_MOD/www -c www/httpd.conf` veya `-p 0.0.0.0:8088`); auth.inc basic-auth (lan modunda).
- [ ] **Step 2: api.cgi** (QUERY_STRING'den verb+arg parse, token kontrol (localhost'ta panel_token, lan'da basic-auth), `exec $DCP_MOD/lib/action.sh "$verb" "$arg"`, `Content-Type: application/json`).
- [ ] **Step 3: Doğrula**
```bash
push -r www $DEV/www
run "$DEV/www/start-httpd.sh & sleep 2"
run "curl -s 'http://127.0.0.1:8088/cgi-bin/api?verb=status&token='\$(cat $DCP_DATA/conf/panel_token)" | jq -e '.ok==true' && echo HTTP-OK
adb -s $S forward tcp:8088 tcp:8088 && curl -s "http://127.0.0.1:8088/cgi-bin/api?verb=signal&token=$(adb -s $S shell su -c 'cat /data/dikec/conf/panel_token')" | jq .ok
```
Expected: cihaz-içi `HTTP-OK`; adb-forward ile host'tan da `true`.
- [ ] **Step 4: Commit** `git add -A www && git commit -m "feat: httpd + api.cgi — panel backend köprüsü + auth"`

---

### Task 18: SPA frontend (index.html + app.js + app.css)

**Files:**
- Create: `www/index.html`, `www/app.js`, `www/app.css`
- Reference: `/tmp/zte-g5-cpe-xray/rootfs/www_xray2/app.js` (UI desenleri, parseUri, importSub).

**Interfaces:**
- Consumes: `/cgi-bin/api?verb=...`.
- Produces: "Dikec Control Panel" SPA; sekmeler: Dashboard, Xray (profiller/import/route/probe), SMS (gelen kutusu/gönder/komut config), Cellular, Clients, Integrations, System. Sekme gizliyken polling durur (`document.hidden`), ayarlanabilir aralık.

- [ ] **Step 1: index.html kabuğu + app.css (marka, dark, hafif)**
- [ ] **Step 2: app.js** — `api(verb,arg)` fetch sarmalayıcı; her sekme render; xray import (zte app.js parseUri/importSub portu); SMS gönder/listele; route toggle; LAN-aç anahtarı. Framework yok.
- [ ] **Step 3: Doğrula (host tarayıcıdan adb-forward ile)**
```bash
adb -s $S forward tcp:8088 tcp:8088
echo "Tarayıcı: http://127.0.0.1:8088/?token=<panel_token> — Dashboard sinyal/durum dolu mu, Xray sekmesinde profil listesi geliyor mu, SMS sekmesi gelen kutusunu gösteriyor mu elle doğrula."
curl -s "http://127.0.0.1:8088/" | grep -q 'Dikec Control Panel' && echo SPA-OK
```
Expected: `SPA-OK`; elle: sekmeler canlı veri çekiyor.
- [ ] **Step 4: Commit** `git add -A www && git commit -m "feat: SPA — Dikec Control Panel arayüzü (Dashboard/Xray/SMS/...)"`

---

## Phase 7 — Self-update, kaynak sıkılaştırma, paketleme, uçtan uca

### Task 19: self-update + CI/zip + update.json

**Files:**
- Create: `lib/core/update.sh` (zte-update portu — `latest.txt` + SHA256 + reinstall)
- Create: `.github/workflows/release.yml` (bin-utils deseni — module.prop değişiminde release)
- Create: `tools/build-zip.sh` (yerel zip üretimi)
- Create: `update.json`

- [ ] **Step 1: update.sh + build-zip.sh + workflow + update.json yaz** (zte-update lines 1-... mantığı; build-zip: `zip -r dist/dikec-control-panel-<ver>.zip . -x '.git/*' 'docs/*' '*.zip'`).
- [ ] **Step 2: Doğrula (yerel zip kurulabilir mi)**
```bash
sh tools/build-zip.sh && unzip -l dist/dikec-control-panel-*.zip | grep -q module.prop && echo ZIP-OK
```
Expected: `ZIP-OK`.
- [ ] **Step 3: Commit** `git add -A && git commit -m "feat: self-update + CI release + build-zip"`

---

### Task 20: Kaynak sıkılaştırma + dcp-engine temizliği

**Files:**
- Modify: ilgili `lib/core/*` (cache TTL, log_rotate çağrıları), `bot/bot.sh` (poll aralıkları).

- [ ] **Step 1: Kaynak denetimi** — her supervisor/poll'da `log_rotate 524288`; cold cache 15s doğrula; xray kapalıyken process sayısı = httpd+bot.
```bash
run "echo 0 > $DCP_DATA/conf/xray_enabled; $DEV/lib/action.sh xray_stop"
run "ps -A -o RSS,CMD | grep -E 'bot.sh|httpd|xray|hev-socks5|dnsmasq.*dikec' | grep -v grep"
run "free -m | awk '/Mem:/{print \"free_mb=\"\$4}'"
```
Expected: xray/hev yok (kapalıyken); httpd+bot toplam RSS makul (< ~12 MB); free RAM kuruluma göre regresyon yok.
- [ ] **Step 2: dcp-engine temizliği**
```bash
run "touch /data/adb/modules/dcp-engine/remove 2>/dev/null; echo removed-flag"
rm -rf /Users/kaandikec/f50-remote-adb/dikec-control-panel  # eski top-level bozuk attempt
rm -f /Users/kaandikec/f50-remote-adb/dikec-control-panel/dcp-engine-v0.1.0-f50.zip 2>/dev/null
echo CLEANUP-OK
```
Expected: `removed-flag`, `CLEANUP-OK`.
- [ ] **Step 3: Commit** `git commit -am "perf: kaynak sıkılaştırma + dcp-engine temizliği"`

---

### Task 21: Uçtan uca cihaz testi (zip kur, reboot, doğrula)

- [ ] **Step 1: Temiz kurulum + reboot**
```bash
sh tools/build-zip.sh
adb -s $S push dist/dikec-control-panel-*.zip /data/local/tmp/dcp.zip
run "magisk --install-module /data/local/tmp/dcp.zip"   # veya panel/bot install_module
adb -s $S reboot; sleep 45; adb -s $S wait-for-device
```
- [ ] **Step 2: Servisler ayakta mı**
```bash
run "$DEV/lib/action.sh status" | jq -e '.ok==true'
run "ps -A | grep -E 'bot.sh|httpd' | grep -v grep | wc -l"   # >=2
adb -s $S forward tcp:8088 tcp:8088; curl -s "http://127.0.0.1:8088/" | grep -q 'Dikec Control Panel' && echo E2E-PANEL-OK
```
- [ ] **Step 3: Fonksiyonel kabul** (elle/komut): profil import → xray on (tun0) → vpn-gateway ile çıkış IP değişti → SMS gönder/oku → SMS uzaktan-komut → adblock sinkhole → bot `/status` panelle aynı. AdGuard Home kapalı, free RAM kazancı doğrula.
- [ ] **Step 4: Final commit + version bump**
```bash
git commit -am "test: uçtan uca cihaz kabul testi; v0.1.0 hazır"
```

---

## Self-Review Notları (planı yazan tarafından)

- **Spec kapsama:** §4.1–4.9 → Task 9-15; §2 dispatcher → Task 8; bot §4.6 → Task 16; panel §4.5 → Task 17-18; SMS §4.3 → Task 7,13; adblock §4.9 → Task 14; AGH kaldırma §6 → Task 2,20; kaynak §7 → Task 20; paketleme §6 → Task 19,21. Kapsam tam.
- **Tip tutarlılığı:** dispatcher sözleşmesi `{ok:...}` tüm verb'lerde; `prof_*`/`xray_*`/`sms_*`/`adblock_*` ad uzayları action.sh'ta birebir.
- **Bağımlılık sırası:** env→system/at/sms→action(temel)→xray/profiles/routing→sms_cmd/adblock/notify→bot→panel→paketleme. Her task kendi cihaz-doğrulamasıyla kapanır.
- **Açık riskler (yürütmede dikkat):** (1) hev-socks5-tunnel release asset adı sürümle değişebilir — indirmede doğrula. (2) `supervisor_loop` gerçek imzasını bin-utils'tan teyit et. (3) tproxy modu mangle/route_table detayları cihazda iteratif test ister. (4) content provider SMS sütun sırası cihaza göre değişebilir — sms-cmd parse'ı referans.
