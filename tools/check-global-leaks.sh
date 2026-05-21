#!/bin/bash
# Pre-commit hook to detect global variable leaks
# Install: Copy to .git/hooks/pre-commit and make executable

echo "Checking for global variable leaks..."

# Pattern: indented assignment that looks like parameter reassignment
# Matches: "    variable = variable or"
LEAKS=$(grep -rn '^\s\+[a-z][a-zA-Z0-9_]*\s*=\s*[a-z][a-zA-Z0-9_]*\s*or\s*' src/ --include="*.lua" | grep -v 'local ')

if [ -n "$LEAKS" ]; then
    echo "ERROR: Potential global variable leaks detected!"
    echo ""
    echo "The following lines reassign parameters without 'local' keyword:"
    echo "$LEAKS"
    echo ""
    echo "FIX: Add 'local' keyword before variable name:"
    echo "  BEFORE: cost = cost or 0"
    echo "  AFTER:  local cost = cost or 0"
    echo ""
    exit 1
fi

echo "No global leaks detected!"
exit 0
