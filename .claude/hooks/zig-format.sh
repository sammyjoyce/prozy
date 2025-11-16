#!/bin/bash
# Auto-format Zig files after editing
# Only formats .zig files that were just edited

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

echo "🎨 Auto-formatting Zig file: $file_path"

# Run zig fmt on the file
if zig fmt "$file_path" 2>&1; then
    echo "✅ Formatted successfully"
    exit 0
else
    # Don't fail the hook if formatting fails, just warn
    echo "⚠️  Warning: zig fmt encountered issues (non-blocking)"
    exit 0
fi
