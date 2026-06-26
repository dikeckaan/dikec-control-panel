#!/system/bin/sh
# profiles.sh — vmess/vless/trojan share-link + subscription import
# Ported from /tmp/zte-g5-cpe-xray/rootfs/usr/bin/xray-import; F50 adaptation:
#   injects OUTBOUND into socks-in template (xray/config.tpl.json) instead of building tproxy config.
set -u
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"

PROF_DIR="$DCP_DATA/xray/profiles"
ACTIVE_FILE="$DCP_DATA/xray/active"
XRAY_BIN="$DCP_MOD/system/bin/xray"
TPL="$DCP_MOD/xray/config.tpl.json"
# xray geo-asset lookup path (dcp-engine module provides the dat files)
XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-/data/adb/modules/dcp-engine/xray/assets}"
export XRAY_LOCATION_ASSET

# ── helpers ──────────────────────────────────────────────────────────────────

_urldecode() {
    printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

_norm_net() {
    case "$1" in
        websocket) printf 'ws';;
        h2|http2)  printf 'http';;
        mkcp)      printf 'kcp';;
        split)     printf 'splithttp';;
        *)         printf '%s' "$1";;
    esac
}

_norm_sec() {
    case "$1" in
        1|true)     printf 'tls';;
        0|false|"") printf 'none';;
        *)          printf '%s' "$1";;
    esac
}

# qget KEY [DEFAULT] — extract from $QS (URL query string)
_qget() {
    local v
    v=$(printf '%s' "$QS" | tr '&' '\n' | sed -n "s/^${1}=//p" | head -1)
    if [ -n "$v" ]; then _urldecode "$v"; else printf '%s' "${2:-}"; fi
}

