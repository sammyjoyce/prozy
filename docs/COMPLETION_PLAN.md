# Prozy Completion Plan

This plan addresses all identified feature and documentation gaps in `prozy`, aligning strict adherence to Zig's new `std.Io` async architecture.

## Guiding Principles (The "New Async" Way)
*   **Capability Passing:** `std.Io` must be passed explicitly to all components requiring I/O.
*   **Colorless Concurrency:** Use `io.async` for non-blocking background tasks (e.g., revalidation) and `io.concurrent` for race-conditions/timeouts (e.g., Keep-Alive vs. Idle Timeout).
*   **Structured Lifetimes:** Resource management via `defer` and explicit cancellation scopes.

---

## Phase 1: Foundations & Accuracy
**Goal:** align documentation with reality and fix low-hanging fruit.
*   [x] **Refactor Architecture Docs:** Rewrite `docs/ARCHITECTURE.md` to reflect the modular `src/prozy/` structure and the `std.Io` design pattern.
*   [x] **Fix X-Forwarded-Proto:** Implement the TODO in `src/prozy/proxy.zig` to detect upstream TLS terminators.
*   [x] **Update Known Limitations:** Update `src/root.zig` to reflect the roadmap, removing "Assumptions" that we are about to break (like "One request per connection").

## Phase 2: The Connection Engine (Keep-Alive)
**Goal:** Transition from "One Request per Connection" to persistent HTTP/1.1 connections.
*   [x] **Connection Loop:** Refactor `proxy.zig`'s `handleConnection` to loop instead of closing after one exchange.
*   [x] **Idle Timeouts:** Use `io.concurrent(io.read(...), io.sleep(keep_alive_timeout))` to manage idle connections without blocking.
*   [x] **Pipelining Support:** Ensure the request parser can handle buffered data remaining after the first request (the "8KB buffer" limitation needs review).

## Phase 3: RFC 9111 Caching Compliance
**Goal:** Move from 85% infrastructure to 100% functional compliance.
*   [x] **Date & Time:** Implement `parseHttpDate` in `http.zig` (currently returns null). Critical for Age/Freshness.
*   [x] **Vary Integration:** Integrate the existing `VaryContext` logic into `CacheKey` generation to support content negotiation.
*   [x] **Conditional Requests:** Implement `generateConditionalRequest` (If-None-Match) and `handle304` logic.
*   [x] **Revalidation (Stale-While-Revalidate):**
    *   Use `io.async` to spawn a *detached* revalidation task when serving stale content.
    *   Ensure the detached task has a copy of the `std.Io` capability and proper allocator safety.

## Phase 4: Resilience & Operations
**Goal:** Make the proxy robust and observable.
*   [x] **Proactive Health Checks:**
    *   Create a `HealthMonitor` struct that holds `std.Io`.
    *   Spawn long-lived background loops (`io.async`) for each backend cluster to actively probe endpoints.
    *   Update `LoadBalancer` state atomically based on probe results.
*   [x] **Digest Authentication:** Implement the missing `TODO` in `auth.zig` for Digest auth parsing.

## Phase 5: Protocol Expansion (Future)
*   [ ] **TLS Termination:** Integrate a Zig TLS implementation (e.g., `std.crypto.tls` if ready, or a wrapper) into the `transport.zig` layer.
*   [ ] **UDP Support:** (Low priority, technically a different proxy type).

---

## Execution Order
Recommended starting point: **Phase 1** (Clean up) -> **Phase 3** (Finish Caching logic) -> **Phase 2** (Major Refactor) -> **Phase 4** (New Features).
