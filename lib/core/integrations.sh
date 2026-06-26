#!/system/bin/sh
# lib/core/integrations.sh — status + control for installed modules
#
#   intg_tailscale <sub>   — tailscale-control module (sub: status|up|down|logout)
#   intg_tor       <sub>   — tor-relay module          (sub: status|start|stop)
#   intg_ssh       <sub>   — dropbear-ssh module       (sub: status|start|stop)
#
# All functions return single-line JSON.
# If the module directory is absent → {installed:false}.

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
_INTG_TS_SOCK="${_INTG_TS_DIR}/tailscaled.sock"
_INTG_TS_STATE="${_INTG_TS_DIR}/tailscaled.state"
_INTG_TS_LOG="${_INTG_TS_DIR}/tailscaled.log"
_INTG_TS_AUTHKEY="${_INTG_TS_DIR}/authkey"
_INTG_TS_AUTOSTART="${_INTG_TS_DIR}/autostart"

# Prefer /system/bin overlay (post-reboot); fall back to module dir (pre-reboot)
_ts_find_bin() {
    local _name="$1" _p
    for _p in "/system/bin/$_name" "${_INTG_TS_MOD}/system/bin/$_name"; do
        [ -x "$_p" ] && { printf '%s' "$_p"; return 0; }
    done
    return 1
}

