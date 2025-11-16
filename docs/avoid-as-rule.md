# Avoid @as() Linting Rule

## Overview

The `avoid-as` rule detects unnecessary `@as()` usage in Zig code where types can be inferred through Zig's powerful result location semantics. This rule helps maintain clean, idiomatic Zig code that leverages the language's type inference capabilities.

## Rule Description

Zig has powerful [Result Location Semantics](https://ziglang.org/documentation/master/#Result-Location-Semantics) for inferring what type something should be. This happens in function parameters, return types, and type annotations. `@as()` is a last resort when no other contextual information is available.

## What the Rule Detects

### ❌ Incorrect Usage

```zig
// Numeric literals - type can be inferred from context
const x = @as(u32, 1);

// Function parameters - type inferred from signature
fn foo(x: u32) u64 {
    return @as(u64, x);
}
foo(@as(u32, 1));

// @intCast() with @as() - often redundant
const result = @as(u16, @intCast(some_value));
```

### ✅ Correct Usage

```zig
// Use type annotations instead
const x: u32 = 1;

// Let function signature infer the type
fn foo(x: u32) u64 {
    return x; // Type inferred from return type
}
foo(1);

// Use type annotations with @intCast()
const result: u16 = @intCast(some_value);
```

## When @as() is Necessary

The rule correctly allows `@as()` usage in these cases:

1. **Test expectations** - `testing.expectEqual()` often requires explicit types
2. **Undefined values** - `undefined` needs explicit type information
3. **Pointer casting** - `@as(*Type, ptr)` for pointer conversions
4. **Const/alignment casting** - `@constCast()`, `@alignCast()`, `@ptrCast()`
5. **Complex type conversions** - When no contextual type information is available

## Implementation

The rule is implemented as a bash script that:

1. Scans `.zig` files for `@as()` occurrences
2. Applies exclusion rules for necessary `@as()` usage
3. Detects patterns where type inference would work better
4. Provides helpful suggestions for improvement

### Files

- `.claude/hooks/avoid-as.sh` - Standalone script for the rule
- `.claude/hooks/avoid-as-batch.sh` - Batch checker for entire codebase
- `.claude/hooks/zig-avoid-as.sh` - Claude Code hook for automatic checking
- `.claude/plugin/style-check.sh` - Integrated into the main style checker

## Usage

### Standalone

```bash
# Check a specific file
./.claude/hooks/avoid-as.sh src/prozy/proxy.zig

# Check multiple files
./.claude/hooks/avoid-as.sh src/prozy/*.zig

# Check entire codebase
./.claude/hooks/avoid-as-batch.sh
```

### Integrated Style Check

The rule is automatically included in the main style checker:

```bash
./.claude/plugin/style-check.sh src/prozy/proxy.zig
```

## Examples from Prozy Codebase

### Detected Violations

```zig
// In tests.zig - unnecessary @as() with @intCast()
8000 + @as(u16, @intCast(i)),
// Better: 8000 + @as(u16, @intCast(i)) → const port: u16 = 8000 + @intCast(i);

// In backend.zig - redundant @as() wrapping
const total_weight_usize = @as(usize, @intCast(total_weight));
// Better: const total_weight_usize: usize = @intCast(total_weight);
```

### Correctly Ignored Cases

```zig
// Test expectations - necessary
try testing.expectEqual(@as(u16, 200), resp.status_code);

// Undefined values - needs explicit type
proxy.handleConnection(@as(*anyopaque, undefined)) catch {};

// Pointer casting - necessary
@as(*ProxyStats, @constCast(&self.stats))
```

## Benefits

1. **Cleaner code** - Reduces visual noise from unnecessary type annotations
2. **Better readability** - Type annotations are more explicit than `@as()`
3. **Leverages Zig features** - Takes advantage of Zig's powerful type inference
4. **Maintains safety** - Only flags truly unnecessary `@as()` usage

## Integration with CI/CD

This rule can be integrated into your CI pipeline:

```yaml
# Example GitHub Actions step
- name: Check @as() usage
  run: |
    ./.claude/hooks/avoid-as.sh src/**/*.zig
    # or use the batch checker
    ./.claude/hooks/avoid-as-batch.sh
    # or use the integrated style checker
    ./.claude/plugin/style-check.sh src/**/*.zig
```

## Configuration

The rule is currently configured with sensible defaults but can be customized:

- **File patterns**: Only checks `.zig` files
- **Exclusions**: Test expectations, undefined values, pointer casting
- **Detection patterns**: Numeric literals, `@intCast()` combinations

## Future Enhancements

Potential improvements for the rule:

1. **AST-based analysis** - More precise type inference detection
2. **Function signature awareness** - Better context understanding
3. **Configurable exclusions** - Allow customizing what gets flagged
4. **Auto-fix capability** - Automatically suggest or apply fixes

## Contributing

To improve the rule:

1. Test on various Zig codebases
2. Add new detection patterns as needed
3. Refine exclusion rules to reduce false positives
4. Consider edge cases and complex type scenarios

## References

- [Zig Result Location Semantics](https://ziglang.org/documentation/master/#Result-Location-Semantics)
- [Prozy Style Guide](../CLAUDE.md)
- [Zig Style Guidelines](https://ziglang.org/documentation/master/#Style-Guidelines)