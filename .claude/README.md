# Claude Code Configuration for Prozy

Enterprise-grade Zig development environment with specialized agents, custom commands, automated hooks, and style enforcement plugins.

## 🚀 Quick Start

The configuration is already set up! Just use Claude Code in this project:

```bash
cd /path/to/prozy
# Claude Code will automatically load .claude/settings.json
```

On session start, you'll see:
```
🚀 Prozy Development Environment Ready
📋 Custom commands: /test-coverage, /review-pr, /benchmark, /memory-audit, /feature-plan, /fix-build
🤖 Agents available: code-reviewer, performance-analyzer, memory-safety, zig-expert
```

## 📁 Structure

```
.claude/
├── settings.json          # Main configuration with hooks & permissions
├── agent/                 # Specialized expert agents
│   ├── code-reviewer.md   # Safety, performance & style review
│   ├── performance-analyzer.md  # Performance analysis
│   ├── memory-safety.md   # Memory & resource auditing
│   └── zig-expert.md      # Zig language expertise
├── command/               # Custom slash commands (skills)
│   ├── test-coverage.txt  # Test coverage analysis
│   ├── review-pr.txt      # Comprehensive PR review
│   ├── benchmark.txt      # Performance benchmarking
│   ├── memory-audit.txt   # Memory safety audit
│   ├── feature-plan.txt   # Feature planning
│   └── fix-build.txt      # Build error diagnosis
└── plugin/                # Automation scripts
    ├── zig-auto-format.sh # Auto-format on save
    ├── test-on-idle.sh    # Run tests after changes
    ├── style-check.sh     # Prozy style guide enforcer
    └── session-stats.sh   # Session productivity metrics
```

## 🤖 Specialized Agents

### When to Use Each Agent

**code-reviewer** - Comprehensive code review
```
Use the code-reviewer agent to review the changes in src/root.zig for safety and style compliance
```
- Checks assertion density (>= 2 per function)
- Verifies error handling
- Enforces Prozy style guide (functions <=70 lines, explicit types)
- Reviews resource cleanup (defer statements)

**performance-analyzer** - Performance analysis with math
```
Use the performance-analyzer agent to analyze the HTTPCache implementation
```
- Performs back-of-the-envelope calculations
- Identifies bottlenecks (Network → Disk → Memory → CPU)
- Suggests optimizations with expected gains
- Analyzes async I/O patterns

**memory-safety** - Memory & concurrency auditor
```
Use the memory-safety agent to audit the connection handling code
```
- Finds memory leaks and use-after-free bugs
- Verifies zero-allocation-after-init policy
- Checks concurrent access protection
- Validates buffer safety

**zig-expert** - Zig language authority
```
Use the zig-expert agent to explain io.concurrent() error handling patterns
```
- Explains Zig 0.16.x features
- Provides runnable code examples
- Shows Prozy usage patterns
- Warns about gotchas

## 🎯 Custom Commands (Skills)

All commands are sourced from `.claude/command/` files.

### test-coverage
Run tests with detailed coverage analysis
```
Source the test-coverage command
```
Analyzes test results and suggests specific test cases for untested code paths.

### review-pr
Comprehensive code review using all agents
```
Source the review-pr command
```
Runs safety, performance, memory, and style reviews on `git diff main...HEAD`.

### benchmark
Performance analysis with calculations
```
Source the benchmark command for HTTPCache
```
Performs back-of-the-envelope calculations for throughput, latency, memory, CPU.

### memory-audit
Rigorous memory safety audit
```
Source the memory-audit command
```
Audits staged changes for memory leaks, resource leaks, and concurrent safety issues.

### feature-plan
Detailed implementation planning
```
Source the feature-plan command for adding TLS termination
```
Creates phased plan following Prozy architecture patterns.

### fix-build
Diagnose and fix build errors
```
Source the fix-build command
```
Analyzes build errors and suggests fixes following Prozy style.

## ⚙️ Automated Hooks

### SessionStart
Runs on every session start:
1. `scripts/setup_env.sh` - Environment setup
2. Welcome message with available commands
3. Agent availability announcement

### BeforeCommit
Runs before git commits:
- **Auto-format**: `zig fmt` on all `*.zig` files

### AfterEdit
Runs after editing source files:
- Reminder to run tests

## 🔌 Plugins

Plugins are bash scripts in `.claude/plugin/` that run automatically.

### zig-auto-format.sh
**Trigger**: After editing any `.zig` file  
**Action**: Runs `zig fmt` to auto-format code  
**Output**: `✓ Formatted <file>`

### test-on-idle.sh
**Trigger**: When session becomes idle  
**Action**: Runs `zig build test` if source files changed  
**Output**: Test results or failure notice

### style-check.sh
**Trigger**: After editing any `.zig` file  
**Action**: Checks Prozy style guide violations:
- Forbidden types (usize → use u32/u64)
- Missing assertions (need >= 2)
- Missing defer after allocations
- Dynamic allocation (CRITICAL violation)

**Output**: Style violation warnings with references to CLAUDE.md

### session-stats.sh
**Trigger**: Throughout session  
**Action**: Tracks files edited, builds, tests  
**Output**: Session summary on demand

## 🔒 Permissions

### Auto-Allowed (No Confirmation)
- `zig build`, `zig test`, `zig fmt`
- `git status`, `git diff`, `git log`, `git add`
- `bun` commands (test server)
- Reading all project files (`*.zig`, `*.md`, `build.zig`, etc.)

### Ask (Require Confirmation)
- Editing source files (`src/*.zig`)
- Creating new Zig files
- Git operations: commit, push, rebase, merge, reset, checkout
- File operations: `rm`, `mv`
- Editing documentation and build config

