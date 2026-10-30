# Weapons and equipment

A weapon is a prefab whose root has the `weapon` component plus a `script` with its behaviour (`weapons.Register(name, values, nodes, source, script_values)` in `addons/game/lua/weapons.lua`, definitions in `lua/weapons/*.lua` of each addon). A held weapon is a child of an entity with `weapon_holder`; a weapon without a holder is a dynamic prop in the world that can be picked up with use.

## Places

A held weapon is either stowed (`Equipped == ""`, hidden) or equipped in a place: `right`, `left`, or a body mount named by its `Mount` (`chest`, the flashlight). `Equipped` replicates and decides the socket the model attaches to (`grip_r`, `grip_l`, `chest`).

- `Mount = "hand"` (default) weapons go in a hand. `TwoHanded` ones are equipped `right` and take the left hand too (`holder:GetWeapon("left")` returns them as well), `Offhand` ones (the shield) only go `left`. `Stance` picks the Source gait clips (`*_melee` for the sword). `weapon:CanEquip(place)` is the rule, `weapon:GetDefaultPlace()` where a given or picked up weapon goes when that place is free (`holder:EquipDefault`).
- `holder:Equip(weapon, place)` is the only way to change places. It stows what was there; moving a weapon to the other hand swaps the two when the displaced one fits; a two handed weapon stows the left hand weapon, which is remembered and comes back when a one handed weapon is equipped right again (`left_choice`, cleared by `holder:EmptyLeftHand()`).
- `OnWeaponEquip` / `OnWeaponHolster` fire on the weapon entity whenever it enters or leaves a place, including hand swaps.
- The flashlight's lamp model sits on the chest, but its spot light (real lumens, a lazily created shadow map) starts just in front of the eyes and follows the aim: a light below the view lets the held weapons throw shadows into the beam.

## Sheath

A weapon with `Sheath` (a socket name, `back`) rests there while it is equipped but not `Drawn` (replicated): the model attaches to the sheath socket with `SheathOffset`/`SheathRotation` (in the socket frame: right, up, back; `blade.SheathRotation(direction)` turns a blade along a direction), the arms are not posed (`GetPosedWeapon` skips it), the gait uses the unarmed stance and it is hidden in first person. `weapon:SetDrawn(true)` (the melee script calls it when a move starts, the owner predicts it) puts it in the hand until `SheathDelay` seconds without another draw, counted on every side from the last time it was set drawn (also when the value arrives from the server); holstering sheathes it. The `back` socket of both socket profiles has no rotation, since the biped chest bone is already model aligned.

## Model replacements

`model_replacements.Register(key, {Game, Path, Position, Rotation, Scale})` (`addons/game/lua/model_replacements.lua`) lets mounted content stand in for a built-in look. `Get(key)` returns the entry only when the game is mounted and the file exists. A weapon with `Replacement = key` and a node `replacement` (its placeholder, usually a pole the size of the real model) gets that node's `model` pointed at `Path` and its transform set from the entry when constructed. The placeholder must match the real model's size and orientation, because everything else (`blade_base`/`blade_tip` markers, hold offset, world size) is shared; fit the real model to it with `Scale`/`Rotation`/`Position`, not the markers. It is applied when the weapon is constructed and again on the `SourceGameMounted` event (fired by `steam.MountSourceGame`), so mounting before or after spawning both work.

## Attributes and statuses

`weapon.Attributes` is a list of damage types (elements, replicated, default empty) and `weapon.Statuses` a list of status names the jrpg addon defines (leech, fast, ...). A weapon that deals damage calls `weapon:GetDamageTypes(default)` (a module level list like `{"slash"}`, never built per call) and deals one hit per type, each with the full damage and the first hit carrying the knockback and reaction; later hits set `info.Secondary` so statuses and reactions fire once per strike. Never hardcode a type. The type decides everything downstream (rpg stats, statuses via the type's `OnDamage`, impact effects, the sword's trail color).

`Rarity`, `Title` (generated name, `weapon:GetTitle()` falls back to `DisplayName`), `DamageMultiplier`, `Strength` (1 + 2% per bonus step) and `RateMultiplier` (divides `FireRate`) complete it. `weapon:GetDamageScale()` is the factor on every hit (`DamageMultiplier`, times `Strength` while there are attributes), so damage dealers multiply by it. A `Rollable` weapon value makes the authority fire `RollWeapon` when the weapon is constructed with no rarity yet (spawned or given, never on a client, and not again after a copy or load); the jrpg addon answers it (`lua/jrpg/weapon_stats.lua`, see [jrpg.md](jrpg.md)).

## Buttons

The holder thinks every equipped weapon on the authority with the buttons `holder:GetButtons(weapon)` gives it, which HUDs use too: a weapon alone in the hands (one hand, or two handed) gets `ATTACK1` (left mouse) as primary and `ATTACK2` (right mouse) as secondary; while dual wielding each mouse button is the primary of its own hand (left mouse the left hand, right mouse the right hand) and there is no secondary; a mount gets `ATTACK3` (F). `OnWeaponPrimary` / `OnWeaponSecondary` are dispatched from those; a weapon that reads buttons itself in `OnWeaponThink` uses `weapon:IsPrimaryDown(cmd)`, `WasPrimaryPressed`, `IsSecondaryDown`, `WasSecondaryPressed` (or `GetPrimaryButton()`), never `BUTTON.ATTACK1/2` directly, so it works in either hand and while dual wielding. Returning false from `OnWeaponPrimary` means nothing was fired (no shot counter, no recoil), which is what melee, the shield and toggles do.

## Selection

A command carries `select` (an index into `holder:GetWeapons()`, sorted by `Slot` then name, or `usercmd.SELECT_EMPTY`) and `select_left`; only the authority applies it. A connected client just sends the command and gets `Equipped` back from the server (the weapons replicate to the owner), so server and client cannot disagree about what is selected. `weapon:SetEquipped` fires `OnWeaponEquip`/`OnWeaponHolster` on the owner's client when the change comes from replication. `player_input` builds it: number keys and the wheel pick the right hand (a number key picks the weapons whose `Slot` floors to it, pressing again cycles them), holding left alt does the same for the left hand, whose cycle also has an empty stop. The wheel skips the weapon held in the other hand; a number key does not, so it moves (or swaps) a weapon between hands.

## Posing

Drivers pose `holder:GetPosedWeapon("right")` and `("left")` (equipped weapons with `PoseArms`). A left hand weapon mirrors the right hand hold (`HoldOffset.x` and the hand offset flip sign); a two handed weapon puts the left hand on its `SupportGrip`; a free hand next to a held weapon takes the neutral pose. The shield does not pose (`PoseArms = false`), blocking raises the left arm instead. A change of either hand blends both arms over the switch time.
