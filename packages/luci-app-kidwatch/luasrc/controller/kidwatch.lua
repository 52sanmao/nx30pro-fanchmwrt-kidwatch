module("luci.controller.kidwatch", package.seeall)

local function q(s)
	if s == nil then return nil end
	s = tostring(s)
	if #s > 200 then return nil end
	if s:match("'") then s = s:gsub("'", "") end
	return "'" .. s .. "'"
end

-- KidWatch 不是一个"大杂烩"页面，而是按固件原有的信息架构分散到各分类下：
--   系统监控 / 上网记录 / 家长控制 / 用户列表
-- 五处入口共用同一份模板，前端按 URL 末段决定默认打开哪个页签，
-- 页签之间仍可横向切换（同一份数据的不同视角）。
local ENTRY = {
	{ {"admin", "fwx_monitor", "kidwatch"}, "家长看板", 60, "ov" },
	{ {"admin", "fwx_internet_record", "kwsites"}, "网站记录", 82, "web" },
	{ {"admin", "fwx_parental_control", "kwnight"}, "夜间守卫", 40, "night" },
	{ {"admin", "fwx_monitor", "kwsys"}, "设备状态", 61, "sys" },
	{ {"admin", "fwx_user", "kwdev"}, "设备标签", 14, "dev" },
}

function index()
	entry({"admin", "fwx_monitor"}, firstchild(), _("System Monitor"), 12).dependent = true
	entry({"admin", "fwx_internet_record"}, firstchild(), _("Internet Record"), 80).dependent = true
	entry({"admin", "fwx_parental_control"}, firstchild(), _("Parental Control"), 30).dependent = true
	entry({"admin", "fwx_user"}, firstchild(), _("User List"), 13).dependent = true

	for _, e in ipairs(ENTRY) do
		entry(e[1], template("kidwatch/main"), e[2], e[3]).dependent = true
	end
	entry({"admin", "kidwatch_api", "call"}, call("api")).leaf = true
end

-- 从固件自带的 fwx DPI 取"此刻在线"快照。
-- 与 kidwatch 自己按 DNS+conntrack 累积的历史数据互补：
--   DPI 看的是连接里真实的 SNI / Host，不受 DNS 缓存、QUIC 直连影响，
--   还能给出应用名（小红书 / DeepSeek …），这是只看 DNS 拿不到的。
local function live()
	local users = luci.util.ubus("fwx", "common", {
		api = "get_active_users",
		data = { count = 64 }
	})
	local out = {}
	local list = users and users.data and users.data.users
	if type(list) ~= "table" then return out end
	for _, u in ipairs(list) do
		local url = tostring(u.url or "")
		local app = tostring(u.app or "")
		if url ~= "" or app ~= "" then
			out[#out + 1] = {
				mac  = tostring(u.mac or ""),
				ip   = tostring(u.ip or ""),
				host = tostring(u.hostname or u.nickname or ""),
				app  = app,
				url  = url,
				up   = tonumber(u.up_rate) or 0,
				down = tonumber(u.down_rate) or 0,
				band = tostring(u.band or ""),
				rssi = tonumber(u.rssi) or 0,
				wl   = tonumber(u.is_wireless) or 0,
			}
		end
	end
	return out
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

	if fn == "live" then
		luci.http.write_json(live())
		return
	end

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