# build_stream: reads _NET _SEC _SNI _FPRINT _ALPN _HOSTH _PATHH _SVC _HDR
#               _PBK _SID _SPX _MODE _SERVER; echoes streamSettings JSON object
_build_stream() {
    local s alpn alpnj sni

    s="\"network\":\"$_NET\""

    case "$_SEC" in
        tls)
            sni="${_SNI:-$_SERVER}"
            # Only set ALPN if explicitly provided; don't force h3 for ws compat
            s="$s,\"security\":\"tls\",\"tlsSettings\":{"
            s="$s\"serverName\":$("$JQ" -rn --arg v "$sni" '$v | @json'),"
            s="$s\"fingerprint\":\"${_FPRINT:-chrome}\""
            if [ -n "$_ALPN" ]; then
                alpnj=$(printf '%s' "$_ALPN" | awk -F, '{
                    o=""
                    for(i=1;i<=NF;i++){
                        g=$i; gsub(/^ +| +$/,"",g)
                        if(g!="") o=o (o==""?"":",") "\"" g "\""
                    }
                    print o
                }')
                s="$s,\"alpn\":[$alpnj]"
            fi
            s="$s}"
            ;;
        reality)
            sni="${_SNI:-$_SERVER}"
            s="$s,\"security\":\"reality\",\"realitySettings\":{"
            s="$s\"serverName\":$("$JQ" -rn --arg v "$sni" '$v | @json'),"
            s="$s\"fingerprint\":\"${_FPRINT:-chrome}\""
            [ -n "$_PBK" ] && s="$s,\"publicKey\":$("$JQ" -rn --arg v "$_PBK" '$v | @json')"
            [ -n "$_SID" ] && s="$s,\"shortId\":$("$JQ" -rn --arg v "$_SID" '$v | @json')"
            s="$s,\"spiderX\":$("$JQ" -rn --arg v "${_SPX:-/}" '$v | @json')}"
            ;;
        *)
            s="$s,\"security\":\"none\""
            ;;
    esac

    case "$_NET" in
        ws)
            s="$s,\"wsSettings\":{\"path\":$("$JQ" -rn --arg v "${_PATHH:-/}" '$v | @json')"
            [ -n "$_HOSTH" ] && s="$s,\"headers\":{\"Host\":$("$JQ" -rn --arg v "$_HOSTH" '$v | @json')}"
            s="$s}"
            ;;
        grpc)
            s="$s,\"grpcSettings\":{\"serviceName\":$("$JQ" -rn --arg v "$_SVC" '$v | @json')"
            [ "$_MODE" = multi ] && s="$s,\"multiMode\":true"
            s="$s}"
            ;;
        http)
            s="$s,\"httpSettings\":{"
            local h2parts=""
            [ -n "$_HOSTH" ] && h2parts="$h2parts\"host\":[$("$JQ" -rn --arg v "$_HOSTH" '$v | @json')]"
            [ -n "$_PATHH" ] && { [ -n "$h2parts" ] && h2parts="$h2parts,"; h2parts="${h2parts}\"path\":$("$JQ" -rn --arg v "$_PATHH" '$v | @json')"; }
            s="$s$h2parts}"
            ;;
        splithttp|xhttp)
            s="$s,\"${_NET}Settings\":{\"path\":$("$JQ" -rn --arg v "${_PATHH:-/}" '$v | @json')"
            [ -n "$_HOSTH" ] && s="$s,\"host\":$("$JQ" -rn --arg v "$_HOSTH" '$v | @json')"
            [ -n "$_MODE" ]  && s="$s,\"mode\":\"$_MODE\""
            s="$s}"
            ;;
        kcp)
            s="$s,\"kcpSettings\":{\"header\":{\"type\":\"${_HDR:-none}\"}"
            [ -n "$_SEED" ] && s="$s,\"seed\":$("$JQ" -rn --arg v "$_SEED" '$v | @json')"
            s="$s}"
            ;;
        tcp)
            if [ -n "$_HDR" ] && [ "$_HDR" != none ]; then
                s="$s,\"tcpSettings\":{\"header\":{\"type\":\"$_HDR\""
                if [ "$_HDR" = http ]; then
                    s="$s,\"request\":{"
                    local tcpparts=""
                    [ -n "$_PATHH" ] && tcpparts="\"path\":[$("$JQ" -rn --arg v "$_PATHH" '$v | @json')]"
                    [ -n "$_HOSTH" ] && { [ -n "$tcpparts" ] && tcpparts="$tcpparts,"; tcpparts="${tcpparts}\"headers\":{\"Host\":[$("$JQ" -rn --arg v "$_HOSTH" '$v | @json')]}"; }
                    s="$s$tcpparts}"
                fi
                s="$s}}"
            fi
            ;;
    esac

    printf '{%s}' "$s"
}

_parse_common_query() {
    _NET=$(_norm_net "$(_qget type "$(_qget net tcp)")")
    _SEC=$(_norm_sec "$(_qget security "$(_qget tls none)")")
    _SNI=$(_qget sni "$(_qget servername "$(_qget peer "")")")
    _FPRINT=$(_qget fp "$(_qget fingerprint chrome)")
    _ALPN=$(_qget alpn "")
    _HOSTH=$(_qget host "$(_qget authority "")")
    _PATHH=$(_qget path "")
    _SVC=$(_qget serviceName "$(_qget service "")"); [ -n "$_SVC" ] || _SVC="$_PATHH"
    _HDR=$(_qget headerType none)
    _PBK=$(_qget pbk "$(_qget publicKey "")")
    _SID=$(_qget sid "$(_qget shortId "")")
    _SPX=$(_qget spx "$(_qget spiderX /)")
    _MODE=$(_qget mode "")
    _SEED=$(_qget seed "")
}

# reject anything that isn't a sanitized profile name (no /, no .., no path tricks)
_prof_valid_name() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        ..|.) return 1 ;;
    esac
    return 0
}

_safe_name() {
    # $1 = candidate name, $2 = server (fallback)
    local n
    n=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-40)
    [ -n "$n" ] || n="import-$(printf '%s' "$2" | tr -cd 'A-Za-z0-9' | cut -c1-12)"
    # never allow bare . or .. as the whole name (path tricks)
    case "$n" in .|..) n="import-$(printf '%s' "$2" | tr -cd 'A-Za-z0-9' | cut -c1-12)";; esac
    printf '%s' "$n"
}

