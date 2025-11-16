#!/usr/bin/env bash
# Zig Auto-Format Plugin for Claude Code
# Automatically formats Zig files when they're edited

set -e

# Get the file that was edited from args
FILE="$1"

# Only format .zig files
if [[ "$FILE" == *.zig ]]; then
    echo "🎨 Formatting $FILE..."
    zig fmt "$FILE" 2>/dev/null || {
        echo "⚠️  Format failed for $FILE"
        exit 0  # Don't fail the edit
    }
    echo "✓ Formatted $FILE"
fi
