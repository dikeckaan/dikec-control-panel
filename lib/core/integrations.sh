#!/system/bin/sh
# lib/core/integrations.sh — read-only status passthrough for installed modules
#
#   intg_tailscale <sub>   — tailscale-control module (sub: status)
#   intg_tor       <sub>   — tor-relay module          (sub: status)
#   intg_ssh       <sub>   — dropbear-ssh module       (sub: status)
#
# All functions return single-line JSON.
# If the module directory is absent → {installed:false}.
# Control sub-commands (up/down/start/stop) are stubbed and NOT invoked in tests.

[ -n "${_INTEGRATIONS_SH_LOADED:-}" ] && return 0
_INTEGRATIONS_SH_LOADED=1

[ -n "${DCP_DATA:-}" ] || {
    _d="${DCP_MOD:-/data/adb/modules/dikec-control-panel}"
    . "$_d/lib/core/env.sh"
}

# ── tailscale-control ─────────────────────────────────────────────────────────
_INTG_TS_MOD=/data/adb/modules/tailscale-control
_INTG_TS_BIN="${_INTG_TS_MOD}/system/bin/tailscale"
_INTG_TS_DIR=/data/tailscale
_INTG_TS_PID="${_INTG_TS_DIR}/tailscaled.pid"

intg_tailscale() {
    local _sub="${1:-status}"

    if [ ! -d "$_INTG_TS_MOD" ]; then
        "$JQ" -nc '{installed:false}'
        return 0
    fi

    case "$_sub" in
        status)
            local _pid _running=false _ip=""
            _pid=$(cat "$_INTG_TS_PID" 2>/dev/null | tr -d ' \t\r\n')
            if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
                _running=true
                # Best-effort: read IP from tailscale0 interface
                _ip=$(ip -4 addr show tailscale0 2>/dev/null \
                    | sed -n 's|.*inet \([0-9.]*\)/.*|\1|p' | head -1 || printf '')
            fi
            "$JQ" -nc \
                --argjson running "$_running" \
                --arg     ip      "${_ip:-}" \
                '{installed:true, running:$running, ip:$ip}'
            ;;
        up|down|logout)
            # Wired but NOT invoked during testing (would change network state)
            "$JQ" -nc --arg sub "$_sub" \
                '{installed:true, ok:false, err:"control sub-commands disabled in read-only mode"}'
            ;;
        *)
            "$JQ" -nc --arg sub "$_sub" \
                '{installed:true, ok:false, err:"unknown tailscale sub-command"}'
            ;;
    esac
}

# ── tor-relay ─────────────────────────────────────────────────────────────────
_INTG_TOR_MOD=/data/adb/modules/tor-relay
_INTG_TOR_BIN="${_INTG_TOR_MOD}/bin/tor"
_INTG_TOR_LOG=/data/tor/daemon.log

intg_tor() {
    local _sub="${1:-status}"

    if [ ! -d "$_INTG_TOR_MOD" ]; then
        "$JQ" -nc '{installed:false}'
        return 0
    fi

    case "$_sub" in
        status)
            local _pid _running=false _bootstrap="" _mem_mb=0
            # pgrep -f matches the full cmdline — only the actual tor binary matches this path
            _pid=$(pgrep -f "$_INTG_TOR_BIN" 2>/dev/null | head -1 || printf '')
            if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
                _running=true
                _rss=$(awk '/^VmRSS:/{print $2; exit}' "/proc/${_pid}/status" 2>/dev/null \
                    || printf '0')
                _mem_mb=$(( ${_rss:-0} / 1024 ))
                # Parse last bootstrap line from log
                _bootstrap=$(grep -oE 'Bootstrapped [0-9]+%[^,]*' "$_INTG_TOR_LOG" \
                    2>/dev/null | tail -1 || printf '')
            fi
            "$JQ" -nc \
                --argjson running   "$_running"          \
                --argjson pid       "${_pid:-0}"         \
                --argjson mem_mb    "${_mem_mb:-0}"      \
                --arg     bootstrap "${_bootstrap:-}"    \
                '{installed:true, running:$running, pid:$pid, mem_mb:$mem_mb, bootstrap:$bootstrap}'
            ;;
        start|stop)
            # Wired but NOT invoked during testing (would change network state)
            "$JQ" -nc --arg sub "$_sub" \
                '{installed:true, ok:false, err:"control sub-commands disabled in read-only mode"}'
            ;;
        *)
            "$JQ" -nc --arg sub "$_sub" \
                '{installed:true, ok:false, err:"unknown tor sub-command"}'
            ;;
    esac
}

# ── dropbear-ssh ──────────────────────────────────────────────────────────────
_INTG_SSH_MOD=/data/adb/modules/dropbear-ssh
_INTG_SSH_KEYS=/data/ssh/authorized_keys

intg_ssh() {
    local _sub="${1:-status}"

    if [ ! -d "$_INTG_SSH_MOD" ]; then
        "$JQ" -nc '{installed:false}'
        return 0
    fi

    case "$_sub" in
        status)
            local _running=false _port="" _keys=false
            if pgrep -x dropbear >/dev/null 2>&1; then
                _running=true
                # Detect listening port from netstat; dropbear may not be on 22
                _port=$(netstat -tlnp 2>/dev/null \
                    | awk '/[0-9]\/dropbear/{split($4,a,":"); print a[length(a)]; exit}')
                # Fallback to ss if netstat failed
                if [ -z "$_port" ]; then
                    _port=$(ss -tlnp 2>/dev/null \
                        | awk '/dropbear/{match($4,/[0-9]+$/); \
                                print substr($4,RSTART,RLENGTH); exit}')
                fi
            fi
            [ -s "$_INTG_SSH_KEYS" ] && _keys=true
            "$JQ" -nc \
                --argjson running "$_running"  \
                --arg     port    "${_port:-}" \
                --argjson keys    "$_keys"     \
                '{installed:true, running:$running, port:$port, keys_present:$keys}'
            ;;
        *)
            "$JQ" -nc --arg sub "$_sub" \
                '{installed:true, ok:false, err:"unknown ssh sub-command"}'
            ;;
    esac
}
