# Navigation and NPCs

Pathfinding probed out of the physics world, and NPC prefabs that walk a map with the animations of their Source model.

## Pieces

- `goluwa/navigation/grid_nav.lua`: pathfinding on a grid probed out of the physics world, no baked data. `GridNav.Get(radius, height, step, drop)` returns a shared instance per agent size (the cache is the point of sharing). `BeginSearch(from, to, ignore_entity, blocked)` + `Step(search, seconds)` (true when done, result in `search.path`), or `FindPath(...)` for one go. `GetRandomPoint(around, radius, tries)`, `GetGround(ix, iz, from_y)`, `GetColumn(x, z)`, `Invalidate()`.
- `addons/game/lua/components/ai_controller.lua` (the npc brain: a command source for `character_movement`, like `player_controller`), `source_pose.lua` (animation from movement, see characters.md), `addons/game/lua/npcs.lua` (prefabs: `npcs.Definitions`, `Register`, `Spawn(name, position, yaw)`, `SpawnNear(name, around, radius)`). Example: `addons/examples/lua/examples/render3d/npc_walkers.lua`.
- Tests: `luajit glw test navigation/grid_nav.lua`, `entities/npc.lua`, `entities/npc_combat.lua` (one file per call).

## Pathfinding

- Cells are 0.5 m columns; a node is a column plus the ground height found by a short downward sweep from the parent's height (at most `step` up and `drop` down, ground normal.y >= 0.7). Edges between the 8 neighbours are one horizontal sphere sweep of the agent radius at step height. World results are cached for as long as the world is unchanged: the cache clears when `RigidBody.WorldGeometryVersion` changes or after `CacheLifetime` seconds.
- A* with lazy edge validation: an edge is only swept when its node is popped; a failed edge reparents the node to its best closed neighbour. Paths are string pulled with sweeps (lookahead of 12 points) and end exactly on the goal.
- Only world geometry (`WorldGeometry` bodies, so the map, terrain heightmaps) is probed. Other rigid bodies taller than the step height are collected as inflated boxes once per search and tested per edge, so they are never cached and cost no physics query. Bodies are obstacles only, never ground. `GridNav.IsObstacle(body)` filters them; `ai_controller` excludes bodies of characters and ragdoll hitboxes (an npc's own hitboxes surround its start and would block every edge).  Geometry without collision (Crysis objects that have no collision mesh yet) is invisible to it.
- A search stops after `max_nodes` (3000, roughly a 40 m radius). `path.complete` false with `path.exhausted` true means the reachable area ran out (the goal is unreachable); without `exhausted` it is the best partial path and the npc repaths when it reaches its end (`PARTIAL_LIMIT` times).
- Cold cost is about 0.3 ms per node, a warm cache is almost free. `ai_controller` slices searches (1 ms per npc, 4 ms per physics step across all npcs), so a long first path takes a few seconds. Water is not detected.
- `physics.StepIndex` is only set on `physics.instance`.

## NPCs

An npc prefab is a model, `animator`, `character_pose`, `source_pose` and `ai_controller` on the root: `Entity.New{prefab = {Path = "npc_zombie"}}` or `npcs.Spawn`. Inputs: `Wander`, `WanderRadius`, `Running`, `WalkSpeed`, `RunSpeed`. Console `npc_spawn <name>[,count]`. A definition is the model, idle/walk/run sequence names and walk/run speed in Source units per second (what `GetGroundSpeed` reports; `entities/npc.lua` checks them within 3%).

- `ai_controller` has no physics of its own: it adds a `character_movement` in `walk` mode and is its controller (controllers register with `character_movement.RegisterController`; read the current command with `character_movement:GetCommand()`) (`NextCommand(dt)` returns a `usercmd` once per physics tick), only where `network.HasAuthority()`; elsewhere the transform replicates.
- API: `MoveTo(position, running)`, `Stop()`, `Teleport(position, yaw)` (use it to place one: setting the transform does not move a dynamic body), `GetGoal/GetPath/IsMoving`; events `OnNPCArrived`, `OnNPCPathFailed`. Stuck detection blocks the cell ahead for a while and repaths; repeated failures give up.
- `character_movement` friction removes `StopSpeed * Friction * dt` per tick, so slow characters never get going unless `StopSpeed` is lowered (the npc sets it to half its walk speed).
- Simulation LOD: a dynamic capsule on a brush world is expensive, so only the nearest `simulation_lod.MaxSimulated` (`addons/game/lua/simulation_lod.lua`) npcs within `PhysicsDistance` of a camera or player keep a body; the rest are in `fly` mode (collision off, `MoveBodyBy` over the probed ground height) and cost almost nothing. With no camera or player everything is simulated.
- Combat: an npc whose definition has a `Weapon` gets a `weapon_holder` and is given the weapon on spawn; humanoid definitions (`Biped`) also get the biped armature and sockets so the weapon sits in the hand and points where the npc aims. `ai_controller` rescans every 0.25 s for the nearest living `player_controller` entity within `AttackRange` with a clear sweep from its eye, stops pathing, turns at `TurnSpeed` and pulses `ATTACK1` every `FireInterval` (randomized) once aligned, with `AimError` radians of jitter on the shot. There are no factions: only players are targeted. Far (not simulated) npcs never fight. Tests: `entities/npc_combat.lua`.
- `source_pose` with the `creature` profile reads the speeds of `character_pose` (works for replicated npcs): idle/walk/run thresholds, `animator:SetSpeed(speed / ground speed)` so feet do not slide, `move_yaw` is the velocity angle against the facing.

## Pitfalls

- `Entity.New{...}` initializes every component a second time at the end of construct, including ones a prefab added. Components that create things in `Initialize` and can sit on a prefab root (`visual`, `ai_controller`, `source_pose`) must skip the second Initialize, or they discard e.g. a model load already started.
- `Entity.New{prefab = ..., transform = {Position = p}}` builds the prefab before the position applies and dynamic bodies do not follow transforms: `npcs.Spawn` calls `Teleport`.

Not done: ladders and jump connections, crouch areas, attack/turn animations, an activity table, water, replanning when a rigid body moves into a path being walked.
