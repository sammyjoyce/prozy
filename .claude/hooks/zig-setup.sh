#!/usr/bin/env bash
# Combined Zig development environment setup for Prozy
# Runs at the start of each Claude Code session
# Tries multiple strategies to ensure Zig 0.16.0-dev is available

# Note: Not using 'set -e' to allow graceful fallback across strategies
# in restricted environments (e.g., Claude Code web)

# Latest nightly version (fallback if all else fails)
NIGHTLY_VERSION="0.16.0-dev.1316+181b25ce4"

echo "🚀 Setting up Prozy development environment..."

# Helper function to download and extract Zig
download_and_extract_zig() {
    local url="$1"
    local dest="$2"

    # Validate URL format
    if [[ ! "$url" =~ ^https?:// ]]; then
        echo "❌ Invalid URL format: $url"
        return 1
    fi

    # Create destination directory if it doesn't exist
    mkdir -p "$dest" || return 1

    echo "   Downloading from: $url"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fL "$url" 2>&1 | tar -xJ -C "$dest" --strip-components=1 2>&1; then
            echo "❌ Download or extraction failed"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -qO- "$url" 2>&1 | tar -xJ -C "$dest" --strip-components=1 2>&1; then
            echo "❌ Download or extraction failed"
            return 1
        fi
    else
        echo "❌ Neither curl nor wget available"
        return 1
    fi

    return 0
}

# Function to setup Zig via Nix flake (preferred method)
setup_with_nix() {
    echo "📦 Nix detected - checking for flake support..."
    
    # Check if flake.nix exists
    if [ ! -f "$CLAUDE_PROJECT_DIR/flake.nix" ]; then
        echo "⚠️  flake.nix not found"
        return 1
    fi
    
    # Check if flakes are enabled by trying to show the flake
    if nix flake metadata "$CLAUDE_PROJECT_DIR" >/dev/null 2>&1; then
        echo "✅ Nix flakes available - using flake.nix for dependencies"
        
        # Use direnv if available, otherwise use nix develop directly
        if command -v direnv &>/dev/null && [ -f "$CLAUDE_PROJECT_DIR/.envrc" ]; then
            echo "🔄 Using direnv to load Nix environment..."
            cd "$CLAUDE_PROJECT_DIR"
            direnv allow . 2>/dev/null || true
            eval "$(direnv export bash 2>/dev/null)" || true
        else
            echo "🔄 Loading Nix flake environment..."
            # Extract PATH from nix develop environment
            NIX_PATH=$(nix develop "$CLAUDE_PROJECT_DIR" --command bash -c 'echo "$PATH"' 2>/dev/null)
            
            if [[ -n "$NIX_PATH" ]]; then
                export PATH="$NIX_PATH"
                
                # Persist for Claude Code session
                if [[ -n "$CLAUDE_ENV_FILE" ]]; then
                    echo "export PATH=\"$NIX_PATH\"" >> "$CLAUDE_ENV_FILE"
                fi
            fi
        fi
        
        # Verify Zig is now available from Nix
        if command -v zig &>/dev/null; then
            ZIG_VERSION=$(zig version)
            echo "✅ Zig from Nix: $ZIG_VERSION"
            return 0
        else
            echo "⚠️  Nix setup completed but Zig still not in PATH"
            return 1
        fi
    else
        echo "⚠️  Nix flakes not enabled - enable with:"
        echo "    nix-env -iA nixpkgs.nixFlakes"
        echo "    Or add 'experimental-features = nix-command flakes' to ~/.config/nix/nix.conf"
        return 1
    fi
}

# Function to install Zig via system package manager
install_via_package_manager() {
    echo "📥 Attempting to install Zig via package manager..."

    # Skip package manager installation in restricted environments (Claude Code web)
    if [[ ! -w /etc/sudoers ]] && [[ ! -w /etc/apt ]] 2>/dev/null; then
        echo "⚠️  Insufficient permissions for package manager installation"
        echo "   Skipping package manager strategy..."
        return 1
    fi

    if command -v apt &>/dev/null; then
        echo "🔧 Installing Zig via apt..."
        sudo apt update && sudo apt install -y zig
        return $?
    elif command -v brew &>/dev/null; then
        echo "🔧 Installing Zig via Homebrew..."
        brew install zig
        return $?
    elif command -v pacman &>/dev/null; then
        echo "🔧 Installing Zig via pacman..."
        sudo pacman -S --noconfirm zig
        return $?
    else
        echo "⚠️  No supported package manager found (apt, brew, pacman)"
        return 1
    fi
}

# Function to download and install Zig master from ziglang.org
install_zig_master() {
    echo "📦 Downloading Zig master from ziglang.org..."
    
    # Determine platform and architecture
    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')

    case $ARCH in
        x86_64) ZIG_ARCH="x86_64" ;;
        aarch64|arm64) ZIG_ARCH="aarch64" ;;
        arm*) ZIG_ARCH="arm" ;;
        *) echo "❌ Unsupported architecture: $ARCH"; return 1 ;;
    esac

    case $OS in
        linux) ZIG_OS="linux" ;;
        darwin) ZIG_OS="macos" ;;
        *) echo "❌ Unsupported OS: $OS"; return 1 ;;
    esac

    # Fetch latest master version from index.json
    echo "📦 Fetching latest Zig master version..."
    ZIG_INDEX=""
    if command -v curl >/dev/null 2>&1; then
        ZIG_INDEX=$(curl -fsSL https://ziglang.org/download/index.json 2>&1) || true
    elif command -v wget >/dev/null 2>&1; then
        ZIG_INDEX=$(wget -qO- https://ziglang.org/download/index.json 2>&1) || true
    else
        echo "❌ Neither curl nor wget available"
        return 1
    fi

    # Extract version and URL for the platform
    PLATFORM_KEY="${ZIG_ARCH}-${ZIG_OS}"
    ZIG_URL=""

    # Only parse if we got valid JSON (starts with '{')
    if [[ "$ZIG_INDEX" == "{"* ]]; then
        ZIG_URL=$(echo "$ZIG_INDEX" | grep -A2 "\"$PLATFORM_KEY\"" | grep "tarball" | sed -E 's/.*"tarball": "([^"]+)".*/\1/' 2>/dev/null || true)
    fi

    # Validate URL format before using it
    if [[ -z "$ZIG_URL" ]] || [[ ! "$ZIG_URL" =~ ^https?:// ]]; then
        echo "⚠️  Could not parse latest version, using fallback..."
        ZIG_URL="https://ziglang.org/builds/zig-${ZIG_ARCH}-${ZIG_OS}-${NIGHTLY_VERSION}.tar.xz"
    fi

    ZIG_DIR="$HOME/.zig"
    ZIG_BIN="$ZIG_DIR/zig"

    # Create directory
    mkdir -p "$ZIG_DIR"

    if ! download_and_extract_zig "$ZIG_URL" "$ZIG_DIR"; then
        echo "❌ Download failed"
        return 1
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
        return 0
    else
        echo "❌ Zig installation failed"
        return 1
    fi
}

# Main installation logic with fallback chain
SKIP_ZIG_INSTALL=false

# Strategy 1: Try Nix first (preferred for Prozy)
if command -v nix >/dev/null 2>&1; then
    if setup_with_nix; then
        SKIP_ZIG_INSTALL=true
    fi
fi

# Strategy 2: Check if Zig is already installed
if [[ "$SKIP_ZIG_INSTALL" != "true" ]] && command -v zig >/dev/null 2>&1; then
    ZIG_VERSION=$(zig version)
    echo "✅ Zig found: $ZIG_VERSION"
    
    # Check if version supports async I/O (0.16.0-dev or later)
    if [[ "$ZIG_VERSION" == *"0.16"* ]]; then
        echo "✅ Zig version supports async I/O APIs"
        SKIP_ZIG_INSTALL=true
    else
        echo "⚠️  Warning: Zig version may not support new async I/O APIs"
        echo "📦 Will attempt to install Zig 0.16.0-dev..."
    fi
fi

# Strategy 3: Try package manager
if [[ "$SKIP_ZIG_INSTALL" != "true" ]]; then
    echo "⚠️  Zig 0.16.0-dev not found - attempting installation..."
    
    if install_via_package_manager; then
        # Verify the installed version
        if command -v zig >/dev/null 2>&1; then
            ZIG_VERSION=$(zig version)
            echo "✅ Zig installed via package manager: $ZIG_VERSION"
            
            if [[ "$ZIG_VERSION" == *"0.16"* ]]; then
                SKIP_ZIG_INSTALL=true
            else
                echo "⚠️  Package manager version is too old, downloading master..."
            fi
        fi
    fi
fi

# Strategy 4: Download Zig master as last resort
if [[ "$SKIP_ZIG_INSTALL" != "true" ]]; then
    if install_zig_master; then
        SKIP_ZIG_INSTALL=true
    else
        echo "❌ All Zig installation strategies failed"
        echo "Please install Zig 0.16.0-dev manually: https://ziglang.org/download/"
        echo ""
        echo "⚠️  Continuing setup without Zig - you may need to install it manually"
    fi
fi

# Final verification
if ! command -v zig &>/dev/null; then
    echo "❌ Zig installation failed - zig not in PATH"
    echo "⚠️  You will need to install Zig 0.16.0-dev manually before building"
    echo "   Download from: https://ziglang.org/download/"
    echo ""
    # Don't exit with error - allow hook to complete for environment setup
else
    ZIG_VERSION=$(zig version)
    echo "✅ Zig version: $ZIG_VERSION"

    # Verify we have the minimum required version (0.16.0-dev)
    if [[ ! "$ZIG_VERSION" =~ ^0\.16\. ]]; then
        echo "⚠️  Warning: Prozy requires Zig 0.16.0-dev or later for async I/O"
        echo "   Current version: $ZIG_VERSION"
        echo "   Consider updating via: nix flake update (if using Nix)"
    fi
fi

# Verify project structure
echo ""
echo "📁 Verifying project structure..."

# Check for build.zig
if [[ -f "$CLAUDE_PROJECT_DIR/build.zig" ]]; then
    echo "✅ Found build.zig"
else
    echo "⚠️  Warning: build.zig not found in project root"
fi

# Check for build.zig.zon (package dependencies)
if [[ -f "$CLAUDE_PROJECT_DIR/build.zig.zon" ]]; then
    echo "✅ Found build.zig.zon (package manager config)"
fi

# Verify source structure
if [[ -f "$CLAUDE_PROJECT_DIR/src/root.zig" ]] && [[ -f "$CLAUDE_PROJECT_DIR/src/main.zig" ]]; then
    echo "✅ Source files found"
else
    echo "❌ Source files missing"
fi

# Check for test files
if [[ -f "$CLAUDE_PROJECT_DIR/tests/e2e_test.zig" ]]; then
    echo "✅ Test files found"
else
    echo "⚠️  Test files missing"
fi

# Set up environment variables for subsequent bash commands
if [[ -n "$CLAUDE_ENV_FILE" ]]; then
    echo "export ZIG_GLOBAL_CACHE_DIR=\"$HOME/.cache/zig\"" >> "$CLAUDE_ENV_FILE"
    echo "export ZIG_LOCAL_CACHE_DIR=\"$CLAUDE_PROJECT_DIR/zig-cache\"" >> "$CLAUDE_ENV_FILE"
    echo "export PROZY_ENV_READY=true" >> "$CLAUDE_ENV_FILE"
    
    # Optimize for your specific architecture
    if command -v uname &>/dev/null; then
        ARCH=$(uname -m)
        echo "export ZIG_ARCH=\"$ARCH\"" >> "$CLAUDE_ENV_FILE"
        echo "✅ Architecture: $ARCH"
    fi
fi

# Create cache directories if they don't exist
mkdir -p "$HOME/.cache/zig" 2>/dev/null || true
mkdir -p "$CLAUDE_PROJECT_DIR/zig-cache" 2>/dev/null || true

# Check build cache directories
if [[ -d "$CLAUDE_PROJECT_DIR/zig-cache" ]]; then
    CACHE_SIZE=$(du -sh "$CLAUDE_PROJECT_DIR/zig-cache" 2>/dev/null | cut -f1)
    echo "📦 Local cache size: $CACHE_SIZE"
fi

# Check for Bun (needed for E2E tests)
echo ""
echo "🧪 Checking test dependencies..."
if command -v bun &>/dev/null; then
    BUN_VERSION=$(bun --version 2>/dev/null || echo "unknown")
    echo "✅ Bun version: $BUN_VERSION (for E2E tests)"
else
    echo "⚠️  Bun not found (optional, needed for E2E tests)"
    echo "   Install: curl -fsSL https://bun.sh/install | bash"
fi

# Verify the project can be built
echo ""
echo "🔧 Verifying build system..."
if [[ -d "$CLAUDE_PROJECT_DIR" ]]; then
    cd "$CLAUDE_PROJECT_DIR" || true
else
    echo "⚠️  Project directory not accessible: $CLAUDE_PROJECT_DIR"
fi

if command -v zig &>/dev/null && zig build --help &>/dev/null; then
    echo "✅ Build system is functional"

    # Fetch dependencies if build.zig.zon exists
    if [[ -f "$CLAUDE_PROJECT_DIR/build.zig.zon" ]]; then
        echo "📦 Fetching build dependencies..."
        zig build --fetch 2>/dev/null || true
    fi

    # Pre-build if possible (fail silently to not block setup)
    echo "🏗️  Attempting pre-build..."
    if zig build >/dev/null 2>&1; then
        echo "✅ Build successful"
    else
        echo "⚠️  Build failed - may need dependency updates"
    fi

    # List available build steps
    echo ""
    echo "📋 Available build targets:"
    zig build --help 2>/dev/null | grep -E "^\s+zig build [a-z_-]+" | head -10 || echo "  Run 'zig build --help' for details"
else
    echo "⚠️  Warning: Could not verify build system"
    echo "   Run 'zig build --help' manually to check build.zig"
fi

echo ""
echo "✨ Prozy development environment ready!"
echo ""
echo "💡 Quick commands:"
echo "   - Build:           zig build"
echo "   - Run proxy:       zig build run"
echo "   - Unit tests:      zig build test"
echo "   - E2E tests:       zig build test_e2e"
echo "   - Format code:     zig fmt src/"
echo "   - Full demo:       zig build full_features"
echo "   - Async I/O demo:  zig build async_io_demo"
echo ""
echo "📚 Documentation:"
echo "   - Architecture:    docs/ARCHITECTURE.md"
echo "   - Development:     CLAUDE.md"
echo "   - Contributing:    CONTRIBUTING.md"
echo ""
echo "Happy coding with Zig async I/O! 🚀"

exit 0
