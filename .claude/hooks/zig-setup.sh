#!/bin/bash
# Zig development environment setup hook
# Runs at the start of each Claude Code session
# Auto-installs Zig if not found using available package managers

set -e

echo "🔧 Initializing Zig development environment..."

# Function to setup Zig via Nix flake
setup_with_nix() {
    echo "📦 Setting up Zig environment using Nix flake..."
    
    # Check if flake.nix exists
    if [ ! -f "$CLAUDE_PROJECT_DIR/flake.nix" ]; then
        echo "❌ Error: flake.nix not found"
        return 1
    fi
    
    # Use direnv if available, otherwise use nix develop directly
    if command -v direnv &>/dev/null && [ -f "$CLAUDE_PROJECT_DIR/.envrc" ]; then
        echo "🔄 Using direnv to load Nix environment..."
        cd "$CLAUDE_PROJECT_DIR"
        direnv allow . 2>/dev/null || true
        eval "$(direnv export bash 2>/dev/null)" || true
    else
        echo "🔄 Loading Nix flake environment..."
        # Export the Nix environment to Claude's env file
        if [ -n "$CLAUDE_ENV_FILE" ]; then
            cd "$CLAUDE_PROJECT_DIR"
            nix develop --command bash -c 'env' | grep -E '^(PATH|ZIG|LD_LIBRARY_PATH|PKG_CONFIG_PATH)=' >> "$CLAUDE_ENV_FILE" || true
        fi
    fi
    
    # Verify Zig is now available
    if command -v zig &>/dev/null; then
        return 0
    else
        echo "⚠️  Nix setup completed but Zig still not in PATH"
        echo "💡 You may need to run: nix develop"
        return 1
    fi
}

# Function to install Zig via package manager
install_zig() {
    echo "📥 Attempting to install Zig..."
    
    if command -v nix &>/dev/null; then
        setup_with_nix
        return $?
    elif command -v apt &>/dev/null; then
        echo "🔧 Installing Zig via apt..."
        sudo apt update && sudo apt install -y zig
    elif command -v brew &>/dev/null; then
        echo "🔧 Installing Zig via Homebrew..."
        brew install zig
    elif command -v pacman &>/dev/null; then
        echo "🔧 Installing Zig via pacman..."
        sudo pacman -S --noconfirm zig
    else
        echo "❌ No supported package manager found (nix, apt, brew, pacman)"
        echo "Please install Zig manually: https://ziglang.org/download/"
        return 1
    fi
}

# Check if Zig is installed, if not, try to install it
if ! command -v zig &> /dev/null; then
    echo "⚠️  Zig compiler not found in PATH"
    
    if install_zig; then
        echo "✅ Zig installation successful!"
    else
        echo "❌ Failed to install Zig automatically"
        exit 1
    fi
fi

# Display Zig version
ZIG_VERSION=$(zig version)
echo "✅ Zig version: $ZIG_VERSION"

# Verify we have the minimum required version (0.16.0-dev)
REQUIRED_VERSION="0.16.0"
if [[ ! "$ZIG_VERSION" =~ ^0\.16\. ]]; then
    echo "⚠️  Warning: Prozy requires Zig 0.16.0-dev or later for async I/O"
    echo "   Current version: $ZIG_VERSION"
    echo "   Consider updating via: nix flake update (if using Nix)"
fi

# Check for build.zig
if [ ! -f "$CLAUDE_PROJECT_DIR/build.zig" ]; then
    echo "⚠️  Warning: build.zig not found in project root"
else
    echo "✅ Found build.zig"
fi

# Check for build.zig.zon (package dependencies)
if [ -f "$CLAUDE_PROJECT_DIR/build.zig.zon" ]; then
    echo "✅ Found build.zig.zon (package manager config)"
fi

# Set up environment variables for subsequent bash commands
if [ -n "$CLAUDE_ENV_FILE" ]; then
    echo "export ZIG_GLOBAL_CACHE_DIR=\"$HOME/.cache/zig\"" >> "$CLAUDE_ENV_FILE"
    echo "export ZIG_LOCAL_CACHE_DIR=\"$CLAUDE_PROJECT_DIR/zig-cache\"" >> "$CLAUDE_ENV_FILE"
    
    # Optimize for your specific architecture
    if command -v uname &> /dev/null; then
        ARCH=$(uname -m)
        echo "export ZIG_ARCH=\"$ARCH\"" >> "$CLAUDE_ENV_FILE"
        echo "✅ Architecture: $ARCH"
    fi
fi

# Create cache directories if they don't exist
mkdir -p "$HOME/.cache/zig" 2>/dev/null || true
mkdir -p "$CLAUDE_PROJECT_DIR/zig-cache" 2>/dev/null || true

# Check build cache directories
if [ -d "$CLAUDE_PROJECT_DIR/zig-cache" ]; then
    CACHE_SIZE=$(du -sh "$CLAUDE_PROJECT_DIR/zig-cache" 2>/dev/null | cut -f1)
    echo "📦 Local cache size: $CACHE_SIZE"
fi

# Check for Bun (needed for E2E tests)
if command -v bun &>/dev/null; then
    BUN_VERSION=$(bun --version 2>/dev/null || echo "unknown")
    echo "✅ Bun version: $BUN_VERSION (for E2E tests)"
else
    echo "⚠️  Bun not found (optional, needed for E2E tests)"
    echo "   Install: curl -fsSL https://bun.sh/install | bash"
fi

# Verify the project can be built
echo ""
echo "🔍 Verifying build system..."
cd "$CLAUDE_PROJECT_DIR"

if zig build --help &> /dev/null; then
    echo "✅ Build system is functional"
    
    # Try a quick build check (don't actually build, just verify)
    if zig build --help 2>&1 | grep -q "zig build"; then
        # Fetch dependencies if build.zig.zon exists
        if [ -f "$CLAUDE_PROJECT_DIR/build.zig.zon" ]; then
            echo "📦 Fetching build dependencies..."
            zig build --fetch 2>/dev/null || true
        fi
    fi
    
    # List available build steps
    echo ""
    echo "📋 Available build commands:"
    zig build --help 2>/dev/null | grep -E "^\s+zig build [a-z_-]+" | head -10 || echo "  Run 'zig build --help' for details"
else
    echo "⚠️  Warning: Could not verify build system"
    echo "   This may indicate a problem with build.zig"
fi

echo ""
echo "✨ Zig environment ready for Prozy development!"
echo ""
echo "💡 Quick commands:"
echo "   - Build:        zig build"
echo "   - Test:         zig build test"
echo "   - E2E Test:     zig build test_e2e"
echo "   - Run:          zig build run"
echo "   - Format:       zig fmt src/"
echo "   - Full Demo:    zig build full_features"
echo ""
echo "📚 See CLAUDE.md for development guidelines"

exit 0
