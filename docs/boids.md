# Boids

The `boids` addon (depends on `game` and `crysis_loader`) spawns flocks of small ambient animals from Crysis models: walking (chicken, turtle, crab, plover), hopping (frog), flying (bird: terns, finches, butterflies) and swimming (fish). The behaviours are ports of CryEngine's boids (`local_stuff/CRYENGINE/Code/GameSDK/GameDll/Boids/`: `ChickenBoids.cpp`, `BoidBird.cpp`, `BoidFish.cpp`, `FrogBoids.cpp`, `BoidObject.cpp`); that source is the reference for behaviour, the Crysis Lua scripts and `Libs/EntityArchetypes/Animals.xml` hold the parameters.

## Pieces

- `lua/boids.lua`: kinds (`boids.Register(name, info)`: model, `Behavior`, speeds, flocking factors, sounds, hitbox), `boids.Spawn(kind, position, count, radius, settings)` and the console command `boids_spawn <kind>[,count]` (spawns where the camera looks).
- `lua/components/boid_flock.lua`: one component per flock (`Kind`, `Count`, `Radius`, `Settings`). `Settings` overrides the kind's definition per flock; Crysis levels fill it from the flock archetype (`boids.SettingsFromCryProperties`), so one kind covers every Crysis variant (the bird kind is terns, finches and butterflies). It spawns animals (root level entities: transform, visual, animator for `.chr`/`.cdf` models, kinematic hitbox, health, `boid`) a few per frame while the camera is within `VisibilityDistance` and removes them beyond it, collects threats, and holds what the behaviours share (traces, `Flocking`, `Move`, `SetPose`, the water level, sounds).
- `lua/boid_behaviors/`: `ground.lua`, `bird.lua`, `fish.lua`, `frog.lua`, each a `Spawn(flock, definition, origin)` and `Update(flock, boid, definition, origin, dt, smooth)`.
- `lua/components/boid.lua`: per animal state; on death the hitbox becomes a dynamic body (it falls, tumbles, or floats in water) and is removed after `CorpseTime`.
- Crysis levels: a definition's `CryClass` claims the level's flock entities through the `CryEntity` event (see [crysis.md](crysis.md)).
- Tests: `luajit glw test boids/`.

## Rules

- Ground kinds with a measured `ClipSpeed` (the walk clip's ground speed at rate 1, from the planted feet) match their feet; other kinds use CryEngine's rate, `((speed - min) / (max - min) * 0.6 + 0.4) * AnimSpeed`. Crysis animal clips have no root motion.
- Model forward is -Z (`orientation.FORWARD_VECTOR`); `SetPose` turns the model to the 3D heading and banks it.
- Ground animals move kinematically over traced ground (world and static bodies only); each move traces along the step at body height first, because a ground ray that starts inside a short wall lands on the floor behind it. Spawning looks through roofs and shelves above the flock origin.
- Streamed terrain has no collision for a while after a map loads, so flocks retry spawning once a second until they find ground. Fish spawn only where the flock origin is under water.
- Birds stay in `HeightMin`..`HeightMax` above the flock origin and never land (Crysis sets `bNoLanding` on its flying flocks); fish stay between the bottom and the water surface; frogs hop ballistically.
- Hitboxes are trace-only (`CollisionMask = 0`, see [physics.md](physics.md)). Fish and birds trace world geometry only; ground animals and frogs also trace static props, and only every 0.1 s, a step ahead. Hundreds of animals each doing a prop-including trace every frame cost tens of milliseconds on Crysis Island.
- Flocks only simulate where `RENDER_3D` is set (Crysis boids were client only too); nothing replicates.
- Threats are living `health` owners that are not boids; `HealthDamaged` and `EntityKilled` anywhere make a decaying scare point. Birds ignore both, as in CryEngine.
- Sounds: a definition's `Sounds` names Crysis FMOD events (`Idle`, `Scared`, `Die`) played at `SoundLevel` (dB SPL at 1 m) times the event's volume, with CryEngine's trigger rates. A flock resolves its events when it spawns, since the first lookup parses the project.
