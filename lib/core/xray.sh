#!/system/bin/sh
# lib/core/xray.sh — start/stop xray + hev-socks5-tunnel; xray_status_json
#
# Interfaces:
#   xray_start()        — start xray; in tun0 mode also start hev-socks5-tunnel
#                         and call route_apply; writes pid files
#   xray_stop()         — stop both, tear down tun0, call route_clear
#   xray_status_json()  — emit {running,pid,mode,listen,vpn_gateway}
#
# Requires: env.sh + routing.sh sourced first (action.sh handles ordering)

[ -n "${_XRAY_SH_LOADED:-}" ] && return 0
_XRAY_SH_LOADED=1

# Source routing.sh if not already loaded (allows standalone sourcing)
[ -n "${_ROUTING_SH_LOADED:-}" ] || {
    _d="${DCP_MOD:-/data/adb/modules/dikec-control-panel}"
    . "$_d/lib/core/routing.sh"
}

# ── constants ─────────────────────────────────────────────────────────────────

XRAY_BIN="${DCP_MOD:-/data/adb/modules/dikec-control-panel}/system/bin/xray"
HEV_BIN="${DCP_MOD:-/data/adb/modules/dikec-control-panel}/system/bin/hev-socks5-tunnel"
XRAY_CONF="${DCP_DATA:-/data/dikec}/xray/config.json"
XRAY_PID="${DCP_DATA:-/data/dikec}/xray/xray.pid"
HEV_PID="${DCP_DATA:-/data/dikec}/xray/hev.pid"
HEV_CONF="${DCP_DATA:-/data/dikec}/xray/hev.yml"
XRAY_LOG="${DCP_DATA:-/data/dikec}/logs/xray.log"
HEV_LOG="${DCP_DATA:-/data/dikec}/logs/hev.log"
SOCKS_PORT=10808
WATCHDOG_PID="${DCP_DATA:-/data/dikec}/xray/watchdog.pid"
WATCHDOG_INTERVAL=30
WATCHDOG_MAX_FAILS=5
WATCHDOG_COOLDOWN=300

# ── hev config ────────────────────────────────────────────────────────────────

_hev_write_config() {
    mkdir -p "$(dirname "$HEV_CONF")"
    cat > "$HEV_CONF" << 'HEVEOF'
tunnel:
  name: tun0
  mtu: 8500
  ipv4: 198.18.0.1
socks5:
  address: 127.0.0.1
  port: 10808
  udp: 'udp'
HEVEOF
    dcp_log "xray: hev config written to $HEV_CONF"
}

# ── port-open check ───────────────────────────────────────────────────────────

# /proc/net/tcp stores IPs in little-endian hex; 127.0.0.1 = 0100007F
# Port 10808 = 0x2A38 (big-endian in proc format)
_socks_listening() {
    grep -qiE "0100007F:2A38[[:space:]]" /proc/net/tcp 2>/dev/null
}

# ── watchdog ──────────────────────────────────────────────────────────────────
# Background loop: her $WATCHDOG_INTERVAL saniyede xray (+ tun0 modunda hev)
# PID'lerini ve socks port'u kontrol eder. Ölmüşse otomatik yeniden başlatır.
# Üst üste $WATCHDOG_MAX_FAILS başarısız restart → $WATCHDOG_COOLDOWN bekle.
# xray_stop çağrıldığında xray_enabled=0 olur → watchdog kendini sonlandırır.

_xray_watchdog_stop() {
    if [ -f "$WATCHDOG_PID" ]; then
        local wpid
        wpid=$(cat "$WATCHDOG_PID" 2>/dev/null)
        if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
            kill "$wpid" 2>/dev/null || true
        fi
        rm -f "$WATCHDOG_PID"
        dcp_log "watchdog: stopped (pid=${wpid:-?})"
    fi
}

