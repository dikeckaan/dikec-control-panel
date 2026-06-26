#!/system/bin/sh
# lib/core/sms_cmd.sh — SMS uzaktan-komut motoru
# Ported from /tmp/zte-g5-cpe-xray/rootfs/usr/bin/sms-control (F50 adaptation).
#
# Fonksiyonlar:
#   smscmd_handle <addr> <body>  →  tek satır JSON {ok:..}
#   smscmd_poll()                →  inbox'u tara, yeni SMS'leri işle
#
# Config: $DCP_DATA/conf/sms-control.conf (env-style, kayıpsız source edilir)
#   SMS_ENABLED=0|1     — kanal aktif mi (varsayılan 0 = kapalı)
#   SMS_SECRET=<metin>  — gelen SMS'in ilk kelimesi bu olmalı
#   SMS_ALLOW=+90x,...  — virgüllü beyaz-liste (boşsa herkese izin)
#   SMS_REPLY=true|false — yanıt SMS'i gönder (test için false)
#
# Komut formatı: <SECRET> <komut> [alt] [arg]
#   durum                  → xray/sistem durumu
#   vpn ac|baslat          → xray_start
#   vpn kapat|durdur       → xray_stop
#   vpn yeniden            → xray_stop + xray_start
#   vpn <profil>           → prof_switch + xray restart
#   vpn import <link>      → prof_import + prof_switch + xray start
#   ip                     → WAN + VPN çıkış IP
#   reboot                 → cihazı yeniden başlat (gecikmeli)
#   wifi on|off            → hotspot geçişi (best-effort)
#   locate                 → hücre konumu (şimdilik desteklenmiyor)
#   panic                  → acil uyarı logu
#
# GÜVENLİK: SMS gövdesi asla eval edilmez. Dispatch yalnızca sabit
#   verb tablosuna göre yapılır; argümanlar action.sh'a tek argv
#   elemanı olarak geçilir (kabuk genişlemesi olmaz).

[ -n "${_SMS_CMD_SH_LOADED:-}" ] && return 0
_SMS_CMD_SH_LOADED=1

. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/sms.sh"

_SMSCMD_CONF="${DCP_DATA}/conf/sms-control.conf"
_SMSCMD_RL="${DCP_DATA}/sms/ratelimit"
_SMSCMD_TS="${DCP_DATA}/sms/last_ts"
_SMSCMD_LOG="${DCP_DATA}/logs/sms_cmd.log"

# ── config yükle ──────────────────────────────────────────────────────────────
_smscmd_load_conf() {
    SMS_ENABLED=0
    SMS_SECRET=""
    SMS_ALLOW=""
    SMS_REPLY="true"
    [ -f "$_SMSCMD_CONF" ] && . "$_SMSCMD_CONF" 2>/dev/null
}

# ── log satırı ────────────────────────────────────────────────────────────────
_slog() {
    mkdir -p "${DCP_DATA}/logs"
    printf '[%s] sms_cmd: %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$*" \
        >> "$_SMSCMD_LOG" 2>/dev/null
}

# ── rate-limit: 60 saniyede en fazla 2 komut ─────────────────────────────────
# Döner 0 = izinli, 1 = limit aşıldı.
# Her çağrıda mevcut timestamp'i yazar (reddedilenleri de sayar → burst engeli).
_smscmd_ratelimit_check() {
    mkdir -p "$(dirname "$_SMSCMD_RL")"
    now=$(date +%s 2>/dev/null || echo 0)
    cutoff=$((now - 60))
    # Bu denemeyi kaydet
    printf '%s\n' "$now" >> "$_SMSCMD_RL"
    # Son 60 saniyedeki kayıt sayısı (bu deneme dahil)
    count=$(awk -v c="$cutoff" 'int($1)>c' "$_SMSCMD_RL" 2>/dev/null | wc -l)
    # Eski kayıtları temizle
    _rl_tmp="${_SMSCMD_RL}.tmp.$$"
    awk -v c="$cutoff" 'int($1)>c' "$_SMSCMD_RL" 2>/dev/null > "$_rl_tmp" \
        && mv "$_rl_tmp" "$_SMSCMD_RL" 2>/dev/null \
        || rm -f "$_rl_tmp" 2>/dev/null
    [ "$count" -le 2 ]
}

