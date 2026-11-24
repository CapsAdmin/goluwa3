# Navigation and NPCs

Pathfinding probed out of the physics world, and NPC prefabs that walk a map with the animations of their Source model.

## Pieces

- `goluwa/navigation/grid_nav.lua`: pathfinding on a grid probed out of the physics world, no baked data. `GridNav.Get(radius, height, step, drop)` returns a shared instance per agent size (sharing is what makes the probe cache useful). `BeginSearch` + `Step(search, seconds)` for time sliced searches, or `FindPath(...)` in one go.
- `addons/game/lua/components/ai_controller.lua`: the npc brain, a command source for `character_movement` like `player_controller`.
- `addons/game/lua/npcs.lua`: npc prefab definitions (`npcs.Definitions`, `Register`, `Spawn`, `SpawnNear`). Console `npc_spawn <name>[,count]`.
- `addons/game/lua/components/source_pose.lua`: animation from movement (see [characters.md](characters.md)).
- `addons/game/lua/simulation_lod.lua`: which npcs keep a physics body.
- `addons/game/lua/nav_overlay.lua`: console `nav_debug` toggles an overlay of the probed cells and the paths and goals of npcs.
- Examples: `addons/examples/lua/examples/render3d/npc_walkers.lua`, and `npc_arena.lua` (waves of free for all npcs fighting in a closed room: the stress scene for npc, ragdoll and sound costs).
- Tests: `luajit glw test navigation/grid_nav.lua`, and in `addons/game/tests/entities/`: `npc.lua`, `npc_combat.lua`, `npc_death.lua`, `npc_sounds.lua`.

## Pathfinding

- Cells are columns on a horizontal grid; a node is a column plus the ground height found by a short downward sweep from the parent's height, limited by the agent's `step` and `drop`. Edges are horizontal sphere sweeps of the agent radius at step height.
- A* with lazy edge validation: an edge is only swept when its node is popped. Paths are string pulled with sweeps and end exactly on the goal.
- Only world geometry (`WorldGeometry` bodies: the map, terrain heightmaps) is probed and cached; the cache clears when `RigidBody.WorldGeometryVersion` changes. Other rigid bodies are collected as inflated boxes per search and tested per edge, so they are obstacles only, never ground. `GridNav.IsObstacle(body)` filters them; `ai_controller` excludes characters and ragdoll hitboxes (an npc's own hitboxes would block every edge around it). Geometry without collision is invisible to it, and water is not detected.
- A search has a node budget. `path.complete` false with `path.exhausted` true means the goal is unreachable; without `exhausted` it is the best partial path and the npc repaths when it reaches its end.

## NPCs

An npc prefab is a model, `animator`, `character_pose`, `source_pose` and `ai_controller` on the root: `Entity.New{prefab = {Path = "npc_zombie"}}` or `npcs.Spawn`. A definition names the model, its idle/walk/run sequences and their ground speeds in Source units per second. Adding an npc is one definition entry; probe the model's sequence names and ground speeds first (`npc.lua` checks them).

- `ai_controller` has no physics of its own: where `network.HasAuthority()` it adds a `character_movement` in `walk` mode and feeds it a `usercmd` per physics tick (controllers register with `character_movement.RegisterController`); elsewhere the transform replicates.
- API: `MoveTo(position, running)`, `Stop()`, `Teleport(position, yaw)` (setting the transform does not move a dynamic body), `GetGoal/GetPath/IsMoving`; events `OnNPCArrived`, `OnNPCPathFailed`.
- `character_movement` friction removes a fixed amount of speed per tick scaled by `StopSpeed`, so slow characters need a lower `StopSpeed` to get going.
- Simulation LOD: only the nearest npcs (`simulation_lod.MaxSimulated` within `PhysicsDistance` of a camera or player) keep a dynamic body; the rest move in `fly` mode over the probed ground and never fight or get targeted. With no camera or player everything is simulated.
- Factions: `ai_controller.Faction` is `friend`, `enemy` or `ai_controller.FreeForAll`; players count as `friend`. Npcs target living, simulated characters of another faction within `AttackRange` with a clear sweep. Friendly npcs are `usable` and follow whoever used them.
- Attacks: biped definitions get a `weapon_holder` and fight with a weapon (see [weapons.md](weapons.md)). Creatures attack with moves (see [characters.md](characters.md), Movesets): their moves are data files in `addons/game/lua/npc_movesets/`, chosen from the definition's `Attacks` list, edited with the move editor like weapon movesets.
- Legs: biped and ValveBiped creatures use the shared foot ik; other creatures list their weight bearing legs in `addons/game/lua/creature_rigs.lua` and `source_pose` solves them with `leg_pose`, using the sole of each foot's physics solid as the contact point.
- Sounds: a definition's `Sounds` comes from `addons/game/lua/npc_voices.lua` (roles like `Foot`, `Pain`, `Death`, `Attack`), played by the `npc_sounds` component from local events (`OnTakeDamage`, `OnDeath`, `OnNPCAlert`, ...) as a replicated event.
- Death is a state of the same entity, never a replacement: the `ragdoll` component turns the character into physics bodies on `OnDeath` and removes the entity after `CorpseTime`; `character_movement:Reset` after `health:Revive()` brings it back.

## Pitfalls

- `Entity.New{...}` initializes every component a second time at the end of construct, including ones a prefab added. Components that create things in `Initialize` and can sit on a prefab root (`visual`, `ai_controller`, `source_pose`) must skip the second Initialize, or they discard work already started (a model load).
- `Entity.New{prefab = ..., transform = {Position = p}}` builds the prefab before the position applies and dynamic bodies do not follow transforms: `npcs.Spawn` calls `Teleport`.
- Design limits: no ladders or jump connections, no crouch areas, no water, and no replanning when a rigid body moves into a path being walked.
