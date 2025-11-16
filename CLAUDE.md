# Prozy - Async TCP Proxy in Zig

Prozy is a demonstration of Zig's new async I/O capabilities, implementing a real TCP proxy using `std.Io.Threaded`, `io.concurrent()`, and `io.select()`.

## Project Overview

This project showcases:
- ✅ **True async I/O**: Using Zig's new `std.Io.Threaded` runtime
- ✅ **Concurrent connections**: `io.concurrent()` for parallel client handling
- ✅ **Bidirectional proxying**: `io.select()` for duplex data flow
- ✅ **Buffered I/O**: Efficient stream readers/writers
- ✅ **Resource management**: Proper cleanup with defer statements
- ✅ **Cross-platform**: Works on Linux, macOS, and Windows

## Architecture

```
Client → Proxy (port 8080) → Backend Server (port 3003)
```

The proxy accepts TCP connections on port 8080 and forwards them to a backend server on port 3003, handling bidirectional data flow asynchronously.

## Quick Start

### Prerequisites
- Zig 0.16.0-dev or later (for new I/O APIs)
- Bun (for test server)
- Git

### Build & Run
```bash
# Build the proxy
zig build

# Run the proxy (listens on 127.0.0.1:8080 → forwards to 127.0.0.1:3003)
zig build run

# Run all tests
zig build test

# Run end-to-end integration test
zig build test_e2e
```

### Testing
```bash
# Unit tests (18 tests covering initialization, edge cases, API stability)
zig test src/root.zig

# Integration test (requires Bun test server)
zig build test_e2e

# Example demos
zig build async_demo_works
```

## Configuration

The proxy uses these default settings:
- **Listen port**: 8080
- **Listen host**: 127.0.0.1
- **Backend host**: 127.0.0.1
- **Backend port**: 3003
- **Max connections**: Unlimited (except in tests)

## Implementation Details

### Core Components

1. **Proxy**: Main proxy struct with configuration and lifecycle management
2. **Io.Group**: Manages async client tasks and ensures proper cleanup
3. **handleClient**: Async function that handles individual client connections
4. **copyBidirectional**: Uses `io.concurrent()` and `io.select()` for duplex forwarding
5. **copyPipe**: Efficient buffered data copying with error handling

### Async Patterns

```zig
// Thread pool initialization
var threaded_io = std.Io.Threaded.init(allocator);
defer threaded_io.deinit();
const io = threaded_io.io();

// Concurrent client handling
connection_group.async(io, handleClient, .{
    client_stream, io, backend_host, backend_port, connect_timeout
});

// Bidirectional copying with io.select()
var future_c2b = io.concurrent(copyPipe, .{job_c2b}) catch |err| switch (err) {
    error.ConcurrencyUnavailable => { /* handle gracefully */ },
};
```

## Testing Strategy

### Unit Tests (18 tests)
- Proxy initialization with various configurations
- Edge cases (port 0, maximum ports, different hosts)
- API stability and method signatures
- Performance characteristics with multiple instances
- Real-world scenarios (web proxy, dev proxy, load balancer patterns)

### Integration Tests
- End-to-end HTTP proxying with Bun test server
- Multiple concurrent connections
- Error handling (backend unavailable, connection drops)
- Resource cleanup verification

### Example Applications
- `async_demo_works`: Demonstrates all async I/O capabilities
- `demo_complete`: Full proxy showcase with configuration
- `test_time`: Time utilities for performance measurement

## Development Notes

### For Claude Code Sessions

When working with this repository in Claude Code:

1. **Building**: Always run `zig build` before testing changes
2. **Testing**: Use `zig build test` for unit tests, `zig build test_e2e` for integration
3. **Running**: The proxy starts immediately and blocks - use background processes for testing
4. **Dependencies**: Zig toolchain is self-contained; no external packages needed
5. **Test Server**: E2E tests use Bun (`bun tests/test-server.ts`) on port 3003

### Common Development Tasks

```bash
# Format code (if zig fmt is available)
zig fmt src/

# Run specific test
zig test src/root.zig --test-filter "Proxy initialization"

# Debug build
zig build -Doptimize=Debug

# Release build
zig build -Doptimize=ReleaseFast
```

## Known Limitations

1. **TCP only**: Currently supports TCP proxying (no UDP or HTTP-specific features)
2. **Simple forwarding**: No protocol inspection or request modification
3. **Memory usage**: Uses fixed-size buffers (4KB for connections, 8KB for copying)
4. **Error handling**: Basic error logging without sophisticated retry mechanisms