# ── komut dispatch (sabit verb tablosu — eval YOK) ──────────────────────────
# $1=cmd $2=sub $3=rest/link   Tümü lowercased dışında rest (URL büyük/küçük korunsun)
_smscmd_dispatch() {
    local cmd="${1:-}" sub="${2:-}" rest="${3:-}"
    local act="${DCP_MOD}/lib/action.sh"
    local r ok name

    case "$cmd" in

        # ── durum ────────────────────────────────────────────────────────────
        durum|status|"")
            r=$("$act" status 2>/dev/null)
            printf '%s' "$r"
            ;;

        # ── vpn kontrol ──────────────────────────────────────────────────────
        vpn)
            case "$sub" in
                ac|baslat|start)
                    r=$("$act" xray_start 2>/dev/null)
                    printf '%s' "$r"
                    ;;
                kapat|durdur|stop)
                    r=$("$act" xray_stop 2>/dev/null)
                    printf '%s' "$r"
                    ;;
                yeniden|restart)
                    "$act" xray_stop >/dev/null 2>&1
                    sleep 2
                    r=$("$act" xray_start 2>/dev/null)
                    printf '%s' "$r"
                    ;;
                import)
                    [ -n "$rest" ] || { j_err "vpn import: link gerekli"; return; }
                    # rest = tek argüman (URL), action.sh'a doğrudan geçilir
                    r=$("$act" prof_import "$rest" 2>/dev/null)
                    ok=$(printf '%s' "$r" | "$JQ" -r '.ok' 2>/dev/null)
                    if [ "$ok" = "true" ]; then
                        name=$(printf '%s' "$r" | "$JQ" -r '.name // empty' 2>/dev/null)
                        if [ -n "$name" ]; then
                            "$act" prof_switch "$name" >/dev/null 2>&1
                            sleep 2
                            "$act" xray_start >/dev/null 2>&1
                        fi
                    fi
                    printf '%s' "$r"
                    ;;
                "")
                    j_err "vpn: alt komut gerekli (ac|kapat|yeniden|<profil>|import <link>)"
                    ;;
                *)
                    # vpn <profil> → profil geç + xray yeniden başlat
                    r=$("$act" prof_switch "$sub" 2>/dev/null)
                    ok=$(printf '%s' "$r" | "$JQ" -r '.ok' 2>/dev/null)
                    if [ "$ok" = "true" ]; then
                        "$act" xray_stop >/dev/null 2>&1
                        sleep 1
                        "$act" xray_start >/dev/null 2>&1
                    fi
                    printf '%s' "$r"
                    ;;
            esac
            ;;

        # ── ip ───────────────────────────────────────────────────────────────
        ip)
            wan=$(ip route get 1.1.1.1 2>/dev/null \
                | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)
            ext=$("$CURL" -s --max-time 8 https://api.ipify.org 2>/dev/null \
                || printf '?')
            "$JQ" -nc --arg wan "${wan:-?}" --arg ext "$ext" \
                '{ok:true, wan:$wan, exit_ip:$ext}'
            ;;

        # ── reboot ───────────────────────────────────────────────────────────
        reboot)
            "$JQ" -nc '{ok:true, msg:"Cihaz yeniden baslatiliyor (5s)"}'
            # Yanıt gönderilebilmesi için 5 saniye bekle, sonra reboot
            ( sleep 5; /system/bin/reboot ) &
            ;;

        # ── wifi ─────────────────────────────────────────────────────────────
        wifi)
            case "$sub" in
                on|off)
                    if svc wifi "$sub" 2>/dev/null; then
                        "$JQ" -nc --arg s "$sub" '{ok:true, wifi:$s}'
                    else
                        j_err "wifi $sub komutu basarisiz (root/svc gerekli)"
                    fi
                    ;;
                *)
                    j_err "wifi: on veya off gerekli"
                    ;;
            esac
            ;;

        # ── locate ───────────────────────────────────────────────────────────
        locate)
            j_err "locate: hucre konumlama bu surumde desteklenmiyor"
            ;;

        # ── panic ────────────────────────────────────────────────────────────
        panic)
            _slog "PANIC komutu alindi!"
            "$JQ" -nc '{ok:true, msg:"PANIC: acil uyari tetiklendi"}'
            ;;

        # ── bilinmeyen ───────────────────────────────────────────────────────
        *)
            j_err "bilinmeyen komut: $cmd"
            ;;
    esac
}

