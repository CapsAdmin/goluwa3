# Boids

The `boids` addon (depends on `game`) spawns flocks of small ambient animals that walk the ground, idle, and run from people and noise. The steering is a port of CryEngine's `CChickenBoid::Think` (`local_stuff/CRYENGINE/Code/GameSDK/GameDll/Boids/ChickenBoids.cpp`); the CryEngine source is the reference for behaviour, not the Crysis Lua scripts, which only hold parameters.

## Pieces

- `lua/boids.lua`: definitions (`boids.Register(name, info)`, `boids.Spawn(kind, position, count, radius)`) and the console command `boids_spawn <kind>[,count]` (spawns where the camera looks).
- `lua/components/boid_flock.lua`: one component per flock simulates all its animals in one update (`Kind`, `Count`, `Radius`). Animals are root level entities (transform, visual, animator, kinematic hitbox, health, `boid`), so bullets hit them.
- `lua/components/boid.lua`: per animal state; on death the hitbox becomes a dynamic body that tumbles and is removed after `CorpseTime`.
- Crysis levels: the loader turns entities it does not translate into `CryEntity` events (see [crysis.md](crysis.md)); a definition's `CryClass` (`Chickens`, `Turtles`) claims them, reading `Boid.nCount` and `Options.Radius` from the archetype.
- Tests: `luajit glw test boids/`.

## Rules

- `ClipSpeed` is the walk clip's ground speed at rate 1, measured from the planted feet (sample the clip, watch a foot bone's model space z while it is at its lowest). The clip rate is `speed / ClipSpeed`, capped by `MaxClipRate`. Crysis animal clips have no root motion.
- Model forward is -Z; heading `(hx, hz)` maps to yaw `atan2(-hx, -hz)`.
- Animals are moved kinematically over traced ground (world and static bodies only). Each move traces along the step at body height first, because a ground ray that starts inside a short wall lands on the floor behind it.
- Streamed terrain has no collision for a while after a map loads, so flocks spawn missing animals once a second until they find ground. Spawning looks through roofs and shelves above the flock origin.
- Flocks only simulate where `RENDER_3D` is set (Crysis boids were client only too); nothing replicates.
- Threats are living `health` owners that are not boids within `ScareDistance`; `HealthDamaged` and `EntityKilled` anywhere make a decaying scare point.
