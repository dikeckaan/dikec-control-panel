#!/system/bin/sh
# lib/core/system.sh — cihaz metrik okuyucu (cold-cache: 15s TTL)
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"

# --- yardımcılar -----------------------------------------------------------

_temp_c(){
    for z in /sys/class/thermal/thermal_zone*/temp; do
        v=$(cat "$z" 2>/dev/null)
        [ "$v" -gt 1000 ] 2>/dev/null && { echo $((v/1000)); return; }
    done
    echo 0
}

# Prints "used_mb total_mb" (space-separated)
_mem(){
    awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d %d",(t-a)/1024,t/1024}' /proc/meminfo
}

# Single-sample CPU% (cumulative-since-boot; YAGNI — no two-sample delta)
# First /proc/stat line: cpu user nice system idle ...
_cpu_pct(){
    awk '/^cpu /{u=$2+$4; t=$2+$4+$5; if(t>0) print int(u/t*100); else print 0; exit}' \
        /proc/stat 2>/dev/null
}

# --- dışa açık fonksiyonlar ------------------------------------------------

sys_status_json(){
    cache="$DCP_DATA/conf/.cold_cache"
    now=$(date +%s)
    mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
    if [ -f "$cache" ] && [ "$(( now - mtime ))" -lt 15 ]; then
        cat "$cache"; return
    fi

    # Avoid toybox heredoc-read quirks — use command-substitution split
    _memstr=$(_mem)
    mu=$(printf '%s' "$_memstr" | awk '{print $1}')
    mt=$(printf '%s' "$_memstr" | awk '{print $2}')
    cpu=$(_cpu_pct)
    [ -z "$cpu" ] && cpu=0          # guard: default to 0 so --argjson stays valid
    up=$(awk '{print int($1)}' /proc/uptime)

    mkdir -p "$DCP_DATA/conf"
    out=$("$JQ" -nc \
        --arg    model "$(getprop ro.product.model)" \
        --argjson up   "$up"         \
        --argjson mu   "${mu:-0}"    \
        --argjson mt   "${mt:-0}"    \
        --argjson cpu  "$cpu"        \
        --argjson temp "$(_temp_c)"  \
        --arg    load1 "$(awk '{print $1}' /proc/loadavg)" \
        '{model:$model,uptime_s:$up,mem_used_mb:$mu,mem_total_mb:$mt,cpu_pct:$cpu,temp_c:$temp,load1:$load1}')
    echo "$out" | tee "$cache"
}

sys_throughput_json(){
    i="${1:-rmnet_data0}"
    awk -v i="$i:" '$1==i{print $2" "$10}' /proc/net/dev | \
        "$JQ" -Rnc 'input | split(" ") | {rx_bytes:(.[0]//"0"|tonumber), tx_bytes:(.[1]//"0"|tonumber)}' \
        2>/dev/null || echo '{}'
}

sys_clients_json(){
    # Count completed ARP entries (excludes the zero-MAC broadcast placeholder)
    count=$(awk 'NR>1 && $4!="00:00:00:00:00:00"{c++}END{print c+0}' /proc/net/arp 2>/dev/null)
    "$JQ" -nc --argjson n "${count:-0}" '{client_count:$n}'
}
