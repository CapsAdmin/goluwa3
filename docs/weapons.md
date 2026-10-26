# Weapons and equipment

A weapon is a prefab whose root has the `weapon` component plus a `script` with its behaviour (`weapons.Register(name, values, nodes, source, script_values)` in `addons/game/lua/weapons.lua`, definitions in `lua/weapons/*.lua` of each addon). A held weapon is a child of an entity with `weapon_holder`; a weapon without a holder is a dynamic prop in the world that can be picked up with use.

## Places

A held weapon is either stowed (`Equipped == ""`, hidden) or equipped in a place: `right`, `left`, or a body mount named by its `Mount` (such as `chest`). `Equipped` replicates and decides the socket the model attaches to (`grip_r`, `grip_l`, `chest`).

- `Mount = "hand"` (default) weapons go in a hand. `TwoHanded` ones are equipped `right` and take the left hand too (`holder:GetWeapon("left")` returns them as well), `Offhand` ones (the shield) only go `left`. `weapon:CanEquip(place)` is the rule, `weapon:GetDefaultPlace()` where a given or picked up weapon goes when that place is free (`holder:EquipDefault`).
- `holder:Equip(weapon, place)` is the only way to change places. It stows what was there; moving a weapon to the other hand swaps the two when the displaced one fits; a two handed weapon stows the left hand weapon, which is remembered and comes back when a one handed weapon is equipped right again (`left_choice`, cleared by `holder:EmptyLeftHand()`).
- `OnWeaponEquip` / `OnWeaponHolster` fire on the weapon entity whenever it enters or leaves a place, including hand swaps.

## Buttons

The holder thinks every equipped weapon on the authority with the buttons `holder:GetButtons(weapon)` gives it, which HUDs use too: a weapon alone in the hands (one hand, or two handed) gets `ATTACK1` (left mouse) as primary and `ATTACK2` (right mouse) as secondary; while dual wielding each mouse button is the primary of its own hand (left mouse the left hand, right mouse the right hand) and there is no secondary; a mount gets `ATTACK3` (F). `OnWeaponPrimary` / `OnWeaponSecondary` are dispatched from those; a weapon that reads buttons itself in `OnWeaponThink` uses `weapon:IsPrimaryDown(cmd)`, `WasPrimaryPressed`, `IsSecondaryDown`, `WasSecondaryPressed` (or `GetPrimaryButton()`), never `BUTTON.ATTACK1/2` directly, so it works in either hand and while dual wielding. Returning false from `OnWeaponPrimary` means nothing was fired (no shot counter, no recoil), which is what melee, the shield and toggles do.

## Selection

A command carries `select` (an index into `holder:GetWeapons()`, sorted by `Slot` then name, or `usercmd.SELECT_EMPTY`) and `select_left`; the holder applies it on the client and the authority alike. `player_input` builds it: number keys and the wheel pick the right hand (a number key picks the weapons whose `Slot` floors to it, pressing again cycles them), holding left alt does the same for the left hand, whose cycle also has an empty stop. The wheel skips the weapon held in the other hand; a number key does not, so it moves (or swaps) a weapon between hands.

## Posing

Drivers pose `holder:GetPosedWeapon("right")` and `("left")` (equipped weapons with `PoseArms`). A left hand weapon mirrors the right hand hold (`HoldOffset.x` and the hand offset flip sign); a two handed weapon puts the left hand on its `SupportGrip`; a free hand next to a held weapon takes the neutral pose. The shield does not pose (`PoseArms = false`), blocking raises the left arm instead. A change of either hand blends both arms over the switch time.
