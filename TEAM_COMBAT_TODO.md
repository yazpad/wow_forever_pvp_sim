# Team combat and NPC policy brainstorming

Status: design discussion, 2026-10-22. No implementation authorized by this document.
Recommendations below are starting hypotheses to test, not settled decisions.

## Starting point

The current combat path represents two participants using A/B columns. `search_sim.Action`
contains ability and movement, without a target identity. `Duel(a, b)` and spec dispatch
are specialized for a pair of specs. The neural policy currently has 44 inputs and
ability/movement outputs. The neuro arena already alternates the evolving side and
maintains historical policies. These are useful foundations, but team support needs
new combat semantics, observations, action targets, and team checkpoints.

## One network per character or per team?

Separate three decisions: who chooses actions, who shares weights, and what we evolve.
They do not need to have the same answer.

| Option | Benefit | Cost / concern |
| --- | --- | --- |
| Independent character actors, separate weights | Mix APL and learned teammates; replace one teammate easily | Actors need team observations and partner diversity to learn coordination |
| Character actors with shared weights per spec/role | Reuse one policy across compatible characters; fewer unique parameters | Need identity/role inputs; identical observations can produce identical choices |
| One team network producing all characters' actions | Direct joint decisions and shared representation | Tied more tightly to roster size/composition; larger output interface and readiness masks |
| Character actors plus a team coordinator | Explicit focus target, CC assignment, or defensive plan | Adds a second decision layer and timing/ownership questions |

Proposed first version: one actor invocation per character, with separate policy
weights per roster slot initially. Each actor sees all living allies/enemies and its
own identity. Package the actors as one team checkpoint for training and evaluation.
This does not require one giant team neural network. Test weight sharing later.

An NPC controller can be scripted, APL-based, or neural behind the same interface:
observation + legal actions -> ability + target + movement. Allow mixed controllers
within one team from the beginning. A configurable APL parser can follow simple
hard-coded priority rules once the targeting API is proven.

## Freeze one team or one character?

“Frozen” means weights and controller configuration do not change during an evaluation
block. Frozen characters still observe, move, cast, and react normally in every fight.
An opponent archive can contain many frozen teams, sampled between matches.

Proposed default: freeze the opposing team for an epoch and evolve a population of
complete friendly team bundles. Each candidate contains all friendly actor weights;
selection uses team results. Alternate sides, retaining historical complete teams.
Evaluate candidates against a fixed seed/opponent schedule within a comparison block.

| Training mode | Useful for | Main concern |
| --- | --- | --- |
| Evolve a whole friendly team against frozen opponents | Learning a coordinated fixed composition | More parameters mutate together; harder to attribute improvements |
| Evolve one friendly character, freeze teammates and opponents | Bootstrapping, debugging, learning to play beside an APL | Can get stuck where improvement requires two partners to change together |
| Rotate which character evolves | Incremental improvement with a smaller mutation space | Slot order and partner overfitting; needs full-team evaluation after each cycle |
| Evolve one character with sampled frozen teammates | Building reusable NPC teammates | More varied evaluations and potentially noisier fitness |

Suggested progression: scripted 2v2 baseline -> one learned actor with scripted
partners -> whole-team evolution. Compare whole-team mutation against rotating-slot
mutation at equal simulation budgets. Keep both if they serve different use cases.
Every candidate still plays a complete team match; never score isolated duels as
a substitute for team performance.

## Coordination and fitness

- Start with team win/draw/loss as the main selection signal. Log individual damage,
  healing, interrupts, deaths, and CC for diagnosis, not as independent objectives.
- Decide timeout scoring explicitly; raw damage/healing rewards can encourage
  farming instead of winning. Any shaping/tiebreaker must be separately reported.
- Give actors information about allies' health, casts, targets, CC and relevant
  cooldowns, plus enemies' corresponding observable state. Decide whether enemy
  information is omniscient or visibility-limited before training datasets exist.
- Do not assume team reward alone guarantees coordination. Include scenarios such
  as avoiding damage on a polymorphed target, interrupt overlap, peeling, and healing.
- For reusable actors, evaluate with multiple partners and compositions; a champion
  team is evidence of that bundle's strength, not each member's portability.
