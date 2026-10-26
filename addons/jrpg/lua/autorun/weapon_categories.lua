local Color = import("goluwa/structs/color.lua")
local weapon_categories = import("lua/weapon_categories.lua")
weapon_categories.Register{Name = "melee", Label = "MELEE", Color = Color(0.9, 0.3, 0.3, 1)}
weapon_categories.Register{Name = "magic", Label = "MAGIC", Color = Color(0.65, 0.4, 1, 1)}
weapon_categories.Register{Name = "defense", Label = "GUARD", Color = Color(0.95, 0.8, 0.3, 1)}
