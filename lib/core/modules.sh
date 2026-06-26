#!/system/bin/sh
# lib/core/modules.sh — Magisk module manager.
#   mod_list_json                  — installed modules (id,name,version,enabled,removing)
#   mod_enable/mod_disable <id>    — toggle Magisk disable flag
#   mod_remove/mod_unremove <id>   — toggle Magisk remove flag
#   mod_catalog_json               — dikeckaan ecosystem catalog (+ installed/update state)
#   mod_install_catalog <id>       — download + install a catalog module
#   mod_install_zip <path>         — install an arbitrary module zip (uploaded)
#
# SECURITY: every <id> is sanitized BEFORE building a /data/adb/modules path
# (path-traversal guard). Zip install paths are restricted to /data/local/tmp/.
# Installing a module runs code as root — these verbs sit behind the panel's
# session/token auth and the bot's owner-gate.

[ -n "${_MODULES_SH_LOADED:-}" ] && return 0
_MODULES_SH_LOADED=1

[ -n "${DCP_DATA:-}" ] || {
    _d="${DCP_MOD:-/data/adb/modules/dikec-control-panel}"
    . "$_d/lib/core/env.sh"
}

MOD_DIR=/data/adb/modules
MOD_CATALOG_URL="https://raw.githubusercontent.com/dikeckaan/f50-magisk-modules/main/modules.json"
MOD_CATALOG_CACHE="$DCP_DATA/.modules-catalog.json"
MOD_CATALOG_TTL=600

# ── id sanitize (path-traversal guard) ────────────────────────────────────────
_mod_valid_id() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        .|..) return 1 ;;
    esac
    return 0
}