### Denied (Blocked)
- Force pushes (`git push --force`)
- Global git config changes
- Dangerous operations (`rm -rf /`, `chmod 777`)
- Editing `.git/` internals

## 🎨 Example Workflows

### Adding a New Feature
```
1. Source the feature-plan command for adding backend health probes
2. [Review the plan]
3. Implement the feature following the plan
4. Source the test-coverage command
5. Source the review-pr command
6. [Address any issues found]
7. git commit -m "Add proactive backend health probes"
```

### Debugging Build Errors
```
1. Source the fix-build command
2. [Apply suggested fixes]
3. zig build
4. zig build test
```

### Performance Optimization
```
1. Use the performance-analyzer agent to analyze the load balancer
2. [Review bottlenecks and suggestions]
3. Source the benchmark command for LoadBalancer
4. [Implement optimizations]
5. Source the test-coverage command
6. Source the review-pr command
```

### Code Review Before PR
```
1. git add <changed files>
2. Source the memory-audit command
3. [Fix any memory safety issues]
4. Source the review-pr command
5. [Address critical issues and style violations]
6. git commit
7. Source the test-coverage command
```

### Learning Zig Patterns
```
1. Use the zig-expert agent to explain defer scoping rules
2. Use the zig-expert agent to show io.select() examples
3. Review src/root.zig for Prozy's usage patterns
```

## 💡 Pro Tips

1. **Agent Specialization**: Each agent has deep expertise - use them for their specialty
   - code-reviewer → comprehensive review
   - performance-analyzer → bottlenecks & calculations
   - memory-safety → leaks & concurrent bugs
   - zig-expert → language questions

2. **Command Chaining**: Commands complement each other
   ```
   feature-plan → [implement] → test-coverage → review-pr
   ```

3. **Hooks Run Automatically**: 
   - Files auto-format on edit
   - Style checks run immediately
   - Tests run when idle
   - Stats track your productivity

4. **@ Mention Files**: Include file context automatically
   ```
   Review @src/root.zig:450-520 for performance issues
   ```

5. **Leverage CLAUDE.md**: All agents reference the Prozy style guide
   - Functions <= 70 lines
   - Assertion density >= 2
   - Zero allocation after init
   - Explicit-sized types

6. **Plugin Output**: Watch for plugin notifications
   ```
   🎨 Formatting src/main.zig...
   ⚠️  Style violation: Uses 'usize' - prefer explicit u32/u64
   🧪 Running tests after 3 file(s) changed...
   ```

## 🛠️ Customization

### Add a New Agent

Create `.claude/agent/my-agent.md`:

```markdown
# My Agent Name

## Role
[What this agent does]

## Mission
[Specific focus areas]

## [Additional sections]
...
```

### Add a New Command

Create `.claude/command/my-command.txt`:

```
[Command description]

[What it does]

[Steps to execute]
```

### Add a New Plugin

Create `.claude/plugin/my-plugin.sh`:

```bash
#!/usr/bin/env bash
# My Plugin - [description]

# Your automation logic here
```

Make it executable:
```bash
chmod +x .claude/plugin/my-plugin.sh
```

### Modify Hooks

Edit `.claude/settings.json` → `hooks` section:

```json
"hooks": {
  "AfterEdit": [
    {
      "matcher": "*.zig",
      "hooks": [
        {
          "type": "command",
          "command": ".claude/plugin/my-plugin.sh $FILE"
        }
      ]
    }
  ]
}
```

## 📚 Reference Documentation

- [Claude Code Official Docs](https://docs.anthropic.com/claude/docs)
- [Prozy Style Guide](../CLAUDE.md) - **Required reading**
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [Zig Standard Library](https://ziglang.org/documentation/master/std/)

## 🎓 Prozy-Specific Patterns

### Zero Allocation After Init
```zig
// All memory allocated at startup
var cache = try HTTPCache.init(allocator, 10 * 1024 * 1024);
defer cache.deinit();

// NO malloc/realloc during operation
// Plugins will flag violations!
```

### Assertion Density >= 2
```zig
pub fn selectBackend(self: *LoadBalancer) ?*Backend {
    assert(self.backends.len > 0);  // Precondition
    
    const backend = self.roundRobin();
    
    assert(backend != null);  // Postcondition
    return backend;
}
```

### Async I/O Patterns
```zig
// Use io.concurrent() for parallel operations
var future = io.concurrent(copyPipe, .{client, backend});

// Use io.select() for bidirectional forwarding
const result = io.select(.{future_c2b, future_b2c});
```

### Function Length <= 70 Lines
```zig
// Extract helpers to keep functions under limit
pub fn handleClient(client: Stream) !void {
    // Setup (< 70 lines)
    try handleClientImpl(client);
}

fn handleClientImpl(client: Stream) !void {
    // Implementation split into focused functions
}
```

## 🚨 Common Violations Caught by Plugins

1. **Using `usize`** → Use explicit `u32` or `u64`
2. **Low assertion density** → Add precondition/postcondition assertions
3. **Missing defer** → Add cleanup after allocations/opens
4. **Dynamic allocation** → CRITICAL - violates Prozy policy
5. **Long functions** → Split into helpers (<= 70 lines each)

## 🤝 Contributing

When enhancing this configuration:

1. Follow Prozy principles (see CLAUDE.md)
2. Add clear documentation
3. Test with real workflows
4. Update this README
5. Keep agents, commands, and plugins focused

---

**Built for Prozy** - Enterprise-ready async TCP proxy in Zig 🚀  
*Where safety meets performance through style*
