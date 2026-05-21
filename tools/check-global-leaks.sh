#!/bin/bash
# Pre-commit hook to detect global variable leaks
# Install: Copy to .git/hooks/pre-commit and make executable

echo "Checking for global variable leaks..."

# Pattern: indented assignment that looks like parameter reassignment
# Matches: "    variable = variable or"
# Excludes: trailing-comma lines (table field assignments) and local declarations
LEAKS=$(grep -rn '^\s\+[a-z][a-zA-Z0-9_]*\s*=\s*[a-z][a-zA-Z0-9_]*\s\+or\s\+' src/ --include="*.lua" \
    | grep -v 'local ' \
    | grep -v ',\s*$')

if [ -n "$LEAKS" ]; then
    echo "WARNING: Possible global variable leaks (review manually):"
    echo "NOTE: This script cannot distinguish function parameters (implicitly local in Lua)."
    echo "      Use tools/find_global_leaks_v2.js for scope-aware analysis."
    echo ""
    echo "$LEAKS"
    echo ""
fi

echo "check-global-leaks done (exit 0 — scope-unaware; review above if any)"
exit 0
