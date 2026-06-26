#!/system/bin/sh
# lib/action.sh — merkezi dispatcher: action.sh <verb> [arg] → tek satır JSON
# Tüketir: lib/core/{env,system,at,sms,profiles,routing,xray,adblock,notify,integrations}.sh
# Kullanım:
#   action.sh status | signal | cellinfo | sms_list [n] | airplane <on|off>
#   action.sh xray_start | xray_stop | xray_status
#   action.sh prof_list | prof_switch <name> | prof_import <uri> | prof_import_sub <url>
#   action.sh route_mode <tun0|tproxy>
#   action.sh bypass_add <ip> | bypass_del <ip>
#   action.sh sms_send <to> <text>  | sms_delete <id>
#   action.sh smscmd_get | smscmd_set <json>
#   action.sh adblock_status | adblock_enable | adblock_disable | adblock_update
#   action.sh tailscale <sub> | tor <sub> | ssh <sub>
#   action.sh notify_test   (wired but NOT invoked automatically — sends real Telegram msg)

D="${0%/lib/action.sh}"; [ -d "$D/lib" ] || D=/data/adb/modules/dikec-control-panel
. "$D/lib/core/env.sh"
. "$D/lib/core/system.sh"
. "$D/lib/core/at.sh"
. "$D/lib/core/sms.sh"
. "$D/lib/core/profiles.sh"
. "$D/lib/core/routing.sh"
. "$D/lib/core/xray.sh"
. "$D/lib/core/adblock.sh"
. "$D/lib/core/notify.sh"
. "$D/lib/core/integrations.sh"

VERB="${1:-}"; ARG="${2:-}"; ARG2="${3:-}"

# ── internal: single-quote a value for safe shell conf writing ────────────────
# Wraps $1 in single quotes; any embedded ' is escaped as '\''
_sq() {
    local _v="$1"
    # escape embedded single quotes
    _v=$(printf '%s' "$_v" | sed "s/'/'\\\\''/g")
    printf "'%s'" "$_v"
}

# ── internal: smscmd conf helpers ─────────────────────────────────────────────
_SMSCMD_CONF_PATH="${DCP_DATA}/conf/sms-control.conf"

_smscmd_read() {
    SMS_ENABLED=0; SMS_SECRET=""; SMS_ALLOW=""; SMS_REPLY="true"
    [ -f "$_SMSCMD_CONF_PATH" ] && . "$_SMSCMD_CONF_PATH" 2>/dev/null
}

_smscmd_write() {
    # $1=enabled $2=secret $3=allow $4=reply
    # Write as shell-sourceable conf; string fields are single-quoted.
    mkdir -p "${DCP_DATA}/conf"
    {
        printf 'SMS_ENABLED=%s\n'  "$1"
        printf 'SMS_SECRET=%s\n'   "$(_sq "$2")"
        printf 'SMS_ALLOW=%s\n'    "$(_sq "$3")"
        printf 'SMS_REPLY=%s\n'    "$4"
    } > "$_SMSCMD_CONF_PATH"
}

