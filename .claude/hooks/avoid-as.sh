#!/usr/bin/env bash
# Avoid @as() Linting Rule for Prozy
# Detects unnecessary @as() usage where types can be inferred

FILE="$1"

# Only check .zig files
if [[ ! "$FILE" == *.zig ]]; then
    exit 0
fi

echo "🔍 Checking @as() usage for $FILE..."

VIOLATIONS=0

# Find all @as() occurrences and check if they're necessary
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
        VIOLATIONS=$((VIOLATIONS + 1))
    fi
    
    # Check for @as() with @intCast() that can often be simplified
    if [[ "$line_content" =~ @intCast ]]; then
        if [[ "$line_content" =~ @as\([a-zA-Z0-9_]+[[:space:]]*,[[:space:]]*@intCast\(.*\) ]]; then
            echo "⚠️  Style violation: Unnecessary @as() with @intCast() at line $line_num"
            echo "   $line_content"
            echo "   💡 Often can be simplified or use type annotation: \`const x: type = @intCast(value);\`"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi
    fi

done < <(grep -n "@as(" "$FILE" || true)

if [ "$VIOLATIONS" -gt 0 ]; then
    echo "❌ Found $VIOLATIONS unnecessary @as() usage(s)"
    echo ""
    echo "📚 Why avoid @as() when possible:"
    echo "   - Zig has powerful result location semantics for type inference"
    echo "   - @as() is a last resort when no contextual type information is available"
    echo "   - Type annotations are more readable and explicit"
    echo ""
    echo "✅ Better alternatives:"
    echo "   const x: u32 = 1;           // Instead of: const x = @as(u32, 1);"
    echo "   foo(1);                     // Instead of: foo(@as(u32, 1));"
    echo "   return 1;                   // Instead of: return @as(u64, x);"
    exit 1
else
    echo "✅ No unnecessary @as() usage found"
fi