# UI widgets

Every widget under `goluwa/render2d/ui` (`elements/`, `widgets/`, `widgets/properties/`) is a `Panel:CreateTemplate("name")` class; start from `widgets/tree.lua` and `widgets/window.lua`. Instantiate with `Widget{Prop = value}{children}`. Every template ends with `return META:Register()`.

## Template rules

- Component defaults go in `META.CMP.transform = {...}`, `META.CMP.layout = {...}`; caller props merge on top and never mutate the shared defaults.
- Options are `META:GetSet` properties. Token or object valued options use a `nil` default because GetSet coerces string/number defaults. Do not name props after entity API (`State`, `Scroll`, `Size`, `Direction`), and declare `Font`/`FontSize` GetSets when forwarding text props, otherwise a `text` component is added.
- Construction is one pipeline in `goluwa/entities/base.lua` (`OnConstruct`) for every entity: flatten props (template `CMP` < `PropDefaults` chain < caller), add components, apply props in a deterministic order (GetSet declaration order, then alphabetical), `OnCreate()`, then `Ref`/`Parent`/`Key`. Never handle `Ref`, `Parent`, `Key`, `Tooltip*` in widgets. `OnCreate()` takes no props and must not mutate them: read `self.Foo`. Defaults depending on other props go in `META.PropDefaults(self, props)` (read-only `props`, returns a table).
- Custom `SetX` setters run while props are applied, before `OnCreate` and before internal children exist: guard them. A GetSet callback only fires when the value differs from the default, so a prop passed as its default never runs it; when a callback configures sub-panels, also apply the initial state explicitly at the end of `OnCreate`, and suspect this first when a default-configured widget lays out differently from one with explicit props.
- Build internal children in `OnCreate` with `Parent = self, IsInternal = true`, kept in private `_fields`. Derived templates share one private-field namespace with their base: use distinct names.
- `META.Slot = "_content"` declares an inner panel for user children: `AddChild` of non-internal children goes there, `RemoveChildren()` clears only it, `RemoveAllChildren()` (what `OnRemove` calls) removes everything. Without a slot `RemoveChildren()` keeps `IsInternal` children, so a widget that rebuilds internal rows must call `RemoveAllChildren()`. React with `OnChildAdd(child)` / `OnChildrenRemoved()`.
- Callbacks are default no-ops (`function META.OnChange() end`) assigned from props and called as `self.OnChange(value, self)`. Derived templates set `META.Base = Other` and call `META.BaseClass.OnCreate`.
- Theme tokens (`"M"`, `"primary"`, font names) in `Padding`, `Color`, `ChildGap`, `Size*`, `IconSize`, `Font`, `FontSize` are remembered and re-resolved on theme change (`Panel.RefreshTheme` -> `ReresolveProperties` -> `OnThemeChanged`; props the user changed afterwards are skipped). Never resolve a token in `OnCreate` and store the number. Theme-derived defaults use `theme.Dynamic(fn, a, b, c)`; forward themed props to children with `self:GetPropertyToken("Padding")`. Widgets that bake theme values in `OnCreate` implement `META:OnThemeChanged()`.
- `theme.active:Draw(self)` dispatches on `pnl.ThemeName or pnl.Name`.
- `event.AddListener` is O(n) per add: never add a global listener per widget instance (use class-level `OnFirstCreated`/`OnLastRemoved` with one shared listener). Read layout component fields directly in hot paths instead of `:GetX()`.
- Escape is bound to toggle_desktop in `goluwa/main.lua` (priority inf), so `event.Call("KeyInput", "escape")` is swallowed in tests; call the handler directly.
- `MenuSpacer{}` needs a table argument. Give every item of a menu an icon or none.
- Framebuffer color textures are sampled upside down by render2d: draw a `ModelPreview` with `preview:Draw(x, y, w, h)`. png/bmp decoders write the bottom row first, jpg/dds/vtf the top row (`render2d.DrawTextureCover(..., flip_y)`). Check orientation with an asymmetric shape.
- `render2d.PushColor(r,g,b)` keeps the current alpha: pass alpha explicitly after a translucent fill.

## Scroll views

