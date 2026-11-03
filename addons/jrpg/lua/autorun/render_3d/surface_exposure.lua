local surface_conditions = import("goluwa/render3d/surface_conditions.lua")
surface_conditions.SetExposure(
	"fire",
	{
		{Overlay = "status_fire", Channel = "heat", Threshold = 0.2, FadeOut = 0.6},
		{Overlay = "charred", Channel = "heat", Threshold = 0.2, Latch = 0.35},
	}
)
surface_conditions.SetExposure(
	"frost",
	{{Overlay = "status_frozen", Channel = "frost", Threshold = 0.3, FadeOut = 0.6}}
)
surface_conditions.SetExposure(
	"poison",
	{{Overlay = "status_poison", Channel = "poison", Threshold = 0.2, FadeOut = 0.6}}
)
