#!/usr/bin/env bash

# Claude Code Environment Setup for Prozy
# This script runs when starting a new Claude Code session

set -e

# Latest nightly version (update as needed)
NIGHTLY_VERSION="0.16.0-dev.1316+181b25ce4"

echo "🚀 Setting up Prozy development environment..."

# Check if Nix is available and use flake if possible
if command -v nix >/dev/null 2>&1; then
    echo "📦 Nix detected - checking for flake support..."

    # Check if flakes are enabled by trying to show the flake
    if nix flake metadata . >/dev/null 2>&1; then
        echo "✅ Nix flakes available - using flake.nix for dependencies"

        # Extract PATH from nix develop environment
        NIX_PATH=$(nix develop --command bash -c 'echo "$PATH"' 2>/dev/null)

        if [[ -n "$NIX_PATH" ]]; then
            export PATH="$NIX_PATH"

            # Persist for Claude Code session
            if [[ -n "$CLAUDE_ENV_FILE" ]]; then
                echo "export PATH=\"$NIX_PATH\"" >> "$CLAUDE_ENV_FILE"
            fi

            echo "✅ Nix environment loaded"

            # Verify Zig is available from Nix
            if command -v zig >/dev/null 2>&1; then
                ZIG_VERSION=$(zig version)
                echo "✅ Zig from Nix: $ZIG_VERSION"

                # Skip manual Zig installation since Nix provides it
                SKIP_ZIG_INSTALL=true
            fi
        else
            echo "⚠️  Failed to load Nix environment - falling back to manual setup"
        fi
    else
        echo "⚠️  Nix flakes not enabled - enable with:"
        echo "    nix-env -iA nixpkgs.nixFlakes"
        echo "    Or add 'experimental-features = nix-command flakes' to ~/.config/nix/nix.conf"
        echo "    Falling back to manual Zig installation..."
    fi
fi

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

# Check Zig installation and version (skip if Nix provided it)
if [[ "$SKIP_ZIG_INSTALL" != "true" ]]; then
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
fi

# Install Zig if needed
if [[ "$INSTALL_ZIG" == "true" ]]; then
    # Determine platform and architecture
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')

    case $ARCH in
        x86_64) ZIG_ARCH="x86_64" ;;
        aarch64|arm64) ZIG_ARCH="aarch64" ;;
        arm*) ZIG_ARCH="arm" ;;
        *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    case $OS in
        linux) ZIG_OS="linux" ;;
        darwin) ZIG_OS="macos" ;;
        *) echo "❌ Unsupported OS: $OS"; exit 1 ;;
    esac

    # Fetch latest master version from index.json
    echo "📦 Fetching latest Zig master version..."
    if command -v curl >/dev/null 2>&1; then
        ZIG_INDEX=$(curl -fsSL https://ziglang.org/download/index.json 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        ZIG_INDEX=$(wget -qO- https://ziglang.org/download/index.json 2>/dev/null)
    else
        echo "❌ Neither curl nor wget available"
        exit 1
    fi

    # Extract version and URL for the platform
    # Format: zig-ARCH-OS-VERSION.tar.xz (e.g., zig-x86_64-linux-0.16.0-dev.1326+2e6f7d36b.tar.xz)
    PLATFORM_KEY="${ZIG_ARCH}-${ZIG_OS}"

    # Try to parse JSON to get the tarball URL (simple grep/sed approach)
    ZIG_URL=$(echo "$ZIG_INDEX" | grep -A2 "\"$PLATFORM_KEY\"" | grep "tarball" | sed -E 's/.*"tarball": "([^"]+)".*/\1/')

    if [[ -z "$ZIG_URL" ]]; then
        echo "⚠️  Could not parse latest version, using fallback..."
        # Fallback to hardcoded nightly version
        ZIG_URL="https://ziglang.org/builds/zig-${ZIG_ARCH}-${ZIG_OS}-${NIGHTLY_VERSION}.tar.xz"
    fi

    ZIG_DIR="$HOME/.zig"
    ZIG_BIN="$ZIG_DIR/zig"

    # Create directory
    mkdir -p "$ZIG_DIR"

    echo "📦 Downloading Zig from: $ZIG_URL"

    if ! download_and_extract_zig "$ZIG_URL" "$ZIG_DIR"; then
        echo "❌ Download failed"
        exit 1
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
