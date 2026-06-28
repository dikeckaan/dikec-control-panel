#!/system/bin/sh
# lib/core/system.sh — cihaz metrik okuyucu (cold-cache: 15s TTL)
. "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/lib/core/env.sh"

# --- yardımcılar -----------------------------------------------------------

_temp_c(){
    local v temp_val=0
    for z in /sys/class/thermal/thermal_zone*/temp; do
        v=$(cat "$z" 2>/dev/null | tr -dc '0-9')
        if [ -n "$v" ] && [ "$v" -gt 1000 ] 2>/dev/null; then
            temp_val=$((v / 1000))
            break
        elif [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null; then
            temp_val="$v"
            break
        fi
    done
    printf '%s' "${temp_val:-0}"
}

# Prints "used_mb total_mb" (space-separated)
_mem(){
    awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}/MemFree/{f=$2}/Buffers/{b=$2}/Cached/{c=$2}END{
        if(a==0) a=f+b+c;
        printf "%d %d", (t-a)/1024, t/1024
    }' /proc/meminfo 2>/dev/null
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
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
    if [ -f "$cache" ] && [ "$(( now - mtime ))" -lt 15 ] 2>/dev/null; then
        # Ensure cache isn't empty/corrupt before returning it
        if grep -q "model" "$cache" 2>/dev/null; then
            cat "$cache"; return
        fi
    fi

    _memstr=$(_mem)
    mu=$(printf '%s' "$_memstr" | awk '{print $1}')
    mt=$(printf '%s' "$_memstr" | awk '{print $2}')
    cpu=$(_cpu_pct)
    up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    tmp=$(_temp_c)
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    modver=$(sed -n 's/^version=//p' "${DCP_MOD:-/data/adb/modules/dikec-control-panel}/module.prop" 2>/dev/null | head -1)
    model=$(getprop ro.product.model 2>/dev/null)

    [ -z "$mu" ] && mu=0
    [ -z "$mt" ] && mt=0
    [ -z "$cpu" ] && cpu=0
    [ -z "$up" ] && up=0
    [ -z "$tmp" ] && tmp=0
    [ -z "$load1" ] && load1="0.00"
    [ -z "$modver" ] && modver="2.0"
    [ -z "$model" ] && model="ZTE F50"

    mkdir -p "$DCP_DATA/conf" 2>/dev/null
    out=$("$JQ" -nc \
        --arg    model  "$model"     \
        --argjson up    "$up"        \
        --argjson mu    "$mu"        \
        --argjson mt    "$mt"        \
        --argjson cpu   "$cpu"       \
        --argjson temp  "$tmp"       \
        --arg    modver "$modver"    \
        --arg    load1  "$load1"     \
        '{model:$model,uptime_s:$up,mem_used_mb:$mu,mem_total_mb:$mt,cpu_pct:$cpu,temp_c:$temp,module_version:$modver,load1:$load1}' 2>/dev/null)
    
    # Fallback if JQ fails for any reason
    if [ -z "$out" ]; then
        out="{\"model\":\"$model\",\"uptime_s\":$up,\"mem_used_mb\":$mu,\"mem_total_mb\":$mt,\"cpu_pct\":$cpu,\"temp_c\":$tmp,\"module_version\":\"$modver\",\"load1\":\"$load1\"}"
    fi

    printf '%s\n' "$out" | tee "$cache"
}

sys_throughput_json(){
    i="${1:-rmnet_data0}"
    awk -v i="$i:" '$1==i{print $2" "$10}' /proc/net/dev | \
        "$JQ" -Rnc 'input | split(" ") | {rx_bytes:(.[0]//"0"|tonumber), tx_bytes:(.[1]//"0"|tonumber)}' \
        2>/dev/null || echo '{}'
}

sys_clients_json(){
    # Hotspot (br0) clients from the ARP table: ip + mac. Excludes the zero-MAC
    # broadcast placeholder. Hostname is best-effort (no readable lease file on
    # this firmware), left empty → the panel falls back to showing the IP.
    # Returns both the full array (per-client bypass UI) and the count.
    local arr
    arr=$(awk 'NR>1 && $4!="00:00:00:00:00:00" && $6=="br0"{print $1" "$4}' /proc/net/arp 2>/dev/null \
        | "$JQ" -Rnc '[inputs | split(" ") | select(.[0]!=null and .[0]!="") | {ip:.[0], mac:.[1], hostname:"", iface:"br0"}]')
    [ -n "$arr" ] || arr='[]'
    "$JQ" -nc --argjson c "${arr:-[]}" '{clients:$c, client_count:($c|length)}'
}