## Future Enhancements

- HTTP-aware proxying with header manipulation
- Dynamic backend configuration
- Connection pooling and keep-alive
- Metrics and monitoring endpoints
- Unix domain socket support
- TLS termination

---

# Prozy Style Guide

> "There are three things extremely hard: steel, a diamond, and to know one's self." — Benjamin Franklin

Prozy's coding style emphasizes safety, performance, and developer experience for async networked systems. This guide captures our principles for building reliable, high-performance proxy infrastructure.

## The Essence Of Style

Our design goals are **safety, performance, and developer experience**. In that order. All three are important. Good style advances these goals.

> "The design is not just what it looks like and feels like. The design is how it works." — Steve Jobs

Style is more than readability. Readability is table stakes, a means to an end rather than an end in itself. We pursue style that makes our proxy safer, faster, and more maintainable.

## Why Have Style?

Another word for style is design. For Prozy, this means:
- **Safety**: Network code handles untrusted input and must never crash or leak resources
- **Performance**: Proxying is latency-sensitive; every microsecond counts
- **Developer Experience**: Clear code enables confident changes and debugging

## On Simplicity And Elegance

Simplicity is not a free pass. It's not in conflict with our design goals. Rather, simplicity is how we bring our design goals together, how we identify the "super idea" that solves the axes simultaneously, to achieve something elegant.

> "Simplicity and elegance are unpopular because they require hard work and discipline to achieve" — Edsger Dijkstra

Contrary to popular belief, simplicity is also not the first attempt but the hardest revision. The hardest part is how much thought goes into everything.

We spend this mental energy upfront, proactively rather than reactively, because we know that when the thinking is done, what is spent on the design will be dwarfed by the implementation and testing, and then again by the costs of operation and maintenance.

## Technical Debt

What could go wrong? What's wrong? Which question would we rather ask? The former, because code, like steel, is less expensive to change while it's hot.

**Prozy has a "zero technical debt" policy.** We do it right the first time. We may lack crucial features, but what we have meets our design goals. This is the only way to make steady incremental progress.

## Safety

> "The rules act like the seat-belt in your car: initially they are perhaps a little uncomfortable, but after a while their use becomes second-nature and not using them becomes unimaginable." — Gerard J. Holzmann

### Control Flow and Abstractions

- Use **only very simple, explicit control flow** for clarity.
- **Do not use recursion** to ensure that all executions that should be bounded are bounded.
- Use **only a minimum of excellent abstractions** but only if they make the best sense of the domain. Abstractions are never zero cost. Every abstraction introduces the risk of a leaky abstraction.

### Bounded Resources

- **Put a limit on everything** because, in reality, this is what we expect—everything has a limit.
- All loops and all queues must have a fixed upper bound to prevent infinite loops or tail latency spikes.
- This follows the "fail-fast" principle so that violations are detected sooner rather than later.
- Where a loop cannot terminate (e.g. an event loop), this must be asserted.

### Explicit Types

- Use explicitly-sized types like `u32` for everything, avoid architecture-specific `usize`.
- For network programming, explicit sizes prevent protocol bugs across architectures.

### Assertions: The Golden Rule

**Assertions detect programmer errors. Unlike operating errors, which are expected and which must be handled, assertion failures are unexpected. The only correct way to handle corrupt code is to crash. Assertions downgrade catastrophic correctness bugs into liveness bugs. Assertions are a force multiplier for discovering bugs by fuzzing.**

- **Assert all function arguments and return values, pre/postconditions and invariants.** A function must not operate blindly on data it has not checked.
- The assertion density of the code must average a minimum of two assertions per function.
- **Pair assertions.** For every property you want to enforce, try to find at least two different code paths where an assertion can be added. For example, assert validity of data right before writing it to the network, and also immediately after reading from the network.
- On occasion, you may use a blatantly true assertion instead of a comment as stronger documentation where the assertion condition is critical and surprising.
- Split compound assertions: prefer `assert(a); assert(b);` over `assert(a and b);`. The former is simpler to read, and provides more precise information if the condition fails.
- Use single-line `if` to assert an implication: `if (a) assert(b)`.
- **Assert the relationships of compile-time constants** as a sanity check, and also to document and enforce subtle invariants or type sizes. Compile-time assertions are extremely powerful because they are able to check a program's design integrity _before_ the program even executes.
- **The golden rule of assertions is to assert the _positive space_ that you do expect AND to assert the _negative space_ that you do not expect** because where data moves across the valid/invalid boundary between these spaces is where interesting bugs are often found.
- Assertions are a safety net, not a substitute for human understanding. Build a precise mental model of the code first, encode your understanding in the form of assertions, write the code and comments to explain and justify the mental model to your reviewer.

