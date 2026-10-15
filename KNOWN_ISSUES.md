# Known Issues & Simulation Invariants

This document tracks known physics discrepancies, deliberate simulation simplifications, and architectural trade-offs in `pvp_sim`.

---

## 1. Projectiles & Pet Spells

### Imp Firebolt Instant Damage vs. Visual Flight
* **Status**: Known Simulation Simplification (Documented).
* **Details**: 
  - In `src/pets.zig`, the Imp's Firebolt is implemented as a 2.0-second stationary cast timer (`pet_timer`).
  - Upon cast completion, the 60 damage lands **immediately** on the target on the exact same tick with **0 travel delay**.
  - **Visualizer Compensation**: The Love2D visualizer (`visualizer/main.lua`) renders a synthetic visual firebolt projectile with dynamic flight duration scaled to distance (~24 m/s, clamped between 0.35s and 1.25s) so the animation feels authentic. However, the simulation's damage numbers and event timestamps reflect instantaneous resolution.
* **Why this was done**: 
  - To preserve extreme SIMD vectorization speed and avoid allocating extra projectile queues for autonomous companion units.

---

## 2. Projectile Architecture & Scaling Limits

### How Projectiles Are Currently Handled
In `src/projectiles.zig`, projectile tracking is implemented as a **fixed Structure-of-Arrays (SoA) queue**:
* **Fixed Capacity**: Exactly **4 slots per fighter** (`Slots = 4`), totaling 8 slots per duel lane.
* **Vectorized Across Duels**: Every slot is an AVX-512 vector (`f32x16`), stepping 16 duels in lockstep.
* **Per-Slot Data**:
  - `spell` (Float/ID)
  - `damage` (Float payload)
  - `x`, `y` (Float 2D coordinates)

```zig
// 4 fixed slots per side unrolled at compile time
inline for (0..Slots) |slot| {
    // Stepped in parallel across 16 duel lanes
}
```

### Are We Limited in How Many Projectile Spell Types We Can Implement?

#### 1. Number of *Spell Types / Varieties* (Unlimited, Zero Cost)
* **Performance Impact**: **None**.
* **Explanation**: The projectile system does not care how many *different* projectile spell types exist in the game. Each projectile in-flight simply stores an integer/float ID (`spell`) and generic payload properties (`damage`, `speed`). 
* In `src/projectiles.zig`, dispatching speed or impact type is an `@select` or LUT lookup over the spell ID. Adding 50 or 100 new projectile spells (e.g. Pyroblast, Lightning Bolt, Shoot Wand, Hunter Arrows) adds **no memory bloat and no tick slowdown**.

#### 2. Number of *Simultaneous In-Flight Projectiles* (Fixed Capacity Limit)
* **Current Constraint**: Each player has a hard cap of **4 active projectiles in the air at the exact same moment**.
* **Why**:
  - Unrolling $N$ projectile slots in the AVX-512 inner loop means every tick processes $N$ vector steps per side.
  - 4 slots is more than sufficient for 1v1 PvP caster duels (even rapid-firing Ice Lances or chain-casting Shadow Bolts rarely exceed 2–3 active in-flight missiles per caster).
* **If More In-Flight Capacity Is Needed (e.g. Pet Missiles, 3v3 Arena, or Multi-Shot)**:
  - If pets are given real in-flight missiles, we can either:
    1. **Increase `Slots` from 4 to 6 or 8**: Linearly increases the loop unroll in `projectiles.zig`. Because SIMD registers are 512-bit wide, increasing from 4 to 6 slots adds only ~2–3% overhead to the overall tick loop.
    2. **Or Add Dedicated Pet Projectile Slot(s)**: A single dedicated 1-slot projectile per side for pets (`Slots = 1`) avoids inflating player queues and keeps vector registers tight.
