# Physics

The rigid body solver lives in `goluwa/physics/` (`physics.lua` the world and its config, `world_step.lua`/`solver.lua` the step, `contact_solver.lua`/`contact_store.lua` contacts, `shapes/`, `constraints/`, `pair_solvers/`, `broadphase.lua`, `islands.lua`). Gameplay on top of it (characters, props, tools) lives in the addons.

## Testing and measuring

- Tests: `luajit glw test physics/` (or a single file such as `physics/impacts.lua`, `physics/contacts.lua`, `physics/buoyancy.lua`, `physics/wheel.lua`). A flaky physics test is a real nondeterminism bug.
- Benchmarks: `luajit glw bench physics_stress` (zones of stacks, mixed shapes, chains, CCD, ragdolls, characters; `ZONES=a,b` picks some, `QUICK=10 luajit glw --cli --physics lua test/benchmarks/physics_stress.lua` is one short run that prints per zone timings and stats), `physics_synthetic_map` (no assets), `physics_map_stack` (needs a gmod map).
- JIT variance between processes is large: compare several alternating runs against a copy or worktree of the old code, and compare trajectories (the simulation is chaotic) before trusting a timing difference. See [performance.md](performance.md).
- The physics debug (`N`, `addons/debug/lua/autorun/physics/`) shows bodies, shapes, joints and character parts. The PHYSICS tab of PERF (`perf physics`; `physics_stats` prints it) shows `goluwa/physics/stats.lua` snapshots. `autorun/physics/` only loads with `--3d` or `--physics`.

## Step layout

- Collide once per step, solve soft contacts per substep: broadphase, islands and narrow phase run on the first substep with velocity look-ahead bounds, later substeps reuse the manifolds while both poses stay within the recycle thresholds in `solver.lua`, CCD runs every substep.
- Per substep: integrate (snapshots `SolverVelocity0`) -> one biased soft solve -> `ApplySolverVelocityDelta` moves bodies by the velocity change -> rigid relax sweeps. Substep, iteration and relax counts are config in `physics.lua`.
- World support contacts (`shapes/support_contacts.lua`) sweep on the collide substep and re-apply the cached contacts on later substeps. They only act on mesh and heightmap surfaces.
- Joints are soft velocity constraints solved after contacts in the main solve and before contacts in the relax pass, so contacts (friction included) get the last word.
- Pairs are solved top-down along gravity (`solve_order.lua`).
- Slow ticks (`slow_step.lua`): over `SlowStepTime` a tick logs a `[physics] slow tick` warning split into listeners and step, and the island holding most of the time is put to sleep (never one that cannot sleep). `MaxFrameStepTime` stops a frame's stepping early so slow ticks cannot snowball.

## Engine integration

- The `Update` listener calls `UpdateFixed` and fires `PhysicsUpdate` before each fixed step; `physics.Update` is the manual variable-dt stepper for tests. Do not add your own step.
- Rendering interpolates from `StepStartPosition/Rotation` with `InterpolationAlpha`. Anything reading the interpolated transform must run after physics and before `Render` (`LateUpdate`: camera, ui layout) or it jitters. Use the frame phases in `main.lua`, not `AddGlobalEvent` priorities, since a component global event takes its priority from the first component that registers it.
- Drive kinematic bodies through their entity's `transform`, not `body.Position` (bodies are synced from the transform every step).
- Removed bodies become NULL on the next update: check `body:IsValid()`.
- Mark world bodies with `SetWorldGeometry(true)` so `RigidBody.WorldGeometryBodies` stays correct; `physics.RayCast` only sees world geometry unless `{IncludeRigidBodies = true}`.
- A `rigid_body` is saved with a scene unless its `Shape`/`Shapes` were set from code (objects a scene cannot store).
- Automatic mass is bounding box volume times `Density` (default 1, in kg/m^3), so content that gives no mass has to set `Density` (wood is about 500).

## Invariants and pitfalls

- Anything that moves a body AND changes its velocity (swept CCD hits, `motion.ApplyBodyMotionDelta`, support push-out) must call `body:SyncSolverVelocity()`, otherwise delta integration moves it twice.
- Never iterate `pairs()` in order-sensitive code: body keyed tables follow ASLR and string keys a per-process hash seed. Use ordered arrays (`island.bodies`, `dynamic_bodies`, a list of names).
- Kinematic bodies: use `HasSolverMass()`, not `not IsStatic()`, for CCD pair decisions.
- Per-tick queries must go through the broadphase (`sweep_candidates.CollectRigidBodyCandidates`, `collider_index` for big static bodies), never loop all bodies and colliders. Many rays in one region can share a candidate list (`physics.CollectRayCandidates`, passed as `options.Candidates`). Broadphase entry bounds are fat, so `entry.bounds` includes a margin.
- Rays use each shape's `TraceAgainstBody`; a shape without it can only be hit by sweeps. `body.TraceOwner` makes a trace that ignores an entity ignore the body too.
- Sampled sweeps alias on long distances and step over thin geometry; thin shapes need an analytic point sweep.
- `Vec3` is float32: fixed epsilons fail far from the origin, scale them with coordinate magnitude (`get_sweep_epsilon` in `sweep_mesh.lua`).
- Soft bias selection in the contact solver is branch free; branches there cause trace aborts. `ffi.copy` of a vector followed by reads of it can miscompile in a trace, write fields one by one. Avoid allocation in per-pair code. See [jit-trace-aborts.md](jit-trace-aborts.md).
- Inverse inertia singularity tests must be relative to the matrix scale, otherwise very light bodies get zero inverse inertia and cannot rotate.
- Per-pass stamps must be compared with `== stamp`, not truthiness, or sleepers wake forever.
- Velocity heuristics for free grounded bodies (`OnGroundedVelocityUpdate`) must skip jointed bodies; they fight the joint solver.
- Joint accumulators stored as world vectors must drop their component along the free axis before each warm start (`rows.RemoveAxis`): the frame turns between substeps and the leftover would be reapplied unsolved every step.
- A body with `SpinAxis` (wheels) integrates its spin about that axis first, so its axle follows its joint.
- Hinge and ragdoll joints take an optional spring (`joint:SetSpring(neutral, hertz, limit_hertz, damping, zone)`, `rows.SpringRow`) that stiffens near the limits so limbs land on them softly. It is not solved in the relax pass (which would damp it dead) and only sees inertia about the body centres.
- Mesh contacts: every contact path must agree on the same rest gap (collision margin plus slop), or a body gets two resting states and rocks awake. Contacts against meshes are grouped by normal into several manifolds (`ResolvePairClusters`) and reduced to points spanning the footprint. The relax pass treats every contact as touching, so open contacts must be filtered at creation.