# ── mod_list_json ─────────────────────────────────────────────────────────────
mod_list_json() {
    local arr="[]" d id name ver vcode enabled removing updatej
    for d in "$MOD_DIR"/*/; do
        [ -f "$d/module.prop" ] || continue
        id=$(sed -n 's/^id=//p'          "$d/module.prop" | head -1)
        name=$(sed -n 's/^name=//p'      "$d/module.prop" | head -1)
        ver=$(sed -n 's/^version=//p'    "$d/module.prop" | head -1)
        vcode=$(sed -n 's/^versionCode=//p' "$d/module.prop" | head -1)
        updatej=$(sed -n 's/^updateJson=//p' "$d/module.prop" | head -1)
        [ -f "$d/disable" ] && enabled=false || enabled=true
        [ -f "$d/remove" ]  && removing=true || removing=false
        case "$vcode" in ''|*[!0-9]*) vcode=0 ;; esac
        arr=$("$JQ" -nc --argjson a "$arr" \
            --arg id "$id" --arg name "$name" --arg ver "$ver" \
            --argjson vcode "$vcode" --argjson en "$enabled" --argjson rm "$removing" \
            --arg uj "$updatej" \
            '$a + [{id:$id,name:$name,version:$ver,versionCode:$vcode,enabled:$en,removing:$rm,updateJson:$uj}]')
    done
    "$JQ" -nc --argjson m "$arr" '{modules: ($m | sort_by(.name|ascii_downcase))}'
}

# ── enable / disable / remove (Magisk flags) ──────────────────────────────────
mod_enable() {
    _mod_valid_id "$1" || { "$JQ" -nc '{err:"invalid-id"}'; return 1; }
    [ -d "$MOD_DIR/$1" ] || { "$JQ" -nc '{err:"not-installed"}'; return 1; }
    rm -f "$MOD_DIR/$1/disable" 2>/dev/null
    "$JQ" -nc --arg id "$1" '{id:$id, enabled:true}'
}
mod_disable() {
    _mod_valid_id "$1" || { "$JQ" -nc '{err:"invalid-id"}'; return 1; }
    [ -d "$MOD_DIR/$1" ] || { "$JQ" -nc '{err:"not-installed"}'; return 1; }
    # never let the user disable the very module serving this request
    [ "$1" = "dikec-control-panel" ] && { "$JQ" -nc '{err:"cannot-disable-self"}'; return 1; }
    : > "$MOD_DIR/$1/disable"
    "$JQ" -nc --arg id "$1" '{id:$id, enabled:false}'
}
mod_remove() {
    _mod_valid_id "$1" || { "$JQ" -nc '{err:"invalid-id"}'; return 1; }
    [ -d "$MOD_DIR/$1" ] || { "$JQ" -nc '{err:"not-installed"}'; return 1; }
    [ "$1" = "dikec-control-panel" ] && { "$JQ" -nc '{err:"cannot-remove-self"}'; return 1; }
    [ "$1" = "bin-utils" ] && { "$JQ" -nc '{err:"bin-utils-required"}'; return 1; }
    : > "$MOD_DIR/$1/remove"
    "$JQ" -nc --arg id "$1" '{id:$id, removing:true, reboot_required:true}'
}
mod_unremove() {
    _mod_valid_id "$1" || { "$JQ" -nc '{err:"invalid-id"}'; return 1; }
    rm -f "$MOD_DIR/$1/remove" 2>/dev/null
    "$JQ" -nc --arg id "$1" '{id:$id, removing:false}'
}

# ── catalog ───────────────────────────────────────────────────────────────────
_mod_catalog_fetch() {
    local now age
    now=$(date +%s 2>/dev/null || echo 0)
    if [ -r "$MOD_CATALOG_CACHE" ]; then
        age=$(( now - $(stat -c %Y "$MOD_CATALOG_CACHE" 2>/dev/null || echo 0) ))
        [ "$age" -lt "$MOD_CATALOG_TTL" ] && { printf '%s' "$MOD_CATALOG_CACHE"; return 0; }
    fi
    local tmp="$MOD_CATALOG_CACHE.tmp"
    if "$CURL" -fsSL --cacert "$CA" --max-time 20 -o "$tmp" "$MOD_CATALOG_URL" 2>/dev/null \
        && "$JQ" -e . "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$MOD_CATALOG_CACHE"
    else
        rm -f "$tmp"
    fi
    [ -r "$MOD_CATALOG_CACHE" ] && printf '%s' "$MOD_CATALOG_CACHE"
}

mod_catalog_json() {
    local cache; cache=$(_mod_catalog_fetch)
    [ -n "$cache" ] && [ -r "$cache" ] || { "$JQ" -nc '{ok:false,err:"catalog-unavailable",catalog:[]}'; return 0; }
    # annotate each catalog entry with installed-state + installed version
    "$JQ" -nc --slurpfile cat "$cache" --argjson inst "$(mod_list_json)" '
        ($inst.modules | map({(.id): .}) | add) as $by
        | { ok:true, catalog: ( ($cat[0].modules // $cat[0] // []) | map(
              . + { installed: (($by[.id] // null) != null),
                    installedVersion: ($by[.id].version // null) } )) }'
}

mod_install_catalog() {
    _mod_valid_id "$1" || { "$JQ" -nc '{err:"invalid-id"}'; return 1; }
    local cache; cache=$(_mod_catalog_fetch)
    [ -n "$cache" ] || { "$JQ" -nc '{err:"catalog-unavailable"}'; return 1; }
    local uj
    uj=$("$JQ" -r --arg id "$1" '((.modules // .)[] | select(.id==$id) | .updateJson // .zipUrl) // empty' "$cache" 2>/dev/null | head -1)
    [ -n "$uj" ] || { "$JQ" -nc '{err:"not-in-catalog"}'; return 1; }
    # resolve a zip url: updateJson points to a json with zipUrl, else uj IS the zip
    local zipurl="$uj"
    case "$uj" in
        *.json) zipurl=$("$CURL" -fsSL --cacert "$CA" --max-time 20 "$uj" 2>/dev/null | "$JQ" -r '.zipUrl // empty' 2>/dev/null) ;;
    esac
    [ -n "$zipurl" ] || { "$JQ" -nc '{err:"no-zip-url"}'; return 1; }
    # mktemp avoids the predictable $$ name (TOCTOU/symlink race in shared tmp)
    local tmp
    tmp=$(mktemp /data/local/tmp/modinstall.XXXXXX 2>/dev/null) || tmp="/data/local/tmp/.modinstall.$$.tmp"
    mv "$tmp" "$tmp.zip" 2>/dev/null && tmp="$tmp.zip"
    "$CURL" -fsSL --cacert "$CA" --max-time 120 -o "$tmp" "$zipurl" 2>/dev/null \
        || { rm -f "$tmp"; "$JQ" -nc '{err:"download-failed"}'; return 1; }
    mod_install_zip "$tmp"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

# ── install an arbitrary module zip ───────────────────────────────────────────
mod_install_zip() {
    local zip="$1"
    # path guard: only allow staged uploads under /data/local/tmp. A bare glob
    # check is bypassable because shell `case` * also matches '/', so resolve the
    # real path (defeats ../ traversal + symlinks) and re-check it.
    case "$zip" in
        *..*|*//*|*'
'*) "$JQ" -nc '{err:"invalid-zip-path"}'; return 1 ;;
    esac
    local real
    real=$(readlink -f -- "$zip" 2>/dev/null) || { "$JQ" -nc '{err:"invalid-zip-path"}'; return 1; }
    case "$real" in
        /data/local/tmp/*.zip) zip="$real" ;;
        *) "$JQ" -nc '{err:"invalid-zip-path"}'; return 1 ;;
    esac
    [ -s "$zip" ] || { "$JQ" -nc '{err:"zip-missing"}'; return 1; }
    # sanity: must be a zip with a module.prop
    if ! "$BB" unzip -l "$zip" 2>/dev/null | grep -q 'module.prop'; then
        "$JQ" -nc '{err:"not-a-module-zip"}'; return 1
    fi
    local out rc
    out=$(magisk --install-module "$zip" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
        "$JQ" -nc --arg log "$(printf '%s' "$out" | tail -c 600)" \
            '{ok:true, installed:true, reboot_required:true, log:$log}'
    else
        "$JQ" -nc --arg log "$(printf '%s' "$out" | tail -c 600)" \
            '{ok:false, err:"install-failed", log:$log}'
    fi
}
