# Multi-threaded training

Use `zig build -Doptimize=ReleaseFast`, then:

```sh
zig-out/bin/pvp_sim --train-only --threads 8 --generations 30 --pop 64 --duels 4 --metrics /tmp/metrics.json
```

The Love2D Training Controls tab exposes the same setting. One thread remains the default: it runs directly without a worker pool, schedule allocation, or synchronization. Evaluation and raw combat benchmarks retain their existing execution paths.

## Design and research

Policy inference reads only weights, not fitness, Elo, or records. Combat batches have no cross-lane interactions. This permits independent simulations while retaining the existing evolution algorithm:

1. Generate the schedule on the main thread with exactly the original random calls and order.
2. Persistent workers claim whole SIMD batches through an atomic index. Each owns a private arena with 42 aligned SoA columns and 16 lanes. Physics ticks only the requested batch, including on the serial path.
3. Workers write disjoint outcome slots and never update genomes, matchmaking RNG, or league counters.
4. A condition-variable barrier waits for all workers. The main thread applies each batch and lane in the original order, preserving floating-point accumulation and sequential Elo updates. Historical and external opponents are copied anew for scoring each match, preserving their frozen ratings.
5. Only then do metrics, breeding, checkpointing, and stop/save proceed. Idle workers sleep; teardown wakes and joins them before freeing arenas.

Synchronization uses Zig 0.14 standard-library threads, mutexes, conditions, and atomics, with no dependencies. Research references: [Zig 0.14 language and threading documentation](https://ziglang.org/documentation/0.14.0/) and the installed Zig 0.14 `lib/std/Thread.zig`, `Thread/Mutex.zig`, and `Thread/Condition.zig` implementations. Mutex handoff publishes schedules/results; the atomic index only assigns ownership and therefore uses monotonic ordering. Pool storage is heap-owned so returning or moving a League cannot invalidate worker addresses. Partial initialization failures join already-started workers and release allocations.

## Target CPU benchmark

AMD Ryzen 9 9950X, 16 cores / 32 hardware threads, Zig 0.14.0, native ReleaseFast. Three sequential runs per worker count, each with 30 generations, 64 agents, four 16-duel batches per agent, 30-second duel limit, seed 42, normal metrics collection. Table shows median overall CLI throughput, including generation boundaries and champion diagnostics. Host scheduling and boost affect timings.

| Workers | Neural duels/sec | Relative to new serial |
| --- | ---: | ---: |
| 1 | 47,644 | 1.00× |
| 2 | 93,740 | 1.97× |
| 4 | 181,154 | 3.80× |
| 8 | 322,351 | 6.77× |
| 16 | 502,562 | 10.55× |
| 32 | 583,529 | 12.25× |

The pre-change run of this workload measured 33,838 duels/sec. The new serial path improves approximately 41%, principally by avoiding physics on unrelated arena lanes. Exported champions match the original baseline byte for byte, and all worker counts produce the same champion.

## Performance concerns and memory

- Small or very short tournaments can spend a larger fraction of time waking workers and applying ordered results. The serial default avoids those costs. Requested workers are capped to the number of scheduled batches (at least one).
- Elo scoring, matchmaking, breeding, and metrics remain sequential; scaling consequently tapers. SMT adds less throughput than additional physical cores. Using all 32 hardware threads may compete with desktop rendering; 4–8 workers are a useful starting point on this CPU.
- Each worker's arena payload is 2,688 bytes (42 columns × 16 lanes × 4 bytes), plus allocator metadata and worker/thread bookkeeping. Schedule and result buffers scale with population × batches per agent; each result is 256 bytes, plus the small policy-pointer/opponent job record. These buffers are allocated once and reused.
- Zig's default thread stack reserves 16 MiB of virtual address space per worker (512 MiB at 32 workers); physical pages are committed as used. Linux `/usr/bin/time` reported roughly 0.8–1.3 MiB maximum resident memory in these short runs, but that measurement is too coarse to estimate individual worker costs. Large populations and schedules need additional memory.
- Existing checkpoints do not serialize RNG state or training configuration. Resumes from the same checkpoint and configuration match across thread counts, but uninterrupted versus resumed evolution is not guaranteed to match. This is a pre-existing checkpoint limitation.

## Validation

`zig build test -Doptimize=ReleaseFast` verifies throughput floors and exact seeded population weights, fitness, Elo, records, RNG state, frozen pools, and telemetry equality for 1/2/4/16 threads over 12 generations, with peer, historical, external, and bot matchmaking. This crosses Hall of Fame updates and exercises persistent pool reuse. Additional tests cover resume across thread counts and allocator cleanup.

`love visualizer/training_test` verifies responsive live metrics, four-worker stop/save, two-worker resume, immediate stop, and trainer failure handling. Graceful stops wait for the generation barrier before saving.