- Archive complete teams to preserve compatible behavior. Recombined partners need
  fresh evaluation before being treated as a strong team.

## Combat architecture TODO

- [ ] Start with fixed-capacity 2v2; reserve inactive slots and explicit alive masks.
- [ ] Define stable unit IDs, team membership, roster specs, and controller per slot.
- [ ] Keep SIMD lanes as independent matches; store participant columns across lanes.
      Do not repurpose the existing 16 duel lanes as 16 teammates.
- [ ] Decide fixed-composition specialization versus runtime spec dispatch. Avoid
      compiling every possible roster combination without measuring code/build cost.
- [ ] Add explicit ability target and movement reference/direction. Validate legal
      ability-target combinations rather than selecting incompatible heads blindly.
- [ ] Track cast/channel targets and projectile source/target at launch; specify what
      happens if the caster switches target or the original target dies.
- [ ] Separate per-unit state, source-target effects, and match-wide state. Define
      effect-specific stacking/refresh rules for duplicate specs; DR belongs to the
      affected target/category, while many DoTs require source ownership.
- [ ] Route damage, healing, drains, dispels, CC, pet actions, and triggered effects
      through explicit source/target identities.
- [ ] Define team death/win/timeout rules and autonomous pet behavior after owner death.
- [ ] Replace pairwise distance clamping with consistent arena bounds and per-unit
      positions; decide whether initial movement remains target-relative or uses 2D directions.
- [ ] Compute all ready actors' choices from the same pre-action observation, then
      resolve with documented deterministic ordering. Do not expose earlier actors'
      newly chosen actions to later actors in the same decision instant.
- [ ] Preserve reaction timers, cast completion, and deterministic snapshot/replay behavior.
- [ ] Extend replay format/UI with unit IDs, team rosters, and targeted combat events.

## Policy and training TODO

- [ ] Define versioned team observations, stable roster ordering, identity inputs,
      dead/empty masks, and legal targeted actions.
- [ ] Build deterministic scripted NPCs: focus damage, CC another enemy, heal/peel ally.
- [ ] Package roster configuration, all actor policies, observation/action versions,
      and any team coordination settings in reproducible team checkpoints.
- [ ] Implement single-slot and whole-team evolution as selectable schedules.
- [ ] Retain archive mixtures, fixed evaluation seeds, side/spawn swaps, and held-out
      opponents. Include duplicate-spec and mixed-controller teams.
- [ ] Version incompatible neural inputs/outputs; old duel checkpoints are not
      automatically team-capable. Consider initialization transfer separately.
- [ ] Defer team MCTS until NPC team combat is correct and benchmarked. Scripted or
      frozen-policy teammates could be the first search continuation model.

## Milestones and acceptance

1. Deterministic scripted 2v2 replay: correct targeting, deaths, effects, and winner.
2. Support interactions: ally healing/dispel and enemy CC without source confusion.
3. One learned character plays with scripted partners; repeatable held-out evaluation.
4. Whole-team alternating evolution with frozen team archives and saved bundles.
5. Compare schedules, partner transfer, and throughput before expanding to 3v3.

Checks should cover duplicate-source DoTs, target death mid-cast/projectile,
simultaneous lethal damage, ally-target legality, CC/DR ownership, snapshot restore,
roster/side swapping, and unchanged duel results. Benchmark complete matches/sec,
policy evaluation cost, state memory, and snapshot cost for each supported team size.

## Questions to settle together

1. Is the first goal strong fixed arena compositions, or NPCs that cooperate with
   arbitrary learned/scripted/player teammates? Proposed starting scope: fixed 2v2,
   while keeping controllers swappable.
2. Should actors see the whole battlefield, or only selected-target details plus
   summaries? Proposed first version: full roster observations with explicit masks.
3. Should focus fire and CC assignments be scripted team commands initially, or
   learned entirely? Proposed baseline: scripted coordination, then compare learning.
4. Do we want whole-team evolution first, or one learned actor beside APL partners?
   Proposed first learning milestone: one learned actor; next milestone: team bundles.
5. Should identical specs share weights? Proposed initial answer: separate slot
   weights; benchmark per-spec sharing once role/identity inputs exist.
