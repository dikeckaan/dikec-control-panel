#!/system/bin/sh
# lib/core/panelauth.sh — panel login / password / session helpers.
# Sourced by the login/passwd CGIs, api.cgi (session check) and action.sh
# (ADB-side password management). Pure functions; single source of auth truth.
#
# Storage:
#   $DCP_DATA/conf/panel_auth        (mode 600) — USER, SALT, PASS_HASH, MUST_CHANGE
#   $DCP_DATA/conf/sessions/<token>  (mode 600) — presence = valid; mtime = created
#
# Password hash = sha256( SALT + password ). No plaintext is ever stored.

[ -n "${_PANELAUTH_SH_LOADED:-}" ] && return 0
_PANELAUTH_SH_LOADED=1

[ -n "${DCP_DATA:-}" ] || {
    _d="${DCP_MOD:-/data/adb/modules/dikec-control-panel}"
    . "$_d/lib/core/env.sh"
}

PA_FILE="$DCP_DATA/conf/panel_auth"
PA_SESS_DIR="$DCP_DATA/conf/sessions"
PA_SESS_TTL=28800            # 8 hours
PA_DEFAULT_USER="admin"
PA_DEFAULT_PASS="admin"

# ── internal: random hex token ────────────────────────────────────────────────
_pa_rand() {
    tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c "${1:-32}" || \
        head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

# ── internal: iterated sha256 password hash → hex ─────────────────────────────
# A single sha256 has no work factor. This device has no argon2/bcrypt/openssl/
# cryptpw, and busybox httpd -m's salt is non-deterministic (can't verify), so
# the only option is iterating sha256. Each round is a sha256sum FORK, and fork
# latency on this low-end CPU swings hugely with system load (~0.85ms idle →
# ~11ms loaded). A high round count therefore made login take 2–20s. panel_auth
# is root-only (mode 600) — the file permission is the primary defence; the hash
# work factor is secondary. So we keep a SMALL iteration: a real work factor
# over single-shot, but a snappy login (≈0.05s idle, ≈0.3s under heavy load).
PA_HASH_ROUNDS=20
_pa_hash() {
    # $1 = salt, $2 = password
    local h i=0
    h=$(printf '%s%s' "$1" "$2" | sha256sum 2>/dev/null); h=${h%% *}
    while [ "$i" -lt "$PA_HASH_ROUNDS" ]; do
        h=$(printf '%s%s' "$h" "$1" | sha256sum 2>/dev/null); h=${h%% *}
        i=$((i + 1))
    done
    printf '%s' "$h"
}

# ── pa_seed_default — create panel_auth with admin/admin + MUST_CHANGE if absent
pa_seed_default() {
    [ -f "$PA_FILE" ] && return 0
    mkdir -p "$DCP_DATA/conf"
    local salt; salt=$(_pa_rand 16)
    {
        printf 'USER=%s\n'        "$PA_DEFAULT_USER"
        printf 'SALT=%s\n'        "$salt"
        printf 'PASS_HASH=%s\n'   "$(_pa_hash "$salt" "$PA_DEFAULT_PASS")"
        printf 'MUST_CHANGE=1\n'
    } > "$PA_FILE"
    chmod 600 "$PA_FILE" 2>/dev/null
}

# ── pa_user — echo the configured username ────────────────────────────────────
pa_user() {
    pa_seed_default
    ( . "$PA_FILE" 2>/dev/null; printf '%s' "${USER:-admin}" )
}

# ── pa_must_change — echo 1 if a password change is required, else 0 ───────────
pa_must_change() {
    pa_seed_default
    ( . "$PA_FILE" 2>/dev/null; printf '%s' "${MUST_CHANGE:-0}" )
}

# ── pa_verify USER PASS — return 0 if credentials match ───────────────────────
pa_verify() {
    pa_seed_default
    local in_user="$1" in_pass="$2" u salt ph
    # read all three fields in ONE subshell (fork cost matters on this CPU).
    # No eval — values go through `read` so a custom username can't inject.
    { read -r u; read -r salt; read -r ph; } <<EOF
$(. "$PA_FILE" 2>/dev/null; printf '%s\n%s\n%s\n' "$USER" "$SALT" "$PASS_HASH")
EOF
    [ "$in_user" = "$u" ] || return 1
    [ -n "$ph" ] || return 1
    [ "$(_pa_hash "$salt" "$in_pass")" = "$ph" ] || return 1
    return 0
}

# ── pa_set_password NEWPASS [NEWUSER] — set password (new salt), clear MUST_CHANGE
#    Invalidates all existing sessions. Echoes nothing; returns 0.
pa_set_password() {
    pa_seed_default
    local newpass="$1" newuser="${2:-}"
    [ -n "$newpass" ] || return 1
    local u salt
    u=$([ -n "$newuser" ] && printf '%s' "$newuser" || pa_user)
    salt=$(_pa_rand 16)
    {
        printf 'USER=%s\n'      "$u"
        printf 'SALT=%s\n'      "$salt"
        printf 'PASS_HASH=%s\n' "$(_pa_hash "$salt" "$newpass")"
        printf 'MUST_CHANGE=0\n'
    } > "$PA_FILE"
    chmod 600 "$PA_FILE" 2>/dev/null
    pa_session_clear_all
    return 0
}

# ── pa_reset — restore admin/admin + MUST_CHANGE=1, clear sessions (ADB rescue) ─
pa_reset() {
    rm -f "$PA_FILE"
    pa_session_clear_all
    pa_seed_default
}

# ── pa_session_new — create a session, echo its token ─────────────────────────
pa_session_new() {
    mkdir -p "$PA_SESS_DIR"; chmod 700 "$PA_SESS_DIR" 2>/dev/null
    local tok; tok=$(_pa_rand 32)
    : > "$PA_SESS_DIR/$tok"
    chmod 600 "$PA_SESS_DIR/$tok" 2>/dev/null
    printf '%s' "$tok"
}

# ── pa_session_valid TOKEN — return 0 if the session exists and isn't expired ──
pa_session_valid() {
    local tok="$1" f mt now
    case "$tok" in ''|*[!a-f0-9]*) return 1 ;; esac   # token charset guard
    f="$PA_SESS_DIR/$tok"
    [ -f "$f" ] || return 1
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    now=$(date +%s 2>/dev/null || echo 0)
    if [ $(( now - mt )) -gt "$PA_SESS_TTL" ]; then
        rm -f "$f"; return 1
    fi
    return 0
}

# ── pa_session_clear_all — drop every session (logout-all / password change) ───
pa_session_clear_all() {
    rm -rf "$PA_SESS_DIR" 2>/dev/null
    mkdir -p "$PA_SESS_DIR"; chmod 700 "$PA_SESS_DIR" 2>/dev/null
}

# ── pa_session_destroy TOKEN — drop one session (logout) ──────────────────────
pa_session_destroy() {
    case "$1" in ''|*[!a-f0-9]*) return 0 ;; esac
    rm -f "$PA_SESS_DIR/$1" 2>/dev/null
}