## Impacts and contacts

- `PhysicsImpact` (global event, after each step) reports collisions above `CollisionPairs.ImpactSpeed`, at most one per entity pair per step. Every path that removes approach velocity (manifolds, CCD and penetration impulses, support contacts, grounding) must record it, or that kind of hit goes silent.
- `PhysicsContact` reports touching pairs that slide (`slip`) or roll (`roll`, `roller`) above `CollisionPairs.ContactSpeed`.
- Positions come from the dynamic body, since world side contact points can be polygon vertices.
- Tests: `physics/impacts.lua`, `physics/contacts.lua`. Sounds built on these events are in [audio.md](audio.md).

## Source content and maps

- Source `.phy` props: the engine has no centre of mass offset (body origin = centre of mass), so hulls are shifted by the `.phy` mass centre and the visual is a child with `PhysicsNoCollision`. Colliders are handed to the solver as if they were bodies: lever arms and inertia use `body:GetBody()`.
- Models with `ragdollconstraint` blocks load as `physics.ragdoll` and spawn through the `prop_ragdoll` prefab with the `source_ragdoll` component (`addons/game/lua/components/source_ragdoll.lua`): one body per solid, hinges from the constraints, the visual rig driven from the bodies. Only the authority builds the limbs. Test: `luajit glw test addons/sandbox/tests/entities/source_ragdoll.lua`.
- BSP collision (`addons/source_loader/lua/source_loader/bsp.lua`, `bsp_collision.lua`): displacements become triangle meshes, world brushes come from the world model's node tree. `scene_loading.IsLoading()` goes false before the BSP collision body exists: wait for a rigid body whose owner has `static_world`.
- Source units: `units.meters` in `goluwa/static_world/units.lua` (0.75 inch, not 1 inch, per unit).

## Character movement

`addons/game/lua/components/character_movement.lua`, shared by players and npcs (see [characters.md](characters.md)): Source style friction and acceleration applied as one impulse per fixed step on a rotation locked capsule that never sleeps, velocity logic in `OnPhysicsUpdate`. Ground is Source's check (`FindGround` sweeps down), not the contact flag; `TryStepUp` steps onto ledges a rigid capsule cannot roll over, while walkable slopes are followed by velocity.

## Buoyancy and water

`goluwa/physics/buoyancy.lua` applies a per-body grid of cells each substep. Fluid regions come from `goluwa/physics/fluid.lua`: every `water_volume` and the ocean (`fluid.GetOceanLevel`, which render3d overrides; a headless server needs `fluid.SetOceanLevel`). `water.SampleOcean` evaluates the same waves as the shader; feed it `water.GetWaveTime()`, never raw elapsed time. Test: `physics/buoyancy.lua`.

## Physgun

`addons/game/lua/weapons/physgun.lua`: right click freezes the held body (a ragdoll part freezes only that limb), reload thaws what this physgun froze. World geometry is never grabbed. On a character with a `BoxRagdoll` it carries the box instead of a limb. Ownership is not checked.

## Vehicles

See [vehicles.md](vehicles.md): wheel joints, the roll mode of keep upright, buoyant hulls with `FluidDrag`, aerodynamic surfaces.

## Toolgun and constraint entities

- Toolgun: `addons/sandbox/lua/toolgun.lua`, one file per tool in `addons/sandbox/lua/tools/`, the weapon in `addons/sandbox/lua/weapons/toolgun.lua`. A tool is a table passed to `toolgun.Register`; `toolgun.ConstraintTool` makes two click constraint tools. Tools run on the authority and push undo entries (`game_history`, through `sandbox_history` on a server, see [networking.md](networking.md)).
- Tool constraints are entities with the `constraint` component (`addons/sandbox/lua/components/constraint.lua`) referencing two entities by GUID (`""` is the world). The physics constraint is built lazily once both bodies exist (scene load order, undo, paste), and it saves, replicates and undoes like any entity.
- `addons/sandbox/lua/game_history.lua` resolves entities by GUID each time and restores bodies before their constraints. Restored and pasted bodies start asleep.
