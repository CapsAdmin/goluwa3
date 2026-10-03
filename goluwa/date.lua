local HOURPERDAY = 24
local MINPERHOUR = 60
local MINPERDAY = 1440
local SECPERMIN = 60
local SECPERHOUR = 3600
local SECPERDAY = 86400
local TICKSPERSEC = 1000000
local TICKSPERDAY = 86400000000
local TICKSPERHOUR = 3600000000
local TICKSPERMIN = 60000000
local DAYNUM_MAX = 365242500
local DAYNUM_MIN = -365242500
local DAYNUM_DEF = 0
local _
local type = type
local pairs = pairs
local error = error
local assert = assert
local tonumber = tonumber
local tostring = tostring
local string = string
local math = math
local os = os
local unpack = unpack or table.unpack
local setmetatable = setmetatable
local getmetatable = getmetatable
local fmt = string.format
local lwr = string.lower
local rep = string.rep
local len = string.len
local sub = string.sub
local gsub = string.gsub
local gmatch = string.gmatch or string.gfind
local find = string.find
local ostime = os.time
local osdate = os.date
local floor = math.floor
local ceil = math.ceil
local abs = math.abs

local function fix(n)
	n = tonumber(n)
	return n and ((n > 0 and floor or ceil)(n))
end

local function mod(n, d)
	return n - d * floor(n / d)
end

local function inlist(str, tbl, ml, tn)
	local sl = len(str)

	if sl < (ml or 0) then return nil end

	str = lwr(str)

	for k, v in pairs(tbl) do
		if str == lwr(sub(v, 1, sl)) then
			if tn then tn[0] = k end

			return k
		end
	end
end

local function fnil() end

local DATE_EPOCH
local sl_weekdays = {
	[0] = "Sunday",
	[1] = "Monday",
	[2] = "Tuesday",
	[3] = "Wednesday",
	[4] = "Thursday",
	[5] = "Friday",
	[6] = "Saturday",
	[7] = "Sun",
	[8] = "Mon",
	[9] = "Tue",
	[10] = "Wed",
	[11] = "Thu",
	[12] = "Fri",
	[13] = "Sat",
}
local sl_meridian = {[-1] = "AM", [1] = "PM"}
local sl_months = {
	[00] = "January",
	[01] = "February",
	[02] = "March",
	[03] = "April",
	[04] = "May",
	[05] = "June",
	[06] = "July",
	[07] = "August",
	[08] = "September",
	[09] = "October",
	[10] = "November",
	[11] = "December",
	[12] = "Jan",
	[13] = "Feb",
	[14] = "Mar",
	[15] = "Apr",
	[16] = "May",
	[17] = "Jun",
	[18] = "Jul",
	[19] = "Aug",
	[20] = "Sep",
	[21] = "Oct",
	[22] = "Nov",
	[23] = "Dec",
}
local sl_timezone = {
	[000] = "utc",
	[0.2] = "gmt",
	[300] = "est",
	[240] = "edt",
	[360] = "cst",
	[300.2] = "cdt",
	[420] = "mst",
	[360.2] = "mdt",
	[480] = "pst",
	[420.2] = "pdt",
}

local function setticks(t)
	TICKSPERSEC = t
	TICKSPERDAY = SECPERDAY * TICKSPERSEC
	TICKSPERHOUR = SECPERHOUR * TICKSPERSEC
	TICKSPERMIN = SECPERMIN * TICKSPERSEC
end

local function isleapyear(y)
	return (mod(y, 4) == 0 and (mod(y, 100) ~= 0 or mod(y, 400) == 0))
end

local function dayfromyear(y)
	return 365 * y + floor(y / 4) - floor(y / 100) + floor(y / 400)
end

local function makedaynum(y, m, d)
	local mm = mod(mod(m, 12) + 10, 12)
	return dayfromyear(y + floor(m / 12) - floor(mm / 10)) + floor((mm * 306 + 5) / 10) + d - 307
end

local function breakdaynum(g)
	local g = g + 306
	local y = floor((10000 * g + 14780) / 3652425)
	local d = g - dayfromyear(y)

	if d < 0 then
		y = y - 1
		d = g - dayfromyear(y)
	end

	local mi = floor((100 * d + 52) / 3060)
	return (floor((mi + 2) / 12) + y),
	mod(mi + 2, 12),
	(d - floor((mi * 306 + 5) / 10) + 1)
