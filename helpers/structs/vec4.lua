local structs = require("helpers.structs.structs")
local META = structs.Template("Vec4")
META.NumberType = "double"
META.Args = {{"x", "y", "z", "w"}, {"r", "g", "b", "a"}, {"u", "v", "s", "t"}}
structs.AddAllOperators(META)
structs.AddOperator(META, "generic_vector")
structs.Swizzle(META)
structs.Swizzle(META, 3, "structs.Vec3")
structs.Swizzle(META, 2, "structs.Vec2")
return structs.Register(META)
