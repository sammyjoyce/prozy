# Claude Code Configuration for Prozy

This repository is configured for Claude Code on the web with the following setup:

## Environment Configuration

- **Name**: Zig Development
- **Network**: Full access (allows package downloads, testing servers, external services)
- **Auto-setup**: Runs environment verification script on session start
- **Zig Installation**: Automatically installs Zig master if not found or if version doesn't support async I/O

## Files Added

- `.claude/settings.json` - Claude Code configuration
- `scripts/setup_env.sh` - Environment verification and Zig installation
- `CLAUDE.md` - Comprehensive project documentation and development guide

## Usage with Claude Code Web

1. Visit [claude.ai/code](https://claude.ai/code)
2. Connect your GitHub account
3. Select this repository
4. Claude will automatically:
   - Check for existing Zig installation
   - Install Zig master if needed (for async I/O support)
   - Verify Zig version compatibility (0.16.0+ required)
   - Check project structure and dependencies
   - Run a pre-build to verify everything works
   - Provide available build targets and commands

## Zig Installation Features

The setup script automatically handles:

### ✅ Auto-installation
- Downloads Zig master if not found in PATH
- Falls back to specific nightly version if master fails
- Supports Linux and macOS (x86_64 and aarch64)
- Installs to `~/.zig/` and adds to PATH

### ✅ Version Management
- Detects existing Zig installation
- Upgrades if version doesn't support async I/O (pre-0.16.0)
- Provides clear version information and compatibility warnings

### ✅ Environment Setup
- Persists PATH changes for session
- Works in both local and remote Claude Code environments
- Handles missing dependencies (curl/wget) gracefully

## Supported Commands

When working with this repo in Claude Code, you can ask Claude to:

- `zig build` - Build the project
- `zig build run` - Run the TCP proxy
- `zig build test` - Run unit tests (18 tests)
- `zig build test_e2e` - Run end-to-end integration tests
- `zig build async_demo_works` - Run the async capabilities demo

## Development Features

The setup script automatically verifies:
- ✅ Zig installation with async I/O support (installs master if needed)
- ✅ Project structure and source files
- ✅ Build system configuration
- ✅ Test framework setup
- ✅ Dependencies for integration testing

## Supported Platforms

The auto-installation supports:
- **Linux**: x86_64, aarch64
- **macOS**: x86_64, aarch64 (Apple Silicon)

## Download Strategy

1. **Primary**: Zig master from `ziglang.org/builds/`
2. **Fallback**: Specific nightly version with known async I/O support
3. **Dependencies**: Requires curl or wget for downloads
4. **Installation**: Extracts to `~/.zig/` and makes executable

This ensures Claude Code always has a properly configured environment with Zig async I/O support, regardless of the base environment.