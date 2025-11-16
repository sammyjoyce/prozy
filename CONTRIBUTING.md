# Contributing to Prozy

Thank you for your interest in Prozy! This guide will help you whether you're contributing to the main repository or forking Prozy to build your own purpose-specific proxy.

## Table of Contents

- [For Fork Maintainers](#for-fork-maintainers)
- [For Contributors](#for-contributors)
- [Development Setup](#development-setup)
- [Code Style](#code-style)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)
- [Release Process](#release-process)

## For Fork Maintainers

Prozy is designed to be a solid foundation for building purpose-specific proxies. Here's how to get started:

### Forking Strategy

1. **Fork the repository** to your own GitHub account or organization
2. **Rename appropriately** (e.g., `prozy-for-cloudflare`, `prozy-monitoring`, etc.)
3. **Update documentation** to reflect your specific use case
4. **Keep the LICENSE** attribution to Prozy contributors
5. **Consider contributing back** improvements that benefit the base project

### Recommended Customizations

When building your purpose-specific proxy:

1. **Configuration**: Extend the `Proxy` struct with your custom fields
2. **Features**: Add new middleware/features using the existing patterns
3. **Protocol Support**: Add protocol-specific logic in `handleClientWithFeatures()`
4. **Backends**: Customize `LoadBalancer` strategies for your use case
5. **Metrics**: Extend `ProxyStats` with domain-specific counters

### Maintaining Your Fork

- **Track upstream**: Add Prozy as an upstream remote to pull in updates
  ```bash
  git remote add upstream https://github.com/sammyjoyce/prozy.git
  git fetch upstream
  git merge upstream/main
  ```

- **Cherry-pick improvements**: Select and integrate relevant Prozy updates
- **Version independently**: Use your own versioning scheme
- **Document differences**: Clearly document how your fork differs from base Prozy

### Example Forks

Ideas for purpose-specific proxies built on Prozy:

- **API Gateway**: Add authentication, request validation, and API versioning
- **CDN Edge**: Enhanced caching, geo-routing, and content optimization
- **Database Proxy**: Connection pooling, query caching, and read/write splitting
- **Monitoring Proxy**: Deep packet inspection, logging, and analytics
- **Security Proxy**: WAF rules, DDoS protection, and threat detection
- **Service Mesh**: Service discovery, circuit breaking, and distributed tracing

## For Contributors

We welcome contributions to improve Prozy as a base proxy platform!

### What We're Looking For

**High Priority:**
- Bug fixes for correctness and safety issues
- Performance optimizations with benchmarks
- Better error handling and recovery
- Documentation improvements
- Test coverage expansion

**Welcome:**
- New load balancing strategies
- Additional caching policies
- Enhanced monitoring and metrics
- Cross-platform improvements
- Example configurations

**Not Accepted:**
- Purpose-specific features (build a fork instead!)
- Breaking API changes without strong justification
- Features that violate the [Prozy Style Guide](CLAUDE.md)
- Dependencies beyond the Zig toolchain

### Before You Start

1. **Check existing issues** to avoid duplicate work
2. **Open an issue** to discuss large changes before implementing
3. **Read the style guide** in [CLAUDE.md](CLAUDE.md) - we take it seriously
4. **Run tests** to ensure your changes don't break existing functionality

## Development Setup

### Prerequisites

- **Zig 0.16.0-dev or later** (for new I/O APIs)
  - Download from [ziglang.org](https://ziglang.org/download/)
  - Or use Nix: `nix develop` (if `flake.nix` is available)
- **Bun** (for test server): [bun.sh](https://bun.sh/)
- **Git** for version control

### Building

```bash
# Clone the repository
git clone https://github.com/sammyjoyce/prozy.git
cd prozy

# Build all components
zig build

# Build specific targets
zig build -Doptimize=ReleaseFast  # Production build
zig build -Doptimize=Debug        # Debug build

# Run the proxy
./zig-out/bin/prozy
```

### Testing

```bash
# Run all unit tests (40+ tests)
zig build test

# Run specific test category
zig test src/root.zig --test-filter "HTTPCache"
zig test src/root.zig --test-filter "LoadBalancer"
zig test src/root.zig --test-filter "Backend"

# Run end-to-end integration tests
zig build test_e2e

# Run full features demo
zig build full_features
```

### Code Organization

```
src/
├── main.zig       # CLI entry point
└── root.zig       # Library exports and core implementation
    ├── ProxyStats      # Statistics and monitoring
    ├── AccessControl   # IP-based filtering
    ├── RateLimiter     # Connection throttling
    ├── HTTPCache       # Response caching with LRU
    ├── HTTPInspector   # Protocol inspection
    ├── Backend         # Backend health tracking
    ├── LoadBalancer    # Traffic distribution
    └── Proxy           # Main proxy orchestration
```

## Code Style

**Read [CLAUDE.md](CLAUDE.md) first** - our style guide is comprehensive and enforced.

### Key Principles

1. **Safety First**: Assertions, bounds checking, no memory leaks
2. **Performance**: Back-of-envelope calculations, benchmarking
3. **Developer Experience**: Clear naming, comprehensive comments
4. **Zero Technical Debt**: Fix it right the first time

### Quick Checklist

- [ ] All functions have pre/postcondition assertions
- [ ] Variables use explicit types (`u32`, not `usize` unless required)
- [ ] Line length ≤ 100 columns
- [ ] Function length ≤ 70 lines
- [ ] Error handling is comprehensive
- [ ] Comments explain "why", not just "what"
- [ ] Tests added for new functionality
- [ ] `zig fmt` has been run

### Assertion Density

**Minimum 2 assertions per function**. Examples:

```zig
fn selectBackend(self: *LoadBalancer, client_ip: IpKey) ?*Backend {
    assert(self.backends.len > 0);  // Pre-condition

    const backend = // ... selection logic

    assert(backend != null or !self.hasHealthyBackends());  // Post-condition
    return backend;
}
```

## Testing

### Test Categories

1. **Unit Tests**: Test individual components in isolation
2. **Integration Tests**: Test component interactions
3. **E2E Tests**: Full proxy flow with real TCP connections

### Writing Tests

```zig
test "Feature: specific behavior" {
    const allocator = std.testing.allocator;

    // Setup
    var component = Component.init(allocator);
    defer component.deinit();

    // Exercise
    const result = try component.operation();

    // Verify
    try std.testing.expectEqual(expected, result);

    // Cleanup (handled by defer)
}
```

### Test Requirements

- All new features must have tests
- Bug fixes must include regression tests
- Tests must clean up resources (use `defer`)
- Tests must be deterministic (no race conditions)
- Integration tests must not require external dependencies (except Bun test server)

## Pull Request Process

### Before Submitting

1. **Run all tests**: `zig build test && zig build test_e2e`
2. **Format code**: `zig fmt src/ examples/ tests/`
3. **Check assertions**: Ensure minimum 2 per function
4. **Update documentation**: README, CLAUDE.md, or docs/ as needed
5. **Add tests**: For all new functionality
6. **Update CHANGELOG.md**: Add entry under "Unreleased"

### PR Guidelines

- **One feature per PR**: Keep changes focused
- **Clear description**: Explain what, why, and how
- **Reference issues**: Link to related issues
- **Include benchmarks**: For performance changes
- **Add examples**: For new features

### PR Template

```markdown
## Description
[Clear description of changes]

## Motivation
[Why is this change needed?]

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing performed

## Checklist
- [ ] Code follows CLAUDE.md style guide
- [ ] All tests pass
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] No new dependencies added
- [ ] Assertions meet density requirements
```

### Review Process

1. **Automated checks**: CI must pass (tests, formatting)
2. **Code review**: At least one maintainer approval
3. **Style compliance**: Must follow CLAUDE.md
4. **Performance**: No regressions without justification
5. **Merge**: Squash and merge with clear commit message

## Release Process

### Versioning

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: Breaking API changes
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes, backward compatible

### Release Checklist

1. **Update VERSION file** with new version number
2. **Update CHANGELOG.md**:
   - Move "Unreleased" changes to new version section
   - Add release date
   - Add comparison links
3. **Update documentation** if API changed
4. **Run full test suite**: All tests must pass
5. **Create release build**: `zig build -Doptimize=ReleaseFast`
6. **Tag release**: `git tag -a v1.0.0 -m "Release 1.0.0"`
7. **Push tag**: `git push origin v1.0.0`
8. **Create GitHub release** with changelog excerpt

### Release Announcement

- Post to GitHub Discussions
- Update README.md badges if applicable
- Notify fork maintainers of significant changes

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue with reproduction steps
- **Security**: Email maintainers privately (see SECURITY.md)
- **Style Questions**: Refer to CLAUDE.md

## Code of Conduct

- Be respectful and professional
- Focus on technical merit
- Welcome newcomers and help them learn
- Provide constructive feedback
- Assume good intentions

## Recognition

Contributors will be:
- Added to CHANGELOG.md for their contributions
- Mentioned in release notes for significant features
- Listed in GitHub's contributor graph

Thank you for helping make Prozy better! 🚀