# ── prof_import_link ──────────────────────────────────────────────────────────

prof_import_link() {
    local uri
    uri=$(printf '%s' "${1:-}" | tr -d ' \t\r' | sed -n '1p')
    [ -n "$uri" ] || { "$JQ" -nc --arg e "uri-empty" '{err:$e}'; return 1; }

    # shared stream-settings state (subshell-safe globals via local-by-convention)
    local _NET _SEC _SNI _FPRINT _ALPN _HOSTH _PATHH _SVC _HDR
    local _PBK _SID _SPX _MODE _SEED _SERVER _PORT _NAME _PROTO
    local QS OUTBOUND
    _NET=tcp; _SEC=none; _SNI=""; _FPRINT=chrome; _ALPN=""
    _HOSTH=""; _PATHH=""; _SVC=""; _HDR=none; _PBK=""; _SID=""
    _SPX=/; _SERVER=""; _SEED=""; _MODE=""
    _PORT=""; _NAME=""; QS=""; OUTBOUND=""

    case "$uri" in

      vmess://*)
        _PROTO=vmess
        local b64 js
        b64=${uri#vmess://}; b64=${b64%%#*}
        b64=$(printf '%s' "$b64" | tr '_-' '/+')
        # pad to multiple-of-4
        case $(( ${#b64} % 4 )) in 2) b64="${b64}==";; 3) b64="${b64}=";; esac
        js=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
        [ -n "$js" ] || { "$JQ" -nc --arg e "vmess-base64-decode-failed" '{err:$e}'; return 1; }

        # use $JQ to parse vmess JSON (not jsonfilter — F50 adaptation)
        _jf() { printf '%s' "$js" | "$JQ" -r --arg k "$1" '.[$k] // empty' 2>/dev/null; }

        _SERVER=$(_jf add); _PORT=$(_jf port)
        local UUID AID SCY
        UUID=$(_jf id)
        [ -n "$_SERVER" ] && [ -n "$UUID" ] || {
            "$JQ" -nc --arg e "vmess-missing-field" '{err:$e}'; return 1
        }
        AID=$(_jf aid); [ -n "$AID" ] || AID=0
        SCY=$(_jf scy); [ -n "$SCY" ] || SCY=auto
        _NET=$(_norm_net "$(_jf net)")
        _SEC=$(_norm_sec "$(_jf tls)")
        _SNI=$(_jf sni); _HOSTH=$(_jf host)
        _PATHH=$(_jf path); _HDR=$(_jf type); [ -n "$_HDR" ] || _HDR=none
        _ALPN=$(_jf alpn); _FPRINT=$(_jf fp); [ -n "$_FPRINT" ] || _FPRINT=chrome
        _SVC="$_PATHH"; _SEED=""; _MODE=""
        [ -z "$_PORT" ] && { [ "$_SEC" = tls ] && _PORT=443 || _PORT=80; }
        _NAME=$(_jf ps)
        OUTBOUND=$("$JQ" -nc \
            --arg addr "$_SERVER" \
            --argjson port "$_PORT" \
            --arg uuid "$UUID" \
            --argjson aid "$AID" \
            --arg scy "$SCY" \
            --argjson stream "$(_build_stream)" \
            '{protocol:"vmess",settings:{vnext:[{address:$addr,port:$port,users:[{id:$uuid,alterId:$aid,security:$scy}]}]},streamSettings:$stream,tag:"proxy"}')
        ;;

      vless://*|trojan://*)
        local proto rest frag cred hostport flow enc
        proto=${uri%%://*}
        _PROTO=$proto
        rest=${uri#*://}
        frag=${rest#*#}; [ "$frag" = "$rest" ] && frag=""
        _NAME=$(_urldecode "$frag")
        rest=${rest%%#*}
        QS=""
        case "$rest" in *\?*) QS=${rest#*\?}; rest=${rest%%\?*};; esac
        cred=${rest%%@*}; hostport=${rest#*@}
        _SERVER=${hostport%%:*}; _PORT=${hostport##*:}; _PORT=${_PORT%%/*}
        _parse_common_query
        [ -n "$_PORT" ] || { [ "$_SEC" = none ] && _PORT=80 || _PORT=443; }
        [ -n "$_SERVER" ] || {
            "$JQ" -nc --arg e "no-server" '{err:$e}'; return 1
        }
        if [ "$proto" = vless ]; then
            flow=$(_qget flow ""); enc=$(_qget encryption none)
            OUTBOUND=$("$JQ" -nc \
                --arg addr "$_SERVER" \
                --argjson port "$_PORT" \
                --arg uuid "$(_urldecode "$cred")" \
                --arg enc "$enc" \
                --arg flow "$flow" \
                --argjson stream "$(_build_stream)" \
                '{protocol:"vless",settings:{vnext:[{address:$addr,port:$port,users:[{id:$uuid,encryption:$enc} + (if $flow!="" then {flow:$flow} else {} end)]}]},streamSettings:$stream,tag:"proxy"}')
        else
            OUTBOUND=$("$JQ" -nc \
                --arg addr "$_SERVER" \
                --argjson port "$_PORT" \
                --arg pass "$(_urldecode "$cred")" \
                --argjson stream "$(_build_stream)" \
                '{protocol:"trojan",settings:{servers:[{address:$addr,port:$port,password:$pass}]},streamSettings:$stream,tag:"proxy"}')
        fi
        ;;

      *)
        "$JQ" -nc --arg e "unsupported-scheme" '{err:$e}'; return 1
        ;;
    esac

    # determine profile name (sanitized to [A-Za-z0-9._-]); reuse the same guard
    # used by prof_switch so saved profiles always pass _prof_valid_name.
    local pname
    pname=$(_safe_name "$_NAME" "$_SERVER")
    _prof_valid_name "$pname" || {
        "$JQ" -nc --arg e "invalid-name" '{err:$e}'; return 1
    }
    local pfile="$PROF_DIR/config-${pname}.json"

    # inject outbound into template
    mkdir -p "$PROF_DIR"
    local tmp_cfg="${PROF_DIR}/.tmp$$.json"

    # Replace __OUTBOUND__ token with the outbound JSON object.
    # awk gsub() treats `&` in the replacement as the matched text and `\` as an
    # escape, so escape both in ob first (backslash before & — order matters).
    # In awk source "\\\\&" is the 2-char replacement `\&`, which gsub emits as a
    # literal `&` (e.g. ws paths like "/ws?ed=2048&token=abc").
    awk -v ob="$OUTBOUND" 'BEGIN{gsub(/\\/,"\\\\",ob); gsub(/&/,"\\\\&",ob)} {gsub(/__OUTBOUND__/, ob); print}' "$TPL" > "$tmp_cfg" || {
        rm -f "$tmp_cfg"
        "$JQ" -nc --arg e "template-write-failed" '{err:$e}'; return 1
    }

    # validate with xray -test
    if ! "$XRAY_BIN" run -test -config "$tmp_cfg" >/dev/null 2>&1; then
        rm -f "$tmp_cfg"
        "$JQ" -nc --arg e "xray-test-failed" '{err:$e}'; return 1
    fi

    mv "$tmp_cfg" "$pfile"

    # print result JSON (protocol, server, port — no j_ok wrapper; Task 12 dispatcher wraps)
    "$JQ" -nc \
        --arg name "$pname" \
        --arg protocol "$_PROTO" \
        --arg server "$_SERVER" \
        --argjson port "$_PORT" \
        '{name:$name, protocol:$protocol, server:$server, port:$port}'
}

# ── prof_import_sub ───────────────────────────────────────────────────────────

prof_import_sub() {
    local url="${1:-}"
    [ -n "$url" ] || { "$JQ" -nc --arg e "url-empty" '{err:$e}'; return 1; }

    local body
    # max 200KB download
    body=$("$CURL" -fsSL --max-time 20 --max-filesize 204800 "$url" 2>/dev/null)
    [ -n "$body" ] || { "$JQ" -nc --arg e "fetch-failed" '{err:$e}'; return 1; }

    # detect if body is already a link list or base64-encoded
    local lines
    if printf '%s' "$body" | grep -qE '^(vmess|vless|trojan)://'; then
        lines="$body"
    else
        # URL-safe base64 decode
        lines=$(printf '%s' "$body" | tr '_-' '/+' | base64 -d 2>/dev/null)
    fi

    local imported=0 failed=0
    while IFS= read -r line; do
        line=$(printf '%s' "$line" | tr -d '\r')
        case "$line" in vmess://*|vless://*|trojan://*) ;; *) continue;; esac
        if prof_import_link "$line" >/dev/null 2>&1; then
            imported=$(( imported + 1 ))
        else
            failed=$(( failed + 1 ))
        fi
    done <<EOF
$lines
EOF

    "$JQ" -nc --argjson i "$imported" --argjson f "$failed" '{imported:$i, failed:$f}'
}

# ── prof_list_json ────────────────────────────────────────────────────────────

prof_list_json() {
    local active
    active=$(prof_active)
    local arr="[]"
    if [ -d "$PROF_DIR" ]; then
        for f in "$PROF_DIR"/config-*.json; do
            [ -f "$f" ] || continue
            local bname="${f##*/}"          # config-<name>.json
            local pname="${bname#config-}"
            pname="${pname%.json}"
            local is_active=false
            [ "$pname" = "$active" ] && is_active=true
            # extract protocol/server/port from the saved config via jq
            local proto server port
            proto=$("$JQ" -r '.outbounds[0].protocol // "unknown"' "$f" 2>/dev/null)
            server=$("$JQ" -r '
                .outbounds[0].settings |
                if .vnext then .vnext[0].address
                elif .servers then .servers[0].address
                else "unknown" end' "$f" 2>/dev/null)
            port=$("$JQ" -r '
                .outbounds[0].settings |
                if .vnext then .vnext[0].port
                elif .servers then .servers[0].port
                else 0 end' "$f" 2>/dev/null)
            arr=$("$JQ" -nc \
                --argjson arr "$arr" \
                --arg name "$pname" \
                --arg protocol "$proto" \
                --arg server "$server" \
                --argjson port "${port:-0}" \
                --argjson active "$is_active" \
                '$arr + [{name:$name,protocol:$protocol,server:$server,port:$port,active:$active}]')
        done
    fi
    "$JQ" -nc --argjson profiles "$arr" '{profiles:$profiles}'
}

# ── prof_switch ───────────────────────────────────────────────────────────────

prof_switch() {
    local name="${1:-}"
    [ -n "$name" ] || { "$JQ" -nc --arg e "name-empty" '{err:$e}'; return 1; }
    # SECURITY: name comes from bot/web/SMS (untrusted) — block path traversal
    # BEFORE building any filesystem path from it.
    _prof_valid_name "$name" || { "$JQ" -nc --arg e "invalid-name" '{err:$e}'; return 1; }
    local pfile="$PROF_DIR/config-${name}.json"
    [ -f "$pfile" ] || { "$JQ" -nc --arg e "profile-not-found" '{err:$e}'; return 1; }
    mkdir -p "$(dirname "$ACTIVE_FILE")"
    printf '%s' "$name" > "$ACTIVE_FILE"
    cp "$pfile" "$DCP_DATA/xray/config.json"
    "$JQ" -nc --arg name "$name" '{ok:true, active:$name}'
}

# ── prof_active ───────────────────────────────────────────────────────────────

prof_active() {
    cat "$ACTIVE_FILE" 2>/dev/null || printf ''
}