end

local function makedayfrc(h, r, s, t)
	return ((h * 60 + r) * 60 + s) * TICKSPERSEC + t
end

local function breakdayfrc(df)
	return mod(floor(df / TICKSPERHOUR), HOURPERDAY),
	mod(floor(df / TICKSPERMIN), MINPERHOUR),
	mod(floor(df / TICKSPERSEC), SECPERMIN),
	mod(df, TICKSPERSEC)
end

local function weekday(dn)
	return mod(dn + 1, 7)
end

local function yearday(dn)
	return dn - dayfromyear((breakdaynum(dn)) - 1)
end

local function getmontharg(v)
	local m = tonumber(v)
	return (m and fix(m - 1)) or inlist(tostring(v) or "", sl_months, 2)
end

local function isow1(y)
	local f = makedaynum(y, 0, 4)
	local d = weekday(f)
	d = d == 0 and 7 or d
	return f + (1 - d)
end

local function isowy(dn)
	local w1
	local y = (breakdaynum(dn))

	if dn >= makedaynum(y, 11, 29) then
		w1 = isow1(y + 1)

		if dn < w1 then w1 = isow1(y) else y = y + 1 end
	else
		w1 = isow1(y)

		if dn < w1 then
			w1 = isow1(y - 1)
			y = y - 1
		end
	end

	return floor((dn - w1) / 7) + 1, y
end

local function isoy(dn)
	local y = (breakdaynum(dn))
	return y + (
			(
				(
					dn >= makedaynum(y, 11, 29)
				) and
				(
					dn >= isow1(y + 1)
				)
			)
			and
			1 or
			(
				dn < isow1(y) and
				-1 or
				0
			)
		)
end

local function makedaynum_isoywd(y, w, d)
	return isow1(y) + 7 * w + d - 8
end

local fmtstr = "%x %X"
local date = {}
setmetatable(date, date)
date.version = 20010001
local dobj = {}
dobj.__index = dobj
dobj.__metatable = dobj

local function date_error_arg()
	return error("invalid argument(s)", 0)
end

local function date_new(dn, df)
	return setmetatable({daynum = dn, dayfrc = df}, dobj)
end

local date_epoch, yt

local function getequivyear(y)
	assert(not yt)
	yt = {}
	local de = date_epoch:copy()
	local dw, dy

	for _ = 0, 3000 do
		de:setyear(de:getyear() + 1, 1, 1)
		dy = de:getyear()
		dw = de:getweekday() * (isleapyear(dy) and -1 or 1)

		if not yt[dw] then yt[dw] = dy end

		if
			yt[1] and
			yt[2] and
			yt[3] and
			yt[4] and
			yt[5] and
			yt[6] and
			yt[7] and
			yt[-1] and
			yt[-2] and
			yt[-3] and
			yt[-4] and
			yt[-5] and
			yt[-6] and
			yt[-7]
		then
			getequivyear = function(y)
				return yt[(weekday(makedaynum(y, 0, 1)) + 1) * (isleapyear(y) and -1 or 1)]
			end
			return getequivyear(y)
		end
	end
end

local function totv(y, m, d, h, r, s)
	return (makedaynum(y, m, d) - DATE_EPOCH) * SECPERDAY + ((h * 60 + r) * 60 + s)
end

local function tmtotv(tm)
	return tm and totv(tm.year, tm.month - 1, tm.day, tm.hour, tm.min, tm.sec)
end

local function getbiasutc2(self)
	local y, m, d = breakdaynum(self.daynum)
	local h, r, s = breakdayfrc(self.dayfrc)
	local tvu = totv(y, m, d, h, r, s)
	local tml = osdate("*t", tvu)

	if (not tml) or (tml.year > (y + 1) or tml.year < (y - 1)) then
		y = getequivyear(y)
		tvu = totv(y, m, d, h, r, s)
		tml = osdate("*t", tvu)
	end

	local tvl = tmtotv(tml)

	if tvu and tvl then
		return tvu - tvl, tvu, tvl
	else
		return error("failed to get bias from utc time")
	end
