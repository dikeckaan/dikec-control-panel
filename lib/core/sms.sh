#!/system/bin/sh
# lib/core/sms.sh — SMS oku / gönder / sil
# Gereksinimler: env.sh (JQ, SENDAT)
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"

# sms_list_json <limit=20>
# → {messages:[{id,address,body,date_ms,read}]}
# Her satır: Row: N _id=X, address=Y, body=<serbest metin içerir virgül/URL>, date=<13 rakam>, read=<0|1>
# Body parse: gözü greedy tutup sona `, date=[0-9]+, read=[0-9]+` ile demirle.
sms_list_json(){
    n="${1:-20}"
    content query --uri content://sms/inbox \
        --projection _id:address:body:date:read \
        --sort 'date DESC' 2>/dev/null \
    | head -n "$n" \
    | while IFS= read -r line; do
        # Sadece Row: satırlarını işle
        case "$line" in Row:*) ;; *) continue ;; esac
        id=$(printf '%s\n' "$line" | sed -nE 's/.*_id=([0-9]+),.*/\1/p')
        [ -z "$id" ] && continue
        ad=$(printf '%s\n' "$line" | sed -nE 's/.*address=([^,]*), body=.*/\1/p')
        # Body: greedy — trailer `, date=<13 rakam>, read=<0|1>` satır sonu ile demirlenmiş
        bd=$(printf '%s\n' "$line" | sed -nE 's/.*body=(.*), date=[0-9]+, read=[0-9]+$/\1/p')
        # date: son `, date=<rakamlar>, read=` örüntüsüne demirle (body içindeki "date=" metnini atla)
        dt=$(printf '%s\n' "$line" | sed -nE 's/.*, date=([0-9]+), read=[0-9]+$/\1/p')
        rd=$(printf '%s\n' "$line" | sed -nE 's/.*read=([0-9]+)$/\1/p')
        "$JQ" -nc \
            --arg   id "$id" \
            --arg   ad "$ad" \
            --arg   bd "$bd" \
            --argjson dt "${dt:-0}" \
            --argjson rd "${rd:-0}" \
            '{id:$id,address:$ad,body:$bd,date_ms:$dt,read:$rd}'
    done | "$JQ" -sc '{messages:.}'
}

# ── SMS gönderme — çok katmanlı (isms → AT fallback) ────────────────────────
#
# GÜVENLİK: girdi Task 13 (SMS uzaktan-kontrol) + web panelinden gelir = güvenilmez.
# - Numara yalnızca rakam ve baştaki + olabilir (komut enjeksiyonu engeli).
# - Gövdeden CR/LF/0x1A (Ctrl-Z) çıkarılır.
#
# Unisoc (Spreadtrum) modemlerde AT+CMGS çalışmaz; bu yüzden birincil yöntem
# Android'in dahili telephony servisi "service call isms" kullanılır.
# AT+CMGS yalnızca fallback olarak tutulur.

# ── isms method numarası tespiti ─────────────────────────────────────────────
# sendTextForSubscriber method numarası Android sürümüne ve OEM'e göre değişir.
# AOSP Android 13: method 5, bazı OEM'ler: method 7.
# Çalışan method cache'lenir (_ISMS_METHOD değişkeninde).
_ISMS_METHOD=""
_ISMS_SUBID=""

_sms_isms_available(){
    # Servis mevcut mu?
    service check isms >/dev/null 2>&1 || return 1
    case "$(service check isms 2>/dev/null)" in
        *"not found"*) return 1 ;;
    esac
    # Android 5+ gerekli (SDK >= 21)
    local sdk
    sdk=$(getprop ro.build.version.sdk 2>/dev/null)
    [ "${sdk:-0}" -ge 21 ] 2>/dev/null || return 1
    return 0
}

_sms_get_subid(){
    # SIM slot (subId): cache'le
    [ -n "$_ISMS_SUBID" ] && { printf '%s' "$_ISMS_SUBID"; return; }
    _ISMS_SUBID=$(settings get global multi_sim_data_call 2>/dev/null)
    case "$_ISMS_SUBID" in
        ''|null|*[!0-9]*) _ISMS_SUBID=0 ;;
    esac
    printf '%s' "$_ISMS_SUBID"
}

# ── Tek deneme: belirli method numarasıyla isms çağrısı ──────────────────────
_sms_try_isms(){
    local method="$1" sub_id="$2" to="$3" text="$4"

    # service call isms <method> i32 <subId> s16 <callingPkg> s16 <attrTag>
    #   s16 <destAddr> s16 <scAddr> s16 <text> s16 <sentIntent>
    #   s16 <deliveryIntent> i32 <persistMessage> i64 <messageId>
    local result
    result=$(service call isms "$method" \
        i32 "$sub_id" \
        s16 "com.android.mms.service" \
        s16 "null" \
        s16 "$to" \
        s16 "null" \
        s16 "$text" \
        s16 "null" \
        s16 "null" \
        i32 1 \
        i64 0 2>&1)

    # Açık hata durumları → kesin başarısız
    case "$result" in
        *"Exception"*|*"rror"*|*"Unknown"*|"") return 1 ;;
    esac

    # Parcel dönmüşse, SMS gönderilmiş olabilir — doğrula
    # void metod → "Result: Parcel(00000000    '...')" döner (boş Parcel)
    # Yanlış metod → genelde hâlâ Parcel döner ama farklı boyutta
    case "$result" in
        *"Parcel("*) return 0 ;;
        *) return 1 ;;
    esac
}

