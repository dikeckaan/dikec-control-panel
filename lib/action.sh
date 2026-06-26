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
#   action.sh update_check | update_apply

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
. "$D/lib/core/panelauth.sh"
. "$D/lib/core/modules.sh"
. "$D/lib/core/update.sh"

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

# ── internal: emit ok:true+out on rc 0, ok:false+out on failure ───────────────
# Core fns (prof_*) print a JSON object and set exit code; on failure they print
# {"err":".."} and return non-zero. j_ok alone would wrongly emit ok:true. j_rc
# respects the exit code: $1=rc, $2=fn output. jq `+` lets the left {ok:..} set
# the flag while preserving the err field from the fn output.
j_rc() {
    if [ "$1" -eq 0 ] 2>/dev/null; then
        j_ok "$2"
    else
        "$JQ" -nc --argjson d "${2:-$_DCP_EMPTYOBJ}" '{ok:false} + $d' 2>/dev/null \
            || j_err "işlem başarısız"
    fi
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
  prof_switch)     _o=$(prof_switch "$ARG"); j_rc $? "$_o";;
  prof_list)       j_ok "$(prof_list_json)";;
  prof_import_link) _o=$(prof_import_link "$ARG"); j_rc $? "$_o";;
  prof_import)     _o=$(prof_import_link "$ARG"); j_rc $? "$_o";;
  prof_import_sub) _o=$(prof_import_sub "$ARG"); j_rc $? "$_o";;
  prof_probe)      _o=$(prof_probe "$ARG"); j_rc $? "$_o";;
  prof_probe_all)  j_ok "$(prof_probe_all)";;

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
  bypass_list)     j_ok "$(bypass_list)";;
  clients)         j_ok "$(sys_clients_json)";;

  # ── tproxy dry-run ────────────────────────────────────────────────────────
  tproxy_dryrun)   _o=$(DRYRUN=1 route_apply tproxy 2>&1); "$JQ" -nc --arg rules "$_o" '{ok:true,dryrun:$rules}';;

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

  # ── panel LAN exposure toggle ─────────────────────────────────────────────
  # panel_lan        → read current lan_expose (0|1)
  # panel_lan <0|1>  → set lan_expose; httpd re-binds on next restart
  panel_lan)
    if [ -z "$ARG" ]; then
      _pv=$(cat "${DCP_DATA}/conf/lan_expose" 2>/dev/null | tr -d '[:space:]' || printf '0')
      j_ok "$("$JQ" -nc --arg v "${_pv:-0}" '{lan_expose:($v|tonumber)}')"
    else
      case "$ARG" in
        0|1) ;;
        *) j_err "panel_lan: arg must be 0 or 1"; exit 1;;
      esac
      mkdir -p "${DCP_DATA}/conf"
      printf '%s' "$ARG" > "${DCP_DATA}/conf/lan_expose"
      j_ok "$("$JQ" -nc --arg v "$ARG" '{lan_expose:($v|tonumber)}')"
    fi
    ;;

  # ── panel password management (ADB / root rescue) ─────────────────────────
  # panel_passwd <newpass> [newuser]  — set password (clears MUST_CHANGE).
  # panel_passwd_reset                — restore admin/admin + force-change.
  # panel_auth_info                   — {user, must_change} (no secrets).
  panel_passwd)
    if [ -z "$ARG" ]; then j_err "panel_passwd: yeni şifre gerekli"; exit 1; fi
    if [ "${#ARG}" -lt 6 ]; then j_err "panel_passwd: şifre çok kısa (min 6)"; exit 1; fi
    pa_set_password "$ARG" "$ARG2" \
      && j_ok "$("$JQ" -nc --arg u "$(pa_user)" '{user:$u, changed:true}')" \
      || j_err "panel_passwd başarısız"
    ;;
  panel_passwd_reset)
    pa_reset && j_ok '{"user":"admin","reset":true,"must_change":true}' || j_err "reset başarısız"
    ;;
  panel_auth_info)
    j_ok "$("$JQ" -nc --arg u "$(pa_user)" --argjson mc "$(pa_must_change)" \
      '{user:$u, must_change:($mc==1)}')"
    ;;

  # ── Magisk module manager ──────────────────────────────────────────────────
  mod_list)            j_ok "$(mod_list_json)";;
  mod_catalog)         j_ok "$(mod_catalog_json)";;
  mod_enable)          _o=$(mod_enable "$ARG"); j_rc $? "$_o";;
  mod_disable)         _o=$(mod_disable "$ARG"); j_rc $? "$_o";;
  mod_remove)          _o=$(mod_remove "$ARG"); j_rc $? "$_o";;
  mod_unremove)        _o=$(mod_unremove "$ARG"); j_rc $? "$_o";;
  mod_install_catalog) _o=$(mod_install_catalog "$ARG"); j_rc $? "$_o";;
  mod_install_url)     _o=$(mod_install_url "$ARG"); j_rc $? "$_o";;
  mod_install_zip)     _o=$(mod_install_zip "$ARG"); j_rc $? "$_o";;

  # ── system reboot ─────────────────────────────────────────────────────────
  sys_reboot)
    j_ok '{}'
    # 2 s delay so the HTTP response is transmitted before the device reboots
    (sleep 2 && /system/bin/reboot) &
    ;;

  # ── self-update ───────────────────────────────────────────────────────────
  update_check)    update_check;;
  update_apply)    update_apply;;

  # ── notify_test — send a real Telegram message (do NOT invoke in CI) ──────
  notify_test)
    tg_notify "dikec-control-panel notify_test @ $(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)" \
        && j_ok '{"msg":"telegram mesajı gönderildi"}' \
        || j_err "tg_notify başarısız (token/chat_id eksik veya ağ hatası)";;

  *)               j_err "bilinmeyen verb: $VERB";;
esac