end

local function getbiasloc2(daynum, dayfrc)
	local tvu
	local y, m, d = breakdaynum(daynum)
	local h, r, s = breakdayfrc(dayfrc)
	local tml = {year = y, month = m + 1, day = d, hour = h, min = r, sec = s}
	local tvl = tmtotv(tml)

	local function chkutc()
		tml.isdst = nil
		local tvug = ostime(tml)

		if tvug and (tvl == tmtotv(osdate("*t", tvug))) then
			tvu = tvug
			return
		end

		tml.isdst = true
		local tvud = ostime(tml)

		if tvud and (tvl == tmtotv(osdate("*t", tvud))) then
			tvu = tvud
			return
		end

		tvu = tvud or tvug
	end

	chkutc()

	if not tvu then
		tml.year = getequivyear(y)
		tvl = tmtotv(tml)
		chkutc()
	end

	return ((tvu and tvl) and (tvu - tvl)) or error("failed to get bias from local time"),
	tvu,
	tvl
end

local strwalker = {}
strwalker.__index = strwalker

local function newstrwalker(s)
	return setmetatable({s = s, i = 1, e = 1, c = len(s)}, strwalker)
end

function strwalker:aimchr()
	return "\n" .. self.s .. "\n" .. rep(".", self.e - 1) .. "^"
end

function strwalker:finish()
	return self.i > self.c
end

function strwalker:back()
	self.i = self.e
	return self
end

function strwalker:restart()
	self.i, self.e = 1, 1
	return self
end

function strwalker:match(s)
	return (find(self.s, s, self.i))
end

function strwalker:__call(s, f)
	local is, ie
	is, ie, self[1], self[2], self[3], self[4], self[5] = find(self.s, s, self.i)

	if is then
		self.e, self.i = self.i, 1 + ie

		if f then f(unpack(self)) end

		return self
	end
end