`ScrollablePanel` (`elements/scrollable_panel.lua`) has overlay scrollbars that expand on hover and never shift the layout; fixed-bar themes return `GetScrollbarWidth()` from `GetScrollbarCollapsedWidth`. A window hosting a scroll view uses `Padding = "none"` and pads the scroll panel. Options: `ScrollbarShiftMode` (`auto`; `VirtualGrid` uses `always_shift`), `ScrollbarButtons`, `KeyScrolling` (viewport takes focus on click, keys go only to the focused object, no bubbling), `CaptureWheelAtExtents` (default false: a view at its end or with nothing to scroll passes the wheel on). Middle-button autoscroll lives in the same file. The wheel never moves focus or raises windows.

## Tabs and property editor

- `TabBar` (`tab_bar.lua`) and `Tabs` (`tabs.lua`, children carry `Tab = "name"`). `SetValue` never fires `OnChange` (only a click does) so programmatic changes cannot loop. `SetTabs` copies the list and skips equal lists; mutate a copy, not `bar.Tabs`. `Tabs` hides inactive pages via `visual:SetVisible(false)` and invalidates layout itself.
- `PropertyEditor:SetFilter(text)` filters rows by words in titles, label or node `Search`; put a `TextEdit` above it (`SetText` does not fire `OnTextChanged`).
- pvars have a `category` (tab) and `group` (section): `pvars.StartGroup(category, group, {store = false, prefix = "ddgi_"})` ... `pvars.EndGroup()`; a pvar without both asserts. `goluwa/render2d/ui/pvar_node.lua` turns a pvar into a property node.

## Input history, autocomplete, undo

`goluwa/text_undo.lua`, `goluwa/input_history.lua`, `goluwa/autocomplete.lua` are plain logic; `TextEdit` consumes them through the `History` and `Autocomplete` props (`widgets/autocomplete_list.lua` is the floating list). `goluwa/cli/command_input.lua` completes `!` console commands/pvars for chat and the terminal repl (`goluwa/cli/repl.lua`).

- Tests that use a named `InputHistory` overwrite the user's real history file: use an unnamed one.
- The panel's `OnKeyInput` prop runs before the editor; returning true for every key swallows modifier presses.
- Ctrl/Shift state comes from `editor.ControlDown/ShiftDown`; type with `CharInput` events in tests. The default right click menu takes keyboard focus: `RequestTextFocus()` after closing it.
- `TextEdit:SetText` resets undo and ends a history search; `editor:SetText` is undoable.

## Icons

All icons are defined up front in `goluwa/render2d/ui/themes/icons.lua` as stroked line drawings on a 24 unit grid; the base theme holds them and an `IconStyle` (stroke width, cap, join). They are rendered as msdf from `render2d/svg.lua` via `math2d.StrokePolylines`, which needs a planar line graph.

- Strokes of an icon must not cross except at shared vertices, keep about 3.5 units between center lines, closed shapes at least 3.5 units wide, stay half a stroke inside the viewBox, and filled shapes must not overlap strokes. Check the heaviest theme weight too.
- `icon` size token is the standard box (the glyph is about 70% of it). Glyphs in tiny boxes need `inset = 0` in `DrawIcon`.
- Use via `Icon{Icon = name}`, `Button{Icon = name}`, `IconButton`, `MenuItem`, `TabBar{Icons = ...}`, tree nodes. `addons/ui_gallery/lua/gallery/icons.lua` is the review page.

## Bitmap fonts and the zsnes theme

`glyphs.RegisterBitmapFont` plus a font path `"bitmap:name:scale"` gives a pixel font drawn from one texture (`fonts/bitmap.lua`; `fonts/raster.lua` is out of date). Bitmap text is drawn with `render2d.PushMargin(0)` because `GetMargin` pads quads when `sdf_softness > 0`. Texture glyph UVs are sampled upside down.

## Desktop, load window, spawn menu

- `desktop.RegisterBackdrop{Name, OnDraw, OnActivate, OnDeactivate}` replaces the dimmed scene behind the desktop (pvar `desktop_backdrop`). `desktop.RegisterProgram{Content = Component}` is the window-less react component of a program (used by the spawn menu Utilities tab). A window that is only hidden on close should unmount live content on `OnVisibilityChanged`.
- The HUD: `event.Call("DrawHUD", dt)` draws before Draw2D and is skipped while `render2d.SetHudHidden(reason, hidden)` has any reason set (the desktop, a `View` with `HideHud` and the equipped camera weapon). The crosshair, weapon selection and chat HUD all draw there.
- Load window (`goluwa/render2d/ui/load_window.lua`) only talks to `goluwa/engines.lua` (see animation-and-source.md "Mounting games").
- Spawn menu (`addons/game/lua/spawnmenu.lua`, hold `q`): a full screen panel mounted once and then hidden; spawnlists come from GMod `settings/spawnlist*` through the vfs (needs the gmod mount); models spawn as `prop_physics` prefab instances (`addons/game/lua/props.lua`); only the process running the menu spawns. Tab hosts that fill a parent need `FitHeight = false` on every column/row between them and a `Splitter` or grid, otherwise they collapse.