_xray_watchdog_start() {
    # Önce mevcut watchdog'u durdur (tekil instance garantisi)
    _xray_watchdog_stop

    (
        fails=0
        while true; do
            sleep "$WATCHDOG_INTERVAL"

            # xray_enabled=0 → kullanıcı xray_stop çağırdı, çık
            [ "$(cfg_get xray_enabled 0)" = "1" ] || {
                dcp_log "watchdog: xray_enabled=0, exiting"
                rm -f "$WATCHDOG_PID"
                exit 0
            }

            alive=true

            # 1) xray PID kontrolü
            xpid=""
            [ -f "$XRAY_PID" ] && xpid=$(cat "$XRAY_PID" 2>/dev/null)
            if [ -z "$xpid" ] || ! kill -0 "$xpid" 2>/dev/null; then
                dcp_log "watchdog: xray process dead (pid=${xpid:-?})"
                alive=false
            fi

            # 2) tun0 modunda hev PID kontrolü
            if $alive && [ "$(cfg_get route_mode tun0)" = "tun0" ]; then
                hpid=""
                [ -f "$HEV_PID" ] && hpid=$(cat "$HEV_PID" 2>/dev/null)
                if [ -z "$hpid" ] || ! kill -0 "$hpid" 2>/dev/null; then
                    dcp_log "watchdog: hev process dead (pid=${hpid:-?})"
                    alive=false
                fi
            fi

            # 3) Socks port health check (process hayatta ama port kapanmış olabilir)
            if $alive && ! _socks_listening; then
                dcp_log "watchdog: socks port 10808 not listening (xray hung?)"
                alive=false
            fi

            # 4) Routing / ip rule kontrolü (Android netd boot sonrası kuralları ezmiş olabilir)
            if $alive; then
                local rmode
                rmode=$(cfg_get route_mode tun0)
                if [ "$rmode" = "tun0" ]; then
                    if ! /system/bin/ip rule show 2>/dev/null | grep -q '200'; then
                        dcp_log "watchdog: ip rule for table 200 missing (wiped by netd?)"
                        alive=false
                    fi
                elif [ "$rmode" = "tproxy" ]; then
                    if ! /system/bin/ip rule show 2>/dev/null | grep -q '100'; then
                        dcp_log "watchdog: ip rule for table 100 missing (wiped by netd?)"
                        alive=false
                    fi
                fi
            fi

            # Herşey yolunda → sayacı sıfırla
            if $alive; then
                fails=0
                continue
            fi

            # Sorun var → restart
            fails=$((fails + 1))
            if [ "$fails" -gt "$WATCHDOG_MAX_FAILS" ]; then
                dcp_log "watchdog: $fails consecutive fails, cooldown ${WATCHDOG_COOLDOWN}s"
                sleep "$WATCHDOG_COOLDOWN"
                fails=0
            fi

            dcp_log "watchdog: restarting xray (attempt #$fails)"
            # _WATCHDOG_RESTART flag: xray_stop/xray_start watchdog'u tekrar
            # başlatıp/durdurup sonsuz döngü oluşturmasın
            _WATCHDOG_RESTART=1
            export _WATCHDOG_RESTART
            xray_stop 2>/dev/null || true
            # xray_stop xray_enabled=0 yapar, geri aç
            cfg_set xray_enabled 1
            sleep 2
            if xray_start 2>/dev/null; then
                dcp_log "watchdog: restart successful"
                fails=0
            else
                dcp_log "watchdog: restart failed"
            fi
            unset _WATCHDOG_RESTART
        done
    ) >> "${DCP_DATA:-/data/dikec}/logs/xray.log" 2>&1 &
    echo $! > "$WATCHDOG_PID"
    dcp_log "watchdog: started (pid=$!, interval=${WATCHDOG_INTERVAL}s)"
}

# ── xray_start ───────────────────────────────────────────────────────────────

xray_start() {
    local mode
    mode=$(cfg_get route_mode tun0)
    dcp_log "xray_start: mode=$mode"

    # Stop any lingering instance cleanly first
    xray_stop 2>/dev/null || true

    # Validate prerequisites
    [ -f "$XRAY_CONF" ] || {
        dcp_log "xray_start: no config.json at $XRAY_CONF (run prof_switch first)"
        return 1
    }
    [ -x "$XRAY_BIN" ] || {
        dcp_log "xray_start: xray binary missing or not executable"
        return 1
    }

    mkdir -p "${DCP_DATA:-/data/dikec}/logs" "${DCP_DATA:-/data/dikec}/xray"

    # ── 1) Start xray ────────────────────────────────────────────────────────
    log_rotate 524288 2>/dev/null || true
    "$XRAY_BIN" run -config "$XRAY_CONF" >> "$XRAY_LOG" 2>&1 &
    local xpid=$!
    printf '%s' "$xpid" > "$XRAY_PID"
    dcp_log "xray_start: xray launched pid=$xpid"

    # Wait up to 8s for socks port to open
    local waited=0
    while ! _socks_listening; do
        if [ "$waited" -ge 8 ]; then
            dcp_log "xray_start: socks port not open after 8s — abort"
            kill "$xpid" 2>/dev/null; rm -f "$XRAY_PID"
            return 1
        fi
        sleep 1; waited=$((waited + 1))
    done
    dcp_log "xray_start: socks 127.0.0.1:$SOCKS_PORT is listening"

    # ── 2) tun0 mode: write hev config and start hev-socks5-tunnel ──────────
    if [ "$mode" = "tun0" ]; then
        [ -x "$HEV_BIN" ] || {
            dcp_log "xray_start: hev binary missing — stop xray and abort"
            kill "$xpid" 2>/dev/null; rm -f "$XRAY_PID"
            return 1
        }

        _hev_write_config
        "$HEV_BIN" "$HEV_CONF" >> "$HEV_LOG" 2>&1 &
        local hpid=$!
        printf '%s' "$hpid" > "$HEV_PID"
        dcp_log "xray_start: hev-socks5-tunnel launched pid=$hpid"

        # Wait up to 10s for tun0 to appear
        local hw=0
        while ! /system/bin/ip link show tun0 >/dev/null 2>&1; do
            if [ "$hw" -ge 10 ]; then
                dcp_log "xray_start: tun0 not up after 10s — abort"
                kill "$hpid" 2>/dev/null; rm -f "$HEV_PID"
                kill "$xpid" 2>/dev/null; rm -f "$XRAY_PID"
                return 1
            fi
            sleep 1; hw=$((hw + 1))
        done
        dcp_log "xray_start: tun0 is up"
    fi

    # ── 3) Apply routing ─────────────────────────────────────────────────────
    if ! route_apply "$mode"; then
        dcp_log "xray_start: route_apply failed — tearing down"
        xray_stop
        return 1
    fi

    cfg_set xray_enabled 1
    dcp_log "xray_start: done mode=$mode"

    # Watchdog başlat (sadece doğrudan çağrılarda, watchdog restart'ından değil)
    if [ -z "${_WATCHDOG_RESTART:-}" ]; then
        _xray_watchdog_start
    fi
}