local function date_parse(str)
	local y, m, d, h, r, s, z, w, u, j, e, x, c, dn, df
	local sw = newstrwalker(gsub(gsub(str, "(%b())", ""), "^(%s*)", ""))

	local function error_dup(q)
		error("duplicate value: " .. (q or "") .. sw:aimchr())
	end

	local function error_syn(q)
		error("syntax error: " .. (q or "") .. sw:aimchr())
	end

	local function error_inv(q)
		error("invalid date: " .. (q or "") .. sw:aimchr())
	end

	local function sety(q)
		y = y and error_dup() or tonumber(q)
	end

	local function setm(q)
		m = (m or w or j) and error_dup(m or w or j) or tonumber(q)
	end

	local function setd(q)
		d = d and error_dup() or tonumber(q)
	end

	local function seth(q)
		h = h and error_dup() or tonumber(q)
	end

	local function setr(q)
		r = r and error_dup() or tonumber(q)
	end

	local function sets(q)
		s = s and error_dup() or tonumber(q)
	end

	local function adds(q)
		s = s + tonumber(q)
	end

	local function setj(q)
		j = (m or w or j) and error_dup() or tonumber(q)
	end

	local function setz(q)
		z = (z ~= 0 and z) and error_dup() or q
	end

	local function setzn(zs, zn)
		zn = tonumber(zn)
		setz(
			(
					(
						zn < 24
					)
					and
					(
						zn * 60
					)
					or
					(
						mod(zn, 100) + floor(zn / 100) * 60
					)
				) * (
					zs == "+" and
					-1 or
					1
				)
		)
	end

	local function setzc(zs, zh, zm)
		setz(((tonumber(zh) * 60) + tonumber(zm)) * (zs == "+" and -1 or 1))
	end

	if
		not (
			sw("^(%d%d%d%d)", sety) and
			(
				sw("^(%-?)(%d%d)%1(%d%d)", function(_, a, b)
					setm(tonumber(a))
					setd(tonumber(b))
				end) or
				sw("^(%-?)[Ww](%d%d)%1(%d?)", function(_, a, b)
					w, u = tonumber(a), tonumber(b or 1)
				end) or
				sw("^%-?(%d%d%d)", setj) or
				sw("^%-?(%d%d)", function(a)
					setm(a)
					setd(1)
				end)
			)
			and
			(
				(
					sw("^%s*[Tt]?(%d%d):?", seth) and
					sw("^(%d%d):?", setr) and
					sw("^(%d%d)", sets) and
					sw("^(%.%d+)", adds)
				) or
				sw:finish() or
				(
					sw("^%s*$") or
					sw("^%s*[Zz]%s*$") or
					sw("^%s-([%+%-])(%d%d):?(%d%d)%s*$", setzc) or
					sw("^%s*([%+%-])(%d%d)%s*$", setzn)
				)
			)
		)
	then
		sw:restart()
		y, m, d, h, r, s, z, w, u, j = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil

		repeat
			if sw("^[tT:]?%s*(%d%d?):", seth) then
				_ = sw("^%s*(%d%d?)", setr) and sw("^%s*:%s*(%d%d?)", sets) and sw("^(%.%d+)", adds)
			elseif sw("^(%d+)[/\\%s,-]?%s*") then
				x, c = tonumber(sw[1]), len(sw[1])

				if (x >= 70) or (m and d and (not y)) or (c > 3) then
					sety(x + ((x >= 100 or c > 3) and 0 or 1900))
				else
					if m then setd(x) else m = x end
				end
			elseif sw("^(%a+)[/\\%s,-]?%s*") then
				x = sw[1]

				if inlist(x, sl_months, 2, sw) then
					if m and (not d) and (not y) then d, m = m, false end

					setm(mod(sw[0], 12) + 1)
				elseif inlist(x, sl_timezone, 2, sw) then
					c = fix(sw[0])

					if c ~= 0 then setz(c, x) end
				elseif not inlist(x, sl_weekdays, 2, sw) then
					sw:back()

					if
						sw("^([bB])%s*(%.?)%s*[Cc]%s*(%2)%s*[Ee]%s*(%2)%s*") or
						sw("^([bB])%s*(%.?)%s*[Cc]%s*(%2)%s*")
					then
						e = e and error_dup() or -1
					elseif sw("^([aA])%s*(%.?)%s*[Dd]%s*(%2)%s*") or sw("^([cC])%s*(%.?)%s*[Ee]%s*(%2)%s*") then
						e = e and error_dup() or 1
					elseif sw("^([PApa])%s*(%.?)%s*[Mm]?%s*(%2)%s*") then
						x = lwr(sw[1])

						if (not h) or (h > 12) or (h < 0) then return error_inv() end

						if x == "a" and h == 12 then h = 0 end

						if x == "p" and h ~= 12 then h = h + 12 end
					else
						error_syn()
					end
				end
			elseif
				not (
					sw("^([+-])(%d%d?):(%d%d)", setzc) or
					sw("^([+-])(%d+)", setzn) or
					sw("^[Zz]%s*$")
				)
			then
				error_syn("?")
			end

			sw("^%s*")		
		until sw:finish()
	end

	if
		(
			not y and
			not h
		)
		or
		(
			(
				m and
				not d
			)
			or
			(
				d and
				not m
			)
		)
		or
		(
			(
				m and
				w
			)
			or
			(
				m and
				j
			)
			or
			(
				j and
				w
			)
		)
	then
		return error_inv("!")
	end

	if m then m = m - 1 end

	if e and e < 0 and y > 0 then y = 1 - y end

	dn = (
			y and
			(
				(
					w and
					makedaynum_isoywd(y, w, u)
				) or
				(
					j and
					makedaynum(y, 0, j)
				)
				or
				makedaynum(y, m, d)
			)
		)
		or
		DAYNUM_DEF
	df = makedayfrc(h or 0, r or 0, s or 0, 0) + ((z or 0) * TICKSPERMIN)
	return date_new(dn, df)
end

local function date_fromtable(v)
	local y, m, d = fix(v.year), getmontharg(v.month), fix(v.day)
	local h, r, s, t = tonumber(v.hour), tonumber(v.min), tonumber(v.sec), tonumber(v.ticks)

	if (y or m or d) and (not (y and m and d)) then
		return error("incomplete table")
	end

	return (
			y or
			h or
			r or
			s or
			t
		)
		and
		date_new(
			y and makedaynum(y, m, d) or DAYNUM_DEF,
			makedayfrc(h or 0, r or 0, s or 0, t or 0)
		)
