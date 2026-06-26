#!/system/bin/sh
# lib/action.sh — merkezi dispatcher: action.sh <verb> [arg] → tek satır JSON
# Tüketir: lib/core/{env,system,at,sms}.sh
# Kullanım: action.sh status | signal | cellinfo | sms_list [n] | airplane <on|off>

D="${0%/lib/action.sh}"; [ -d "$D/lib" ] || D=/data/adb/modules/dikec-control-panel
. "$D/lib/core/env.sh"
. "$D/lib/core/system.sh"
. "$D/lib/core/at.sh"
. "$D/lib/core/sms.sh"

VERB="$1"; ARG="$2"
case "$VERB" in
  status)   j_ok "$(sys_status_json)";;
  signal)   j_ok "$(at_signal_json)";;
  cellinfo) j_ok "$(at_cellinfo_json)";;
  sms_list) j_ok "$(sms_list_json "${ARG:-20}")";;
  airplane) at_airplane "$ARG" && j_ok '{}' || j_err "airplane $ARG başarısız";;
  *)        j_err "bilinmeyen verb: $VERB";;
esac
