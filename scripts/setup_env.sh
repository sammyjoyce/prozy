#!/bin/bash

# Claude Code Environment Setup for Prozy
# This script runs when starting a new Claude Code session

set -e

# Latest nightly version (update as needed)
NIGHTLY_VERSION="0.16.0-dev.1316+181b25ce4"

echo "🚀 Setting up Prozy development environment..."

# Helper function to download and extract Zig
download_and_extract_zig() {
    local url="$1"
    local dest="$2"
    
    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" | tar -xJ -C "$dest" --strip-components=1 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url" | tar -xJ -C "$dest" --strip-components=1 2>/dev/null
    else
        echo "❌ Neither curl nor wget available"
        return 1
    fi
}

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
        echo "📦 Installing latest Zig master for async I/O support..."
        
        # Proceed with installation even if older version found
        INSTALL_ZIG=true
    fi
else
    echo "❌ Zig not found - installing Zig master..."
    INSTALL_ZIG=true
fi

# Install Zig if needed
if [[ "$INSTALL_ZIG" == "true" ]]; then
    # Determine platform and architecture
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    
    case $ARCH in
        x86_64) ZIG_ARCH="x86_64" ;;
        aarch64|arm64) ZIG_ARCH="aarch64" ;;
        *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
    esac
    
    case $OS in
        linux) ZIG_OS="linux" ;;
        darwin) ZIG_OS="macos" ;;
        *) echo "❌ Unsupported OS: $OS"; exit 1 ;;
    esac
    
    # Download Zig master
    ZIG_TAR="zig-${ZIG_OS}-${ZIG_ARCH}.tar.xz"
    ZIG_URL="https://ziglang.org/builds/${ZIG_TAR}"
    ZIG_DIR="$HOME/.zig"
    ZIG_BIN="$ZIG_DIR/zig"
    
    # Create directory
    mkdir -p "$ZIG_DIR"
    
    echo "📦 Downloading Zig master from: $ZIG_URL"
    
    # Try master first, then fallback to specific nightly if it fails
    if ! download_and_extract_zig "$ZIG_URL" "$ZIG_DIR"; then
        echo "⚠️  Master download failed, trying specific nightly..."
        ZIG_TAR="zig-${ZIG_OS}-${ZIG_ARCH}-${NIGHTLY_VERSION}.tar.xz"
        ZIG_URL="https://ziglang.org/download/${ZIG_TAR}"
        
        if ! download_and_extract_zig "$ZIG_URL" "$ZIG_DIR"; then
            echo "❌ Both master and nightly downloads failed"
            exit 1
        fi
    fi
    
    # Make executable
    chmod +x "$ZIG_BIN"
    
    # Add to PATH for this session
    export PATH="$ZIG_DIR:$PATH"
    
    # Persist PATH for subsequent commands
    if [[ -n "$CLAUDE_ENV_FILE" ]]; then
        echo "export PATH=\"$ZIG_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE"
    fi
    
    # Verify installation
    if [[ -x "$ZIG_BIN" ]]; then
        ZIG_VERSION=$("$ZIG_BIN" version)
        echo "✅ Zig installed successfully: $ZIG_VERSION"
    else
        echo "❌ Zig installation failed"
        exit 1
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