end

local tmap = {
	["number"] = function(v)
		return date_epoch:copy():addseconds(v)
	end,
	["string"] = function(v)
		return date_parse(v)
	end,
	["boolean"] = function(v)
		return date_fromtable(osdate(v and "!*t" or "*t"))
	end,
	["table"] = function(v)
		local ref = getmetatable(v) == dobj
		return ref and v or date_fromtable(v), ref
	end,
}

local function date_getdobj(v)
	local o, r = (tmap[type(v)] or fnil)(v)
	return (o and o:normalize() or error("invalid date time value")), r
end

local function date_from(arg1, arg2, arg3, arg4, arg5, arg6, arg7)
	local y, m, d = fix(arg1), getmontharg(arg2), fix(arg3)
	local h, r, s, t = tonumber(arg4 or 0),
	tonumber(arg5 or 0),
	tonumber(arg6 or 0),
	tonumber(arg7 or 0)

	if y and m and d and h and r and s and t then
		return date_new(makedaynum(y, m, d), makedayfrc(h, r, s, t)):normalize()
	else
		return date_error_arg()
	end
end

function dobj:normalize()
	local dn, df = fix(self.daynum), self.dayfrc
	self.daynum, self.dayfrc = dn + floor(df / TICKSPERDAY), mod(df, TICKSPERDAY)
	return (
			dn >= DAYNUM_MIN and
			dn <= DAYNUM_MAX
		)
		and
		self or
		error("date beyond imposed limits:" .. self)
end

function dobj:getdate()
	local y, m, d = breakdaynum(self.daynum)
	return y, m + 1, d
end

function dobj:gettime()
	return breakdayfrc(self.dayfrc)
end

function dobj:getclockhour()
	local h = self:gethours()
	return h > 12 and mod(h, 12) or (h == 0 and 12 or h)
end

function dobj:getyearday()
	return yearday(self.daynum) + 1
end

function dobj:getweekday()
	return weekday(self.daynum) + 1
end

function dobj:getyear()
	local r, _, _ = breakdaynum(self.daynum)
	return r
end

function dobj:getmonth()
	local _, r, _ = breakdaynum(self.daynum)
	return r + 1
end

function dobj:getday()
	local _, _, r = breakdaynum(self.daynum)
	return r
end

function dobj:gethours()
	return mod(floor(self.dayfrc / TICKSPERHOUR), HOURPERDAY)
end

function dobj:getminutes()
	return mod(floor(self.dayfrc / TICKSPERMIN), MINPERHOUR)
end

function dobj:getseconds()
	return mod(floor(self.dayfrc / TICKSPERSEC), SECPERMIN)
end

function dobj:getfracsec()
	return mod(floor(self.dayfrc / TICKSPERSEC), SECPERMIN) + (
			mod(self.dayfrc, TICKSPERSEC) / TICKSPERSEC
		)
end

function dobj:getticks(u)
	local x = mod(self.dayfrc, TICKSPERSEC)
	return u and ((x * u) / TICKSPERSEC) or x
end

function dobj:getweeknumber(wdb)
	local wd, yd = weekday(self.daynum), yearday(self.daynum)

	if wdb then
		wdb = tonumber(wdb)

		if wdb then
			wd = mod(wd - (wdb - 1), 7)
		else
			return date_error_arg()
		end
	end

	return (yd < wd and 0) or (floor(yd / 7) + ((mod(yd, 7) >= wd) and 1 or 0))
end

function dobj:getisoweekday()
	return mod(weekday(self.daynum) - 1, 7) + 1
end

function dobj:getisoweeknumber()
	return (isowy(self.daynum))
end

function dobj:getisoyear()
	return isoy(self.daynum)
end

function dobj:getisodate()
	local w, y = isowy(self.daynum)
	return y, w, self:getisoweekday()
end

function dobj:setisoyear(y, w, d)
	local cy, cw, cd = self:getisodate()

	if y then cy = fix(tonumber(y)) end

	if w then cw = fix(tonumber(w)) end

	if d then cd = fix(tonumber(d)) end

	if cy and cw and cd then
		self.daynum = makedaynum_isoywd(cy, cw, cd)
		return self:normalize()
	else
		return date_error_arg()
	end
