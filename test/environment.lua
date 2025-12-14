do
	local test = require("goluwa.helpers.test")
	_G.test = test.Test
	_G.run_for = test.RunFor
	_G.run_until = test.RunUntil
end

do
	local attest = require("goluwa.helpers.attest")
	_G.attest = attest
	_G.eq = attest.equal
	_G.equal = attest.equal
	_G.ok = attest.ok
end