# ── smscmd_handle <addr> <body> ───────────────────────────────────────────────
# body = "<SECRET> <komut> [alt] [arg...]"   — eval EDİLMEZ, yalnız string split.
# Döner: tek satır JSON {ok:true,...} veya {ok:false,err:...}
smscmd_handle() {
    local addr="${1:-}" body="${2:-}"
    local secret cmd_line cmd1 cmd1_lc sub1 sub1_lc rest1 remaining
    local result reply_text norm_addr _NOTIFY_SH

    _smscmd_load_conf

    # 1. Kanal aktif mi?
    [ "${SMS_ENABLED:-0}" = "1" ] || { j_err "SMS kanal devre disi (SMS_ENABLED!=1)"; return; }

    # 2. Secret tanımlı mı?
    [ -n "${SMS_SECRET:-}" ] || { j_err "SMS_SECRET tanimlanmamis"; return; }

    # 3. Gövdeden secret'ı ayır: ilk kelime = secret  (IFS split değil, shell pattern)
    secret="${body%% *}"
    cmd_line=""
    [ "$body" != "$secret" ] && cmd_line="${body#* }"

    # 4. Beyaz-liste kontrolü (set ise ve numara dışarıdaysa → sessiz red, silme yok)
    if [ -n "${SMS_ALLOW:-}" ]; then
        norm_addr=$(printf '%s' "$addr" | sed 's/[^0-9+]//g')
        _wl_match=0
        case ",$SMS_ALLOW," in *",$norm_addr,"*) _wl_match=1 ;; esac
        [ "$_wl_match" = "0" ] && case ",$SMS_ALLOW," in *",$addr,"*) _wl_match=1 ;; esac
        if [ "$_wl_match" = "0" ]; then
            _slog "whitelist reddi: $addr"
            j_err "yetkisiz numara"
            return
        fi
    fi

    # 5. Secret karşılaştırması — tam eşleşme (sabit uzunluk olmasa da
    #    gövde eval edilmediği için enjeksiyon riski taşımıyor).
    if [ "$secret" != "$SMS_SECRET" ]; then
        _slog "yanlis secret, gonderen: $addr"
        j_err "yetkilendirme hatasi"
        return
    fi

    # 6. Rate-limit (max 2 / 60s)
    if ! _smscmd_ratelimit_check; then
        _slog "rate-limit asildi, gonderen: $addr"
        j_err "rate-limit: cok fazla komut (maks 2/dk)"
        return
    fi

    # 7. cmd_line parse: kelime kelime, kesinlikle eval kullanmadan
    cmd1="" sub1="" rest1=""
    if [ -n "$cmd_line" ]; then
        cmd1="${cmd_line%% *}"
        cmd1_lc=$(printf '%s' "$cmd1" | tr 'A-Z' 'a-z')
        remaining=""
        [ "$cmd_line" != "$cmd1" ] && remaining="${cmd_line#* }"
        if [ -n "$remaining" ]; then
            sub1="${remaining%% *}"
            sub1_lc=$(printf '%s' "$sub1" | tr 'A-Z' 'a-z')
            [ "$remaining" != "$sub1" ] && rest1="${remaining#* }"
        else
            sub1_lc=""
        fi
        cmd1="$cmd1_lc"
        sub1="${sub1_lc:-}"
    fi

    _slog "komut: addr=$addr cmd='$cmd1' sub='$sub1'"

    # 8. Dispatch (sabit tablo — eval yok; rest URL büyük/küçük harf korumalı)
    result=$(_smscmd_dispatch "$cmd1" "$sub1" "$rest1")

    # Boş sonuç güvenliği
    [ -n "$result" ] || result=$(j_err "dispatch sonuc donmedi")

    # 9. SMS yanıtı (SMS_REPLY=true ise; test için false)
    if [ "${SMS_REPLY:-true}" = "true" ]; then
        reply_text=$(printf '%s' "$result" | "$JQ" -r '
            if .ok then (.msg // (. | tostring))
            else "HATA: \(.err // "bilinmeyen hata")"
            end
        ' 2>/dev/null) || reply_text="$result"
        sms_send "$addr" "$reply_text" 2>/dev/null || true
    fi

    # 10. Telegram forward (notify.sh Task 15'te gelecek — yoksa sadece log)
    _NOTIFY_SH="${DCP_MOD}/lib/core/notify.sh"
    if [ -f "$_NOTIFY_SH" ]; then
        # shellcheck source=/dev/null
        . "$_NOTIFY_SH" 2>/dev/null
        notify_telegram "SMS komut [$addr]: $cmd1 $sub1" 2>/dev/null || true
    else
        _slog "notify.sh mevcut degil, Telegram forward atlandi"
    fi

    printf '%s\n' "$result"
}

# ── smscmd_poll ───────────────────────────────────────────────────────────────
# Inbox'u tara; last_ts'ten yeni SMS'leri smscmd_handle'a ilet, sonra sil.
smscmd_poll() {
    local last_ts new_ts count i msg date_ms date_s addr body sms_id

    _smscmd_load_conf
    [ "${SMS_ENABLED:-0}" = "1" ] || return 0

    mkdir -p "${DCP_DATA}/sms"

    last_ts=0
    [ -f "$_SMSCMD_TS" ] && last_ts=$(cat "$_SMSCMD_TS" 2>/dev/null || echo 0)
    new_ts="$last_ts"

    msgs=$(sms_list_json 30 2>/dev/null) || return 0
    count=$(printf '%s' "$msgs" | "$JQ" -r '.messages | length' 2>/dev/null || echo 0)

    i=0
    while [ "$i" -lt "${count:-0}" ]; do
        msg=$(printf '%s' "$msgs" | "$JQ" -c ".messages[$i]" 2>/dev/null)
        date_ms=$(printf '%s' "$msg" | "$JQ" -r '.date_ms' 2>/dev/null || echo 0)
        date_s=$((date_ms / 1000))

        if [ "$date_s" -gt "$last_ts" ]; then
            addr=$(printf '%s' "$msg" | "$JQ" -r '.address' 2>/dev/null)
            body=$(printf '%s' "$msg" | "$JQ" -r '.body' 2>/dev/null)
            sms_id=$(printf '%s' "$msg" | "$JQ" -r '.id' 2>/dev/null)

            [ "$date_s" -gt "$new_ts" ] && new_ts="$date_s"

            _slog "poll: SMS $sms_id gonderen=$addr"
            smscmd_handle "$addr" "$body"

            # İşlenen SMS'i sil (referans davranışı)
            sms_delete "$sms_id" 2>/dev/null || true
        fi

        i=$((i + 1))
    done

    # last_ts'i ilerlet
    printf '%s\n' "$new_ts" > "$_SMSCMD_TS"
}
