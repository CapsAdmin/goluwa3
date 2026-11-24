# Characters: pose, skeleton and attachments

Players and npcs share one character, built from components in `addons/game/lua/components/` and modules in `addons/game/lua/`. `character_movement` consumes a `usercmd` from a controller (`player_controller`, `ai_controller`; `character_movement.RegisterController` adds more). Looks follow the same split.

```
usercmd -> character_movement (body yaw, velocity, grounded, crouch)
        -> character_pose     (replicated aim, crouch, actions, counters; derived pitch, speeds)
        -> a driver writes the biped armature (source_pose or procedural_pose)
        -> attachment_points  (named sockets on the armature)
        -> weapons attach to a socket, never to a raw bone
```

Tests live in `addons/game/tests/entities/` (`character_pose.lua`, `aim_pose.lua`, `leg_pose.lua`, `ragdoll.lua`, `keyframes.lua`, `grab.lua`, `character_scale.lua`, `pose_variation.lua`, `rig_profiles.lua`, ...), run with `luajit glw test addons/game/tests/entities/<file>.lua`. The physics debug (`N`) draws every ragdoll part, joint and movement capsule and picks bodies the way weapons do (`damage.Sweep`), see [physics.md](physics.md).

## Module map

- `character_movement` (component): Source style movement on a capsule, ground check, steps, crouch, scale, impact damage, and the drive APIs moves use. See the character section of [physics.md](physics.md).
- `character_pose` (component): state only, on every character, so drivers and `weapon_holder` never look at a controller. Replicates view/aim, crouch, holding, blocking, the current actions and the `Shots`/`Hits` counters; derives pitch, crouch alpha and speeds every frame.
- `lua/animations.lua` + `lua/animations/*.lua`: animation definitions (actions, states, impulses) with optional layers (aim, torso, bone keys, body transform, view).
- `lua/keyframes.lua`, `lua/movesets.lua`, `move_runner` (component): keyed moves and the runner that plays them; data format and editor in [jrpg.md](jrpg.md).
- Drivers: `source_pose` (plays Source sequences on the entity's `animator`, applies aim, leg ik and ragdoll) and `procedural_pose` (the eye body of the default outfit, `lua/eye_pose.lua`, computed headless). A driver sets `pose.driver` so only one writes the armature.
- `lua/aim_pose.lua`: aim and arm ik as pure functions over bone matrices, tested without a rig.
- `lua/leg_pose.lua`: foot ik onto the ground for Source rigs and multi-legged rigs (`LegRig`, see [navigation-and-npcs.md](navigation-and-npcs.md)).
- `lua/biped.lua`, `lua/rig_profiles.lua`: the in-engine biped skeleton, socket profiles, ragdoll profiles and the mapping from Source 1 / Source 2 rigs.
- `attachment_points` (component): sockets on the armature.
- `lua/pose_variation.lua`: per character rate, sway, lean and gait phase.
- `lua/faces.lua`: flex expressions on Source rigs.
- `ragdoll`, `ragdoll_part` (components), `lua/knockout_pose.lua`, `lua/model_profile.lua`: body parts, limpness, death and knockouts.
- `player_avatar` (component): the player's outfit, first person hiding and the head camera.
- `lua/character_scale.lua`: `Get(entity)` reads a character's scale where its movement may be missing (clients have no movement for npcs or remote players).

## Commands, view and aim

A `usercmd` carries `view` (the head: camera rotation, body yaw, walking direction, pose pitch) and `aim` (where the character points: weapons, use, tools, crosshair). With aim slack (`cl_aim_slack`) first person aim is a cursor inside a circle and only movement past it turns the view; elsewhere `aim` equals `view`. A controller that writes `cmd.view` must write `cmd.aim` too. `pose.pitch` is the head relative to the body, `pose.aim` the aim relative to the body: torso and head follow the pitch, arms and weapon follow the aim.

`character_movement:SetBodyYaw` snaps the body yaw without physics interpolation; `player_input` applies it every frame so things attached to the body do not jitter against the camera.

## Replication rule for pose state

Pose state that must match between server and clients is either a pure function of state every machine has, or the server replicates the one input that is not. The per character seed is hashed from the network owner or id; noise and rate drift are functions of the seed and `system.GetGameTime()`; leans are computed where the character is simulated and replicated; the gait phase comes from a replicated odometer (`character_movement.distance` -> `character_pose.Distance`) that `source_pose` feeds to `animator:SyncCycle`. Fire and hit reactions start from the replicated counters, so they need no extra packets. Add new pose inputs by the same rule, never from `math.random` or local frame time.

## Animations

- Kinds: `action` (timed one-shot, `pose:PlayAction(name, duration)`, replicated), `state` (held, `pose:SetState(name, arg)`, replicated), `impulse` (set by a counter, decays). States and impulses that every client can derive itself are started every frame with `pose:EnableState` / `pose:Trigger` and do not replicate. Query with `pose:IsPlaying`, `GetWeight`, `GetActiveAction` (skips `Passive` actions).
- A definition can make itself the Source base sequence (`Sequence`) and add layers that `source_pose` runs after the aim: `AimKeys`/`Aim`, `Torso`, `BoneKeys` (data, `lua/bone_keys.lua`) / `Bones` (code), `Body` (transform override), `View` (first person camera). Layer functions live at module level, never create closures in them.
- Keys (`animations.SampleKeys`) are `{t, values..., ease = ...}` rows; `AimKeys`, `TorsoKeys`, `HandKeys`, `PelvisKeys`, `HeadKeys` and `BoneKeys` all sample this way. Pelvis keys move everything above the feet and leg ik re-plants the feet, so do not set `Locomotion = false` on an action that moves the body. An action with a `Group` replaces the running action of that group instead of stacking.
- Gait clips come from the right hand weapon's `Stance`. `source_pose` picks walk/run/sprint from the measured ground speed (so remote clients agree without extra state) and sets the playback rate from the speed the clip itself reports (`clip:GetGroundSpeed`), so clips need no per clip tuning.
- Hit reactions: damage plays the `flinch` action with the hit part, direction and strength (`lua/animations/stagger.lua`, `stagger` is the stunning version). `Stun = true` makes `pose:IsStunned()` true: no movement, no melee, npcs neither move nor fight.

## Moves

A moveset is plain data registered with `movesets.Register(name, def, path)`. `move_runner` plays one move at a time: `Begin` focuses the target and plays the pose action, `Step` samples the move's `motion` into `character_movement:Drive` and calls `listener:OnMoveEvent` for each event on the authority. What an event does, queueing and chaining belong to the listener (`weapon_melee`, `ai_controller`). Moves with `Clips` play Source sequences (creatures take their whole animation from them). Canceling, rewinding and grabbing are described in [weapons.md](weapons.md).

Movement hooks moves use, all on `character_movement`:

- `Drive(position, vertical)` (call every tick) sets the velocity that reaches a body centre in one tick, overriding input.
- `Push(velocity)` knocks the body (waits out a freeze), `Hang(seconds)` holds a juggle at its apex, `Lunge(direction, distance, delay, duration)` overrides movement over a speed curve.
- `IgnoreImpacts()` suspends fall and impact damage until the body is back on the ground undriven; drives, melee hits and throws set it. Impact damage measures what physics took from the commanded velocity, so a drive stopping against a wall is not a collision.
- Hitstop: `character_pose:Freeze(seconds, clock)` holds the drawing at the render level (`transform:SetFrozen`, `Rig:SetHeld`) and, with `clock`, the animation time (`pose:GetTimeScale()`, use it instead of `animation_speed`). Npc bodies are held still; a player's body never is, since the owner learns of a freeze a round trip late and would mispredict.
- `character_pose:PredictAction` starts an action locally and adopts the server's matching one when it arrives, so the owner sees its own swings without the round trip.

## Aim, arms and legs

- The pose pitch is shared over the spine joints, neck and head (`aim_pose.Shares`). With a posed weapon the arms get two bone ik to the weapon grip (`ArmReach` along the aim plus the weapon's `HoldOffset`), the left arm to `SupportGrip` for two handed weapons; `HoldFromHead` holds from the head bone instead. `PoseArms = false` leaves the arms to the animation. `weapon_holder:GetPosedWeapon(place)` is what pose code reads.
- A weapon's origin is the centre of the gripping hand. The ik puts the palm centre (`aim_pose.PalmOffset`) on the target and turns the hand to the aim, so the armature's grip socket points where the character aims.
- `Holster` weapons are held lowered until fired (`ready` state, `aim_pose.GetHoldAim`). Switching weapons blends the old arm solve into the new one.
- `source_pose` writes the aimed bones back into the animator rig as model space overrides and clears its own overrides before reading the bones each frame, otherwise rotations accumulate.
- `Quat:Lerp` mutates its receiver; use `GetLerped` for a new value.
- Leg ik (`source_pose:UpdateLegs`, `leg_pose.Apply`): a ray per foot, ground height smoothed in world space (not relative to the capsule, which steps up ledges), pelvis moved to the feet's ground, two bone ik per leg with the knee kept near forward, feet tilted to the surface. Horizontal foot planting is not locked. `source_pose:UpdateGroundSink` sinks the rig by the gap between the capsule and the ground.

## Skeleton, rigs and sockets

- The biped (`lua/biped.lua`, `armature` skeleton `biped`) only exists where something drives it (client side, rendering) and for humanoids; creatures just animate their model.
- Pose code works in canonical Source 1 bone frames. `rig_profiles` maps other rigs (Source 2 / Alyx) by bone names and `biped.ReadBones`/`GetBone`/`WriteBone` convert frames; never read a rig with `rig:GetBone(name)` using a Source name. Models can lack biped bones: go through `biped.HasBone` and `biped.ReadBones`, which substitute the parent's matrix.
- Source 2 humanoids have no gmod sequences, so `source_pose:AddDonorClips` retargets a gmod player model's clips onto them (`animation_retarget`) relative to a neutral reference stance of the rig rather than bind to bind (the two skeletons' shoulder rests differ).
- Sockets (`armature:SetSocket(name, bone, offset, rotation)`) work like bones for `transform.Attachment`. `attachment_points` applies a profile from `biped.SocketProfiles` when the armature is built (`SocketProfile` on the driver). Per-model offsets go into a profile. Facing sockets (`chest`, `mouth`) look along -z with y up.
- `source_pose` profiles: `creature` and `gmod_player`. `OwnsArmature` puts the armature on the component's own entity (npcs), otherwise it belongs to an ancestor (the player).

## First person and the head camera

- In first person the outfit stays shown and only its head is `ViewHidden` (still in reflections and shadows). Source outfits hide the primitives weighted to the head bone (`player_avatar:ApplyFirstPerson`). `HidesPlayer` weapons (the camera) hide the whole outfit while held in first person.
- Head camera (`cl_outfit_head_camera` and related pvars, set in the Outfit window): with a Source outfit that has eyeballs, `player_avatar` measures the rig's eye position against the capsule eye point and writes it into the command's `head`. Gameplay (weapon origins, use, teleport, npc sight) reads `character_movement:GetViewOffset()` (eye offset plus the clamped command head); placing the capsule from an eye position uses `GetEyeOffset()`. The camera itself runs `player_avatar:UpdateHeadOffset` in `OnLateUpdate`, after the rig is posed, so the first person view sits on the current frame's eyes. Dead or limp characters have no head camera.

## Scale

`character_movement:SetScale(s)` multiplies every stored length, speed and the character's gravity (so a jump is as high relative to the body and lasts as long), the mass by `s^3`, and rebuilds the capsule and ragdoll parts. Players get `sv_player_scale` times the level scale (`autorun/level_player_scale.lua`); server and clients must agree or prediction drifts. Npcs get it from `npcs.Spawn`. The rig stays in unscaled model space: whatever reads rig bones as owner space multiplies translations by the scale and whatever writes them back divides. `character_pose` divides speeds by it so animation thresholds stay in Source terms.

## Ragdoll and body parts

- Every character with a `ragdoll` component has one capsule body per part of its profile (`biped.Profiles`: `humanoid`, `eye`; `model` for creatures, built from the model's `physics.ragdoll` by `lua/model_profile.lua`). Parts have a `Role` (`head`, `torso`, `limb`); use `ragdoll:FindPart(role)` instead of asking whether a character is a biped or a creature.
- Alive, parts are kinematic, follow the animated rig every physics tick and never push anything; they exist for traces. `damage.Sweep` skips the movement capsule of characters with parts, `damage.GetVictim` returns the character and the part's damage multiplier, and `TraceOwner` keeps a character's own traces off its parts.
- A part is fixed to its bone by a frame computed once from the rig (`BuildFrames`): alive the part is `frame * bone`, limp the bone is written back as `part * frame^-1` (`DriveRig`). Nothing is sampled at the moment of death. Drive kinematic parts through their entity's `transform` and pass copies (`transform:SetPosition` keeps the reference).
- Limpness: each part has a limpness 0..1 from its sources (hits, physgun hold, death, knockdown) and is dynamic and jointed to its parent while it has any; a child is never less limp than its parent. A dynamic part is steered toward the pose only through angular velocity; translation is left to physics. When the root is limp the whole body is: movement and weapons ignore the command, the capsule follows the root, and after settling the character blends back up.
- Muscle tone is a property of the joints (`joint:SetSpring` toward the built pose, see [physics.md](physics.md)), not a drive on the bodies, so it injects no momentum. Joint limits are measured from the pose the joint was built in.
- `ragdoll:Knockdown(velocity, source)` throws the whole body; flung limbs are posed to trail the travel. `ragdoll:Grab`/`Ungrab` are the physgun's.
- Box ragdoll (`BoxRagdoll`, npcs): a knockout, death or grab turns the character into one sphere, with `knockout_pose.lua` springing the rig from the body's motion; a dead one lands into the part ragdoll.
- Corpses: jointed limbs keep a slow residual motion below any sleep threshold, so the ragdoll puts all its parts to sleep itself once they have stopped drifting (`UpdateRest`). The cost of a corpse is its awake time in the solver.
- Parts are authority only until they go dynamic; then they get a `network` component and `ragdoll_part` replicates which character and group they belong to, so a client's `ragdoll:HasLimp()` and `IsPartLimp(name)` work.
- Limitations: players always use the humanoid hitbox profile (the server does not know the outfit), and there is no lag compensation.

## Seats

The replicated `character_pose.Seat` puts a character on a `seat` component; see [vehicles.md](vehicles.md).
