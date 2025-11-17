#!/usr/bin/env bash
# Validate Zig-related bash commands before execution
# Provides helpful feedback for common mistakes

set -e

# Read JSON input from stdin
input=$(cat)

# Extract command and description
command=$(echo "$input" | jq -r '.tool_input.command // empty')
description=$(echo "$input" | jq -r '.tool_input.description // empty')

# Exit if no command
if [ -z "$command" ]; then
    exit 0
fi

# Only validate Zig-related commands
if [[ ! "$command" =~ ^zig ]]; then
    exit 0
fi

# Validation rules for Zig commands
issues=()

# Check for common mistakes
if [[ "$command" =~ ^zig\ build\ test$ ]]; then
    issues+=("Use 'zig build test' to run tests (not 'zig test' directly)")
fi

# Warn about missing build steps
if [[ "$command" == "zig build" ]] && ! echo "$command" | grep -q "\-\-"; then
    # This is just informational, not an error
    echo "💡 Tip: You can add build options like -Doptimize=ReleaseFast"
fi

# Check for potentially destructive cache operations
if [[ "$command" =~ zig-cache ]] && [[ "$command" =~ rm ]]; then
    issues+=("⚠️  Removing zig-cache will force a full rebuild")
fi

# Report issues if any found
if [ ${#issues[@]} -gt 0 ]; then
    echo "⚠️  Command validation issues:" >&2
    for issue in "${issues[@]}"; do
        echo "  • $issue" >&2
    done
    # Exit code 2 blocks the command and shows stderr to Claude
    exit 2
fi

# Command looks good
exit 0
