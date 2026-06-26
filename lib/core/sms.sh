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

# sms_send <to> <text>  (maks 140 karakter) → 0=OK 1=hata
# GÜVENLİK: girdi Task 13 (SMS uzaktan-kontrol) + web panelinden gelir = güvenilmez.
# - Numara yalnızca rakam ve baştaki + olabilir (AT komut enjeksiyonu engeli).
# - Gövdeden CR/LF/0x1A (Ctrl-Z) çıkarılır; bunlar SMS PDU'sunu erken bitirip
#   ardına AT komutu enjekte edilmesine izin verirdi. Meşru sonlandırıcı \x1A
#   payload'da KORUNUR, yalnızca kullanıcı metninden temizlenir.
sms_send(){
    case "$1" in
        ''|*[!0-9+]*) return 1 ;;  # yalnızca rakam ve baştaki +
    esac
    to="$1"
    text=$(printf '%s' "$2" | tr -d '\r\n\032' | head -c 140)
    payload=$(printf 'AT+CMGS="%s"\r\n%s\x1A' "$to" "$text")
    "$SENDAT" -c "$payload" -n 0 >/dev/null 2>&1
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
