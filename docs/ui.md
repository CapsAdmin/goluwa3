# UI widgets

Every widget under `goluwa/render2d/ui` (`elements/`, `widgets/`, `widgets/properties/`) is a `Panel:CreateTemplate("name")` class; start from `widgets/tree.lua` and `widgets/window.lua`. Instantiate with `Widget{Prop = value}{children}`. Every template ends with `return META:Register()`.

## Template rules

- Component defaults go in `META.CMP.transform = {...}`, `META.CMP.layout = {...}`; caller props merge on top and never mutate the shared defaults.
- Options are `META:GetSet` properties. Token or object valued options use a `nil` default because GetSet coerces string/number defaults. Do not name props after entity API (`State`, `Scroll`, `Size`, `Direction`), and declare `Font`/`FontSize` GetSets when forwarding text props, otherwise a `text` component is added.
- Construction is one pipeline in `goluwa/entities/base.lua` (`OnConstruct`) for every entity: flatten props (template `CMP` < `PropDefaults` chain < caller), add components, apply props in a deterministic order (GetSet declaration order, then alphabetical), `OnCreate()`, then `Ref`/`Parent`/`Key`. Never handle `Ref`, `Parent`, `Key`, `Tooltip*` in widgets. `OnCreate()` takes no props and must not mutate them: read `self.Foo`. Defaults depending on other props go in `META.PropDefaults(self, props)` (read-only `props`, returns a table).
- Custom `SetX` setters run while props are applied, before `OnCreate` and before internal children exist: guard them. A GetSet callback only fires when the value differs from the default, so a prop passed as its default never runs it; when a callback configures sub-panels, also apply the initial state explicitly at the end of `OnCreate`.
- Build internal children in `OnCreate` with `Parent = self, IsInternal = true`, kept in private `_fields`. Derived templates share one private-field namespace with their base: use distinct names.
- `META.Slot = "_content"` declares an inner panel for user children: `AddChild` of non-internal children goes there, `RemoveChildren()` clears only it, `RemoveAllChildren()` removes everything. Without a slot `RemoveChildren()` keeps `IsInternal` children, so a widget that rebuilds internal rows must call `RemoveAllChildren()`.
- Callbacks are default no-ops (`function META.OnChange() end`) assigned from props and called as `self.OnChange(value, self)`. Derived templates set `META.Base = Other` and call `META.BaseClass.OnCreate`.
- Theme tokens (`"M"`, `"primary"`, font names) in props like `Padding`, `Color`, `ChildGap`, `Size*`, `Font` are remembered and re-resolved on theme change (`Panel.RefreshTheme` -> `OnThemeChanged`). Never resolve a token in `OnCreate` and store the number. Theme-derived defaults use `theme.Dynamic(...)`; forward themed props to children with `self:GetPropertyToken("Padding")`. Widgets that bake theme values implement `META:OnThemeChanged()`.
- `theme.active:Draw(self)` dispatches on `pnl.ThemeName or pnl.Name`. HUD drawing (progress bars, reticles, HUD panels, keycaps, world text) goes through `theme.active:Draw*` methods so it follows the active theme; new HUD elements get a theme method and a gallery entry instead of fixed colors. Text drawn straight onto the game world uses `theme.active:GetWorldTextStyle()`, not the plain `text` token.
- `event.AddListener` is O(n) per add: never add a global listener per widget instance (use class-level `OnFirstCreated`/`OnLastRemoved` with one shared listener). Read layout component fields directly in hot paths instead of `:GetX()`.
- Escape is bound to `toggle_desktop` in `goluwa/main.lua`, so `event.Call("KeyInput", "escape")` is swallowed in tests; call the handler directly.
- Framebuffer color textures are sampled upside down by render2d, and image decoders differ in row order (`render2d.DrawTextureCover(..., flip_y)`). Check orientation with an asymmetric shape.
- `render2d.PushColor(r,g,b)` keeps the current alpha: pass alpha explicitly after a translucent fill.

## Notable widgets

Read the widget file for its props; the gallery page of the same name shows it in use.

- `elements/scrollable_panel.lua`: overlay scrollbars that never shift layout, keyboard scrolling, wheel pass-through at the extents, middle-button autoscroll.
- `widgets/tab_bar.lua`, `widgets/tabs.lua`: `SetValue` never fires `OnChange` (only a click does), so programmatic changes cannot loop.
- `widgets/timeline.lua`: rows of keys and clip blocks on one time axis. It holds no data state: every edit (scrub, select, move, trim, resize, scale a selection) is reported through `On*` callbacks and the caller updates `Rows`.
- `widgets/tree_table.lua` and `VirtualGrid`: draw rows or tiles instead of panels, so they scale to thousands of items; they implement `GetDrawnItems()` so the MCP UI driver can target them.
- Property editor (`widgets/properties/`): nodes by `Type` (`list`, `panel`, `curve`, `color_range`, `sound`, `code`, ...). Lists never mutate data themselves: every action calls back and the owner rebuilds the items. `RowButtons` and `ContextActions` on a node add buttons and menu entries. `PropertyEditor:SetFilter(text)` filters rows. Blocks (lists, groups) must not sit inside a flattened non group child.
- pvars have a `category` (tab) and `group` (section), set with `pvars.StartGroup(...)` ... `pvars.EndGroup()`; `goluwa/render2d/ui/pvar_node.lua` turns a pvar into a property node.
- `Dropdown` menus beyond a size threshold are virtual and optionally searchable. `Window{Headerless = true}` is dragged by its content area. `elements/ghost.lua` draws a panel subtree again at another position (drag previews).

