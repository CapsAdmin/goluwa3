# Goluwa
Goluwa is a game engine written entirely in LuaJIT and ffi, without any third party dependencies except for Vulkan and OS. There is no C code, everything is LuaJIT.

`goluwa/*` is the engine's source code

`addons/*` is the place for examples, experimental scripts, and sub projects that don't fit in the core engine. For example the love2d wrapper, garrysmod wrapper, ui gallery and more exist there. Addons are implicitly loaded once the engine starts from autorun directories. It works similar to how garrysmod addons work.

`storage/*` is for logs, caches, settings and other dynamic data.

`test/*` is the test suite.

# Running
Use luajit installed on the system. `glw` is a lua script without a .lua extension that simply calls into `goluwa/main.lua` with the remaining arguments. Optional engine flags come first, then a command, followed by the command's arguments. `main.lua` sets up a default global environment globals, but scripts mostly uses import statements, ie `local Vec3 = import("goluwa/structs/vec3.lua")`

- The file watcher is off by default, pass --hot-reload to reload lua files on change while developing
- Use the --validate flag to prevent the engine from running forever after a lua error. It also enables the Vulkan validation layers (off by default) and exits on the first validation error, which roughly triples CPU frame time, so never benchmark with it

- Always pass `--background` and `--validate` when launching the engine with a window (`--2d`, `--3d`, `shot`, `test`, screenshots, ad hoc scripts). `--background` opens the window minimized so it does not steal the user's focus (Wayland), and `--validate` makes errors and validation messages exit instead of hanging. Example: `luajit glw --2d --background --validate --screenshot lua "./tmp/script.lua"`. The only exception is performance measurement, where `--validate` must be left off (it triples CPU frame time) but `--background` should still be used.

- The engine in --3d mode starts in about 2 seconds, --2d is less than one second, and --cli/--headless is instant. Therefore, using `timeout` for more than 20 seconds is most likely not needed.

- If you need to write a temporary script to run, write it in `./tmp/`

- Run a single lua script: `luajit glw --2d --one-frame lua "./tmp/path/to/file.lua"`

- Run a single test file with name pattern: `luajit glw test render2d/render2d.lua --name-pattern="Graphics render2d blend modes visual"`

- Run all test files in a directory: `luajit glw test render2d/`

- Running the whole test suite is expensive and may cause vram errors due to the constrained environment. Prefer not to run the whole test suite.

- Run inline lua: `luajit glw --2d --one-frame lua "print('hello')"`. For scripts that span multiple lines, prefer the cycle of writing the script in ./tmp/, run, edit, run again, etc

- When running the engine without the `--one-frame` or `--screenshot` flag, it will run forever. In which case you must use the timeout command or call `system.ShutDown()` manually at some point

## Screenshots

- Take a screenshot: `luajit glw --2d --screenshot lua "./tmp/path/to/some/render/script.lua"`. this runs for one frame like `--one-frame`. If you need more advanced screenshots, use the Screenshot global.
- The `Screenshot(cb, opt)` global captures the screen. `cb(texture)` receives a `TextureDownloaded` with ready pixels (`:SaveWithoutAlpha(path)`, `:GetPixel(x, y)`). 
- `opt.update_events = n` runs n Update events first. Use this for UI so layout resolves before the capture. 
- `opt.midframe = true` captures immediately mid-frame. Call it from inside a Draw/Draw2D listener, and maybe use `TextureDownloaded:Save(path)` which saves the screenshot with alpha.

Example:
  ```lua
  Screenshot(function(texture)
      print(texture:SaveWithoutAlpha()) -- auto path under storage/logs/screenshots/
  end, {update_events = 3})
  ```

## 3D shots and the camera

`Screenshot` captures whatever is being rendered, so use it for 2D, UI and mid-frame captures. To capture the 3D scene from a chosen position, use `Shot` (`goluwa/render3d/shot.lua`). It holds a view until GI, TAA and auto exposure have settled, then captures.