## Asset browser and pickers (addons/editor)

- `vfs.FindRecursive` and `assets.GetIndex(category)` (rebuilt on `vfs.mount_generation` change) are the cached asset index; `VirtualGrid` draws only visible cells (`CellAspect`, `Items`, silent `SelectedItem`, `KeepScroll`); `previews` budgets render work and evicts LRU. `picker.lua` is standalone (`picker.Start{mode, on_pick, ...}`) and imports the browser lazily because the browser imports it.
- Stalls of 200-500 ms while scrolling are full GC cycles of the large heap, not the browser.

# React style UI

`goluwa/render2d/ui/react.lua`: hooks and a keyed tree diff on top of the stateful widgets; tests `test/tests/panel/react.lua`, gallery page `react`. `react.Element(template)` makes a template return a description; `react.Component(fn)` makes a component; `react.Mount(tree, parent_entity)` returns a root with `Render`, `GetEntity`, `Unmount`. `import("goluwa/render2d/ui/react_ui.lua")` is a table making elements on first use (`ui.Button`, ...). Uses LuaJIT lambdas (`|x| -> expr`, `|| -> do ... end`, `cond && Element{}`, `a ?? b`, `c ? a : b`). A nested ternary whose then-branch is an identifier parses as a method call: avoid it.

- Hooks: `UseState`, `UseReducer`, `UseRef`, `UseMemo`, `UseCallback`, `UseEffect`, `UseLayoutEffect` (after layout, before the frame), `UseStable`, `UseDrag`, `UseDebounce`, `UsePoll(fn, interval)`, `UseResource(create, dispose, deps)` (also disposed when an `ErrorBoundary` tears down a half-built subtree: use it for objects with a lifetime), `UseEvent(name, cb)`, `UseContext`. State changes batch and flush on the next `Update` (`react.Flush()` in tests).
- Props are diffed against the previous description, not the live widget, so widget-owned state (typed text) is never overwritten unless the app passes a different value. Props only read in `OnCreate` cannot update: change the `Key` to remount. `Key` is the reconciler's and is not passed to the entity. Component tables like `layout = {}` diff per field and must be flat. A prop that disappears resets to its default; `On*` to the class no-op.
- Children: nil, booleans and nested lists are dropped, a string child errors. Matching is by `Key` or position plus type. An entity removed from outside unmounts its node on the next flush.
- Widgets that keep their own state (slider, text edit, color picker) get a start value as a prop and report with `On*`; feeding the value back as `Value` can lose information. Imperative APIs go through `UseRef`.
- `react.Memo` skips renders on shallow-equal props: pass stable callbacks (`UseCallback`, `UseStable`). `Context.Provider` schedules every consumer when `Value` changes (keep it stable). `react.Foreign{Create}` hosts code-built entities; `react.Portal{Target}` mounts children elsewhere (a Window under `Panel.World`); `react.OpenWindow(key, Component, props)` opens one window per key.
- `react.ErrorBoundary{Fallback}`: throws in render, mount, effects or `On*` props below it tear the subtree down and render the fallback. Per-frame callbacks (names containing `Draw`, `Update`, `Move`, `Hover`, `OnTransformChanged`) are never wrapped (no `xpcall` in hot code).
- Editor pattern (`addons/editor/lua/editor_kit.lua`: `ViewerWindow`, `Canvas`, `InfoRow`, `OpenOnce`): everything frames and the mouse change goes in one `UseResource`/`UseMemo` table nothing renders from; draw and mouse callbacks are `UseCallback(fn, {})`; per-frame work is `UseEvent("Update")`; what the user sees changing is state.
- Not supported: text children, hot reload of components (a reloaded component is a new type and remounts).
- The gallery (`luajit glw --2d --background --validate lua "import('addons/ui_gallery/lua/gallery_browser.lua')()"`) is the showcase: each file in `lua/gallery/` returns `{Name, Section, Order, View}`; build pages from `gallery_kit.lua` and spacing tokens only. `test/tests/panel/gallery.lua` builds every page in every theme; `test/tests/panel/construction.lua` covers the construction pipeline.
