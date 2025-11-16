#!/usr/bin/env bash
# Session Stats Plugin for Claude Code
# Tracks editing statistics during session

STATS_FILE="/tmp/prozy-session-stats"

# Initialize stats file if it doesn't exist
if [ ! -f "$STATS_FILE" ]; then
    echo "START_TIME=$(date +%s)" > "$STATS_FILE"
    echo "FILES_EDITED=0" >> "$STATS_FILE"
    echo "BUILD_ATTEMPTS=0" >> "$STATS_FILE"
    echo "TEST_RUNS=0" >> "$STATS_FILE"
fi

# Source current stats
source "$STATS_FILE"

# Handle different events
case "$1" in
    edit)
        FILES_EDITED=$((FILES_EDITED + 1))
        echo "FILES_EDITED=$FILES_EDITED" >> "$STATS_FILE"
        ;;
    build)
        BUILD_ATTEMPTS=$((BUILD_ATTEMPTS + 1))
        echo "BUILD_ATTEMPTS=$BUILD_ATTEMPTS" >> "$STATS_FILE"
        ;;
    test)
        TEST_RUNS=$((TEST_RUNS + 1))
        echo "TEST_RUNS=$TEST_RUNS" >> "$STATS_FILE"
        ;;
    summary)
        DURATION=$(( ($(date +%s) - START_TIME) / 60 ))
        echo ""
        echo "📊 Session Statistics:"
        echo "   Duration: $DURATION minutes"
        echo "   Files edited: $FILES_EDITED"
        echo "   Build attempts: $BUILD_ATTEMPTS"
        echo "   Test runs: $TEST_RUNS"
        echo ""
        ;;
esac