case "$VERB" in
  # ── cell / modem ──────────────────────────────────────────────────────────
  status)          j_ok "$(sys_status_json)";;
  signal)          j_ok "$(at_signal_json)";;
  cellinfo)        j_ok "$(at_cellinfo_json)";;
  sms_list)        j_ok "$(sms_list_json "${ARG:-20}")";;
  airplane)        at_airplane "$ARG" && j_ok '{}' || j_err "airplane $ARG başarısız";;

  # ── SMS send / delete ──────────────────────────────────────────────────────
  sms_send)
    sms_send "$ARG" "$ARG2" && j_ok '{}' || j_err "sms_send başarısız (numara geçersiz veya AT hatası)"
    ;;
  sms_delete)
    sms_delete "$ARG" && j_ok '{}' || j_err "sms_delete başarısız (geçersiz id: $ARG)"
    ;;

  # ── SMS remote-control conf ────────────────────────────────────────────────
  smscmd_get)
    _smscmd_read
    j_ok "$("$JQ" -nc \
        --arg en     "$SMS_ENABLED"  \
        --arg sec    "$SMS_SECRET"   \
        --arg allow  "$SMS_ALLOW"    \
        --arg reply  "$SMS_REPLY"    \
        '{SMS_ENABLED:$en, SMS_SECRET:$sec, SMS_ALLOW:$allow, SMS_REPLY:$reply}')"
    ;;

  smscmd_set)
    # Security: parse with jq (never eval); validate field values.
    [ -n "$ARG" ] || { j_err "smscmd_set: JSON argümanı gerekli"; exit 1; }

    _jout=$(printf '%s' "$ARG" | "$JQ" -c '.' 2>/dev/null) \
        || { j_err "smscmd_set: geçersiz JSON"; exit 1; }

    _new_en=$(    printf '%s' "$_jout" | "$JQ" -r '.SMS_ENABLED  // empty' 2>/dev/null)
    _new_sec=$(   printf '%s' "$_jout" | "$JQ" -r '.SMS_SECRET   // empty' 2>/dev/null)
    _new_allow=$( printf '%s' "$_jout" | "$JQ" -r '.SMS_ALLOW    // empty' 2>/dev/null)
    _new_reply=$( printf '%s' "$_jout" | "$JQ" -r '.SMS_REPLY    // empty' 2>/dev/null)

    # Validate SMS_ENABLED: 0 or 1 only
    if [ -n "$_new_en" ]; then
        case "$_new_en" in
            0|1) ;;
            *) j_err "smscmd_set: SMS_ENABLED 0 veya 1 olmalı"; exit 1;;
        esac
    fi

    # Validate SMS_ALLOW: sadece rakam / + / virgül
    if [ -n "$_new_allow" ]; then
        case "$_new_allow" in
            *[!0-9+,]*) j_err "smscmd_set: SMS_ALLOW yalnızca rakam/+/virgül içerebilir"; exit 1;;
        esac
    fi

    # Validate SMS_REPLY: true or false
    if [ -n "$_new_reply" ]; then
        case "$_new_reply" in
            true|false) ;;
            *) j_err "smscmd_set: SMS_REPLY 'true' veya 'false' olmalı"; exit 1;;
        esac
    fi

    # Merge with existing values
    _smscmd_read
    _en="${_new_en:-$SMS_ENABLED}"
    _sec="${_new_sec:-$SMS_SECRET}"
    _allow="${_new_allow:-$SMS_ALLOW}"
    _reply="${_new_reply:-$SMS_REPLY}"

    _smscmd_write "$_en" "$_sec" "$_allow" "$_reply"

    j_ok "$("$JQ" -nc \
        --arg en    "$_en"    \
        --arg sec   "$_sec"   \
        --arg allow "$_allow" \
        --arg reply "$_reply" \
        '{SMS_ENABLED:$en, SMS_SECRET:$sec, SMS_ALLOW:$allow, SMS_REPLY:$reply}')"
    ;;

  # ── profiles ──────────────────────────────────────────────────────────────
  prof_switch)     j_ok "$(prof_switch "$ARG")";;
  prof_list)       j_ok "$(prof_list_json)";;
  prof_import_link) j_ok "$(prof_import_link "$ARG")";;
  prof_import)     j_ok "$(prof_import_link "$ARG")";;
  prof_import_sub) j_ok "$(prof_import_sub "$ARG")";;

  # ── xray engine ───────────────────────────────────────────────────────────
  xray_start)      xray_start && j_ok '{}' || j_err "xray_start başarısız";;
  xray_stop)       xray_stop  && j_ok '{}' || j_err "xray_stop başarısız";;
  xray_status)     j_ok "$(xray_status_json)";;

  # ── routing mode ──────────────────────────────────────────────────────────
  route_mode)
    case "$ARG" in
      tun0|tproxy) ;;
      *) j_err "geçersiz mod: $ARG (tun0 veya tproxy olmalı)"; exit 1;;
    esac
    cfg_set route_mode "$ARG"
    # Re-apply routing only if xray is currently running
    _xpid=$(cat "${XRAY_PID:-/data/dikec/xray/xray.pid}" 2>/dev/null || printf '0')
    if [ -n "$_xpid" ] && [ "$_xpid" -gt 0 ] 2>/dev/null && kill -0 "$_xpid" 2>/dev/null; then
      route_apply "$ARG" || { j_err "route_apply $ARG başarısız"; exit 1; }
    fi
    j_ok "$("$JQ" -nc --arg m "$ARG" '{route_mode:$m}')";;

  # ── per-client bypass ─────────────────────────────────────────────────────
  bypass_add)      bypass_add "$ARG" && j_ok "{}" || j_err "bypass_add $ARG başarısız";;
  bypass_del)      bypass_del "$ARG" && j_ok "{}" || j_err "bypass_del $ARG başarısız";;

  # ── tproxy dry-run ────────────────────────────────────────────────────────
  tproxy_dryrun)   DRYRUN=1 route_apply tproxy;;

  # ── adblock ───────────────────────────────────────────────────────────────
  adblock_status)
    j_ok "$(adblock_status_json)";;
  adblock_enable)
    adblock_enable && j_ok '{}' || j_err "adblock_enable başarısız";;
  adblock_disable)
    adblock_disable && j_ok '{}' || j_err "adblock_disable başarısız";;
  adblock_update)
    _n=$(adblock_update 2>/dev/null) \
        && j_ok "$("$JQ" -nc --argjson n "${_n:-0}" '{domains:$n}')" \
        || j_err "adblock_update başarısız";;

  # ── integrations: tailscale / tor / ssh ──────────────────────────────────
  tailscale)
    j_ok "$(intg_tailscale "${ARG:-status}")";;
  tor)
    j_ok "$(intg_tor "${ARG:-status}")";;
  ssh)
    j_ok "$(intg_ssh "${ARG:-status}")";;

  # ── notify_test — send a real Telegram message (do NOT invoke in CI) ──────
  notify_test)
    tg_notify "dikec-control-panel notify_test @ $(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" \
        && j_ok '{"msg":"telegram mesajı gönderildi"}' \
        || j_err "tg_notify başarısız (token/chat_id eksik veya ağ hatası)";;

  *)               j_err "bilinmeyen verb: $VERB";;
esac
