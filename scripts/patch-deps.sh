#!/usr/bin/env bash
# Patches botan 1.13.x to replace the removed `delete` keyword with `destroy()`
# so it compiles with LDC 1.39+ (Arch's system ldc package).
# Safe to run multiple times.
set -euo pipefail

DUB_CACHE="${DUB_HOME:-$HOME/.dub}/packages"

FILES=$(grep -rl --include="*.d" $'^\s*delete ' "$DUB_CACHE"/botan* 2>/dev/null || true)

if [ -z "$FILES" ]; then
    echo "No botan files need patching (already patched or not yet fetched)."
    exit 0
fi

echo "Patching botan source files..."
echo "$FILES" | while read -r f; do
    sed -i -E 's/^([[:space:]]*)delete (.*);/\1destroy(\2);/' "$f"
    echo "  patched: $f"
done
echo "Done."
