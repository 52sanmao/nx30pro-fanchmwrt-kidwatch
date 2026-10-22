module("luci.controller.kidwatch", package.seeall)

local function q(s)
	if s == nil then return nil end
	s = tostring(s)
	if #s > 200 then return nil end
	if s:match("'") then s = s:gsub("'", "") end
	return "'" .. s .. "'"
end

function index()
	entry({"admin", "fwx_monitor"}, firstchild(), _("System Monitor"), 12).dependent = true
	entry({"admin", "fwx_monitor", "kidwatch"}, template("kidwatch/main"), "家长看板", 60).dependent = true
	entry({"admin", "kidwatch_api", "call"}, call("api")).leaf = true
end

local FN = {
	overview = true, top = true, cats = true, hours = true, days = true,
	list = true, sess = true, devs = true, night = true, base = true,
	sys = true, stat = true, sites = true,
}

local function safe_num(v)
	if v and v:match("^%d+$") then return v end
	return nil
end

local function safe_word(v)
	if v and v:match("^[%w_%-]+$") then return v end
	return nil
end

local function safe_mac(v)
	if v and v:match("^[%x][%x:%-]+$") then return v end
	return nil
end

local function safe_range(v)
	if v and v:match("^[%w,]+$") then return v end
	return nil
end

local function safe_dom(v)
	if v and v:match("^[%w%.:_%-]+$") then return v end
	return nil
end

function api()
	luci.http.prepare_content("application/json")
	local fn = luci.http.formvalue("fn") or ""
	local cmd = "/usr/bin/kidwatch "

	if fn == "setdev" or fn == "setsite" then
		if not luci.dispatcher.context.authsession then
			luci.http.write('{"error":"auth"}')
			return
		end
		local mac = safe_mac(luci.http.formvalue("mac") or "")
		local key = safe_word(luci.http.formvalue("key") or "")
		local val = luci.http.formvalue("val") or ""
		if fn == "setdev" then
			if not mac or not key then luci.http.write('{"error":"args"}') return end
			cmd = cmd .. "setdev " .. mac .. " " .. key .. " " .. q(val)
		else
			local dom = safe_dom(luci.http.formvalue("dom") or "")
			local cat = safe_word(luci.http.formvalue("cat") or "other")
			if not dom then luci.http.write('{"error":"args"}') return end
			cmd = cmd .. "setsite " .. dom .. " " .. q(val) .. " " .. (cat or "other")
		end
		luci.http.write(luci.util.exec(cmd) or "{}")
		return
	end

	if not FN[fn] then
		luci.http.write('{"error":"unknown"}')
		return
	end

	cmd = cmd .. "query " .. fn
	local r = safe_range(luci.http.formvalue("range"))
	if r then cmd = cmd .. " --range " .. r end
	local f = safe_num(luci.http.formvalue("from"))
	local t = safe_num(luci.http.formvalue("to"))
	if f and t then cmd = cmd .. " --from " .. f .. " --to " .. t end
	local mac = safe_mac(luci.http.formvalue("mac"))
	if mac and mac ~= "all" then cmd = cmd .. " --mac " .. mac end
	local cat = safe_word(luci.http.formvalue("cat"))
	if cat and cat ~= "all" then cmd = cmd .. " --cat " .. cat end
	local met = safe_word(luci.http.formvalue("met"))
	if met then cmd = cmd .. " --met " .. met end
	local win = safe_word(luci.http.formvalue("win"))
	if win then cmd = cmd .. " --win " .. win end
	local lim = safe_num(luci.http.formvalue("lim"))
	if lim then cmd = cmd .. " --lim " .. lim end
	local off = safe_num(luci.http.formvalue("off"))
	if off then cmd = cmd .. " --off " .. off end
	local day = safe_num(luci.http.formvalue("day"))
	if day then cmd = cmd .. " --day " .. day end
	local days = safe_num(luci.http.formvalue("days"))
	if days then cmd = cmd .. " --days " .. days end
	local dom = safe_dom(luci.http.formvalue("dom"))
	if dom then cmd = cmd .. " --dom " .. dom end
	local kw = luci.http.formvalue("q")
	if kw and #kw <= 60 then cmd = cmd .. " --q " .. q(kw) end

	local out = luci.util.exec(cmd)
	if not out or out == "" then out = "[]" end
	luci.http.write(out)
end
