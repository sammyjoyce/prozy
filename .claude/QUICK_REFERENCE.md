# Claude Code Quick Reference - Prozy

## 🤖 Agents (Use in prompts)

```
Use the code-reviewer agent to review src/root.zig
Use the performance-analyzer agent to analyze HTTPCache
Use the memory-safety agent to audit connection handling
Use the zig-expert agent to explain io.concurrent()
```

## 📋 Commands (Source these)

```
Source the test-coverage command
Source the review-pr command
Source the benchmark command for LoadBalancer
Source the memory-audit command
Source the feature-plan command for adding TLS support
Source the fix-build command
```

## ⚙️ Hooks (Run automatically)

**SessionStart**: Environment setup + welcome message  
**BeforeCommit**: Auto-format with `zig fmt`  
**AfterEdit**: Reminder to run tests

## 🔌 Plugins (Always watching)

- **zig-auto-format.sh**: Auto-formats on save
- **test-on-idle.sh**: Runs tests when idle
- **style-check.sh**: Flags Prozy violations
- **session-stats.sh**: Tracks productivity

## 🎯 Common Workflows

### New Feature
```
1. Source feature-plan for [feature]
2. [Implement]
3. Source test-coverage
4. Source review-pr
```

### Fix Build
```
1. Source fix-build
2. [Apply fixes]
3. zig build && zig build test
```

### Code Review
```
1. git add [files]
2. Source memory-audit
3. Source review-pr
4. [Fix issues]
```

### Performance Check
```
1. Use performance-analyzer for [component]
2. Source benchmark for [component]
3. [Optimize]
```

## ⚡ Prozy Rules (Enforced by plugins)

- ✅ Functions <= 70 lines
- ✅ Assertions >= 2 per function
- ✅ Explicit types (u32 not usize)
- ✅ defer after allocations
- ✅ Zero allocation after init
- ✅ Comments explain WHY

## 🚨 Quick Violations Fix

**"Uses usize"** → Change to `u32` or `u64`  
**"Low assertions"** → Add pre/postcondition asserts  
**"Missing defer"** → Add cleanup after alloc/open  
**"Dynamic allocation"** → CRITICAL - redesign to static  
**"Function too long"** → Extract helpers (<= 70 lines)

## 📖 Documentation

Full docs: `.claude/README.md`  
Style guide: `CLAUDE.md`  
Project: `README.md`
