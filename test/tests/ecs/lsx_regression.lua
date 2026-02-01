local T = require("test.environment")
local lsx = require("ecs.lsx_ecs")
local ecs = require("ecs.ecs")
local prototype = require("prototype")

T.Test("lsx multiple mount cleanup", function()
    ecs.Clear2DWorld()
    local root = ecs.Get2DWorld()
    
    local call_count = 0
    local function MyComponent()
        call_count = call_count + 1
        return lsx:Panel({ Name = "Child" })
    end

    -- First mount
    lsx:Mount(MyComponent, root)
    T(#root:GetChildren())["=="](1)
    T(root:GetChildren()[1]:GetName())["=="]("Child")

    -- Second mount on same root should replace the first one
    lsx:Mount(MyComponent, root)
    T(#root:GetChildren())["=="](1)
    T(call_count)["=="](2)
    
    ecs.Clear2DWorld()
end)

T.Test("lsx conditional nil rendering state persistence", function()
    ecs.Clear2DWorld()
    local root = ecs.Get2DWorld()
    root:AddComponent(require("ecs.components.2d.transform"))
    root:AddComponent(require("ecs.components.2d.layout"))
    
    local last_rendered_state = nil
    local function ToggleComponent(props)
        local state, set_state = lsx:UseState(0)
        last_rendered_state = state
        
        -- Use an effect to increment state once
        lsx:UseEffect(function()
            set_state(state + 1)
        end, {})

        if props.hide then
            return nil
        end
        
        return lsx:Panel({ Name = "VisiblePanel" })
    end

    -- 1. Mount hidden
    lsx:Mount({ToggleComponent, hide = true}, root)
    T(#root:GetChildren())["=="](0)
    
    -- Wait for Update for effects to run
    lsx:Update()
    
    -- 2. Update to visible - should have state 1 from the effect
    lsx:Mount({ToggleComponent, hide = false}, root)
    
    -- We need to wait for the render scheduled by set_state
    lsx:Update()
    
    T(root:IsValid())["=="](true)
    T(#root:GetChildren())["=="](1)
    T(last_rendered_state)["=="](1)
    
    ecs.Clear2DWorld()
end)

T.Test("lsx fragment cleanup", function()
    ecs.Clear2DWorld()
    local root = ecs.Get2DWorld()
    
    local function FragmentComp(props)
        if props.hide then return nil end
        return lsx:Fragment({
            lsx:Panel({ Name = "P1" }),
            lsx:Panel({ Name = "P2" }),
        })
    end
    
    lsx:Mount({FragmentComp, hide = false}, root)
    T(#root:GetChildren())["=="](2)
    
    lsx:Mount({FragmentComp, hide = true}, root)
    T(#root:GetChildren())["=="](0)
    
    ecs.Clear2DWorld()
end)