### Memory Management

- All memory must be statically allocated at startup. **No memory may be dynamically allocated (or freed and reallocated) after initialization.**
- This avoids unpredictable behavior that can significantly affect performance, and avoids use-after-free.
- As a second-order effect, this also makes for more efficient, simpler designs that are more performant and easier to maintain and reason about.

### Scope and Function Length

- Declare variables at the **smallest possible scope**, and **minimize the number of variables in scope**, to reduce the probability that variables are misused.
- Restrict the length of function bodies to reduce the probability of poorly structured code. We enforce a **hard limit of 70 lines per function**.

Splitting code into functions requires taste. Some rules of thumb:

- Good function shape is often the inverse of an hourglass: a few parameters, a simple return type, and a lot of meaty logic between the braces.
- Centralize control flow. When splitting a large function, try to keep all switch/if statements in the "parent" function, and move non-branchy logic fragments to helper functions. Divide responsibility. All control flow should be handled by _one_ function, the rest shouldn't care about control flow at all. In other words, "push `if`s up and `for`s down".
- Similarly, centralize state manipulation. Let the parent function keep all relevant state in local variables, and use helpers to compute what needs to change, rather than applying the change directly. Keep leaf functions pure.

### Compiler Warnings and External Interaction

- Appreciate, from day one, **all compiler warnings at the compiler's strictest setting**.
- Whenever your program has to interact with external entities (network connections, file descriptors), **don't do things directly in reaction to external events**. Instead, your program should run at its own pace. Not only does this make your program safer by keeping the control flow of your program under your control, it also improves performance for the same reason (you get to batch, instead of context switching on every event).

### Additional Safety Rules

- Compound conditions that evaluate multiple booleans make it difficult for the reader to verify that all cases are handled. Split compound conditions into simple conditions using nested `if/else` branches. Split complex `else if` chains into `else { if { } }` trees. Consider whether a single `if` does not also need a matching `else` branch, to ensure that the positive and negative spaces are handled or asserted.
- Negations are not easy! State invariants positively. When working with lengths and indexes, prefer this form:

  ```zig
  if (index < length) {
      // The invariant holds.
  } else {
      // The invariant doesn't hold.
  }
  ```

- All errors must be handled. An analysis of production failures in distributed data-intensive systems found that the majority of catastrophic failures could have been prevented by simple testing of error handling code.

> "Specifically, we found that almost all (92%) of the catastrophic system failures are the result of incorrect handling of non-fatal errors explicitly signaled in software."

- **Always motivate, always say why**. Never forget to say why. Because if you explain the rationale for a decision, it not only increases the hearer's understanding, and makes them more likely to adhere or comply, but it also shares criteria with them with which to evaluate the decision and its importance.
- **Explicitly pass options to library functions at the call site, instead of relying on the defaults**. For example, write `@prefetch(a, .{ .cache = .data, .rw = .read, .locality = 3 });` over `@prefetch(a, .{});`. This improves readability but most of all avoids latent, potentially catastrophic bugs in case the library ever changes its defaults.

## Performance

> "The lack of back-of-the-envelope performance sketches is the root of all evil." — Rivacindela Hudsoni

### Design-Time Performance

- Think about performance from the outset, from the beginning. **The best time to solve performance, to get the huge 1000x wins, is in the design phase, which is precisely when we can't measure or profile.**
- It's also typically harder to fix a system after implementation and profiling, and the gains are less. So you have to have mechanical sympathy. Like a carpenter, work with the grain.

### Back-of-the-Envelope Sketches

- **Perform back-of-the-envelope sketches with respect to the four resources (network, disk, memory, CPU) and their two main characteristics (bandwidth, latency).**
- Sketches are cheap. Use sketches to be "roughly right" and land within 90% of the global maximum.

### Resource Optimization

- Optimize for the slowest resources first (network, disk, memory, CPU) in that order, after compensating for the frequency of usage.
- For example, a memory cache miss may be as expensive as a disk fsync, if it happens many times more.

### Control Plane vs Data Plane

- Distinguish between the control plane and data plane. A clear delineation between control plane and data plane through the use of batching enables a high level of assertion safety without losing performance.

### Batching and CPU Optimization

