#!/bin/bash

# Claude Code Environment Setup for Prozy
# This script runs when starting a new Claude Code session

set -e

echo "🚀 Setting up Prozy development environment..."

# Check Zig installation and version
echo "📋 Checking Zig installation..."
if command -v zig >/dev/null 2>&1; then
    ZIG_VERSION=$(zig version)
    echo "✅ Zig found: $ZIG_VERSION"
    
    # Check if version supports async I/O (0.16.0-dev or later)
    if [[ "$ZIG_VERSION" == *"0.16"* ]]; then
        echo "✅ Zig version supports async I/O APIs"
    else
        echo "⚠️  Warning: Zig version may not support new async I/O APIs"
    fi
else
    echo "❌ Zig not found - installing or using fallback..."
    # Fallback: try to download Zig if not available
    if [[ "$CLAUDE_CODE_REMOTE" == "true" ]]; then
        echo "📦 In remote environment, Zig should be pre-installed"
    fi
fi

# Check for build system
echo "🔧 Checking build system..."
if [[ -f "build.zig" ]]; then
    echo "✅ build.zig found"
else
    echo "❌ build.zig not found"
fi

# Check for test dependencies
echo "🧪 Checking test dependencies..."
if command -v bun >/dev/null 2>&1; then
    echo "✅ Bun found for E2E tests"
else
    echo "⚠️  Bun not found - E2E tests may fail"
fi

# Verify source structure
echo "📁 Verifying project structure..."
if [[ -f "src/root.zig" ]] && [[ -f "src/main.zig" ]]; then
    echo "✅ Source files found"
else
    echo "❌ Source files missing"
fi

if [[ -f "tests/e2e_test.zig" ]]; then
    echo "✅ Test files found"
else
    echo "⚠️  Test files missing"
fi

# Pre-build if possible
echo "🏗️  Attempting pre-build..."
if zig build >/dev/null 2>&1; then
    echo "✅ Build successful"
else
    echo "⚠️  Build failed - check dependencies"
fi

echo "✨ Environment setup complete!"
echo ""
echo "Available Zig build targets:"
echo "  zig build            - Build the project"
echo "  zig build run         - Run the proxy"
echo "  zig build test        - Run unit tests"  
echo "  zig build test_e2e    - Run integration tests"
echo "  zig build async_demo_works - Run async demo"
echo ""
echo "Happy coding with Zig async I/O! 🚀"

# Export environment variables for subsequent commands
if [[ -n "$CLAUDE_ENV_FILE" ]]; then
    echo "PROZY_ENV_READY=true" >> "$CLAUDE_ENV_FILE"
fi