_ts_daemon_running() {
    local _p
    _p=$(cat "$_INTG_TS_PID" 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

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

        up)
            local _ts_bin _tsd_bin
            _ts_bin=$(_ts_find_bin tailscale)   || {
                "$JQ" -nc '{installed:true,ok:false,err:"tailscale binary not found"}'
                return 0
            }
            _tsd_bin=$(_ts_find_bin tailscaled) || {
                "$JQ" -nc '{installed:true,ok:false,err:"tailscaled binary not found"}'
                return 0
            }

            # Start daemon if not running
            if ! _ts_daemon_running; then
                mkdir -p "$_INTG_TS_DIR" "${_INTG_TS_DIR}/cache"
                chmod 700 "$_INTG_TS_DIR"
                # Clean up leftovers from any prior crash (idempotent)
                rm -f "$_INTG_TS_SOCK" "$_INTG_TS_PID"
                ip link delete tailscale0 2>/dev/null
                echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
                # TS_DEBUG_FIREWALL_MODE=iptables: skip nftables auto-detect
                # (Android kernel returns EINVAL on listTables netlink → fatal otherwise)
                HOME="$_INTG_TS_DIR" XDG_CACHE_HOME="${_INTG_TS_DIR}/cache" \
                TS_DEBUG_FIREWALL_MODE=iptables \
                nohup "$_tsd_bin" \
                    --tun=tailscale0 \
                    --state="$_INTG_TS_STATE" \
                    --socket="$_INTG_TS_SOCK" \
                    --statedir="$_INTG_TS_DIR" \
                    >> "$_INTG_TS_LOG" 2>&1 &
                echo $! > "$_INTG_TS_PID"
                # Wait for control socket (up to 15 s)
                local _i=0
                while [ "$_i" -lt 15 ]; do
                    [ -S "$_INTG_TS_SOCK" ] && break
                    sleep 1; _i=$((_i+1))
                done
                if [ ! -S "$_INTG_TS_SOCK" ]; then
                    rm -f "$_INTG_TS_PID"
                    "$JQ" -nc \
                        --arg log "$(tail -5 "$_INTG_TS_LOG" 2>/dev/null)" \
                        '{installed:true,ok:false,err:"tailscaled socket not ready",log:$log}'
                    return 0
                fi
                # iptables: allow exit-node forwarding (idempotent via -C check)
                iptables -t nat -C POSTROUTING -s 100.64.0.0/10 -j MASQUERADE 2>/dev/null \
                    || iptables -t nat -A POSTROUTING -s 100.64.0.0/10 -j MASQUERADE
                iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null \
                    || iptables -A FORWARD -i tailscale0 -j ACCEPT
                iptables -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null \
                    || iptables -A FORWARD -o tailscale0 -j ACCEPT
            fi

            # tailscale up (connect to tailnet)
            local _upargs="--advertise-exit-node --accept-dns=false --accept-routes=false --hostname=ZTE-F50"
            if [ -s "$_INTG_TS_AUTHKEY" ]; then
                _upargs="$_upargs --auth-key=$(cat "$_INTG_TS_AUTHKEY")"
            fi
            local _upresp
            _upresp=$("$_ts_bin" --socket="$_INTG_TS_SOCK" up $_upargs 2>&1)
            sleep 2
            local _ts_ip
            _ts_ip=$("$_ts_bin" --socket="$_INTG_TS_SOCK" ip -4 2>/dev/null | head -1)
            if [ -n "$_ts_ip" ]; then
                # Persist boot-autostart intent
                touch "$_INTG_TS_AUTOSTART" 2>/dev/null
                "$JQ" -nc --arg ip "$_ts_ip" \
                    '{installed:true,ok:true,running:true,ip:$ip}'
            else
                # No IP yet — check for login URL (new node / no authkey)
                local _login
                _login=$(printf '%s' "$_upresp" \
                    | grep -oE 'https://login\.tailscale\.com[^ ]*' | head -1)
                if [ -n "$_login" ]; then
                    "$JQ" -nc --arg url "$_login" \
                        '{installed:true,ok:true,running:true,login_url:$url}'
                else
                    "$JQ" -nc \
                        --arg resp "$(printf '%s' "$_upresp" | head -c 500)" \
                        '{installed:true,ok:true,running:true,response:$resp}'
                fi
            fi
            ;;

        down)
            if ! _ts_daemon_running; then
                "$JQ" -nc \
                    '{installed:true,ok:true,running:false,msg:"daemon not running"}'
                return 0
            fi
            local _ts_bin
            _ts_bin=$(_ts_find_bin tailscale) || {
                "$JQ" -nc '{installed:true,ok:false,err:"tailscale binary not found"}'
                return 0
            }
            "$_ts_bin" --socket="$_INTG_TS_SOCK" down 2>/dev/null
            "$JQ" -nc \
                '{installed:true,ok:true,running:true,msg:"tailscale down — daemon still running"}'
            ;;

        logout)
            local _ts_bin
            _ts_bin=$(_ts_find_bin tailscale) || {
                "$JQ" -nc '{installed:true,ok:false,err:"tailscale binary not found"}'
                return 0
            }
            if _ts_daemon_running; then
                "$_ts_bin" --socket="$_INTG_TS_SOCK" logout 2>/dev/null
                sleep 1
                local _pid
                _pid=$(cat "$_INTG_TS_PID" 2>/dev/null | tr -d ' \t\r\n')
                [ -n "$_pid" ] && kill "$_pid" 2>/dev/null
            fi
            iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -j MASQUERADE 2>/dev/null
            iptables -D FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
            iptables -D FORWARD -o tailscale0 -j ACCEPT 2>/dev/null
            rm -f "$_INTG_TS_STATE" "$_INTG_TS_PID" \
                  "$_INTG_TS_AUTHKEY" "$_INTG_TS_AUTOSTART"
            "$JQ" -nc '{installed:true,ok:true,running:false,msg:"logged out"}'
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

        start)
            local _pid
            _pid=$(pgrep -f "$_INTG_TOR_BIN" 2>/dev/null | head -1 || printf '')
            if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
                # Already running — return current status
                local _rss _mem_mb=0
                _rss=$(awk '/^VmRSS:/{print $2; exit}' \
                    "/proc/${_pid}/status" 2>/dev/null || printf '0')
                _mem_mb=$(( ${_rss:-0} / 1024 ))
                "$JQ" -nc \
                    --argjson pid    "${_pid}" \
                    --argjson mem_mb "${_mem_mb}" \
                    '{installed:true,ok:true,running:true,pid:$pid,mem_mb:$mem_mb,msg:"already running"}'
                return 0
            fi
            # torrc has "User shell" — tor drops to shell uid BEFORE opening its
            # log file.  /data/tor/ is root:root 755, so shell can't create new
            # files there.  Pre-create the log file as root with shell ownership
            # so tor can open it after the privilege drop.
            mkdir -p /data/tor/state 2>/dev/null
            chown -R shell:shell /data/tor/state 2>/dev/null
            touch /data/tor/tor.log 2>/dev/null
            chown shell:shell /data/tor/tor.log 2>/dev/null
            # Launch tor directly (bypasses service.sh 25 s warmup sleep;
            # routing rules from service.sh's boot loop are already in place)
            LD_LIBRARY_PATH="${_INTG_TOR_MOD}/lib" \
                nohup "$_INTG_TOR_BIN" -f /data/tor/torrc \
                >> "$_INTG_TOR_LOG" 2>&1 &
            sleep 2
            _pid=$(pgrep -f "$_INTG_TOR_BIN" 2>/dev/null | head -1 || printf '')
            local _running=false
            [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null && _running=true
            "$JQ" -nc \
                --argjson running "${_running}" \
                --argjson pid     "${_pid:-0}"  \
                '{installed:true,ok:true,running:$running,pid:$pid}'
            ;;

        stop)
            # Kill tor binary and any service.sh supervisor (prevents auto-restart)
            pkill -f "${_INTG_TOR_BIN}" 2>/dev/null
            pkill -f "${_INTG_TOR_MOD}/service.sh" 2>/dev/null
            sleep 1
            local _still _running=false
            _still=$(pgrep -f "$_INTG_TOR_BIN" 2>/dev/null | head -1 || printf '')
            [ -n "$_still" ] && kill -0 "$_still" 2>/dev/null && _running=true
            "$JQ" -nc \
                --argjson running "${_running}" \
                '{installed:true,ok:true,running:$running}'
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
_INTG_SSH_DATA=/data/ssh
_INTG_SSH_MOUNTDIR=/dev/ssh
_INTG_SSH_BIN=/system/bin/dropbear
_INTG_SSH_PID=/data/ssh/dropbear.pid
_INTG_SSH_LOG=/data/ssh/dropbear.log
_INTG_SSH_PORT=22222

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

        start)
            if pgrep -x dropbear >/dev/null 2>&1; then
                # Already running — return current status
                local _port=""
                _port=$(netstat -tlnp 2>/dev/null \
                    | awk '/[0-9]\/dropbear/{split($4,a,":"); print a[length(a)]; exit}')
                [ -z "$_port" ] && _port="$_INTG_SSH_PORT"
                "$JQ" -nc \
                    --arg port "${_port}" \
                    '{installed:true,ok:true,running:true,port:$port,msg:"already running"}'
                return 0
            fi
            # Refuse start without authorized_keys (avoids unauthenticated root sshd)
            if [ ! -s "$_INTG_SSH_KEYS" ]; then
                "$JQ" -nc \
                    '{installed:true,ok:false,err:"no authorized_keys — cannot start unauthenticated sshd"}'
                return 0
            fi
            # Ensure /dev/ssh bind-mount (dropbear requires non-group-writable parent dir)
            mkdir -p "$_INTG_SSH_MOUNTDIR"
            if ! mountpoint -q "$_INTG_SSH_MOUNTDIR" 2>/dev/null; then
                mount --bind "$_INTG_SSH_DATA" "$_INTG_SSH_MOUNTDIR" 2>/dev/null
            fi
            # Launch dropbear directly (-F: no self-fork; backgrounded via &).
            # -E: log to stderr (captured by >> redirect). -s/-g: no passwords.
            nohup "$_INTG_SSH_BIN" -F -E -s -g \
                -D "$_INTG_SSH_MOUNTDIR" \
                -c /system/bin/ssh-login \
                -r "${_INTG_SSH_MOUNTDIR}/keys/rsa" \
                -r "${_INTG_SSH_MOUNTDIR}/keys/ecdsa" \
                -r "${_INTG_SSH_MOUNTDIR}/keys/ed25519" \
                -p "$_INTG_SSH_PORT" \
                -P "$_INTG_SSH_PID" \
                -K 60 \
                >> "$_INTG_SSH_LOG" 2>&1 &
            sleep 1
            local _running=false _port=""
            if pgrep -x dropbear >/dev/null 2>&1; then
                _running=true
                _port="$_INTG_SSH_PORT"
            fi
            "$JQ" -nc \
                --argjson running "${_running}" \
                --arg     port    "${_port:-}"  \
                '{installed:true,ok:true,running:$running,port:$port}'
            ;;

        stop)
            # Kill service.sh supervisor first (prevents auto-restart in 5 s),
            # then terminate dropbear via pidfile + pgrep fallback.
            pkill -f "${_INTG_SSH_MOD}/service.sh" 2>/dev/null
            local _pid
            _pid=$(cat "$_INTG_SSH_PID" 2>/dev/null | tr -d ' \t\r\n')
            [ -n "$_pid" ] && kill "$_pid" 2>/dev/null
            pkill -x dropbear 2>/dev/null
            sleep 1
            local _running=false
            pgrep -x dropbear >/dev/null 2>&1 && _running=true
            "$JQ" -nc \
                --argjson running "${_running}" \
                '{installed:true,ok:true,running:$running}'
            ;;

        *)
            "$JQ" -nc --arg sub "$_sub" \
                '{installed:true, ok:false, err:"unknown ssh sub-command"}'
            ;;
    esac
}
