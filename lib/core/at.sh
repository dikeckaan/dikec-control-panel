#!/system/bin/sh
# lib/core/at.sh — AT sinyal/cellinfo/airplane sarmalayıcıları (sendat)
# Tüketir: env.sh ($SENDAT, $JQ)
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"

# at_raw <AT komut> [slot=0] → ham modem cevabı (temizlenmiş)
at_raw(){
    [ -x "$SENDAT" ] || return 1
    "$SENDAT" -c "$1" -n "${2:-0}" 2>/dev/null \
        | tr -d '\r\0' \
        | sed 's/OK$//' \
        | head -c 600
}

# at_signal_json → {"csq":N,"rssi_dbm":N,"rsrp":"N","rsrq":"N"}
# AT+CSQ  → +CSQ: <rssi>,<ber>
# AT+CESQ → +CESQ: <rxlev>,<ber>,<rscp>,<ecno>,<rsrq_idx>,<rsrp_idx>[,...]
# (3GPP sırası: rsrq alan 5, rsrp alan 6 — TAKASLAMA)
at_signal_json(){
    csq=$(at_raw 'AT+CSQ' | sed -nE 's/.*\+CSQ: ([0-9]+).*/\1/p')
    # RSSI dBm: CSQ*2 - 113; CSQ=99 means unknown
    if [ -n "$csq" ] && [ "$csq" -lt 99 ] 2>/dev/null; then
        rssi=$((csq * 2 - 113))
    else
        rssi=0
    fi
    esq=$(at_raw 'AT+CESQ')
    # 3GPP CESQ alan sırası: rxlev,ber,rscp,ecno,rsrq,rsrp
    # Field 5 = rsrq index, Field 6 = rsrp index (modem 9 alan döndürür)
    rsrq=$(printf '%s' "$esq" | sed -nE 's/.*\+CESQ: [0-9]+,[0-9]+,[0-9]+,[0-9]+,([0-9]+),.*/\1/p')
    rsrp=$(printf '%s' "$esq" | sed -nE 's/.*\+CESQ: [0-9]+,[0-9]+,[0-9]+,[0-9]+,[0-9]+,([0-9]+).*/\1/p')
    # 255 = "not available" → boş string yap
    [ "$rsrq" = "255" ] && rsrq=
    [ "$rsrp" = "255" ] && rsrp=
    "$JQ" -nc \
        --argjson csq "${csq:-0}" \
        --argjson rssi "${rssi:-0}" \
        --arg rsrp "${rsrp:-}" \
        --arg rsrq "${rsrq:-}" \
        '{csq:$csq,rssi_dbm:$rssi,rsrp:$rsrp,rsrq:$rsrq}'
}

# _act_to_str <AcT> → ağ tipi adı
_act_to_str(){
    case "$1" in
        0)  printf 'GSM';;
        2)  printf 'UTRAN';;
        3)  printf 'EGPRS';;
        4|5|6) printf 'HSPA';;
        7)  printf 'LTE';;
        8)  printf 'EC-GSM-IoT';;
        9)  printf 'NB-IoT';;
        10) printf 'LTE-5GCN';;
        11) printf 'NR';;
        12) printf 'NG-RAN';;
        13) printf 'LTE-NR';;
        *)  printf '';;
    esac
}

# at_cellinfo_json → {"operator":"...","nettype":"...","imei":"...","iccid":"...","imsi":"...","phone":""}
# AT+COPS? → +COPS: <mode>,<fmt>,"<oper>",<AcT>
# AT+CGSN  → <15-digit IMEI>
# AT+CCID  → #+CCID: "<ICCID>"   (cihaza özgü: ICCID tırnak içinde, # öneki)
# AT+CIMI  → <15-digit IMSI>
# AT+CNUM  → CME ERROR: 22 (bu cihazda desteklenmiyor)
at_cellinfo_json(){
    cops=$(at_raw 'AT+COPS?')
    # Operatör: tırnak içindeki metin ("28603" gibi sayısal da olabilir)
    op=$(printf '%s' "$cops" | sed -nE 's/.*"([^"]+)".*/\1/p')
    # Ağ tipi: son sayısal alan (AcT)
    act=$(printf '%s' "$cops" | sed -nE 's/.*"[^"]+",([0-9]+).*/\1/p')
    nettype=$(_act_to_str "$act")

    # IMEI: sadece rakamlar, 15 karakter
    imei=$(at_raw 'AT+CGSN' | tr -dc '0-9' | head -c 15)

    # ICCID: bu modemde tırnak içinde → "([0-9A-Fa-f]+)"
    iccid=$(at_raw 'AT+CCID' | sed -nE 's/.*"([0-9A-Fa-f]+)".*/\1/p')

    # IMSI: sadece rakamlar, 15 karakter
    imsi=$(at_raw 'AT+CIMI' | tr -dc '0-9' | head -c 15)

    # Telefon numarası: bu cihazda desteklenmiyor (CME ERROR: 22)
    phone=''

    "$JQ" -nc \
        --arg op "$op" \
        --arg nettype "$nettype" \
        --arg imei "$imei" \
        --arg iccid "$iccid" \
        --arg imsi "$imsi" \
        --arg phone "$phone" \
        '{operator:$op,nettype:$nettype,imei:$imei,iccid:$iccid,imsi:$imsi,phone:$phone}'
}

# at_airplane on|off — dikkat: üretim modeminde test edilmez
at_airplane(){
    case "$1" in
        on)  at_raw 'AT+CFUN=4';;
        off) at_raw 'AT+CFUN=1';;
    esac
}

# at_imei_set <yeni_imei> — Unisoc (Spreadtrum) modemler için IMEI yazma komutları
at_imei_set(){
    local imei="${1:-}"
    [ -n "$imei" ] || return 1
    # 15 haneli rakam kontrolü
    case "$imei" in
        *[!0-9]*) return 1;;
    esac
    [ "${#imei}" -eq 15 ] || return 1
    at_raw "AT+SPIMEI=0,\"$imei\""

    return 0
}
