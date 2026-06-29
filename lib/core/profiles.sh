#!/system/bin/sh
# profiles.sh — vmess/vless/trojan share-link + subscription import
# Ported from /tmp/zte-g5-cpe-xray/rootfs/usr/bin/xray-import; F50 adaptation:
#   injects OUTBOUND into socks-in template (xray/config.tpl.json) instead of building tproxy config.
# NB: no `set -u` here — this file is sourced into the same shell as action.sh,
# the Telegram bot and the panel CGI (via env.sh); a global set -u would break
# the legacy statusbot. This file is written defensively with ${var:-} guards.
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"

PROF_DIR="$DCP_DATA/xray/profiles"
ACTIVE_FILE="$DCP_DATA/xray/active"
XRAY_BIN="$DCP_MOD/system/bin/xray"
TPL="$DCP_MOD/xray/config.tpl.json"
# xray geo-asset lookup path — our own module ships geoip.dat/geosite.dat
# (the old dcp-engine module was removed at cutover; never point here).
XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-$DCP_MOD/xray/assets}"
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

# _compute_cert_pin SERVER PORT SNI — echo the server leaf-cert SHA256 (hex).
# xray 26.3.27 removed `allowInsecure`; the migration target is
# `pinnedPeerCertSha256` (a hex string). For TLS-fronting links (sni spoofed,
# allowInsecure=1) we replicate "trust this exact server" by pinning the cert
# the server actually presents under that SNI. openssl isn't on the device, so:
# curl -w %{certs} dumps the chain PEM → busybox base64 -d the leaf → sha256sum.
# Echoes empty on any failure (caller then omits the pin).
_compute_cert_pin() {
    local _srv="$1" _port="${2:-443}" _sni="${3:-$1}" _pem _hex
    [ -x "$CURL" ] && [ -x "$BB" ] || return 0
    # NOTE: do NOT bail on curl's exit code. A VLESS/VMess server doesn't speak
    # HTTP, so curl completes the TLS handshake (cert dumped via %{certs}) but
    # then the HTTP request fails (empty reply → non-zero exit). We still have
    # the cert. Capture output regardless; the awk/decode below decides success.
    _pem=$("$CURL" -ksS --max-time 12 -o /dev/null -w '%{certs}' \
        --connect-to "${_sni}:${_port}:${_srv}:${_port}" \
        "https://${_sni}:${_port}" 2>/dev/null)
    _hex=$(printf '%s\n' "$_pem" \
        | awk '/-----BEGIN CERTIFICATE-----/{f=1;next} /-----END CERTIFICATE-----/{exit} f' \
        | "$BB" base64 -d 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}')
    case "$_hex" in [0-9a-fA-F]*) printf '%s' "$_hex";; esac
}

# build_stream: reads _NET _SEC _SNI _FPRINT _ALPN _HOSTH _PATHH _SVC _HDR
#               _PBK _SID _SPX _MODE _SERVER _PORT _INSECURE; echoes streamSettings JSON
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
            # allowInsecure=1 → pin the cert the server presents under this SNI
            # (xray removed allowInsecure; pinnedPeerCertSha256 is the hex replacement)
            case "$_INSECURE" in
                1|true|TRUE|True)
                    _pin=$(_compute_cert_pin "$_SERVER" "${_PORT:-443}" "$sni")
                    [ -n "$_pin" ] && s="$s,\"pinnedPeerCertSha256\":$("$JQ" -rn --arg v "$_pin" '$v | @json')"
                    ;;
            esac
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
    # allowInsecure=1 → xray 26.3.27'de cert-pin'e çevrilir (bkz _compute_cert_pin)
    _INSECURE=$(_qget allowInsecure "$(_qget insecure "")")
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
    local _PBK _SID _SPX _MODE _SEED _SERVER _PORT _NAME _PROTO _INSECURE _pin
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