# ── content://sms/sent kontrolü — SMS gerçekten gitti mi? ────────────────────
_sms_verify_sent(){
    local to="$1"
    local before_ts="$2"
    # Numaranın son 7+ hanesini al (prefix farkları: +90, 090, 0 vb.)
    local tail
    tail=$(printf '%s' "$to" | tr -dc '0-9' | sed 's/^.*\(.\{7\}\)$/\1/')
    # Son birkaç saniyede gönderilmiş SMS var mı?
    local row
    row=$(content query --uri content://sms/sent \
        --projection address:date \
        --sort 'date DESC' \
        --where "date>$before_ts" 2>/dev/null \
        | head -5)
    # Satırlardan birinde numara eşleşiyor mu?
    printf '%s\n' "$row" | while IFS= read -r line; do
        case "$line" in Row:*) ;; *) continue ;; esac
        case "$line" in *"$tail"*) return 0 ;; esac
    done
    # Subshell dönüş değerini yakala
    [ $? -eq 0 ] && return 0
    return 1
}

# ── Birincil: service call isms ──────────────────────────────────────────────
# Android framework SMS stack'ini kullanır — modem AT katmanını bypass eder.
# Unisoc dahil tüm işlemcilerde çalışır.
# Method numarasını ilk başarılı denemede cache'ler.
_sms_send_isms(){
    local to="$1" text="$2"
    _sms_isms_available || return 1

    local sub_id
    sub_id=$(_sms_get_subid)

    # Zaman damgası: gönderim sonrası doğrulama için (milisaniye)
    local ts_before
    ts_before=$(date +%s%3N 2>/dev/null || date +%s000 2>/dev/null)

    # Daha önce çalışan method varsa direkt onu dene
    if [ -n "$_ISMS_METHOD" ]; then
        _sms_try_isms "$_ISMS_METHOD" "$sub_id" "$to" "$text" || return 1
        # 2 saniye bekle, sent tablosundan doğrula
        sleep 2
        _sms_verify_sent "$to" "$ts_before" && return 0
        # Cache'lenmiş method artık çalışmıyor — sıfırla ve yeniden dene
        _ISMS_METHOD=""
    fi

    # Method 5 ve 7'yi sırayla dene (AOSP'de en yaygın ikisi)
    local m
    for m in 5 7; do
        ts_before=$(date +%s%3N 2>/dev/null || date +%s000 2>/dev/null)
        _sms_try_isms "$m" "$sub_id" "$to" "$text" || continue
        sleep 2
        if _sms_verify_sent "$to" "$ts_before"; then
            _ISMS_METHOD="$m"  # çalışan method'u cache'le
            return 0
        fi
    done

    return 1
}

# ── Fallback: AT+CMGS ────────────────────────────────────────────────────────
# Eski yöntem — Unisoc'ta çalışmaz ama diğer modemlerde (Qualcomm, MediaTek)
# hâlâ geçerli olabilir.
_sms_send_at(){
    local to="$1" text="$2"
    [ -x "$SENDAT" ] || return 1
    local payload
    payload=$(printf 'AT+CMGS="%s"\r\n%s\x1A' "$to" "$text")
    "$SENDAT" -c "$payload" -n 0 >/dev/null 2>&1
}

# ── sms_send <to> <text>  (maks 140 karakter) → 0=OK 1=hata ─────────────────
# Fallback zinciri: isms → AT → hata
sms_send(){
    case "$1" in
        ''|*[!0-9+]*) return 1 ;;  # yalnızca rakam ve baştaki +
    esac
    local to="$1"
    local text
    text=$(printf '%s' "$2" | tr -d '\r\n\032' | head -c 140)
    [ -z "$text" ] && return 1

    # 1) Birincil: Android isms servisi (modem bağımsız)
    _sms_send_isms "$to" "$text" && return 0

    # 2) Fallback: AT+CMGS (eski modemler için)
    _sms_send_at "$to" "$text" && return 0

    # 3) Her iki yöntem de başarısız
    return 1
}

# sms_delete <id>
# GÜVENLİK: $1 güvenilmez. Android `content` CLI parametre bağlama desteklemez,
# bu yüzden katı tamsayı doğrulaması (where-clause enjeksiyon engeli).
sms_delete(){
    case "$1" in
        ''|*[!0-9]*) return 1 ;;  # yalnızca pozitif tamsayı id
    esac
    content delete --uri content://sms/inbox --where "_id=$1" 2>/dev/null
}