- Amortize network, disk, memory and CPU costs by batching accesses.
- Let the CPU be a sprinter doing the 100m. Be predictable. Don't force the CPU to zig zag and change lanes. Give the CPU large enough chunks of work. This comes back to batching.
- Be explicit. Minimize dependence on the compiler to do the right thing for you.
- In particular, extract hot loops into stand-alone functions with primitive arguments without `self`. That way, the compiler doesn't need to prove that it can cache struct's fields in registers, and a human reader can spot redundant computations easier.

## Developer Experience

> "There are only two hard things in Computer Science: cache invalidation, naming things, and off-by-one errors." — Phil Karlton

### Naming Things

- **Get the nouns and verbs just right.** Great names are the essence of great code, they capture what a thing is or does, and provide a crisp, intuitive mental model. They show that you understand the domain. Take time to find the perfect name.
- Use Zig's `CamelCase.zig` style for "struct" files to keep the convention simple and consistent.
- Do not abbreviate variable names, unless the variable is a primitive integer type used as an argument to a sort function or matrix calculation. Use long form arguments in scripts: `--force`, not `-f`. Single letter flags are for interactive usage.
- Use proper capitalization for acronyms (`TCPProxy`, not `TcpProxy`).
- For the rest, follow the Zig style guide.
- Add units or qualifiers to variable names, and put the units or qualifiers last, sorted by descending significance, so that the variable starts with the most significant word, and ends with the least significant word. For example, `latency_ms_max` rather than `max_latency_ms`. This will then line up nicely when `latency_ms_min` is added, as well as group all variables that relate to latency.
- Infuse names with meaning. For example, `allocator: Allocator` is a good, if boring name, but `gpa: Allocator` and `arena: Allocator` are excellent. They inform the reader whether `deinit` should be called explicitly.
- When choosing related names, try hard to find names with the same number of characters so that related variables all line up in the source. For example, as arguments to a copy function, `source` and `target` are better than `src` and `dest` because they have the second-order effect that any related variables such as `source_offset` and `target_offset` will all line up in calculations and slices.
- When a single function calls out to a helper function or callback, prefix the name of the helper function with the name of the calling function to show the call history. For example, `handleClient()` and `handleClientCallback()`.
- Callbacks go last in the list of parameters. This mirrors control flow: callbacks are also _invoked_ last.
- _Order_ matters for readability (even if it doesn't affect semantics). On the first read, a file is read top-down, so put important things near the top. The `main` function goes first.

  The same goes for `structs`, the order is fields then types then methods:

  ```zig
  listen_port: u16,
  backend_port: u16,

  const Config = struct { host: []const u8, port: u16 };
  const Proxy = @This(); // This alias concludes the types section.

  pub fn init(gpa: std.mem.Allocator, config: Config) !Proxy {
      ...
  }
  ```

  If a nested type is complex, make it a top-level struct.

  At the same time, not everything has a single right order. When in doubt, consider sorting alphabetically, taking advantage of big-endian naming.

- Don't overload names with multiple meanings that are context-dependent.
- Think of how names will be used outside the code, in documentation or communication. A noun is often a better descriptor than an adjective or present participle, because a noun can be directly used in correspondence without having to be rephrased.
- Zig has named arguments through the `options: struct` pattern. Use it when arguments can be mixed up. A function taking two `u16` must use an options struct. If an argument can be `null`, it should be named so that the meaning of `null` literal at the call site is clear.

  Because dependencies like an allocator are singletons with unique types, they should be threaded through constructors positionally, from the most general to the most specific.

- **Write descriptive commit messages** that inform and delight the reader, because your commit messages are being read.

### Comments and Documentation

- Don't forget to say why. Code alone is not documentation. Use comments to explain why you wrote the code the way you did. Show your workings.
- Don't forget to say how. For example, when writing a test, think of writing a description at the top to explain the goal and methodology of the test.
- Comments are sentences, with a space after the slash, with a capital letter and a full stop, or a colon if they relate to something that follows. Comments are well-written prose describing the code, not just scribblings in the margin. Comments after the end of a line _can_ be phrases, with no punctuation.

### Cache Invalidation

- Don't duplicate variables or take aliases to them. This will reduce the probability that state gets out of sync.
- If you don't mean a function argument to be copied when passed by value, and if the argument type is more than 16 bytes, then pass the argument as `*const`. This will catch bugs where the caller makes an accidental copy on the stack before calling the function.
- Construct larger structs _in-place_ by passing an _out pointer_ during initialization.

  In-place initializations can assume **pointer stability** and **immovable types** while eliminating intermediate copy-move allocations, which can lead to undesirable stack growth.

  Keep in mind that in-place initializations are viral — if any field is initialized in-place, the entire container struct should be initialized in-place as well.

  **Prefer:**
  ```zig
  fn init(target: *Proxy) !void {
      target.* = .{
          // in-place initialization.
      };
  }

  fn main() !void {
      var target: Proxy = undefined;
      try target.init();
  }
  ```

  **Over:**
  ```zig
  fn init() !Proxy {
      return Proxy {
          // moving the initialized object.
      };
  }

  fn main() !void {
      var target = try Proxy.init();
  }
  ```

- **Shrink the scope** to minimize the number of variables at play and reduce the probability that the wrong variable is used.
- Calculate or check variables close to where/when they are used. **Don't introduce variables before they are needed.** Don't leave them around where they are not. This will reduce the probability of a POCPOU (place-of-check to place-of-use), a distant cousin to the infamous TOCTOU.
- Use simpler function signatures and return types to reduce dimensionality at the call site. For example, as a return type, `void` trumps `bool`, `bool` trumps `u64`, `u64` trumps `?u64`, and `?u64` trumps `!u64`.
- Ensure that functions run to completion without suspending, so that precondition assertions are true throughout the lifetime of the function.
- Be on your guard for **buffer bleeds**. This is a buffer underflow, the opposite of a buffer overflow, where a buffer is not fully utilized, with padding not zeroed correctly. This may not only leak sensitive information, but may cause deterministic guarantees to be violated.
- Use newlines to **group resource allocation and deallocation**, i.e. before the resource allocation and after the corresponding `defer` statement, to make leaks easier to spot.

### Off-By-One Errors

- **The usual suspects for off-by-one errors are casual interactions between an `index`, a `count` or a `size`.** These are all primitive integer types, but should be seen as distinct types, with clear rules to cast between them. To go from an `index` to a `count` you need to add one, since indexes are _0-based_ but counts are _1-based_. To go from a `count` to a `size` you need to multiply by the unit. Again, this is why including units and qualifiers in variable names is important.
- Show your intent with respect to division. For example, use `@divExact()`, `@divFloor()` or `div_ceil()` to show the reader you've thought through all the interesting scenarios where rounding may be involved.

### Style By The Numbers

- Run `zig fmt`.
- Use 4 spaces of indentation, rather than 2 spaces, as that is more obvious to the eye at a distance.
- Hard limit all line lengths, without exception, to at most 100 columns for a good typographic "measure". Use it up. Never go beyond. Nothing should be hidden by a horizontal scrollbar. Let your editor help you by setting a column ruler. To wrap a function signature, call or data structure, add a trailing comma, close your eyes and let `zig fmt` do the rest.
- Add braces to the `if` statement unless it fits on a single line for consistency and defense in depth against "goto fail;" bugs.

### Dependencies

Prozy has **a "zero dependencies" policy**, apart from the Zig toolchain. Dependencies, in general, inevitably lead to supply chain attacks, safety and performance risk, and slow install times. For foundational infrastructure in particular, the cost of any dependency is further amplified throughout the rest of the stack.

### Tooling

Similarly, tools have costs. A small standardized toolbox is simpler to operate than an array of specialized instruments each with a dedicated manual. Our primary tool is Zig. It may not be the best for everything, but it's good enough for most things.

> "The right tool for the job is often the tool you are already using—adding new tools has a higher cost than many people appreciate" — John Carmack

For example, the next time you write a script, instead of `scripts/*.sh`, write `scripts/*.zig`.

This not only makes your script cross-platform and portable, but introduces type safety and increases the probability that running your script will succeed for everyone on the team.

Standardizing on Zig for tooling is important to ensure that we reduce dimensionality, as the team, and therefore the range of personal tastes, grows. This may be slower for you in the short term, but makes for more velocity for the team in the long term.

## The Last Stage

At the end of the day, keep trying things out, have fun, and remember—it's called Prozy, not only because it proxies, but because it's built with purpose!

> You don't really suppose, do you, that all your adventures and escapes were managed by mere luck, just for your sole benefit? You are a very fine person, Mr. Baggins, and I am very fond of you; but you are only quite a little fellow in a wide world after all!"
>
> "Thank goodness!" said Bilbo laughing, and handed him the tobacco-jar.

## License

This project is provided as a demonstration of Zig's async I/O capabilities.