# ── prof_probe ────────────────────────────────────────────────────────────────
# Measure a profile's real latency by spawning a SHORT-LIVED temporary xray that
# binds a probe SOCKS port (NOT 10808 — the live tunnel keeps that), then curl
# through it to a 204 endpoint and time it. Echoes {name,latency_ms,ok}.
# latency_ms is null + ok:false if the tunnel can't carry traffic.
PROBE_PORT=10899
prof_probe() {
    local name="${1:-}"
    _prof_valid_name "$name" || { "$JQ" -nc --arg e "invalid-name" '{err:$e}'; return 1; }
    local pfile="$PROF_DIR/config-${name}.json"
    [ -f "$pfile" ] || { "$JQ" -nc --arg e "profile-not-found" '{err:$e}'; return 1; }

    local tmp="$PROF_DIR/.probe.$$.json"
    # rewrite the socks inbound to the probe port so we don't clash with 10808
    "$JQ" --argjson p "$PROBE_PORT" \
        '(.inbounds |= map(if .protocol=="socks" then .port=$p | .listen="127.0.0.1" else . end))' \
        "$pfile" > "$tmp" 2>/dev/null || { rm -f "$tmp"; "$JQ" -nc --arg n "$name" '{name:$n,latency_ms:null,ok:false}'; return 0; }

    XRAY_LOCATION_ASSET="$XRAY_LOCATION_ASSET" "$XRAY_BIN" run -config "$tmp" >/dev/null 2>&1 &
    local xpid=$!
    # give xray a moment to dial the upstream
    sleep 2
    local secs
    secs=$("$CURL" -s -o /dev/null --max-time 8 \
        --socks5-hostname "127.0.0.1:$PROBE_PORT" \
        -w '%{time_total}' "https://www.gstatic.com/generate_204" 2>/dev/null)
    kill "$xpid" 2>/dev/null; wait "$xpid" 2>/dev/null
    rm -f "$tmp"

    case "$secs" in
        ''|0|0.000000)
            "$JQ" -nc --arg n "$name" '{name:$n,latency_ms:null,ok:false}' ;;
        *)
            local ms
            ms=$(awk -v t="$secs" 'BEGIN{printf "%d", t*1000}')
            "$JQ" -nc --arg n "$name" --argjson ms "${ms:-0}" '{name:$n,latency_ms:$ms,ok:true}' ;;
    esac
}

# prof_probe_all — probe every profile sequentially; echo a list SORTED by
# latency (reachable first, ascending). Used by "switch to fastest".
prof_probe_all() {
    local results="[]" f pname r
    if [ -d "$PROF_DIR" ]; then
        for f in "$PROF_DIR"/config-*.json; do
            [ -f "$f" ] || continue
            pname="${f##*/}"; pname="${pname#config-}"; pname="${pname%.json}"
            r=$(prof_probe "$pname")
            results=$("$JQ" -nc --argjson a "$results" --argjson r "$r" '$a + [$r]')
        done
    fi
    # sort: reachable (ok) by ascending latency, unreachable last
    "$JQ" -nc --argjson r "$results" \
        '{results: ($r | sort_by(if .ok then .latency_ms else 9999999 end)),
          fastest: ([$r[] | select(.ok)] | sort_by(.latency_ms) | (.[0].name // null))}'
}

# ── prof_delete ───────────────────────────────────────────────────────────────

prof_delete() {
    local name="${1:-}"
    [ -n "$name" ] || { "$JQ" -nc --arg e "name-empty" '{err:$e}'; return 1; }
    _prof_valid_name "$name" || { "$JQ" -nc --arg e "invalid-name" '{err:$e}'; return 1; }
    local pfile="$PROF_DIR/config-${name}.json"
    [ -f "$pfile" ] || { "$JQ" -nc --arg e "profile-not-found" '{err:$e}'; return 1; }
    rm -f "$pfile"
    if [ "$name" = "$(prof_active)" ]; then
        rm -f "$ACTIVE_FILE"
    fi
    "$JQ" -nc --arg name "$name" '{ok:true, deleted:$name}'
}

# ── prof_get ──────────────────────────────────────────────────────────────────

prof_get() {
    local name="${1:-}"
    [ -n "$name" ] || { "$JQ" -nc --arg e "name-empty" '{err:$e}'; return 1; }
    _prof_valid_name "$name" || { "$JQ" -nc --arg e "invalid-name" '{err:$e}'; return 1; }
    local pfile="$PROF_DIR/config-${name}.json"
    [ -f "$pfile" ] || { "$JQ" -nc --arg e "profile-not-found" '{err:$e}'; return 1; }
    local content
    content=$(cat "$pfile" 2>/dev/null)
    "$JQ" -nc --arg name "$name" --arg config "$content" '{ok:true, name:$name, config:$config}'
}

# ── prof_save ─────────────────────────────────────────────────────────────────

prof_save() {
    local name="${1:-}"
    local content="${2:-}"
    [ -n "$name" ] || { "$JQ" -nc --arg e "name-empty" '{err:$e}'; return 1; }
    _prof_valid_name "$name" || { "$JQ" -nc --arg e "invalid-name" '{err:$e}'; return 1; }
    local pfile="$PROF_DIR/config-${name}.json"
    [ -f "$pfile" ] || { "$JQ" -nc --arg e "profile-not-found" '{err:$e}'; return 1; }
    [ -n "$content" ] || { "$JQ" -nc --arg e "content-empty" '{err:$e}'; return 1; }

    mkdir -p "$PROF_DIR"
    local tmp_cfg="${PROF_DIR}/.tmp$$.json"
    printf '%s\n' "$content" > "$tmp_cfg"

    if ! "$XRAY_BIN" run -test -config "$tmp_cfg" >/dev/null 2>&1; then
        rm -f "$tmp_cfg"
        "$JQ" -nc --arg e "xray-test-failed" '{err:$e}'; return 1
    fi

    mv "$tmp_cfg" "$pfile"
    if [ "$name" = "$(prof_active)" ]; then
        cp "$pfile" "$DCP_DATA/xray/config.json"
    fi
    "$JQ" -nc --arg name "$name" '{ok:true, saved:$name}'
}
