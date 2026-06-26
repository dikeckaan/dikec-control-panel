#!/system/bin/sh
# lib/core/update.sh — self-update: check remote update.json, apply via magisk --install-module
# Verbs wired into action.sh: update_check, update_apply
# Port of zte-update logic adapted for Magisk module ecosystem.

# ── constants ──────────────────────────────────────────────────────────────────
_UPD_JSON_URL="https://raw.githubusercontent.com/dikeckaan/dikec-control-panel/main/update.json"
_UPD_LOG="${DCP_DATA}/logs/update.log"
_UPD_MODULE_PROP="${DCP_MOD}/module.prop"

# ── helpers ────────────────────────────────────────────────────────────────────
_upd_log() {
    mkdir -p "${DCP_DATA}/logs"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$_UPD_LOG"
}

# Read a field from module.prop  (field name → value)
_prop() {
    sed -n "s/^$1=//p" "$_UPD_MODULE_PROP" 2>/dev/null | tr -d '\r' | head -1
}

# Fetch URL to a file; uses $CURL + --cacert if CA is set.
_upd_fetch() {  # <url> <outfile>
    local _url="$1" _out="$2" _cacert=""
    [ -n "${CA:-}" ] && _cacert="--cacert $CA"
    # shellcheck disable=SC2086
    "$CURL" -fsSL --max-time 60 $_cacert -o "$_out" "$_url" 2>/dev/null
}

# ── update_check ───────────────────────────────────────────────────────────────
# Returns JSON: {ok,current,latest,versionCode_current,versionCode_latest,update_available}
# On network failure: {ok:false,err:"..."}
update_check() {
    local _work _url _rc
    _work=$(mktemp -d "${TMPDIR:-/data/local/tmp}/dcp-update.XXXXXX" 2>/dev/null) \
        || _work="/data/local/tmp/dcp-update.$$"
    mkdir -p "$_work"

    # Determine URL: prefer module.prop updateJson field
    _url=$(_prop updateJson)
    [ -n "$_url" ] || _url="$_UPD_JSON_URL"

    # Fetch remote update.json
    if ! _upd_fetch "$_url" "$_work/update.json"; then
        rm -rf "$_work"
        "$JQ" -nc --arg e "update_check: ağ hatası veya URL ulaşılamaz ($_url)" \
            '{ok:false, err:$e}'
        return 1
    fi

    # Parse remote fields
    local _rver _rcode _rzip _rsha _lver _lcode _avail
    _rver=$(  "$JQ" -r '.version      // ""' "$_work/update.json" 2>/dev/null)
    _rcode=$( "$JQ" -r '.versionCode  // "0"' "$_work/update.json" 2>/dev/null)
    _rzip=$(  "$JQ" -r '.zipUrl       // ""' "$_work/update.json" 2>/dev/null)
    _rsha=$(  "$JQ" -r '.sha256       // ""' "$_work/update.json" 2>/dev/null)

    if [ -z "$_rver" ] || [ -z "$_rcode" ]; then
        rm -rf "$_work"
        "$JQ" -nc --arg e "update_check: uzak update.json ayrıştırılamadı" \
            '{ok:false, err:$e}'
        return 1
    fi

    # Local version from module.prop
    _lver=$(_prop version)
    _lcode=$(_prop versionCode)
    [ -n "$_lcode" ] || _lcode=0

    # Compare numerically
    if [ "$_rcode" -gt "$_lcode" ] 2>/dev/null; then
        _avail=true
    else
        _avail=false
    fi

    rm -rf "$_work"
    "$JQ" -nc \
        --arg  lver   "${_lver:-unknown}" \
        --arg  rver   "$_rver" \
        --argjson lc  "${_lcode:-0}" \
        --argjson rc  "${_rcode:-0}" \
        --argjson av  "$_avail" \
        --arg    zip  "$_rzip" \
        --arg    sha  "$_rsha" \
        '{ok:true, current:$lver, versionCode_current:$lc,
          latest:$rver, versionCode_latest:$rc,
          update_available:$av, zipUrl:$zip, sha256:$sha}'
}

# ── update_apply ───────────────────────────────────────────────────────────────
# Downloads + SHA256-verifies (if hash present) + installs via magisk --install-module.
# Runs in background; logs to _UPD_LOG.
# Returns immediately: {ok:true, started:true}
update_apply() {
    local _url _rc

    # Determine updateJson URL
    _url=$(_prop updateJson)
    [ -n "$_url" ] || _url="$_UPD_JSON_URL"

    # Kick off background apply
    (
        _upd_log "update_apply: başlatılıyor"

        local _work
        _work=$(mktemp -d "${TMPDIR:-/data/local/tmp}/dcp-apply.XXXXXX" 2>/dev/null) \
            || _work="/data/local/tmp/dcp-apply.$$"
        mkdir -p "$_work"

        # Fetch update.json
        if ! _upd_fetch "$_url" "$_work/update.json"; then
            _upd_log "update_apply: update.json indirilemedi ($_url)"
            rm -rf "$_work"; exit 1
        fi

        local _rver _rcode _rzip _rsha _lcode
        _rver=$( "$JQ" -r '.version     // ""' "$_work/update.json" 2>/dev/null)
        _rcode=$("$JQ" -r '.versionCode // "0"' "$_work/update.json" 2>/dev/null)
        _rzip=$( "$JQ" -r '.zipUrl      // ""' "$_work/update.json" 2>/dev/null)
        _rsha=$( "$JQ" -r '.sha256      // ""' "$_work/update.json" 2>/dev/null)

        _lcode=$(_prop versionCode); [ -n "$_lcode" ] || _lcode=0

        # Check if update is actually needed
        if [ ! "$_rcode" -gt "$_lcode" ] 2>/dev/null; then
            _upd_log "update_apply: zaten güncel (local=$_lcode remote=$_rcode)"
            rm -rf "$_work"; exit 0
        fi

        [ -n "$_rzip" ] || { _upd_log "update_apply: zipUrl boş"; rm -rf "$_work"; exit 1; }

        _upd_log "update_apply: indiriliyor $_rver (code $_rcode) — $_rzip"
        if ! _upd_fetch "$_rzip" "$_work/module.zip"; then
            _upd_log "update_apply: zip indirilemedi"
            rm -rf "$_work"; exit 1
        fi

        # SHA256 verify (if hash provided)
        if [ -n "$_rsha" ]; then
            local _have
            _have=$(sha256sum "$_work/module.zip" 2>/dev/null | awk '{print $1}')
            if [ "$_have" != "$_rsha" ]; then
                _upd_log "update_apply: sha256 UYUŞMUYOR — beklenen $_rsha, alınan $_have"
                rm -rf "$_work"; exit 1
            fi
            _upd_log "update_apply: sha256 doğrulandı"
        fi

        # Install via magisk
        _upd_log "update_apply: magisk --install-module çalıştırılıyor"
        magisk --install-module "$_work/module.zip" >> "$_UPD_LOG" 2>&1
        local _mrc=$?
        if [ $_mrc -eq 0 ]; then
            _upd_log "update_apply: TAMAMLANDI — $_rver kuruldu (yeniden başlatma gerekli)"
        else
            _upd_log "update_apply: magisk --install-module başarısız (rc=$_mrc)"
        fi
        rm -rf "$_work"
    ) &

    "$JQ" -nc '{ok:true, started:true}'
}