- CLI: `luajit glw --3d shot tmp/out.png --setup tmp/scene.lua --pos 0,4,18 --ang -10,0,0 --fov 70 --ev 15 --settle 3 --converge 0.5`. Angles are in degrees, `--ev` locks exposure at that EV100, and `--setup` runs a Lua file first, e.g. to build a scene. Without `--ev`, auto exposure is used.
- `Shot.Capture(view_properties, cb, opt)` calls `cb(texture, info)`. `info.seconds` and `info.frames` say how long the view was held.
- `opt.settle` is the minimum number of seconds held (default 2). `opt.converge = n` then keeps capturing until the mean rgb difference (0-255) between captures is at most n, or `opt.max_settle` seconds (default 15) pass. `info.converged` and `info.difference` report the outcome.
- `Shot.Sequence(list_of_view_properties, cb, opt, done)` captures several views in turn without the player's view showing in between.

  ```lua
  local Shot = import("goluwa/render3d/shot.lua")
  Shot.Capture({Position = Vec3(0, 5, 0), Rotation = QuatDeg3(-30, 0, 0), ExposureLock = 15}, function(texture, info)
      print(texture:SaveWithoutAlpha("tmp/shot.png"), info.seconds)
      system.ShutDown(0)
  end, {settle = 3, converge = 0.5})
  ```

To move the camera, don't write to `render3d.GetCamera()` (the player's view overwrites it every frame). Activate a view above the player (priority 0) instead: `local view = View.New{Priority = 100, Position = Vec3(0, 5, 0), Rotation = QuatDeg3(45, 0, 0), ExposureLock = 15}:Activate()` with `View = import("goluwa/render3d/view.lua")`. Unset fields are copied from the current camera, `ExposureLock` is an EV100, and the exposure fields default to the global `r_exposure_*` settings. `view:Remove()` gives control back to the player.

# Networking

Server authoritative, Source/GMod style. Start a server with `luajit glw --server` (physics is on, `host` runs automatically, `GOLUWA_PORT` overrides the port for `host` and `connect`), and a client with `luajit glw --3d` then `connect 127.0.0.1`, or headless with `luajit glw --cli --physics`.

- Transport: `goluwa/network/connection.lua` (handshake, reliable ordered per channel, fragmentation, sequenced/unreliable, pings, timeouts) on `transport_layer.lua` (UDP). `GOLUWA_NET_LATENCY`, `GOLUWA_NET_JITTER` (ms) and `GOLUWA_NET_LOSS` (%) simulate bad connections.
- To replicate an entity, give it the `network` component (`shapes.Box{Network = true, ...}` or `Entity.New{network = {}, ...}`). Every component declares what replicates in a `META.Network = {Key = {type, rate, flags, interp}}` table (transform, model, rigid_body, lights, ...). The spawn packet carries the component list and their values, and the client builds the entity through `Entity.New`. Models are paths the client already knows (`model` component: `ModelPath`, `ModelOptions`, `MaterialConfig`, procedural `models/*.lua` work). Rigid bodies obey transform scale. Non owned bodies are kinematic on clients.
- Players: input is a `usercmd` (`goluwa/network/usercmd.lua`) produced once per physics tick by `player_controller` (from `player_input` locally, from the network on the server, or from a `CreateMove` hook for bots). `player_movement` only consumes the command, so the same code predicts on the client and simulates on the server. The client reconciles against `player_ack`, the server relays commands to the other players, and the physgun runs on the server from the command buttons.
- `net_stats` toggles a network HUD. Tests: `luajit glw test network/` (includes two process e2e tests that spawn a server, a bot and an observer from `test/network_e2e/`).

# Prefabs

A prefab (`goluwa/entities/prefab.lua`) is a tree of scene records plus declared inputs. An instance is an entity with the `prefab` component (`Path`, `Inputs`), its generated nodes are never saved with the scene, only the path and the input values are. Editing any instance writes back to the definition and every other instance follows.

