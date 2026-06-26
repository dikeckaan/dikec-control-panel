#!/system/bin/sh
# www/cgi-bin/upload.cgi — receive a Magisk module zip (raw POST body) and
# install it via mod_install_zip. The panel POSTs the file as the request body
# (Content-Type application/zip), NOT multipart — so no multipart parsing.
# Requires a valid session (or token). Returns the install result JSON.

DCP=/data/adb/modules/dikec-control-panel
DCP_DATA=/data/dikec
BB=/data/adb/modules/bin-utils/system/bin/busybox
JQ=/data/adb/modules/bin-utils/system/bin/jq
. "$DCP/lib/core/panelauth.sh"

_reply() { printf 'Status: %s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "$2"; exit 0; }

# ── auth: valid session cookie OR panel token (?token= / X-Token) ─────────────
COOKIE_TOK=$(printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' \
    | sed -n 's/^[[:space:]]*dcp_sess=//p' | head -1 | tr -d '[:space:]')
_authed=0
pa_session_valid "$COOKIE_TOK" && _authed=1
if [ "$_authed" != 1 ]; then
    _qtok=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^token=//p' | head -1)
    _stored=$(cat "$DCP_DATA/conf/panel_token" 2>/dev/null | tr -d '\r\n')
    [ -n "$_stored" ] && [ "$_qtok" = "$_stored" ] && _authed=1
fi
[ "$_authed" = 1 ] || _reply "401 Unauthorized" '{"ok":false,"error":"unauthorized"}'

[ "$REQUEST_METHOD" = "POST" ] || _reply "405 Method Not Allowed" '{"ok":false,"error":"POST required"}'
case "${CONTENT_LENGTH:-0}" in ''|*[!0-9]*) _reply "400 Bad Request" '{"ok":false,"error":"no body"}';; esac
[ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null || _reply "400 Bad Request" '{"ok":false,"error":"empty body"}'

# size cap: 80 MB
_MAX=83886080
[ "$CONTENT_LENGTH" -gt "$_MAX" ] && _reply "413 Payload Too Large" '{"ok":false,"error":"too large (max 80MB)"}'

ZIP="/data/local/tmp/_modupload.zip"
rm -f "$ZIP"
# read exactly CONTENT_LENGTH bytes of the binary body (head -c handles binary)
"$BB" head -c "$CONTENT_LENGTH" > "$ZIP" 2>/dev/null

# install (mod_install_zip validates it's a module zip + installs as root)
. "$DCP/lib/core/env.sh"
. "$DCP/lib/core/modules.sh"
RESULT=$(mod_install_zip "$ZIP")
rm -f "$ZIP"

printf 'Content-Type: application/json\r\n\r\n%s\n' "$RESULT"
