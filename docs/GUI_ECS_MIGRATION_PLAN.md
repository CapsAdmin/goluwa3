# GUI ECS Migration Plan

## Executive Summary

This document outlines a comprehensive plan to migrate the current GUI system from a prototype-based panel architecture to a full Entity Component System (ECS) architecture. The migration will leverage the existing ECS infrastructure (`ecs.lua`) and maintain compatibility with the LSX declarative framework.

---

## Table of Contents

1. [Current Architecture Analysis](#current-architecture-analysis)
2. [Target Architecture](#target-architecture)
3. [Migration Strategy](#migration-strategy)
4. [Phase 1: Foundation](#phase-1-foundation)
5. [Phase 2: Core Components](#phase-2-core-components)
6. [Phase 3: Advanced Features](#phase-3-advanced-features)
7. [Phase 4: Integration](#phase-4-integration)
8. [Phase 5: Migration & Cleanup](#phase-5-migration--cleanup)
9. [Risk Assessment](#risk-assessment)
10. [File-by-File Changes](#file-by-file-changes)

---

## Current Architecture Analysis

### GUI System Overview

**Location**: `goluwa/gui/`

| File | Lines | Purpose |
|------|-------|---------|
| `gui.lua` | 257 | Core initialization, events, LSX hooks |
| `panels/base.lua` | 46 | Base panel assembler |
| `panels/frame.lua` | 104 | Window frame panel |
| `panels/text.lua` | 125 | Text rendering panel |
| `panels/text2.lua` | ~150 | Advanced text panel |
| `components/transform.lua` | 179 | 2D transforms |
| `components/drawing.lua` | 93 | Rendering |
| `components/hover.lua` | 26 | Hover detection |
| `components/animations.lua` | 70 | Animation system |
| `components/mouse_input.lua` | 70 | Mouse handling |
| `components/focus.lua` | 38 | Keyboard focus |
| `components/resize.lua` | 128 | Panel resizing |
| `components/key_input.lua` | 24 | Keyboard input |
| `components/layout.lua` | 1058 | Layout system |

### Current Component Application Pattern

```lua
-- panels/base.lua applies components as mixins
local META = prototype.CreateTemplate("panel_base")
prototype.ParentingTemplate(META)  -- Hierarchy support

require("gui.components.transform")(META)  -- Mixin pattern
require("gui.components.hover")(META)
-- ... 7 more components
```

### Key Problems with Current Architecture

1. **Dual Parenting Systems**: GUI uses `prototype.ParentingTemplate()` while ECS entities have their own parenting
2. **Component Coupling**: All 9 components are hardcoded onto every panel
3. **No Component Querying**: Cannot efficiently query all transforms, all hover-enabled elements, etc.
4. **Inflexible Composition**: Cannot create panels with only a subset of components
5. **Difficult System Implementation**: Layout, rendering, input systems have to iterate through panel hierarchy

### Existing ECS Infrastructure

**Location**: `goluwa/ecs.lua` (169 lines)

**Capabilities**:
- `ecs.CreateEntity(name, parent)` - Create entities
- `entity:AddComponent(meta)` - Add component by metatable
- `entity:RemoveComponent(name)` - Remove component
- `entity:GetComponent(name)` / `entity:HasComponent(name)` - Query
- `ecs.GetComponents(name)` - Get all instances of a component type
- `component.Require = {meta1, meta2}` - Dependency injection
- `component.Events = {"EventName"}` - Event subscription
- `component.OnAdd(entity)` / `component.OnRemove()` - Lifecycle hooks
- `component:OnEntityAddComponent(other)` - Cross-component notifications

---

## Target Architecture

### Entity Hierarchy

```
gui.World (GUI World Entity)
├── gui.Root (Root Panel Entity)
│   ├── Window Entity
│   │   ├── TitleBar Entity
│   │   └── Content Entity
│   │       ├── Button Entity
│   │       └── Text Entity
│   └── Popup Entity
```

### Component Structure

```lua
-- GUI Entity with components
local button = ecs.CreateEntity("button", parent)
button:AddComponent(gui_transform)     -- Position, Size, Matrix
button:AddComponent(gui_drawing)       -- Rendering
button:AddComponent(gui_hover)         -- Hover detection
button:AddComponent(gui_mouse_input)   -- Mouse handling
button:AddComponent(gui_focus)         -- Optional: keyboard focus
button:AddComponent(gui_layout)        -- Optional: layout participation
```

### System Architecture

```lua
-- Systems iterate over components globally
local function DrawSystem()
    for _, drawable in ipairs(ecs.GetComponents("gui_drawing")) do
        if drawable.Visible then
            drawable:Draw()
        end
    end
end

local function LayoutSystem()
    -- Process layout in tree order
    for _, layout in ipairs(ecs.GetComponents("gui_layout")) do
        if layout.dirty then
            layout:Calculate()
        end
    end
end
```

---

## Migration Strategy

### Approach: Parallel Development with Bridge Layer

1. Create new ECS-based GUI components alongside existing ones
2. Build a compatibility bridge that allows old panels and new entities to coexist
3. Migrate panel types one at a time
4. Remove old system once migration is complete

### Guiding Principles

- **Incremental**: Each phase produces a working system
- **Compatible**: LSX continues to work throughout migration
- **Testable**: Each component can be tested in isolation
- **Reversible**: Can roll back at any phase boundary

---

## Phase 1: Foundation

### 1.1 Create GUI World and Root Entity

**New File**: `goluwa/gui/gui_world.lua`

```lua
local ecs = require("ecs")
local gui_world = {}

local world_entity = nil
local root_entity = nil

function gui_world.GetWorld()
    if not world_entity or not world_entity:IsValid() then
        world_entity = ecs.CreateEntity("gui_world", nil)
        -- Don't use 3D world as parent
    end
    return world_entity
end

function gui_world.GetRoot()
    if not root_entity or not root_entity:IsValid() then
        root_entity = ecs.CreateEntity("gui_root", gui_world.GetWorld())
        -- Initialize root with screen size
    end
    return root_entity
end

function gui_world.Clear()
    if root_entity and root_entity:IsValid() then
        root_entity:Remove()
    end
    if world_entity and world_entity:IsValid() then
        world_entity:Remove()
    end
    root_entity = nil
    world_entity = nil
end

return gui_world
```

### 1.2 Create GUI Entity Base

**New File**: `goluwa/gui/entity_base.lua`

```lua
local prototype = require("prototype")
local ecs = require("ecs")

-- Extend the base entity template for GUI-specific behavior
local GUI_ENTITY = prototype.CreateTemplate("gui_entity")
prototype.DeriveFrom(GUI_ENTITY, prototype.GetTemplate("entity"))

-- GUI entities need to track their "panel type" for LSX compatibility
GUI_ENTITY:GetSet("PanelType", "base")
GUI_ENTITY.IsPanel = true

function GUI_ENTITY:Initialize()
    self.ComponentsHash = {}
end

-- Bridge method for LSX compatibility
function GUI_ENTITY:CreatePanel(name)
    local gui = require("gui.gui")
    return gui.CreateEntity(name, self)
end

return GUI_ENTITY:Register()
```

### 1.3 Modify ECS to Support GUI World Separation

**Modify**: `goluwa/ecs.lua`

Add support for multiple world types:

```lua
-- Add after existing 3D world code
do
    local gui_world_entity = nil

    function ecs.GetGUIWorld()
        if not gui_world_entity or not gui_world_entity:IsValid() then
            gui_world_entity = ecs.CreateEntity("gui_world", nil)
        end
        return gui_world_entity
    end

    function ecs.ClearGUIWorld()
        if gui_world_entity and gui_world_entity:IsValid() then
            gui_world_entity:Remove()
        end
        gui_world_entity = nil
    end
end
```

### 1.4 Deliverables

- [ ] `gui/gui_world.lua` created
- [ ] `gui/entity_base.lua` created
- [ ] `ecs.lua` extended with GUI world support
- [ ] Unit tests for GUI entity creation/destruction

---

## Phase 2: Core Components

### 2.1 Transform Component

**New File**: `goluwa/components/gui/transform.lua`

Convert the existing mixin to a proper ECS component:

```lua
local prototype = require("prototype")
local Matrix44 = require("structs.matrix44")
local Vec2 = require("structs.vec2")

local META = prototype.CreateTemplate("gui_transform")
META.ComponentName = "gui_transform"
META.Type = "gui_transform"

META:GetSet("Position", Vec2(0, 0))
META:GetSet("Size", Vec2(100, 100))
META:GetSet("Rotation", 0)
META:GetSet("Scale", Vec2(1, 1))
META:GetSet("Pivot", Vec2(0.5, 0.5))
META:GetSet("Perspective", 0)
META:GetSet("Scroll", Vec2(0, 0))

-- Matrix caching
META:GetSet("LocalMatrix", nil)
META:GetSet("WorldMatrix", nil)

function META:Initialize()
    self.LocalMatrix = Matrix44():Identity()
    self.LocalMatrixDirty = true
    self.WorldMatrixDirty = true
end

function META:SetPosition(pos)
    self.Position = pos
    self:InvalidateMatrices()
end

function META:InvalidateMatrices()
    self.LocalMatrixDirty = true
    self:InvalidateWorldMatrices()

    -- Notify layout component if present
    local layout = self.Entity:GetComponent("gui_layout")
    if layout then layout:Invalidate() end
end

function META:InvalidateWorldMatrices()
    if self.WorldMatrixDirty then return end
    self.WorldMatrixDirty = true

    -- Invalidate children
    for _, child in ipairs(self.Entity:GetChildren()) do
        local child_transform = child:GetComponent("gui_transform")
        if child_transform then
            child_transform:InvalidateWorldMatrices()
        end
    end
end

function META:GetLocalMatrix()
    if self.LocalMatrixDirty then
        self:RebuildLocalMatrix()
    end
    return self.LocalMatrix
end

function META:GetWorldMatrix()
    if self.WorldMatrixDirty then
        self:RebuildWorldMatrix()
    end
    return self.WorldMatrix
end

function META:RebuildLocalMatrix()
    -- ... (copy logic from gui/components/transform.lua)
end

function META:RebuildWorldMatrix()
    local local_mat = self:GetLocalMatrix()
    local parent = self.Entity:GetParent()

    if parent and parent:HasComponent("gui_transform") then
        local parent_transform = parent:GetComponent("gui_transform")
        local parent_world = parent_transform:GetWorldMatrix()
        self.WorldMatrix = local_mat:Copy()
        self.WorldMatrix = self.WorldMatrix * parent_world
    else
        self.WorldMatrix = local_mat:Copy()
    end

    self.WorldMatrixDirty = false
end

-- Convenience accessors (for compatibility)
function META:GetWidth() return self.Size.x end
function META:GetHeight() return self.Size.y end
function META:SetWidth(w) self.Size.x = w; self:InvalidateMatrices() end
function META:SetHeight(h) self.Size.y = h; self:InvalidateMatrices() end
function META:GetX() return self.Position.x end
function META:GetY() return self.Position.y end
function META:SetX(x) self.Position.x = x; self:InvalidateMatrices() end
function META:SetY(y) self.Position.y = y; self:InvalidateMatrices() end

return {Component = META:Register()}
```

### 2.2 Drawing Component

**New File**: `goluwa/components/gui/drawing.lua`

```lua
local prototype = require("prototype")
local Color = require("structs.color")
local gfx = require("render2d.gfx")
local render2d = require("render2d.render2d")

local META = prototype.CreateTemplate("gui_drawing")
META.ComponentName = "gui_drawing"
META.Type = "gui_drawing"
META.Require = {require("components.gui.transform").Component}
META.Events = {"Draw2D"}

META:GetSet("Visible", true)
META:GetSet("Color", Color(1, 1, 1, 1))
META:GetSet("Clipping", false)
META:GetSet("BorderRadius", 0)
META:GetSet("Texture", nil)
-- Draw animation offsets
META:GetSet("DrawSizeOffset", Vec2(0, 0))
META:GetSet("DrawScaleOffset", Vec2(1, 1))
META:GetSet("DrawPositionOffset", Vec2(0, 0))
META:GetSet("DrawAngleOffset", Ang3(0, 0, 0))
META:GetSet("DrawColor", Color(1, 1, 1, 1))
META:GetSet("DrawAlpha", 1)

function META:Initialize()
    self.DrawSizeOffset = Vec2(0, 0)
    self.DrawScaleOffset = Vec2(1, 1)
    self.DrawPositionOffset = Vec2(0, 0)
end

function META:OnDraw2D()
    if not self.Visible then return end

    local transform = self.Entity:GetComponent("gui_transform")
    if not transform then return end

    self:PreDraw(transform)
    self:Draw(transform)
    self:DrawChildren()
    self:PostDraw(transform)
end

function META:PreDraw(transform)
    if self.Clipping then
        -- Setup stencil clipping
        render2d.PushStencil()
        -- Draw stencil mask
    end

    -- Apply world matrix
    render2d.PushMatrix(transform:GetWorldMatrix())
end

function META:Draw(transform)
    -- Default: draw rounded rect
    local size = transform.Size + self.DrawSizeOffset
    gfx.RoundedRect(0, 0, size.x, size.y, self.BorderRadius, self.Color)
end

function META:DrawChildren()
    for _, child in ipairs(self.Entity:GetChildren()) do
        local child_drawing = child:GetComponent("gui_drawing")
        if child_drawing then
            child_drawing:OnDraw2D()
        end
    end
end

function META:PostDraw(transform)
    render2d.PopMatrix()

    if self.Clipping then
        render2d.PopStencil()
    end
end

-- Override point for custom drawing
function META:OnDraw() end
function META:OnPostDraw() end

return {Component = META:Register()}
```

### 2.3 Hover Component

**New File**: `goluwa/components/gui/hover.lua`

```lua
local prototype = require("prototype")
local gui = require("gui.gui")

local META = prototype.CreateTemplate("gui_hover")
META.ComponentName = "gui_hover"
META.Type = "gui_hover"
META.Require = {require("components.gui.transform").Component}

function META:IsHovered(mouse_pos)
    mouse_pos = mouse_pos or gui.mouse_pos
    if not mouse_pos then return false end

    local transform = self.Entity:GetComponent("gui_transform")
    local local_pos = transform:GlobalToLocal(mouse_pos)

    return local_pos.x >= 0 and
           local_pos.x <= transform.Size.x and
           local_pos.y >= 0 and
           local_pos.y <= transform.Size.y
end

function META:IsHoveredExclusively(mouse_pos)
    mouse_pos = mouse_pos or gui.mouse_pos
    return gui.GetHoveredEntity(mouse_pos) == self.Entity
end

return {Component = META:Register()}
```

### 2.4 Mouse Input Component

**New File**: `goluwa/components/gui/mouse_input.lua`

```lua
local prototype = require("prototype")

local META = prototype.CreateTemplate("gui_mouse_input")
META.ComponentName = "gui_mouse_input"
META.Type = "gui_mouse_input"
META.Require = {
    require("components.gui.transform").Component,
    require("components.gui.hover").Component,
}

META:GetSet("IgnoreMouseInput", false)
META:GetSet("FocusOnClick", false)
META:GetSet("BringToFrontOnClick", false)
META:GetSet("Cursor", "arrow")
META:GetSet("DragEnabled", false)

function META:Initialize()
    self.ButtonStates = {}
end

function META:MouseInput(button, press, local_pos)
    if self.IgnoreMouseInput then return false end

    self.ButtonStates[button] = press

    if press then
        if self.FocusOnClick then
            local focus = self.Entity:GetComponent("gui_focus")
            if focus then focus:RequestFocus() end
        end

        if self.BringToFrontOnClick then
            -- Move to end of parent's children list
            local parent = self.Entity:GetParent()
            if parent then
                self.Entity:SetParent(nil)
                self.Entity:SetParent(parent)
            end
        end

        if self.DragEnabled and button == "button_1" then
            -- Start drag
            local gui = require("gui.gui")
            gui.DraggingObject = self.Entity
            gui.DragMouseStart = gui.mouse_pos:Copy()
            local transform = self.Entity:GetComponent("gui_transform")
            gui.DragObjectStart = transform.Position:Copy()
        end
    end

    -- Call handler if present
    if self.OnMouseInput then
        return self:OnMouseInput(button, press, local_pos)
    end

    return false
end

function META:GetCursor()
    -- Check resize component for resize cursors
    local resize = self.Entity:GetComponent("gui_resize")
    if resize then
        local cursor = resize:GetResizeCursor()
        if cursor then return cursor end
    end

    return self.Cursor
end

return {Component = META:Register()}
```

### 2.5 Focus Component

**New File**: `goluwa/components/gui/focus.lua`

```lua
local prototype = require("prototype")
local gui = require("gui.gui")

local META = prototype.CreateTemplate("gui_focus")
META.ComponentName = "gui_focus"
META.Type = "gui_focus"

function META:RequestFocus()
    gui.focus_entity = self.Entity
end

function META:Unfocus()
    if gui.focus_entity == self.Entity then
        gui.focus_entity = nil
    end
end

function META:IsFocused()
    return gui.focus_entity == self.Entity
end

function META:MakePopup()
    self:RequestFocus()
    -- Move to front
    local parent = self.Entity:GetParent()
    if parent then
        self.Entity:SetParent(nil)
        self.Entity:SetParent(parent)
    end
end

return {Component = META:Register()}
```

### 2.6 Key Input Component

**New File**: `goluwa/components/gui/key_input.lua`

```lua
local prototype = require("prototype")

local META = prototype.CreateTemplate("gui_key_input")
META.ComponentName = "gui_key_input"
META.Type = "gui_key_input"
META.Require = {require("components.gui.focus").Component}

function META:KeyInput(key, press)
    if self.OnPreKeyInput then
        if self:OnPreKeyInput(key, press) then return true end
    end

    if self.OnKeyInput then
        if self:OnKeyInput(key, press) then return true end
    end

    if self.OnPostKeyInput then
        if self:OnPostKeyInput(key, press) then return true end
    end

    return false
end

function META:CharInput(char)
    if self.OnCharInput then
        return self:OnCharInput(char)
    end
    return false
end

return {Component = META:Register()}
```

### 2.7 Animation Component

**New File**: `goluwa/components/gui/animations.lua`

```lua
local prototype = require("prototype")
local easing = require("easing")

local META = prototype.CreateTemplate("gui_animations")
META.ComponentName = "gui_animations"
META.Type = "gui_animations"
META.Events = {"Update"}

function META:Initialize()
    self.ActiveAnimations = {}
end

function META:Animate(config)
    local var_name = config.var
    local to_value = config.to
    local duration = config.duration or 0.2
    local ease = config.ease or "outQuad"
    local spring = config.spring

    -- Get current value
    local getter = self.Entity["Get" .. var_name]
    if not getter then return end
    local from_value = getter(self.Entity)

    self.ActiveAnimations[var_name] = {
        from = from_value,
        to = to_value,
        duration = duration,
        elapsed = 0,
        ease = ease,
        spring = spring,
        setter = self.Entity["Set" .. var_name],
    }
end

function META:IsAnimating(var_name)
    return self.ActiveAnimations[var_name] ~= nil
end

function META:OnUpdate(dt)
    for var_name, anim in pairs(self.ActiveAnimations) do
        anim.elapsed = anim.elapsed + dt
        local t = math.min(anim.elapsed / anim.duration, 1)

        if anim.spring then
            -- Spring animation logic
            -- ... (implement spring physics)
        else
            -- Easing animation
            local eased_t = easing[anim.ease](t)
            local value = self:Lerp(anim.from, anim.to, eased_t)
            anim.setter(self.Entity, value)
        end

        if t >= 1 then
            self.ActiveAnimations[var_name] = nil
        end
    end
end

function META:Lerp(from, to, t)
    if type(from) == "number" then
        return from + (to - from) * t
    elseif from.Lerp then
        return from:Lerp(to, t)
    else
        -- Assume Vec2 or similar
        local result = from:Copy()
        result.x = from.x + (to.x - from.x) * t
        result.y = from.y + (to.y - from.y) * t
        return result
    end
end

return {Component = META:Register()}
```

### 2.8 Resize Component

**New File**: `goluwa/components/gui/resize.lua`

```lua
local prototype = require("prototype")
local Vec2 = require("structs.vec2")

local META = prototype.CreateTemplate("gui_resize")
META.ComponentName = "gui_resize"
META.Type = "gui_resize"
META.Require = {
    require("components.gui.transform").Component,
    require("components.gui.hover").Component,
}

META:GetSet("Resizable", false)
META:GetSet("ResizeBorder", 8)
META:GetSet("MinimumSize", Vec2(50, 50))

function META:Initialize()
    self.ResizeState = nil
end

function META:GetResizeDirection(mouse_pos)
    if not self.Resizable then return nil end

    local transform = self.Entity:GetComponent("gui_transform")
    local local_pos = transform:GlobalToLocal(mouse_pos)
    local size = transform.Size
    local border = self.ResizeBorder

    local on_left = local_pos.x < border
    local on_right = local_pos.x > size.x - border
    local on_top = local_pos.y < border
    local on_bottom = local_pos.y > size.y - border

    if on_top and on_left then return "nw"
    elseif on_top and on_right then return "ne"
    elseif on_bottom and on_left then return "sw"
    elseif on_bottom and on_right then return "se"
    elseif on_left then return "w"
    elseif on_right then return "e"
    elseif on_top then return "n"
    elseif on_bottom then return "s"
    end

    return nil
end

function META:GetResizeCursor()
    local gui = require("gui.gui")
    local dir = self:GetResizeDirection(gui.mouse_pos)

    if dir == "n" or dir == "s" then return "sizens"
    elseif dir == "e" or dir == "w" then return "sizewe"
    elseif dir == "nw" or dir == "se" then return "sizenwse"
    elseif dir == "ne" or dir == "sw" then return "sizenesw"
    end

    return nil
end

return {Component = META:Register()}
```

### 2.9 Deliverables

- [ ] `components/gui/transform.lua` created
- [ ] `components/gui/drawing.lua` created
- [ ] `components/gui/hover.lua` created
- [ ] `components/gui/mouse_input.lua` created
- [ ] `components/gui/focus.lua` created
- [ ] `components/gui/key_input.lua` created
- [ ] `components/gui/animations.lua` created
- [ ] `components/gui/resize.lua` created
- [ ] Unit tests for each component

---

## Phase 3: Advanced Features

### 3.1 Layout Component (Most Complex)

**New File**: `goluwa/components/gui/layout.lua`

The layout system is the most complex component (~1058 lines). Strategy:

1. Create layout component with dirty-flag system
2. Implement layout commands as methods
3. Create LayoutSystem that processes all dirty layouts

```lua
local prototype = require("prototype")
local Vec2 = require("structs.vec2")
local Rect = require("structs.rect")

local META = prototype.CreateTemplate("gui_layout")
META.ComponentName = "gui_layout"
META.Type = "gui_layout"
META.Require = {require("components.gui.transform").Component}

META:GetSet("MinimumSize", Vec2(0, 0))
META:GetSet("Margin", Rect(0, 0, 0, 0))
META:GetSet("Padding", Rect(0, 0, 0, 0))
META:GetSet("LayoutSize", nil)
META:GetSet("IgnoreLayout", false)
META:GetSet("CollisionGroup", "none")
META:GetSet("Layout", nil)  -- Layout commands table
META:GetSet("Flex", false)
META:GetSet("FlexDirection", "row")
META:GetSet("FlexGap", 0)
META:GetSet("FlexJustifyContent", "start")
META:GetSet("FlexAlignItems", "start")
META:GetSet("Stack", false)
META:GetSet("StackRight", true)
META:GetSet("StackDown", true)

function META:Initialize()
    self.dirty = true
    self.in_layout = 0
end

function META:Invalidate()
    if self.dirty then return end
    self.dirty = true

    -- Propagate to parent
    local parent = self.Entity:GetParent()
    if parent then
        local parent_layout = parent:GetComponent("gui_layout")
        if parent_layout then
            parent_layout:Invalidate()
        end
    end
end

function META:Calculate()
    if not self.dirty then return end
    if self.in_layout > 0 then return end

    self.in_layout = self.in_layout + 1

    -- Process flex layout
    if self.Flex then
        self:FlexLayout()
    end

    -- Execute layout commands
    self:ExecuteLayoutCommands()

    -- Process stack layout
    if self.Stack then
        self:StackChildren()
    end

    -- Recursively layout children
    for _, child in ipairs(self.Entity:GetChildren()) do
        local child_layout = child:GetComponent("gui_layout")
        if child_layout then
            child_layout:Calculate()
        end
    end

    self.dirty = false
    self.in_layout = self.in_layout - 1
end

-- Layout commands (Fill, Center, Move*, etc.)
-- These are implemented on the entity for LSX compatibility
-- ... (port from gui/components/layout.lua)

return {Component = META:Register()}
```

### 3.2 Layout System

**New File**: `goluwa/systems/gui/layout_system.lua`

```lua
local ecs = require("ecs")
local event = require("event")

local layout_system = {}

function layout_system.Update()
    -- Get root and traverse tree in order
    local gui_world = require("gui.gui_world")
    local root = gui_world.GetRoot()

    if root and root:IsValid() then
        local root_layout = root:GetComponent("gui_layout")
        if root_layout and root_layout.dirty then
            root_layout:Calculate()
        end
    end
end

-- Hook into the update loop
event.AddListener("Update", "gui_layout_system", function()
    layout_system.Update()
end)

return layout_system
```

### 3.3 Drawing System

**New File**: `goluwa/systems/gui/drawing_system.lua`

```lua
local ecs = require("ecs")
local event = require("event")
local render2d = require("render2d.render2d")

local drawing_system = {}

local function draw_recursive(entity)
    local drawing = entity:GetComponent("gui_drawing")
    if drawing and drawing.Visible then
        drawing:Draw()
    end

    for _, child in ipairs(entity:GetChildren()) do
        draw_recursive(child)
    end
end

function drawing_system.Draw()
    local gui_world = require("gui.gui_world")
    local root = gui_world.GetRoot()

    if root and root:IsValid() then
        render2d.ClearStencil()
        draw_recursive(root)
    end
end

event.AddListener("Draw2D", "gui_drawing_system", function()
    drawing_system.Draw()
end)

return drawing_system
```

### 3.4 Input System

**New File**: `goluwa/systems/gui/input_system.lua`

```lua
local ecs = require("ecs")
local event = require("event")
local window = require("window")

local input_system = {}
input_system.PressedObjects = {}
input_system.focus_entity = nil
input_system.mouse_pos = nil

local function get_hovered_entity(entity, mouse_pos)
    local drawing = entity:GetComponent("gui_drawing")
    if drawing and not drawing.Visible then return nil end

    local mouse_input = entity:GetComponent("gui_mouse_input")
    if mouse_input and mouse_input.IgnoreMouseInput then return nil end

    -- Check clipping
    if drawing and drawing.Clipping then
        local hover = entity:GetComponent("gui_hover")
        if hover and not hover:IsHovered(mouse_pos) then return nil end
    end

    -- Check children in reverse order (top-most first)
    local children = entity:GetChildren()
    for i = #children, 1, -1 do
        local found = get_hovered_entity(children[i], mouse_pos)
        if found then return found end
    end

    -- Check self
    local hover = entity:GetComponent("gui_hover")
    if hover and hover:IsHovered(mouse_pos) then
        return entity
    end

    return nil
end

function input_system.GetHoveredEntity(mouse_pos)
    local gui_world = require("gui.gui_world")
    local root = gui_world.GetRoot()
    if root and root:IsValid() then
        return get_hovered_entity(root, mouse_pos)
    end
    return nil
end

-- Mouse input handling
event.AddListener("MouseInput", "gui_input_system", function(button, press)
    local pos = window.GetMousePosition()
    input_system.mouse_pos = pos

    local target
    if press then
        target = input_system.GetHoveredEntity(pos)
        input_system.PressedObjects[button] = target
    else
        target = input_system.PressedObjects[button]
        input_system.PressedObjects[button] = nil

        if not (target and target:IsValid()) then
            target = input_system.GetHoveredEntity(pos)
        end
    end

    while target and target:IsValid() do
        local mouse_input = target:GetComponent("gui_mouse_input")
        if mouse_input then
            local transform = target:GetComponent("gui_transform")
            local local_pos = transform:GlobalToLocal(pos)
            if mouse_input:MouseInput(button, press, local_pos) then
                break
            end
        end
        target = target:GetParent()
    end
end)

-- Keyboard input handling
event.AddListener("KeyInput", "gui_input_system", function(key, press)
    local entity = input_system.focus_entity
    if entity and entity:IsValid() then
        local key_input = entity:GetComponent("gui_key_input")
        if key_input then
            key_input:KeyInput(key, press)
            return true
        end
    end
end)

event.AddListener("CharInput", "gui_input_system", function(char)
    local entity = input_system.focus_entity
    if entity and entity:IsValid() then
        local key_input = entity:GetComponent("gui_key_input")
        if key_input then
            key_input:CharInput(char)
            return true
        end
    end
end)

return input_system
```

### 3.5 Deliverables

- [ ] `components/gui/layout.lua` created (port all layout commands)
- [ ] `systems/gui/layout_system.lua` created
- [ ] `systems/gui/drawing_system.lua` created
- [ ] `systems/gui/input_system.lua` created
- [ ] Layout command tests
- [ ] System integration tests

---

## Phase 4: Integration

### 4.1 LSX Adapter for ECS

**Modify**: `goluwa/gui/gui.lua`

Create a new LSX adapter that works with ECS entities:

```lua
-- Add after existing LSX setup
local ECSAdapter = {
    Create = function(panel_type, parent)
        return require("gui.gui").CreateEntity(panel_type, parent)
    end,
    GetRoot = function()
        local gui_world = require("gui.gui_world")
        return gui_world.GetRoot()
    end,
    PostRender = function(entity)
        local gui_world = require("gui.gui_world")
        local root = gui_world.GetRoot()
        if root then
            local layout = root:GetComponent("gui_layout")
            if layout then layout:Calculate() end
        end
    end,
}

local lsx_ecs = LSX.New(ECSAdapter)
-- ... add hooks similar to existing lsx
gui.lsx_ecs = lsx_ecs
```

### 4.2 Entity Factory

**New File**: `goluwa/gui/entity_factory.lua`

```lua
local ecs = require("ecs")
local gui_world = require("gui.gui_world")

-- Component imports
local gui_transform = require("components.gui.transform").Component
local gui_drawing = require("components.gui.drawing").Component
local gui_hover = require("components.gui.hover").Component
local gui_mouse_input = require("components.gui.mouse_input").Component
local gui_focus = require("components.gui.focus").Component
local gui_key_input = require("components.gui.key_input").Component
local gui_animations = require("components.gui.animations").Component
local gui_resize = require("components.gui.resize").Component
local gui_layout = require("components.gui.layout").Component

local factory = {}

-- Predefined component sets for common panel types
factory.ComponentSets = {
    base = {
        gui_transform,
        gui_drawing,
        gui_hover,
        gui_mouse_input,
        gui_focus,
        gui_resize,
        gui_key_input,
        gui_animations,
        gui_layout,
    },
    text = {
        gui_transform,
        gui_drawing,
        gui_hover,
        gui_layout,
        -- text-specific component
    },
    button = {
        gui_transform,
        gui_drawing,
        gui_hover,
        gui_mouse_input,
        gui_focus,
        gui_animations,
        gui_layout,
    },
    -- Lightweight panel (no input, no animations)
    static = {
        gui_transform,
        gui_drawing,
        gui_layout,
    },
}

function factory.Create(panel_type, parent)
    parent = parent or gui_world.GetRoot()

    local entity = ecs.CreateEntity(panel_type, nil)
    entity.PanelType = panel_type
    entity.IsPanel = true

    -- Don't use 3D world parenting for GUI
    if parent and parent:IsValid() then
        entity:SetParent(parent)
    end

    -- Add components for this panel type
    local components = factory.ComponentSets[panel_type] or factory.ComponentSets.base
    for _, component in ipairs(components) do
        entity:AddComponent(component)
    end

    -- Initialize
    if entity.Initialize then entity:Initialize() end

    return entity
end

-- Compatibility method for old panel creation
function factory.CreatePanel(name, parent)
    return factory.Create(name, parent)
end

return factory
```

### 4.3 Bridge Layer (Old Panel ↔ New Entity)

**New File**: `goluwa/gui/bridge.lua`

During migration, this allows old panels and new entities to coexist:

```lua
local bridge = {}

-- Wrap an ECS entity to look like an old panel
function bridge.WrapEntity(entity)
    local wrapper = {}

    -- Forward transform methods
    local transform = entity:GetComponent("gui_transform")
    if transform then
        wrapper.GetPosition = function() return transform:GetPosition() end
        wrapper.SetPosition = function(_, v) transform:SetPosition(v) end
        wrapper.GetSize = function() return transform:GetSize() end
        wrapper.SetSize = function(_, v) transform:SetSize(v) end
        -- ... etc
    end

    -- Forward drawing methods
    local drawing = entity:GetComponent("gui_drawing")
    if drawing then
        wrapper.GetVisible = function() return drawing.Visible end
        wrapper.SetVisible = function(_, v) drawing.Visible = v end
        wrapper.GetColor = function() return drawing.Color end
        wrapper.SetColor = function(_, v) drawing.Color = v end
    end

    -- Forward layout methods
    local layout = entity:GetComponent("gui_layout")
    if layout then
        wrapper.SetLayout = function(_, cmds) layout:SetLayout(cmds) end
        wrapper.InvalidateLayout = function() layout:Invalidate() end
        wrapper.CalcLayout = function() layout:Calculate() end
    end

    -- Hierarchy
    wrapper.GetParent = function() return entity:GetParent() end
    wrapper.SetParent = function(_, p) entity:SetParent(p) end
    wrapper.GetChildren = function() return entity:GetChildren() end
    wrapper.AddChild = function(_, c) c:SetParent(entity) end

    -- Identity
    wrapper.IsValid = function() return entity:IsValid() end
    wrapper.Remove = function() entity:Remove() end
    wrapper.IsPanel = true
    wrapper._entity = entity

    return wrapper
end

-- Check if something is a wrapped entity
function bridge.IsWrappedEntity(obj)
    return obj and obj._entity ~= nil
end

-- Get underlying entity from wrapper
function bridge.GetEntity(obj)
    return obj._entity
end

return bridge
```

### 4.4 Deliverables

- [ ] LSX ECS adapter implemented
- [ ] `gui/entity_factory.lua` created
- [ ] `gui/bridge.lua` created
- [ ] LSX works with new ECS entities
- [ ] Integration tests

---

## Phase 5: Migration & Cleanup

### 5.1 Migrate Existing Panels

Order of migration (simplest to most complex):

1. **Text Panel** - Simple, few dependencies
2. **Frame Panel** - Moderate complexity
3. **Base Panel** - Core panel type
4. **Custom Panels** - Application-specific

For each panel:
1. Create ECS-based version
2. Update all references
3. Test thoroughly
4. Remove old version

### 5.2 Update gui.Create()

**Modify**: `goluwa/gui/gui.lua`

```lua
function gui.Create(class_name, parent)
    parent = parent or gui.Root

    -- Use new ECS factory
    local factory = require("gui.entity_factory")
    return factory.Create(class_name, parent)
end

-- Also expose entity-specific creation
function gui.CreateEntity(class_name, parent)
    local factory = require("gui.entity_factory")
    return factory.Create(class_name, parent)
end
```

### 5.3 Remove Old Code

Once migration is complete:

1. Remove `gui/panels/` directory (old panel implementations)
2. Remove `gui/components/` directory (old mixin-style components)
3. Remove bridge layer
4. Clean up deprecated methods

### 5.4 Deliverables

- [ ] All panels migrated to ECS
- [ ] `gui.Create()` uses ECS factory
- [ ] Old panel code removed
- [ ] Old component mixins removed
- [ ] Bridge layer removed
- [ ] Full regression testing passed

---

## Risk Assessment

### High Risk Areas

| Risk | Impact | Mitigation |
|------|--------|------------|
| Layout system complexity | Breaking existing UIs | Extensive testing, parallel development |
| LSX compatibility | Breaking declarative UIs | Adapter pattern, wrapper objects |
| Performance regression | Slower UI rendering | Benchmark before/after, optimize systems |
| Matrix invalidation | Visual glitches | Unit tests for transform hierarchy |

### Rollback Plan

Each phase boundary is a safe rollback point:

- **After Phase 1**: GUI world exists but isn't used
- **After Phase 2**: Components exist but panels still work
- **After Phase 3**: Systems exist but old rendering still active
- **After Phase 4**: Bridge allows mixed usage
- **After Phase 5**: Fully migrated (rollback requires restoring old files)

---

## File-by-File Changes

### New Files

```
goluwa/
├── gui/
│   ├── gui_world.lua           (Phase 1)
│   ├── entity_base.lua         (Phase 1)
│   ├── entity_factory.lua      (Phase 4)
│   └── bridge.lua              (Phase 4)
├── components/
│   └── gui/
│       ├── transform.lua       (Phase 2)
│       ├── drawing.lua         (Phase 2)
│       ├── hover.lua           (Phase 2)
│       ├── mouse_input.lua     (Phase 2)
│       ├── focus.lua           (Phase 2)
│       ├── key_input.lua       (Phase 2)
│       ├── animations.lua      (Phase 2)
│       ├── resize.lua          (Phase 2)
│       └── layout.lua          (Phase 3)
└── systems/
    └── gui/
        ├── layout_system.lua   (Phase 3)
        ├── drawing_system.lua  (Phase 3)
        └── input_system.lua    (Phase 3)
```

### Modified Files

```
goluwa/
├── ecs.lua                     (Phase 1: Add GUI world)
└── gui/
    └── gui.lua                 (Phase 4: LSX adapter, Phase 5: CreateEntity)
```

### Deleted Files (Phase 5)

```
goluwa/gui/
├── panels/
│   ├── base.lua
│   ├── frame.lua
│   ├── text.lua
│   └── text2.lua
└── components/
    ├── transform.lua
    ├── drawing.lua
    ├── hover.lua
    ├── mouse_input.lua
    ├── focus.lua
    ├── key_input.lua
    ├── animations.lua
    ├── resize.lua
    └── layout.lua
```

---

## Testing Strategy

### Unit Tests

Each component should have tests for:
- Initialization
- Property get/set
- Dependency injection (Require)
- Event handling

### Integration Tests

- Entity creation with all components
- Parent-child relationships
- Layout calculation
- Input routing
- LSX rendering

### Visual Tests

- Side-by-side comparison of old vs new rendering
- Animation smoothness
- Layout accuracy

### Performance Tests

- Benchmark entity creation (1000+ entities)
- Benchmark layout calculation (deep hierarchies)
- Benchmark rendering (complex UIs)

---

## Appendix: Component Dependency Graph

```
                    ┌─────────────┐
                    │  transform  │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
      ┌─────────┐    ┌─────────┐    ┌─────────┐
      │ drawing │    │  hover  │    │ layout  │
      └─────────┘    └────┬────┘    └─────────┘
                          │
              ┌───────────┴───────────┐
              │                       │
              ▼                       ▼
        ┌───────────┐           ┌─────────┐
        │mouse_input│           │ resize  │
        └─────┬─────┘           └─────────┘
              │
              ▼
        ┌─────────┐
        │  focus  │
        └────┬────┘
             │
             ▼
       ┌───────────┐
       │ key_input │
       └───────────┘

       ┌────────────┐
       │ animations │ (standalone)
       └────────────┘
```

---

## Conclusion

This migration plan provides a structured approach to converting the GUI system to ECS while:

1. Maintaining backward compatibility during migration
2. Leveraging existing ECS infrastructure
3. Improving code organization and testability
4. Enabling more flexible UI composition
5. Allowing efficient system-based processing

The phased approach ensures that the GUI remains functional throughout the migration, with clear rollback points if issues arise.
