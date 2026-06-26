#!/bin/bash
# tools/build-zip.sh — local zip builder for dikec-control-panel Magisk module
# Usage: sh tools/build-zip.sh
# Output: dist/dikec-control-panel-<version>.zip

set -euo pipefail

# Resolve module root regardless of where this script is called from
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Read version from module.prop
MODULE_PROP="$ROOT/module.prop"
if [ ! -f "$MODULE_PROP" ]; then
    echo "ERROR: module.prop not found at $MODULE_PROP" >&2
    exit 1
fi

VERSION=$(grep '^version=' "$MODULE_PROP" | sed 's/^version=//' | tr -d '\r')
if [ -z "$VERSION" ]; then
    echo "ERROR: could not read version from module.prop" >&2
    exit 1
fi

DIST="$ROOT/dist"
mkdir -p "$DIST"

OUT="$DIST/dikec-control-panel-${VERSION}.zip"

echo "Building: dikec-control-panel ${VERSION}"
echo "Root:     $ROOT"
echo "Output:   $OUT"

# Remove any existing zip at that path
rm -f "$OUT"

# Build the zip from the module root.
# Include everything, then explicitly exclude unwanted paths.
# zip -x patterns are shell globs matched against the in-archive paths.
(
    cd "$ROOT"
    zip -r "$OUT" . \
        -x ".git/*" \
        -x ".git" \
        -x "docs/*" \
        -x "docs" \
        -x ".superpowers/*" \
        -x ".superpowers" \
        -x ".github/*" \
        -x ".github" \
        -x "dist/*" \
        -x "dist" \
        -x "*.zip" \
        -x "tools/build-zip.sh" \
        -x ".DS_Store" \
        -x "*/.DS_Store" \
        -x "*.md" \
        -x ".gitignore" \
        2>&1 | grep -v "^\s*$" || true
)

# Verify mandatory entries are present
_tmplist=$(mktemp)
unzip -l "$OUT" > "$_tmplist" 2>&1
missing=0
for entry in module.prop META-INF/com/google/android/update-binary lib/action.sh; do
    if ! grep -q "$entry" "$_tmplist"; then
        echo "WARNING: expected entry missing from zip: $entry" >&2
        missing=1
    fi
done
rm -f "$_tmplist"

SIZE=$(du -sh "$OUT" | awk '{print $1}')
BYTES=$(wc -c < "$OUT" | tr -d ' ')

echo ""
echo "Done: $OUT"
echo "Size: $SIZE ($BYTES bytes)"
[ "$missing" -eq 0 ] && echo "Verification: OK" || echo "Verification: WARNINGS (see above)"
