#!/usr/bin/env bash
# Test On Idle Plugin for Claude Code
# Runs tests when source files have been modified

set -e

MARKER_FILE="/tmp/prozy-files-changed"

# If we get a file argument, mark that files were changed
if [ -n "$1" ]; then
    FILE="$1"
    if [[ "$FILE" == src/*.zig ]]; then
        echo "$FILE" >> "$MARKER_FILE"
        echo "📝 Tracked change to $FILE"
    fi
    exit 0
fi

# If no args, this is an idle check - run tests if files changed
if [ -f "$MARKER_FILE" ]; then
    CHANGED_COUNT=$(wc -l < "$MARKER_FILE")
    echo "🧪 Running tests after $CHANGED_COUNT file(s) changed..."
    
    if zig build test 2>&1; then
        echo "✅ All tests passed!"
        rm "$MARKER_FILE"
    else
        echo "❌ Tests failed! Use custom command to diagnose:"
        echo "   Source the test-coverage command"
        echo "   Or use the fix-build command"
        # Keep marker file to remember failure
    fi
fi
