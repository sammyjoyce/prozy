#!/usr/bin/env bash
# Avoid @as() Hook for Claude Code
# Automatically checks for unnecessary @as() usage after editing Zig files

set -e

# Read JSON input from stdin
input=$(cat)

# Extract file path using jq
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Exit if no file path or not a Zig file
if [ -z "$file_path" ] || [[ ! "$file_path" =~ \.zig$ ]]; then
    exit 0
fi

# Check if file exists
if [ ! -f "$file_path" ]; then
    exit 0
fi

echo "🔍 Checking @as() usage in: $file_path"

# Run the avoid-as check
if ./.claude/hooks/avoid-as.sh "$file_path" 2>&1; then
    echo "✅ No unnecessary @as() usage found"
    exit 0
else
    # Don't fail the hook, just warn about violations
    echo "⚠️  Warning: Found unnecessary @as() usage (non-blocking)"
    echo "💡 Run './.claude/hooks/avoid-as.sh $file_path' for detailed suggestions"
    exit 0
fi