end

function dobj:setisoweekday(d)
	return self:setisoyear(nil, nil, d)
end

function dobj:setisoweeknumber(w, d)
	return self:setisoyear(nil, w, d)
end

function dobj:setyear(y, m, d)
	local cy, cm, cd = breakdaynum(self.daynum)

	if y then cy = fix(tonumber(y)) end

	if m then cm = getmontharg(m) end

	if d then cd = fix(tonumber(d)) end

	if cy and cm and cd then
		self.daynum = makedaynum(cy, cm, cd)
		return self:normalize()
	else
		return date_error_arg()
	end
end

function dobj:setmonth(m, d)
	return self:setyear(nil, m, d)
end

function dobj:setday(d)
	return self:setyear(nil, nil, d)
end

function dobj:sethours(h, m, s, t)
	local ch, cm, cs, ck = breakdayfrc(self.dayfrc)
	ch, cm, cs, ck = tonumber(h or ch), tonumber(m or cm), tonumber(s or cs), tonumber(t or ck)

	if ch and cm and cs and ck then
		self.dayfrc = makedayfrc(ch, cm, cs, ck)
		return self:normalize()
	else
		return date_error_arg()
	end
end

function dobj:setminutes(m, s, t)
	return self:sethours(nil, m, s, t)
end

function dobj:setseconds(s, t)
	return self:sethours(nil, nil, s, t)
end

function dobj:setticks(t)
	return self:sethours(nil, nil, nil, t)
end

function dobj:spanticks()
	return (self.daynum * TICKSPERDAY + self.dayfrc)
end

function dobj:spanseconds()
	return (self.daynum * TICKSPERDAY + self.dayfrc) / TICKSPERSEC
end

function dobj:spanminutes()
	return (self.daynum * TICKSPERDAY + self.dayfrc) / TICKSPERMIN
end

function dobj:spanhours()
	return (self.daynum * TICKSPERDAY + self.dayfrc) / TICKSPERHOUR
end

function dobj:spandays()
	return (self.daynum * TICKSPERDAY + self.dayfrc) / TICKSPERDAY
end

function dobj:addyears(y, m, d)
	local cy, cm, cd = breakdaynum(self.daynum)

	if y then y = fix(tonumber(y)) else y = 0 end

	if m then m = fix(tonumber(m)) else m = 0 end

	if d then d = fix(tonumber(d)) else d = 0 end

	if y and m and d then
		self.daynum = makedaynum(cy + y, cm + m, cd + d)
		return self:normalize()
	else
		return date_error_arg()
	end
end

function dobj:addmonths(m, d)
	return self:addyears(nil, m, d)
end

local function dobj_adddayfrc(self, n, pt, pd)
	n = tonumber(n)

	if n then
		local x = floor(n / pd)
		self.daynum = self.daynum + x
		self.dayfrc = self.dayfrc + (n - x * pd) * pt
		return self:normalize()
	else
		return date_error_arg()
	end
end

function dobj:adddays(n)
	return dobj_adddayfrc(self, n, TICKSPERDAY, 1)
end

function dobj:addhours(n)
	return dobj_adddayfrc(self, n, TICKSPERHOUR, HOURPERDAY)
end

function dobj:addminutes(n)
	return dobj_adddayfrc(self, n, TICKSPERMIN, MINPERDAY)
end

function dobj:addseconds(n)
	return dobj_adddayfrc(self, n, TICKSPERSEC, SECPERDAY)
end

function dobj:addticks(n)
	return dobj_adddayfrc(self, n, 1, TICKSPERDAY)
end

