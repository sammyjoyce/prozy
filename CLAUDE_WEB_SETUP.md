# Claude Code Configuration for Prozy

This repository is configured for Claude Code on the web with the following setup:

## Environment Configuration

- **Name**: Zig Development
- **Network**: Limited (allows package managers, GitHub, and development tools)
- **Auto-setup**: Runs environment verification script on session start

## Files Added

- `.claude/settings.json` - Claude Code configuration
- `scripts/setup_env.sh` - Environment verification and setup
- `CLAUDE.md` - Project documentation and development guide

## Usage with Claude Code Web

1. Visit [claude.ai/code](https://claude.ai/code)
2. Connect your GitHub account
3. Select this repository
4. Claude will automatically:
   - Verify Zig installation and version
   - Check project structure and dependencies
   - Run a pre-build to verify everything works
   - Provide available build targets and commands

## Supported Commands

When working with this repo in Claude Code, you can ask Claude to:

- `zig build` - Build the project
- `zig build run` - Run the TCP proxy
- `zig build test` - Run unit tests (18 tests)
- `zig build test_e2e` - Run end-to-end integration tests
- `zig build async_demo_works` - Run async capabilities demo

## Development Features

The setup script automatically verifies:
- ✅ Zig installation with async I/O support (0.16.0+)
- ✅ Project structure and source files
- ✅ Build system configuration
- ✅ Test framework setup
- ✅ Dependencies for integration testing

This ensures Claude Code has a properly configured environment for working with Zig's async I/O APIs.