# ── xray_stop ─────────────────────────────────────────────────────────────────

xray_stop() {
    local mode
    mode=$(cfg_get route_mode tun0)
    dcp_log "xray_stop: mode=$mode"

    # Watchdog'u durdur (sadece doğrudan çağrılarda, watchdog restart'ından değil)
    if [ -z "${_WATCHDOG_RESTART:-}" ]; then
        _xray_watchdog_stop
    fi

    # ── 1) Clear routing first ───────────────────────────────────────────────
    # This removes ip rules/routes and removes tun0 from rt_tables,
    # triggering vpn-gateway inotifyd to clean up its FORWARD + ip rules.
    route_clear "$mode" 2>/dev/null || true

    # ── 2) Kill hev-socks5-tunnel (tears down tun0 interface) ───────────────
    local hpid=""
    if [ -f "$HEV_PID" ]; then
        hpid=$(cat "$HEV_PID" 2>/dev/null || true)
        if [ -n "$hpid" ] && kill -0 "$hpid" 2>/dev/null; then
            kill "$hpid" 2>/dev/null
            sleep 1
            kill -9 "$hpid" 2>/dev/null || true
        fi
        rm -f "$HEV_PID"
        dcp_log "xray_stop: hev killed pid=${hpid:-?}"
    fi
    # Fallback: catch any stray hev processes
    BU_BB="${BU:-/data/adb/modules/bin-utils}/system/bin/busybox"
    "$BU_BB" pkill -f hev-socks5-tunnel 2>/dev/null || true

    # ── 3) Ensure tun0 is gone ───────────────────────────────────────────────
    # hev normally closes the TUN fd on exit → interface auto-removed.
    # If it persists (e.g. IFF_PERSIST), force-remove it.
    local tw=0
    while /system/bin/ip link show tun0 >/dev/null 2>&1; do
        if [ "$tw" -ge 3 ]; then
            dcp_log "xray_stop: tun0 still present after 3s, trying ip link delete"
            /system/bin/ip link set tun0 down 2>/dev/null || true
            /system/bin/ip link delete tun0 2>/dev/null || true
            break
        fi
        sleep 1; tw=$((tw + 1))
    done
    if /system/bin/ip link show tun0 >/dev/null 2>&1; then
        dcp_log "xray_stop: WARNING — tun0 still exists after forced removal"
    else
        dcp_log "xray_stop: tun0 is gone"
    fi

    # ── 4) Kill xray ─────────────────────────────────────────────────────────
    local xpid=""
    if [ -f "$XRAY_PID" ]; then
        xpid=$(cat "$XRAY_PID" 2>/dev/null || true)
        if [ -n "$xpid" ] && kill -0 "$xpid" 2>/dev/null; then
            kill "$xpid" 2>/dev/null
            sleep 1
            kill -9 "$xpid" 2>/dev/null || true
        fi
        rm -f "$XRAY_PID"
        dcp_log "xray_stop: xray killed pid=${xpid:-?}"
    fi
    # Fallback
    "$BU_BB" pkill -f "xray run" 2>/dev/null || true

    cfg_set xray_enabled 0
    dcp_log "xray_stop: done"
}

# ── xray_status_json ──────────────────────────────────────────────────────────

xray_status_json() {
    local running=false xpid=0 mode vpn_gw=false

    mode=$(cfg_get route_mode tun0)

    if [ -f "$XRAY_PID" ]; then
        xpid=$(cat "$XRAY_PID" 2>/dev/null || printf '0')
        if [ -n "$xpid" ] && [ "$xpid" -gt 0 ] 2>/dev/null && kill -0 "$xpid" 2>/dev/null; then
            running=true
        fi
    fi

    _vpn_gateway_installed && vpn_gw=true

    "${JQ:-jq}" -nc \
        --argjson running  "$running" \
        --argjson pid      "${xpid:-0}" \
        --arg     mode     "$mode" \
        --argjson listen   "$SOCKS_PORT" \
        --argjson vpn_gateway "$vpn_gw" \
        '{running:$running, pid:$pid, mode:$mode, listen:$listen, vpn_gateway:$vpn_gateway}'
}
