#!/usr/bin/env bash
# Avoid @as() Linting Rule - Batch Checker for Prozy
# Checks all .zig files in the project for unnecessary @as() usage

echo "🔍 Running avoid-as() rule on entire Prozy codebase..."
echo ""

TOTAL_VIOLATIONS=0
FILES_WITH_VIOLATIONS=0

# Find all .zig files and check them
while IFS= read -r -d '' file; do
    if [[ "$file" == *.zig ]]; then
        echo "📁 Checking $file..."
        
        # Run the avoid-as script and capture violations
        VIOLATION_OUTPUT=$(./tools/avoid-as.sh "$file" 2>&1)
        EXIT_CODE=$?
        
        if [ $EXIT_CODE -ne 0 ]; then
            FILES_WITH_VIOLATIONS=$((FILES_WITH_VIOLATIONS + 1))
            # Extract violation count from output
            VIOLATIONS=$(echo "$VIOLATION_OUTPUT" | grep "Found [0-9]* unnecessary" | grep -o "[0-9]*" | head -1)
            if [ -n "$VIOLATIONS" ]; then
                TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + VIOLATIONS))
            fi
        fi
        
        echo ""
    fi
done < <(find src -name "*.zig" -print0)

echo "📊 Summary:"
echo "   Files checked: $(find src -name "*.zig" | wc -l)"
echo "   Files with violations: $FILES_WITH_VIOLATIONS"
echo "   Total violations: $TOTAL_VIOLATIONS"
echo ""

if [ $TOTAL_VIOLATIONS -gt 0 ]; then
    echo "❌ avoid-as() rule failed with $TOTAL_VIOLATIONS violation(s)"
    echo ""
    echo "💡 To fix violations:"
    echo "   1. Replace @as(type, literal) with const x: type = literal"
    echo "   2. Replace @as(type, @intCast(value)) with const x: type = @intCast(value)"
    echo "   3. Let function signatures infer types when possible"
    echo ""
    echo "📚 See docs/avoid-as-rule.md for detailed guidance"
    exit 1
else
    echo "✅ avoid-as() rule passed - no unnecessary @as() usage found"
    exit 0
fi