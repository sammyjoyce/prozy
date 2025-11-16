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

# Check for unnecessary @as() usage
AS_VIOLATIONS=0
while IFS= read -r line; do
    line_num=$(echo "$line" | cut -d: -f1)
    line_content=$(echo "$line" | cut -d: -f2-)
    
    # Skip @as() in test expectations (often necessary)
    if [[ "$line_content" =~ testing\.expect ]]; then
        continue
    fi
    
    # Skip @as() with undefined (needs explicit type)
    if [[ "$line_content" =~ @as\(.*undefined.*\) ]]; then
        continue
    fi
    
    # Skip @as() with pointer casting
    if [[ "$line_content" =~ @as\(\*.*\) ]]; then
        continue
    fi
    
    # Skip @as() with constCast, alignCast, ptrCast
    if [[ "$line_content" =~ @as\(.*(constCast|alignCast|ptrCast).*\) ]]; then
        continue
    fi
    
    # Check for @as() with numeric literals that can be inferred
    if [[ "$line_content" =~ @as\([a-zA-Z0-9_]+,\s*[0-9+-]+\s*\) ]]; then
        echo "⚠️  Style violation: Unnecessary @as() with numeric literal at line $line_num"
        echo "   $line_content"
        echo "   💡 Use type annotation instead: \`const x: type = value;\`"
        AS_VIOLATIONS=$((AS_VIOLATIONS + 1))
    fi
    
    # Check for @as() with @intCast() that can often be simplified
    if [[ "$line_content" =~ @as\([a-zA-Z0-9_]+[[:space:]]*,[[:space:]]*@intCast\(.*\) ]]; then
        echo "⚠️  Style violation: Unnecessary @as() with @intCast() at line $line_num"
        echo "   $line_content"
        echo "   💡 Often can be simplified: \`const x: type = @intCast(value);\`"
        AS_VIOLATIONS=$((AS_VIOLATIONS + 1))
    fi

done < <(grep -n "@as(" "$FILE" || true)

VIOLATIONS=$((VIOLATIONS + AS_VIOLATIONS))

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "❌ Found $VIOLATIONS style violation(s) - see CLAUDE.md for Prozy style guide"
    if [ "$AS_VIOLATIONS" -gt 0 ]; then
        echo ""
        echo "📚 @as() Rule: Zig has powerful result location semantics for type inference"
        echo "   @as() is a last resort when no contextual type information is available"
        echo "   Type annotations are more readable and explicit"
    fi
else
    echo "✅ Style check passed"
fi
