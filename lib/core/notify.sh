#!/system/bin/sh
# lib/core/notify.sh — notification helpers
#   tg_notify <text>        — send Telegram message via api.telegram.org
#   notify_telegram <text>  — alias (used by sms_cmd.sh)
#   sms_notify <to> <text>  — wrapper over sms.sh sms_send
#
# Security: text goes to curl --data-urlencode (never into a shell command).
# Missing token/chat_id → return 1 quietly (no crash).

[ -n "${_NOTIFY_SH_LOADED:-}" ] && return 0
_NOTIFY_SH_LOADED=1

[ -n "${DCP_DATA:-}" ] || {
    _d="${DCP_MOD:-/data/adb/modules/dikec-control-panel}"
    . "$_d/lib/core/env.sh"
}

# tg_notify <text>
# Reads token from $DCP_DATA/token and chat_id from $DCP_DATA/chat_id.
# Returns non-zero quietly when either is missing or the network call fails.
tg_notify() {
    local _text="$1"
    local _token _chat_id
    _token=$(cat "${DCP_DATA}/token" 2>/dev/null | tr -d ' \t\r\n')
    _chat_id=$(cat "${DCP_DATA}/chat_id" 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$_token" ] && [ -n "$_chat_id" ] || return 1

    "$CURL" -sSf --cacert "$CA" --max-time 15 \
        "https://api.telegram.org/bot${_token}/sendMessage" \
        -d "chat_id=${_chat_id}" \
        --data-urlencode "text=${_text}" \
        >/dev/null 2>&1
}

# notify_telegram — backward-compat alias used by sms_cmd.sh
notify_telegram() { tg_notify "$@"; }

# sms_notify <to> <text>
# Delegates to sms.sh sms_send; sms_send validates the number and strips
# control bytes so we do not duplicate that logic here.
sms_notify() {
    local _to="$1" _text="$2"
    # Source sms.sh if not already loaded (guard variable set inside sms.sh
    # would be ideal, but it doesn't have one — source is idempotent via env.sh guard)
    local _mod="${DCP_MOD:-/data/adb/modules/dikec-control-panel}"
    [ "$(type sms_send 2>/dev/null)" ] || . "$_mod/lib/core/sms.sh" 2>/dev/null
    sms_send "$_to" "$_text"
}