## Input history, autocomplete, undo

`goluwa/text_undo.lua`, `goluwa/input_history.lua`, `goluwa/autocomplete.lua` are plain logic; `TextEdit` consumes them through the `History` and `Autocomplete` props (`widgets/autocomplete_list.lua` is the floating list). `goluwa/cli/command_input.lua` completes `!` console commands/pvars for chat and the terminal repl (`goluwa/cli/repl.lua`).

- Tests that use a named `InputHistory` overwrite the user's real history file: use an unnamed one.
- `TextEdit:SetText` does not fire `OnTextChanged`, resets undo and ends a history search; `editor:SetText` is undoable. Type with `CharInput` events in tests.
- The panel's `OnKeyInput` prop runs before the editor; returning true for every key swallows modifier presses.

## Icons

All icons are defined in `goluwa/render2d/ui/themes/icons.lua` as stroked line drawings on a 24 unit grid, rendered as msdf from `render2d/svg.lua` via `math2d.StrokePolylines`, which needs a planar line graph: strokes must not cross except at shared vertices, keep enough spacing that the heaviest theme stroke weight does not merge lines, and stay half a stroke inside the viewBox. `addons/ui_gallery/lua/gallery/icons.lua` is the review page.

## Fonts

Every distinct (font, size, weight) is its own font object whose glyphs are rasterized and uploaded with a blocking GPU submit the first time a string needs them. Animate text size with `DrawText{scale = ...}` at a fixed `size`, never by changing `size` per frame. Bitmap fonts: `glyphs.RegisterBitmapFont` plus a font path `"bitmap:name:scale"` (`render2d/fonts/bitmap.lua`).

## Desktop, HUD, menus

- `desktop.RegisterBackdrop` replaces the dimmed scene behind the desktop; `desktop.RegisterProgram{Content = Component}` registers a window-less react program.
- `event.Call("DrawHUD", dt)` draws before Draw2D and is skipped while `render2d.SetHudHidden(reason, hidden)` has any reason set.
- Load window (`goluwa/render2d/ui/load_window.lua`) only talks to `goluwa/loaders.lua` (see animation-and-source.md).
- Spawn menu: `addons/sandbox/lua/spawnmenu.lua` (hold `q`), model catalog in `model_catalog.lua` and `model_families.lua`. Tab hosts that fill a parent need `FitHeight = false` on every column/row between them and a `Splitter` or grid, otherwise they collapse.
- Asset browser and pickers live in `addons/editor` (`picker.lua`, built on the cached `assets.GetIndex(category)`), brush editing in `addons/editor/lua/brush_editor.lua`.

# React style UI

`goluwa/render2d/ui/react.lua`: hooks and a keyed tree diff on top of the stateful widgets; tests `test/tests/panel/react.lua`, gallery page `react`. `react.Element(template)` makes a template return a description; `react.Component(fn)` makes a component; `react.Mount(tree, parent_entity)` returns a root with `Render`, `GetEntity`, `Unmount`. `import("goluwa/render2d/ui/react_ui.lua")` makes elements on first use (`ui.Button`, ...). Uses LuaJIT lambdas (`|x| -> expr`, `cond && Element{}`, `a ?? b`, `c ? a : b`). A nested ternary whose then-branch is an identifier parses as a method call: avoid it.

- Hooks are in `react.lua` (`UseState`, `UseRef`, `UseMemo`, `UseCallback`, `UseEffect`, `UseResource` for objects with a lifetime, `UseEvent`, ...). State changes batch and flush on the next `Update` (`react.Flush()` in tests).
- Props are diffed against the previous description, not the live widget, so widget-owned state (typed text) is never overwritten unless the app passes a different value. Props only read in `OnCreate` cannot update: change the `Key` to remount. Component tables like `layout = {}` diff per field and must be flat. A prop that disappears resets to its default.
- Widgets that keep their own state (slider, text edit, color picker) get a start value as a prop and report with `On*`; feeding the value back as `Value` can lose information. Imperative APIs go through `UseRef`.
- `react.Memo` skips renders on shallow-equal props: pass stable callbacks. `react.ErrorBoundary{Fallback}` tears a failing subtree down; per-frame callbacks (`Draw`, `Update`, ...) are never wrapped, since hot code must not run under `xpcall`.
- Editor pattern (`addons/editor/lua/editor_kit.lua`): per-frame and mouse state goes in one `UseResource`/`UseMemo` table nothing renders from; draw and mouse callbacks are `UseCallback(fn, {})`; per-frame work is `UseEvent("Update")`; what the user sees changing is state.
- Not supported: text children, hot reload of components (a reloaded component is a new type and remounts).

## Gallery and tests

The gallery (`luajit glw --2d --background --exit-on-error lua "import('addons/ui_gallery/lua/gallery_browser.lua')()"`) is the showcase: each file in `addons/ui_gallery/lua/gallery/` returns `{Name, Section, Order, View}`; build pages from `gallery_kit.lua` and spacing tokens only. `test/tests/panel/gallery.lua` builds every page in every theme; `test/tests/panel/construction.lua` covers the construction pipeline. To drive the UI like a user, see [mcp.md](mcp.md).
