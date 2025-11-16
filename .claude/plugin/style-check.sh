#!/usr/bin/env bash
# Style Check Plugin for Claude Code
# Checks Prozy style guide violations

FILE="$1"

# Only check .zig files
if [[ ! "$FILE" == *.zig ]]; then
    exit 0
fi

echo "📏 Checking Prozy style guide for $FILE..."

VIOLATIONS=0

# Check function length (simplified - counts lines between `fn` and closing brace)
# In a real implementation, would use proper parsing
LINE_COUNT=$(wc -l < "$FILE")

# Check for forbidden types
if grep -q ': usize' "$FILE" || grep -q ' usize ' "$FILE"; then
    echo "⚠️  Style violation: Uses 'usize' - prefer explicit u32/u64"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# Check for assertions
ASSERT_COUNT=$(grep -c 'assert(' "$FILE" || true)
if [ "$ASSERT_COUNT" -lt 2 ]; then
    echo "⚠️  Style violation: Only $ASSERT_COUNT assertions - need >= 2 per function"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

# Check for defer after common allocation patterns
if grep -qE '(init|alloc|create|open)\(' "$FILE"; then
    if ! grep -q 'defer' "$FILE"; then
        echo "⚠️  Style violation: Allocation found but no 'defer' cleanup"
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
fi

# Check for malloc/realloc (forbidden after init)
if grep -qE '\b(malloc|realloc|free)\b' "$FILE"; then
    echo "🚨 CRITICAL: Dynamic allocation detected - violates Prozy zero-allocation-after-init policy!"
    VIOLATIONS=$((VIOLATIONS + 1))
fi

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "❌ Found $VIOLATIONS style violation(s) - see CLAUDE.md for Prozy style guide"
else
    echo "✅ Style check passed"
fi
