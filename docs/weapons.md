# Weapons and equipment

A weapon is a prefab whose root has the `weapon` component plus a `script` with its behaviour, registered with `weapons.Register` (`addons/game/lua/weapons.lua`; definitions in `lua/weapons/*.lua` of each addon). A held weapon is a child of an entity with `weapon_holder`; without a holder it is a dynamic prop that can be picked up with use.

## Places

- A held weapon is stowed (`Equipped == ""`, hidden) or equipped in a place: `right`, `left`, or a body mount named by its `Mount` (`chest`, the flashlight). `Equipped` replicates and decides the socket the model attaches to (`grip_r`, `grip_l`, `chest`, see [characters.md](characters.md)).
- `TwoHanded` weapons are equipped `right` and occupy the left hand too; `Offhand` ones only go `left`. `weapon:CanEquip(place)` is the rule, `GetDefaultPlace()` where a given or picked up weapon goes.
- `holder:Equip(weapon, place)` is the only way to change places; it stows, swaps or remembers what was displaced. `OnWeaponEquip` / `OnWeaponHolster` fire on the weapon whenever it enters or leaves a place.
- `Sheath` (a socket name) makes an equipped weapon rest there until it is `Drawn` (replicated, `weapon:SetDrawn`); it returns to the sheath after `SheathDelay`. A sheathed weapon does not pose the arms.
- `Stance` picks the Source gait clips the holder plays.

## Model replacements

`model_replacements.Register(key, {Game, Path, Position, Rotation, Scale})` (`addons/game/lua/model_replacements.lua`) lets mounted game content stand in for a built-in placeholder node (`replacement`) of a weapon with `Replacement = key`. The placeholder must match the real model's size and orientation, because markers (`blade_base`/`blade_tip`), hold offset and world size are shared: fit the real model with `Scale`/`Rotation`/`Position`, never by moving the markers. It is applied on construction and again on `SourceGameMounted`, so mount order does not matter.

## Attributes, stats and rolls

`weapon.Attributes` (damage type names) and `weapon.Statuses` (status names from jrpg) extend a weapon's single base damage type. `weapon:GetDamageScale()` is the factor every damage dealer multiplies by. Rarity, bonuses and names come from a roll: `weapons.Spawn(name, pos, rot, roll)` / `holder:Give(name, roll)` take an explicit one, otherwise the authority fires `RollWeapon` for a `Rollable` weapon and jrpg answers it (`lua/jrpg/weapon_stats.lua`, see [jrpg.md](jrpg.md)).

## Buttons

The holder thinks every equipped weapon on the authority with the buttons `holder:GetButtons(weapon)` assigns (alone in the hands: primary and secondary mouse buttons; dual wielding: each mouse button is its hand's primary; a mount: `ATTACK3`). HUDs use the same function. Weapons that read buttons themselves use `weapon:IsPrimaryDown(cmd)`, `WasPrimaryPressed`, `IsSecondaryDown`, `WasSecondaryPressed`, never `BUTTON.ATTACK1/2`, so they work in either hand. Returning `false` from `OnWeaponPrimary`/`OnWeaponSecondary` means nothing fired (no shot counter, no recoil); a number is the delay before that button fires again.

## Ammo

`AmmoType` names a reserve on the holder (`holder:GetAmmo/GiveAmmo/TakeAmmo`); `ClipSize > 0` adds a clip that reloads from the reserve (`ReloadIncrement` for shotgun style). The `weapon` component gates firing and reloading; scripts spend ammo themselves with `TakePrimaryAmmo`/`TakeSecondaryAmmo` on the authority. `sv_infinite_ammo` makes reserves infinite (clips still empty).

## Bullets and effects

- `bullets.Fire{...}` (`lua/bullets.lua`) traces pellets, deals damage and pushes bodies on the authority and plays effects wherever it runs, so a predicting client calls it from `OnWeaponPredictPrimary` too.
- `weapon_effects` holds muzzle flashes (`RegisterMuzzle`, `MuzzleFlash`), tracers, impacts and bullet holes; impact sounds come from the sound profiles (see [audio.md](audio.md)).
- Explosions: `explosions.Blast{...}` for damage and impulse, `grenade_effects.Explode`/`ExplodeSmall` for the look.

## Selection and inventory

- A `usercmd` carries `select` / `select_left` (indices into `holder:GetWeapons()`, or `usercmd.SELECT_EMPTY`). Only the authority applies them and `Equipped` replicates back, so server and client cannot disagree about what is selected. `player_input` maps number keys, the wheel and left alt (left hand) onto them.
- `~` toggles the inventory menu: model in `lua/inventory_menu.lua`, panel in `lua/inventory_ui.lua`, camera in `autorun/render_3d/inventory_camera.lua`. The player equips through the command path, other party members through `holder:Equip` on the authority.

## Posing

Drivers pose `holder:GetPosedWeapon("right")` and `("left")` (equipped weapons with `PoseArms`). A left hand weapon mirrors the right hand hold, a two handed one puts the left hand on its `SupportGrip`. The aim and ik are described in [characters.md](characters.md).

## Grabbing

`lua/grab.lua` latches one character onto another: `grab.Latch(grabber, victim, opts)` and `grab.Release(victim, velocity)`. The victim becomes kinematic and collisionless (like a seat) and plays the `held` state. A move drives the hold from keyframe tracks (`carry`, `grip`, `impale`, `attach`; see `keyframes.lua` and [jrpg.md](jrpg.md)), solved from two snapshotted victim bones so any size of victim lands on the same hold. Only the authority latches.

Rules the latch relies on:

- The drawn victim is built on the grabber's drawn frame (`grab.GetBaseFrame(grabber, true)`), the physics placement (`LATCH:Step`) on the physics transform; never mix the two frames.
- The victim is kept out of world geometry by a sweep from the grabber (whose capsule is always clear) toward the victim (`LATCH:Constrain`); the physics step and the render frame each constrain their own wanted frame.
- Throw velocity comes from the keyed motion (`keyframes.EvaluateVictimVelocity`) plus `Throw`, never from measured motion, since the grabber's frame updates per rendered frame.
- `keyframes.EvaluateBody/EvaluateCarry/EvaluateVictim` are pure functions of (move, phase, victim bones), the base for previews.

## Canceling and interrupting a move

`move_runner:Rewind()` cancels the running move (no more events, body and action clock played back to where the move began; the listener gets `OnMoveCanceled`). The runner rewinds by itself when a driven move is blocked by a wall, and melee rewinds when every victim blocked. A new flinch or stun during a move interrupts it at once (`OnMoveInterrupted`). Guard results reach the attacker as `info.Block` (`parry`, `block`, `broken`).

## Previewing a move

`lua/jrpg/move_preview.lua`: `move_preview.Start(grabber, victim, move)`, `:SetPhase(f)`, `:Stop()` pose two real characters at phase `f` of a move without simulating it (the throw is not simulated). Call `SetPhase` every frame you want the pose held; a scrubbing harness then needs no waiting for clocks.