- The root record becomes the instance's own entity. The instance keeps its entity properties, `transform`, `rigid_body` and `network`, the definition owns every other root component and all child nodes. `shapes.Box/Sphere/Cone/Capsule` are thin wrappers over the `box`, `sphere`, `cone` and `capsule` prefabs in `goluwa/entities/prefabs/shapes.lua`.
- Definitions are `prefab.Register(name, {inputs = {...}, entities = {...}})` data, or `.prefab` files in `storage/prefabs/` (`prefab.Save`, `prefab.Get`). `entities` use the scene record format, parents before children, the root first with the guid `root`. Instantiate with `Entity.New{prefab = {Path = name, Inputs = {...}}}`.
- An input is `{Name, Type, Default, Targets = {{Node, Component, Property, Key}}}`. Setting it (`instance.prefab:SetInput(name, value)`, the property editor, or the `Inputs` property) pushes the value into every target. `Component = "entity"` targets entity properties, `Key` addresses a field of a table valued property such as `ModelOptions.size`. Bound properties are not captured back into the definition. Inputs with `Hidden = true` are not shown in the editor.
- Edits are written back with `prefab.MarkDirty(object, property_name)` (only that property of that node is written to its record, `CommitProperties`) and `prefab.MarkStructureDirty(entity)` (nodes, components and the hierarchy are captured again, `Commit`, the values of nodes that were already there are kept from their records), both flushed once per frame by `prefab.Flush`. Nothing else of the instance is read, so what scripts or physics changed is never written to the definition. Editing a property an input pushes into changes the input of that instance instead, so it and the other targets stay in step. The editor does this for the selected entity (`addons/editor/lua/prefab_tools.lua`), gameplay code that changes nodes of an instance does not write to the definition. File backed definitions are saved a short while after the last commit. `PrefabChanged` fires for every change to a definition, `PrefabInputsChanged` only when inputs or links change (the editor rebuilds its property panel on that one, not on value edits, a rebuild would drop the control being dragged).
- `prefab.CreateFromEntity(entity, name)` turns an entity subtree into a prefab and the entity into an instance, `prefab.Unpack(entity)` turns an instance into plain entities. Prefabs can contain instances of other prefabs.
- Definitions replicate through `scene_sync`: the server sends every definition that is not an untouched built-in before the scene snapshot and again after each edit, a client editor sends its edits to the server (`sv_scene_push`) which saves them and passes them on. Instance paths, inputs and the root components replicate like any other component, child nodes are built on every side from the definition.
- Inputs can be removed or given a new default from the right click menu of their row under the instance's `prefab` component (property infos list such items as `context_actions`, a node carries them as `ContextActions`), `prefab.RemoveInput` and `prefab.SetInputDefault` do the same from code. Right clicking any storable property of a prefab instance's node or owned component offers Show in prefab (a new input, or a link to an existing input of the same type, `prefab.AddTarget`) / Hide from prefab, and any row of an instance's `prefab` component offers Add input (a number, boolean, string, vec3 or color without targets that scripts read and write) (`prefab_tools.GetPropertyActions`, hooked into the property editor through its `OnContextActions` callback, `prefab.IsExposed/Unlink` underneath), the entity tree's right click menu has Prefab with Make prefab / Unpack / Place. Moving a node with the entity tree writes the new hierarchy back (`EntityTreeReparent`). Code that drives nodes (scripts) is never written back, `prefab.Suppress/Unsuppress` wrap it.
- Prefabs are assets of the category `prefabs` (`prefabs/<name>.prefab`, files from any mounted `prefabs/` folder are found by `prefab.Get`, a definition registered in code is a virtual asset until it is saved). The category's `get_value/get_path` make pickers hold the prefab name and not the path. The `Path` property of the `prefab` component has `asset = "prefabs"`, so the property editor offers the asset browser for it, which has a prefabs tab with thumbnails (`prefab.CreatePreview`, an instance with only transform and model components, rendered with `ModelPreview:SetTargets`), a details panel (`prefab.Describe`) and Place and Use on selected actions.
- The editor marks prefabs visually. Entity tree: an instance root has a green label and its prefab name after it, nodes the instance generated have the blue + marker, entities with a script get a "script" badge ("script error" in red), nodes list such badges as `Badges = {{Text, Color}}`. Property editor: components are listed in the order of `COMPONENT_ORDER` in `editor.lua` (the `CategoryOrder` property, prefab first, the rest alphabetical), a component header gets a badge from `OnGetCategoryBadge` (shared, this instance, prefab, a failed script turns its header red) and a property an input pushes into gets a green label with a `<- Input` badge from `OnGetPropertyBadge`, both implemented in `prefab_tools.lua`. The badge also names a `Tab`: with more than one tab among the categories the property editor shows a tab bar and only lists the categories of the active tab, so an instance root has Instance (the prefab component with its inputs, transform, physics) and Shared (everything the prefab defines), a node of an instance only has Shared and no bar. A badge with `HideWithTabs` (shared, this instance, prefab) is only drawn when there is no tab bar, as on the nodes of an instance, the error badge always is. Category groups (an info's `category`, the prefab inputs are one) have a plain text header.
- `BaseEntity:GetPrefab()` returns the nearest instance root at or above an entity, `GetNode(id)` a node of it.
- `addons/examples/lua/examples/render3d/prefab_inputs.lua` is an example with one input driving two targets. Tests: `luajit glw test entities/prefab.lua`.

# Scripts and use

The `script` component has one property, `Source`, a Lua string. It is loaded as `local Entity = {} <source> return Entity` with the whole engine as its environment, `import` works with root relative paths. `self` in every function is the script's owner. Module scope runs when the script is created, then `Entity:OnCreate()` (once the prefab it is part of has finished building, so every node exists), `Entity:Update(dt)` every frame, `Entity:OnRemove()`, and every other `Entity:On*` function is a local event of the owner (`CallLocalEvent`). A script that errors is logged, stays off and shows the error in its editor until the source changes. Editing `Source` reloads it. In the property editor the value opens a small Lua editor window (`code_editor.lua`, property type `info.code`).

- Scripts run in every process. Shared state belongs in prefab inputs, changed only by whoever `network.HasAuthority()` (true on the server and in a standalone game, false on a client connected to a server; `SERVER` alone is false in a standalone game), visuals follow them in `Update`.
- `sv_client_scripts` (off by default) controls whether the server keeps script components that clients send, either as entities or inside a prefab definition. Without it they are removed before anything is applied or forwarded.
- Pressing E (not while holding something with the physgun) sets `usercmd.BUTTON.USE`, the authoritative side (`weapon_holder`) calls `use.Press`, which finds the closest collider or visible mesh within `use.MaxDistance` and fires `OnUse(user, hit)` on that entity and up its parents until a handler returns true. The server then tells the clients (`use_sync.lua`), who fire it too. A dedicated server only sees colliders, so things that can be used there need a `rigid_body`, a script can add one in `OnCreate`.
- `addons/examples/lua/examples/render3d/prefab_scripts.lua` has a lamp, a door, a crate dispenser and a color cycling beacon. Tests: `luajit glw test entities/script.lua`.

# UI widgets

Every widget under `goluwa/render2d/ui` (`elements/`, `widgets/`, `widgets/properties/`) is a `Panel:CreateTemplate("name")` class, see `widgets/tree.lua` and `widgets/window.lua`. Instantiate with `Widget{Prop = value}{children}`.

- Component defaults go in `META.CMP.transform = {...}`, `META.CMP.layout = {...}` and so on. Props passed by the caller are merged on top, they never mutate the defaults.
- Options are `META:GetSet` properties. Tokens (`"M"`, `"XS"`, palette names) are resolved through `theme.active`. Token or object valued options use a `nil` default because GetSet coerces string and number defaults.
- Build internal children in `OnCreate` with `Parent = self, IsInternal = true` and keep them in private `_fields`. Forward user children with `PreChildAdd` and `PreRemoveChildren` (or `self:RemoveExternalChildren()`).
- Callbacks are default no-ops (`function META.OnChange() end`) assigned from props and called as `self.OnChange(value, self)`. Derived templates set `META.Base = Other` and call `META.BaseClass.OnCreate`, so a base template must define `OnCreate`.
- Custom `SetX` methods run while props are applied, before the internal children exist. Guard them.
- Construction is one pipeline in `goluwa/entities/base.lua` (`OnConstruct`) for every entity. Props are flattened into one table (template `CMP` defaults < `PropDefaults` chain < caller), components are added, props are applied in a deterministic order (`GetSet` declaration order, then alphabetical), then `OnCreate()` runs, then `Ref`/`Parent`/`Key` are handled. The caller's table is never mutated.
- `OnCreate()` takes no props and must not mutate them. Read `self.Foo`. Defaults that depend on other props go in `function META.PropDefaults(self, props)`, which returns a table (nested component tables like `layout = {...}` merge, the caller wins, derived templates win over base ones, `props` is read-only). Do not handle `Ref`, `Parent`, `Key` or `Tooltip*` in widgets, the core does.
- Theme tokens (`"M"`, `"primary"`, font names) in `Padding`, `Color`, `ChildGap`, `Size`/`MinSize`/`MaxSize`/`IconSize`, `Font`, `FontSize` are remembered and re-resolved when the theme changes. Never resolve a token in `OnCreate` and store the number. For a default derived from the theme use `theme.Dynamic(fn, a, b, c)` (`fn(active_theme, a, b, c)`, see `theme.InputSize`), and when forwarding a themed prop to a child use `self:GetPropertyToken("Padding")`. Widgets that still bake theme values in `OnCreate` (children sized from a font size, rebuilt rows) implement `META:OnThemeChanged()`.
- `theme.active:Draw(self)` dispatches on `pnl.ThemeName or pnl.Name`. Do not name props after entity API (`State`, `Scroll`, `Size`, `Direction`) and declare `Font` and `FontSize` GetSets when forwarding text props, otherwise a `text` component is added to the panel.
- Scroll views: the scrollbar hugs the `ScrollablePanel`'s own edge (theme sets its width and hairline margin). A window or frame that hosts a scroll view uses `Padding = "none"` and puts the padding on the scroll panel, otherwise the bar floats inward. `ScrollbarShiftMode` defaults to `auto` (reserves a gutter in big panels, floats over content in small ones); `VirtualGrid` defaults to `always_shift` so its columns do not reflow when the bar appears.
- `addons/ui_gallery` is the showcase: `luajit glw --2d --background --validate lua "import('addons/ui_gallery/lua/gallery_browser.lua'){Key = 'GalleryWindow'}"`. Each file in `lua/gallery/` returns `{Name, Section, Order, Create}` and is built from `gallery_kit.lua` (Page, Section, Group, Labeled). Use spacing tokens only.

# Icons

Every icon the UI uses is defined up front in `goluwa/render2d/ui/themes/icons.lua`, no icon is loaded from a url. They are stroked line drawings on a 24 unit grid (`add(category, name, body)`, the body is svg elements, the category groups them in the gallery).

- The base theme holds them (`Icons`, name -> body, `GetIconNames`, `GetIconSource(name)`) and the `IconStyle` that strokes all of them: `StrokeWidth` (in the 24 unit grid), `LineCap` butt | round | square, `LineJoin` miter | round | bevel, `MiterLimit`. jrpg and playful merge into both in `Initialize`, `SetIcons(self:MergeTables(self:GetIcons(), {name = body}))` overrides single icons and `SetIconStyle(self:MergeTables(self:GetIconStyle(), {StrokeWidth = ...}))` changes the look of all of them, jrpg is 1.25, base 1.75, playful 2.75. Anything else that should apply to every icon belongs in `IconStyle` and `BaseTheme:GetIcon`.
- The `icon` size token is the box of a standard icon. `theme.active:DrawIcon(name, size_vec2, {color, size, inset})` draws one immediate mode, `disclosure` and `dropdown_indicator` are the chevron turned by `open_fraction`.
- Use them with `Icon{Icon = name}`, `Button{Icon = name}`, `IconButton{Icon = name}`, `MenuItem{Icon = name}` (give every item of a menu an icon or none, the text only lines up inside a menu that is consistent), `TabBar{Icons = {tab = name}}`, tree nodes (`Icon = name` or `Icon = function(node, expanded)`, `IconColor`) and property context actions `{Text, Icon, OnClick}`. The entity tree picks the icon of an entity from `EntityTree.GetComponentIcon(component_name)`, which the editor reuses for its component menus.
- The icons are drawn as msdf from `render2d/svg.lua`. `codecs/svg.lua` fills and strokes paths, `circle`, `ellipse`, `rect`, `line`, `polyline` and `polygon`, and `SVG.New(source, {StrokeWidth, LineCap, LineJoin, MiterLimit})` replaces the stroke settings of the document. `math2d.StrokePolylines` turns the strokes into outlines: all strokes of an icon are one line graph, so they join where they share a point and they must not cross anywhere else (split a line at a junction, `ring`, `arc` and `teardrop` in `icons.lua` take care of the shared points of curves). A filled shape must not overlap a stroke. Keep about 3.5 units between center lines and make closed shapes at least 3.5 units wide, the heaviest weight is about 3 units thick.
- `addons/ui_gallery/lua/gallery/icons.lua` is the icons page: every icon of the active theme, the same icons at three weights and the cap and join styles. Switch the theme in the gallery to compare.

# Debugging

When debugging and thinking about why somnething happens, feel free to do print logging and changing code around temporarily to verify.

- print a table and its contents: `table.print(tbl)`
- print something once per session: `print_once(...)`
- print a traceback to see where something is called from: `debug.trace()`
- print something and force exit: `print(something) os.realexit(0)`

# Profiling

The profiler uses luajit's statistical profiler and jit.attach to observe trace recording.

- `_G.PROF.Start("myprofilesession")` is a high level global helper that starts the JIT profiler with sane default arguments. It runs for 300 update frames, stops and prints a text summary, then calls system.ShutDown(0)

- Profile the update loop for 1000 frames, then implicitly shutdown: `luajit glw --2d lua "PROF.Start('profilesession1', {frames = 1000}) import('tmp/benchmark_test.lua')"`

- Profile a one-off action and shutdown manually: `luajit glw --2d lua "PROF.Start('profilesession2') something_expensive_and_blocking() PROF.Stop() system.ShutDown(0)"`

- The profile capture is saved to `storage/logs/jit_profile_someid.glwp` which can be read in detail, ie `PROF.Summary("storage/logs/jit_profile_someid.glwp", {top_n = 20})`

# Optimizations

- Trace abort reasons like `blacklisted` are caused by other trace abort reasons, it means that it was attempted too many times

- LuaJIT's trace compiler is non deterministic, sometimes you may get unlucky or lucky. Beware of this.

- `error thrown or hook called during recording` may happen because of the profiler itself. jit.attach and jprofile.start. There is no debug.sethook in this engine.

- Sometimes caching is prefered, but sometimes it is not. The luajit does very well with pure numeric arithmetic, so caching may sometimes interfere with that. Sometimes you may think a function needs caching, but the underlying issue might be a trace abort causing the function not to compile properly, this case might benefit from caching, but if the underlying problem was solved, the function might even be faster than the cached variant.

# Coding rules

"Hot code" is anything called every frame in the update/render loop, or any function invoked in a tight loop.
If you see code that does the below, consider refactoring if relevant to the task at hand.

- Do not worry about whitespace as the formatter will take care of it.

- Never use camelCase. use snake_case for locals and private fields, PascalCase for methods and globals.

- Favor fixing underlying issues rather than patching symptoms.

- Don't add unnesseceary comments that just repeat what the code obviously does.
```lua
-- ShutDown function
local function ShutDown(code)
    -- call os.exit
    os.exit(code)
end
```
do this instead
```lua
local function ShutDown(code)
    os.exit(code)
end
```

- Do not write backwards-compatible code unless asked to. This repository is the only consumer of the APIs you write, so if you change an API, update every consumer in this repository, don't preserve the old signature or add shims.

- Do not normalize arguments. If a function takes in a texture object, then you must assume that the caller will always pass a valid texture object.

- Favor errors over silent failures, but beware of complex error handling in hot functions. In hot functions it is favorable to just let luajit error naturally in case of the wrong type passed.

- Don't call `obj:IsValid()` defensively/speculatively, only call it when you already know that the object's validity can genuinely be in question

- Do not write defensive code like "if obj.SetFoo then obj:SetFoo() end". assume the function exist. If obj is an object that you feel is missing a helper function, add the function at the object's source.

- Never create functions (closures) inside hot code. This allocates a new closure per call and causes jit to abort tracing. Hoist them to module level or an outer scope that is evaluated once. 

- Prefer long functions. Do not extract code into a local function unless the same logic is used elsewhere.

- If you do need a local helper function or a cache variable that's only consumed by one function, place it as close to the caller as possible and limit its scope with a `do...end` block:

```lua
do
    local function compute(str) return #str * #str end
    local cache = {}

    function mylib.Hash(str)
        if cache[str] then return cache[str] end
        local x = compute(str) + compute(str)
        cache[str] = x
        return x
    end
end

function mylib.SomethingElse() end
```
- Avoid creating local variables that are just used in one place.
```lua
local this_is_a_variable = x + y
compute(this_is_a_variable)

```
do this instead
```lua
compute(x + y)
```

- Prefer using `import` at the top of the script. In case of circular dependency, see how import.loaded is used

- If you are using a library like render2d, and it's missing functionality, AND the functionality is generally useful, add it to render2d. The same can be applied for standard lua libraries like string, table, math, etc functions. see for example goluwa/string/* for string library extensions.

- Use functions like table.merge, math.clamp, math.lerp, etc, over creating local functions that duplicate existing functionality

- Prefer using ffi.cdef and ffi.typeof at the module level, never adhoc inside of a hot function.

- When declaring ffi types, prefer using ffi.typeof to create anonymous localized types rather than ffi.cdef, as ffi.cdef creates global type definitions. 

# macos

On macos, the kosmickrisp vulkan driver is used as opposed to moltenvk

# Love2D and Garrysmod wrapper

These wrappers make it possible to run lua scripts made for those engines, in this engine. They exist in `addons/love/*` and `addons/gmod/*`

- Never modify a love2d game's source code. Always fix issues in the wrapper itself. The same applies for garrysmod scripts.

- Do not add script and game specific workarounds in the wrapper for specific games and scripts.

- The glua wrapper uses garrysmod's lua source as-is and only implements functions that garrysmod defines in C. Never redefine something like Color, since it's already in garrysmod's lua source.

- If this engine lacks core functionality that the wrapper's engine assume exists, consider adding it to this engine if it's generic and useful enough, as opposed to adding functionality to the wrapper only. For example, if render2d in this engine is missing alpha blending, add alpha blending to render2d, then write wrapper code to to use the new engine functionality.
