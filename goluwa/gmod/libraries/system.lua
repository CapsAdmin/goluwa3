local system = gine.env.system

function system.IsLinux()
	return jit.os == "Linux"
end

function system.IsWindows()
	return jit.os == "Windows"
end

function system.IsOSX()
	return jit.os == "OSX"
end

function system.GetCountry()
	return "NO"
end

function system.BatteryPower()
	return 255
end