local tvspec = {
	["%a"] = function(self)
		return sl_weekdays[weekday(self.daynum) + 7]
	end,
	["%A"] = function(self)
		return sl_weekdays[weekday(self.daynum)]
	end,
	["%b"] = function(self)
		return sl_months[self:getmonth() - 1 + 12]
	end,
	["%B"] = function(self)
		return sl_months[self:getmonth() - 1]
	end,
	["%C"] = function(self)
		return fmt("%.2d", fix(self:getyear() / 100))
	end,
	["%d"] = function(self)
		return fmt("%.2d", self:getday())
	end,
	["%g"] = function(self)
		return fmt("%.2d", mod(self:getisoyear(), 100))
	end,
	["%G"] = function(self)
		return fmt("%.4d", self:getisoyear())
	end,
	["%h"] = function(self)
		return self:fmt0("%b")
	end,
	["%H"] = function(self)
		return fmt("%.2d", self:gethours())
	end,
	["%I"] = function(self)
		return fmt("%.2d", self:getclockhour())
	end,
	["%j"] = function(self)
		return fmt("%.3d", self:getyearday())
	end,
	["%m"] = function(self)
		return fmt("%.2d", self:getmonth())
	end,
	["%M"] = function(self)
		return fmt("%.2d", self:getminutes())
	end,
	["%p"] = function(self)
		return sl_meridian[self:gethours() > 11 and 1 or -1]
	end,
	["%S"] = function(self)
		return fmt("%.2d", self:getseconds())
	end,
	["%u"] = function(self)
		return self:getisoweekday()
	end,
	["%U"] = function(self)
		return fmt("%.2d", self:getweeknumber())
	end,
	["%V"] = function(self)
		return fmt("%.2d", self:getisoweeknumber())
	end,
	["%w"] = function(self)
		return self:getweekday() - 1
	end,
	["%W"] = function(self)
		return fmt("%.2d", self:getweeknumber(2))
	end,
	["%y"] = function(self)
		return fmt("%.2d", mod(self:getyear(), 100))
	end,
	["%Y"] = function(self)
		return fmt("%.4d", self:getyear())
	end,
	["%z"] = function(self)
		local b = -self:getbias()
		local x = abs(b)
		return fmt("%s%.4d", b < 0 and "-" or "+", fix(x / 60) * 100 + floor(mod(x, 60)))
	end,
	["%Z"] = function(self)
		return self:gettzname()
	end,
	["%\b"] = function(self)
		local x = self:getyear()
		return fmt("%.4d%s", x > 0 and x or (-x + 1), x > 0 and "" or " BCE")
	end,
	["%\f"] = function(self)
		local x = self:getfracsec()
		return fmt("%s%.9f", x >= 10 and "" or "0", x)
	end,
	["%%"] = function(self)
		return "%"
	end,
	["%r"] = function(self)
		return self:fmt0("%I:%M:%S %p")
	end,
	["%R"] = function(self)
		return self:fmt0("%I:%M")
	end,
	["%T"] = function(self)
		return self:fmt0("%H:%M:%S")
	end,
	["%D"] = function(self)
		return self:fmt0("%m/%d/%y")
	end,
	["%F"] = function(self)
		return self:fmt0("%Y-%m-%d")
	end,
	["%c"] = function(self)
		return self:fmt0("%x %X")
	end,
	["%x"] = function(self)
		return self:fmt0("%a %b %d %\b")
	end,
	["%X"] = function(self)
		return self:fmt0("%H:%M:%\f")
	end,
	["${iso}"] = function(self)
		return self:fmt0("%Y-%m-%dT%T")
	end,
	["${http}"] = function(self)
		return self:fmt0("%a, %d %b %Y %T GMT")
	end,
	["${ctime}"] = function(self)
		return self:fmt0("%a %b %d %T GMT %Y")
	end,
	["${rfc850}"] = function(self)
		return self:fmt0("%A, %d-%b-%y %T GMT")
	end,
	["${rfc1123}"] = function(self)
		return self:fmt0("%a, %d %b %Y %T GMT")
	end,
	["${asctime}"] = function(self)
		return self:fmt0("%a %b %d %T %Y")
	end,
}

function dobj:fmt0(str)
	return (
		gsub(str, "%%[%a%%\b\f]", function(x)
			local f = tvspec[x]
			return (f and f(self)) or x
		end)
	)
end

function dobj:fmt(str)
	str = str or self.fmtstr or fmtstr
	return self:fmt0(
		(
				gmatch(str, "${%w+}")
			) and
			(
				gsub(str, "${%w+}", function(x)
					local f = tvspec[x]
					return (f and f(self)) or x
				end)
			) or
			str
	)
end

function dobj.__lt(a, b)
	if (a.daynum == b.daynum) then
		return (a.dayfrc < b.dayfrc)
	else
		return (a.daynum < b.daynum)
	end
end

function dobj.__le(a, b)
	if (a.daynum == b.daynum) then
		return (a.dayfrc <= b.dayfrc)
	else
		return (a.daynum <= b.daynum)
	end
end

function dobj.__eq(a, b)
	return (a.daynum == b.daynum) and (a.dayfrc == b.dayfrc)
end

function dobj.__sub(a, b)
	local d1, d2 = date_getdobj(a), date_getdobj(b)
	local d0 = d1 and d2 and date_new(d1.daynum - d2.daynum, d1.dayfrc - d2.dayfrc)
	return d0 and d0:normalize()
end

function dobj.__add(a, b)
	local d1, d2 = date_getdobj(a), date_getdobj(b)
	local d0 = d1 and d2 and date_new(d1.daynum + d2.daynum, d1.dayfrc + d2.dayfrc)
	return d0 and d0:normalize()
end

function dobj.__concat(a, b)
	return tostring(a) .. tostring(b)
end

function dobj:__tostring()
	return self:fmt()
end

function dobj:copy()
	return date_new(self.daynum, self.dayfrc)
end

function dobj:tolocal()
	local dn, df = self.daynum, self.dayfrc
	local bias = getbiasutc2(self)

	if bias then
		self.daynum = dn
		self.dayfrc = df - bias * TICKSPERSEC
		return self:normalize()
	else
		return nil
	end
end

function dobj:toutc()
	local dn, df = self.daynum, self.dayfrc
	local bias = getbiasloc2(dn, df)

	if bias then
		self.daynum = dn
		self.dayfrc = df + bias * TICKSPERSEC
		return self:normalize()
	else
		return nil
	end
end

function dobj:getbias()
	return (getbiasloc2(self.daynum, self.dayfrc)) / SECPERMIN
end

function dobj:gettzname()
	local _, tvu, _ = getbiasloc2(self.daynum, self.dayfrc)
	return tvu and osdate("%Z", tvu) or ""
end

function date.time(h, r, s, t)
	h, r, s, t = tonumber(h or 0), tonumber(r or 0), tonumber(s or 0), tonumber(t or 0)

	if h and r and s and t then
		return date_new(DAYNUM_DEF, makedayfrc(h, r, s, t))
	else
		return date_error_arg()
	end
end

function date:__call(arg1, ...)
	local arg_count = select("#", ...) + (arg1 == nil and 0 or 1)

	if arg_count > 1 then
		return (date_from(arg1, ...))
	elseif arg_count == 0 then
		return (date_getdobj(false))
	else
		local o, r = date_getdobj(arg1)
		return r and o:copy() or o
	end
end

date.diff = dobj.__sub

function date.isleapyear(v)
	local y = fix(v)

	if not y then
		y = date_getdobj(v)
		y = y and y:getyear()
	end

	return isleapyear(y + 0)
end

function date.epoch()
	return date_epoch:copy()
end

function date.isodate(y, w, d)
	return date_new(makedaynum_isoywd(y + 0, w and (w + 0) or 1, d and (d + 0) or 1), 0)
end

function date.fmt(str)
	if str then fmtstr = str end

	return fmtstr
end

function date.daynummin(n)
	DAYNUM_MIN = (n and n < DAYNUM_MAX) and n or DAYNUM_MIN
	return n and DAYNUM_MIN or date_new(DAYNUM_MIN, 0):normalize()
end

function date.daynummax(n)
	DAYNUM_MAX = (n and n > DAYNUM_MIN) and n or DAYNUM_MAX
	return n and DAYNUM_MAX or date_new(DAYNUM_MAX, 0):normalize()
end

function date.ticks(t)
	if t then setticks(t) end

	return TICKSPERSEC
end

local tm = osdate("!*t", 0)

if tm then
	date_epoch = date_new(makedaynum(tm.year, tm.month - 1, tm.day), makedayfrc(tm.hour, tm.min, tm.sec, 0))
	DATE_EPOCH = date_epoch and date_epoch:spandays()
else
	date_epoch = setmetatable({}, {
		__index = function()
			error("failed to get the epoch date")
		end,
	})
end

return date
