module("luci.controller.kidwatch", package.seeall)

-- 把参数包成 shell 单引号字面量。
-- 两条老隐患：① 没滤换行——sh -c 会把 \n 当命令分隔符，别名里带个换行
-- 就能截断命令；② 超过 200 字直接 return nil，而调用处是 cmd .. q(val)，
-- 会抛 attempt to concatenate a nil value，给设备起个长别名就 500。
-- 现在统一成"去掉控制字符 + 截断"，永远返回字符串。
local function q(s)
	s = tostring(s or "")
	s = s:gsub("%c", "")        -- 换行/回车/Tab 等控制字符一律去掉
	s = s:gsub("'", "")         -- 单引号会提前闭合字面量
	if #s > 200 then s = s:sub(1, 200) end
	return "'" .. s .. "'"
end

-- 三页组成独立分组「守护视图」，order 5：紧跟固件「仪表板」(order 1)，
-- 排在「系统监控」(12) /「终端列表」/「应用中心」(15) 之前。
-- 父节点名刻意取 fwx_guard：主题的 getMenuCategory() 只看节点名是否以 fwx 开头，
-- 是则归普通模式，否则落到高级模式。用 kidwatch 这种名字会被推进高级模式，
-- 所以这里不叫 admin/kidwatch。主题 JS 一行都不用改。
-- URL 末段仍是 ov/web/night，模板靠它决定打开哪个视角。
-- 本应用只新增自己的页面，固件自带页面（含仪表板）一概不动。
local NAV = {
	{ "ov",    "概览",     10 },
	{ "web",   "上网详单", 20 },
	{ "night", "夜间守卫", 30 },
}

function index()
	-- 标题直接写中文：这些词条不在固件的中文词表里，走 _() 会回落成英文
	-- order 5：紧跟固件「仪表板」(order 1)，在「系统监控」(12) 之前
	entry({"admin", "fwx_guard"}, firstchild(), "守护视图", 5).dependent = true
	for idx, p in ipairs(NAV) do
		entry({"admin", "fwx_guard", p[1]}, template("kidwatch/main"), p[2], p[3]).dependent = true
	end
	-- 「运行状态」不占守护视图：挂进固件「系统监控」组 (admin/fwx_monitor，
	-- 固件 order 12) 的末尾，URL 末段保持 sys，模板据此打开整机指标视角。
	entry({"admin", "fwx_monitor", "sys"}, template("kidwatch/main"), "运行状态", 60).dependent = true

	-- DDNS-Go 是后装的独立程序（/usr/bin/ddns-go，自带 http 管理界面），
	-- 固件菜单里本来没有它。这里补一个入口。
	-- 节点名故意不带 fwx 前缀：主题的 getMenuCategory() 据此归到「高级模式」，
	-- 正好符合它"进阶功能"的定位，也不会把普通模式的顺序挤乱。
	-- 用 alias 让顶层直接可点，不必先展开再点一层。
	entry({"admin", "ddnsgo"}, alias("admin", "ddnsgo", "cfg"), "DDNS-Go", 88).dependent = true
	entry({"admin", "ddnsgo", "cfg"}, template("kidwatch/ddnsgo"), "运行状态", 10).dependent = true

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

-- 今日流量直接取固件的数：总量在 get_dashboard_common 的 system.flow，
-- 每设备在 get_daily_top_users。固件已经按连接记过账，不必自己再累加一遍。
local function flow()
	local res = luci.util.ubus("fwx", "common", { api = "get_dashboard_common", data = {} })
	local sys = res and res.data and res.data.system_status
	local fl = (sys and sys.flow) or {}
	local out = {
		up = tonumber(fl.today_up) or 0,
		down = tonumber(fl.today_down) or 0,
		per = {},
	}
	local du = luci.util.ubus("fwx", "common", { api = "get_daily_top_users", data = {} })
	local users = du and du.data and du.data.users
	if type(users) == "table" then
		for _, u in ipairs(users) do
			if u.mac then
				out.per[u.mac] = {
					up = tonumber(u.up_bytes) or 0,
					dn = tonumber(u.down_bytes) or 0,
				}
			end
		end
	end
	return out
end

-- 应用视角：直接用固件 visit_list 里"今天每个应用用了多久"的累计值。
-- 这是仪表板"活跃网址"背后的同一份数据，DPI 识别到应用名和 appid，
-- 类目用固件的 class_list，不需要域名库，也不用自己按连接去猜。
-- 名字要跟固件 class_list 里实际出现的分类一一对上，漏一个就有整类应用掉进"工具"。
-- 这张表必须与 kidwatch/files/poll.lua 里的 CATMAP 保持一致，
-- 否则采集层写进 sess 的类和前端这里的归类会对不上。
local CATMAP = {
	["聊天"] = "social", ["社交"] = "social",
	["游戏"] = "game", ["视频"] = "video", ["音乐"] = "music",
	["购物"] = "shop", ["教育"] = "study", ["学习"] = "study",
	["小说"] = "novel", ["阅读"] = "novel",
	["新闻"] = "news", ["资讯"] = "news", ["常用网站"] = "news",
	["工具"] = "tool", ["办公"] = "tool", ["下载"] = "tool",
	["招聘"] = "tool", ["金融"] = "tool", ["旅游"] = "tool", ["生活"] = "tool",
}

-- 固件把支付、办公也塞进"聊天"，按应用名纠一下就没那么离谱
local NAMECAT = {
	["支付宝"] = "shop", ["钉钉"] = "tool", ["飞书"] = "tool",
	["微信"] = "social", ["QQ"] = "social", ["微博"] = "social",
	["王者荣耀"] = "game", ["原神"] = "game", ["和平精英"] = "game",
	["抖音"] = "video", ["快手"] = "video", ["哔哩哔哩"] = "video",
	["腾讯视频"] = "video", ["爱奇艺"] = "video", ["优酷"] = "video",
	["淘宝"] = "shop", ["京东"] = "shop", ["拼多多"] = "shop",
	["网易云音乐"] = "music", ["QQ音乐"] = "music",
	["知乎"] = "news", ["小红书"] = "social",
}

-- 设备名跟终端列表用同一招：DHCP 租约里按 MAC 找主机名（固件 user.lua 也是这么干的）
local function lease_names()
	local map, fd = {}, io.open("/tmp/dhcp.leases", "r")
	if not fd then return map end
	for ln in fd:lines() do
		local _, mac, _, name = ln:match("^(%d+) (%S+) (%S+) (%S+)")
		if mac and name and name ~= "*" then map[mac:lower()] = name end
	end
	fd:close()
	return map
end

local function apps()
	local res = luci.util.ubus("fwx", "common", { api = "visit_list", data = {} })
	local devs = res and res.data and res.data.dev_list
	if type(devs) ~= "table" then return {} end

	local cls = luci.util.ubus("fwx", "common", {
		api = "class_list", data = {}, CopyRight = "www.fanchmwrt.com",
	})
	local aid_cat = {}
	local list = cls and cls.data and cls.data.class_list
	if type(list) == "table" then
		for _, c in ipairs(list) do
			local cat = CATMAP[c.name or ""] or "tool"
			for _, item in ipairs(c.app_list or {}) do
				local id = tostring(item):match("^(%d+),")
				if id then aid_cat[tonumber(id)] = cat end
			end
		end
	end

	local out, agg, leases = {}, {}, lease_names()
	for _, d in ipairs(devs) do
		local mac = tostring(d.mac or "")
		local who = tostring(d.hostname or "")
		if who == "" and mac ~= "" then who = leases[mac:lower()] or "" end
		for _, v in ipairs(d.visit_info or {}) do
			local aid = tonumber(v.appid) or 0
			local app = tostring(v.appname or "")
			local key = mac .. "|" .. aid
			local row = {
				mac = mac,
				host = who,
				app = app,
				appid = aid,
				cat = NAMECAT[app] or aid_cat[aid] or "tool",
				dur = tonumber(v.total_time) or 0,
				online = tonumber(v.online) or 0,
				last = tonumber(v.latest_time) or 0,
			}
			-- 同一设备同一应用可能出现多条（不同连接），累计时长取最大值，别叠加
			local old = agg[key]
			if old then
				if row.dur > old.dur then old.dur = row.dur; old.last = row.last end
				if row.online > old.online then old.online = row.online end
			else
				agg[key] = row
				out[#out + 1] = row
			end
		end
	end
	table.sort(out, function(a, b) return a.dur > b.dur end)

	-- 应用级流量同样没有现成数据：固件 DPI 只给时长，字节数只到"设备"这一层。
	-- 用这台设备当天真实字节总量，按各应用时长占比分摊；同一台设备各应用加起来
	-- 正好等于固件的总量。前端必须带"≈"，别让家长当成实测值。
	local fl, dur_of = flow(), {}
	for _, r in ipairs(out) do
		dur_of[r.mac] = (dur_of[r.mac] or 0) + r.dur
	end
	for _, r in ipairs(out) do
		local f  = fl.per[r.mac]
		local tb = f and ((f.up or 0) + (f.dn or 0)) or 0
		local td = dur_of[r.mac] or 0
		r.by = (tb > 0 and td > 0) and math.floor(tb * r.dur / td + 0.5) or 0
	end
	return out
end

local FN = {
	overview = true, top = true, cats = true, hours = true, days = true,
	list = true, sess = true, sesswin = true, devs = true, night = true, base = true,
	sys = true, stat = true, sites = true,
	-- 终端列表页要滤掉的设备（用户点过"删除"的），只有 mac+ts 两列
	hid = true,
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

	-- 流量直接用固件的数（站点级流量固件没有，采样也拿不到，就不编了）
	if fn == "flow" then
		luci.http.write_json(flow())
		return
	end

	-- 应用维度（活跃网址）：固件 DPI 的应用时长，按设备 + 应用聚合
	if fn == "apps" then
		local all, mac = apps(), luci.http.formvalue("mac")
		if mac and mac ~= "all" and mac ~= "" then
			local f = {}
			for _, x in ipairs(all) do
				if x.mac == mac then f[#f + 1] = x end
			end
			all = f
		end
		luci.http.write_json(all)
		return
	end

	if fn == "setdev" or fn == "setsite" then
		if not luci.dispatcher.context.authsession then
			luci.http.write('{"error":"auth"}')
			return
		end
		local macraw = luci.http.formvalue("mac") or ""
		local mac = safe_mac(macraw)
		local key = safe_word(luci.http.formvalue("key") or "")
		local val = luci.http.formvalue("val") or ""
		-- 恢复全部已删除的终端用 mac=*。这里必须单引号包起来再交给 shell，
		-- 否则 '*' 会在路由器上被当成通配符展开成文件名。
		if macraw == "*" and key == "undel" then mac = "'*'" end
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

	-- 主题模式：写 fwx.global.theme_mode。
	-- 主题模板 header.ut 按这个值渲染 <html data-darkmode>，所以写进去以后
	-- 不只是本页，整个后台下次渲染都会跟着变；本页则先改属性即时生效。
	if fn == "theme" then
		if not luci.dispatcher.context.authsession then
			luci.http.write('{"error":"auth"}')
			return
		end
		local v = luci.http.formvalue("v") or ""
		if v ~= "0" and v ~= "1" then
			luci.http.write('{"error":"args"}')
			return
		end
		luci.util.exec("uci set fwx.global.theme_mode=" .. v .. " >/dev/null 2>&1; uci commit fwx >/dev/null 2>&1")
		luci.http.write('{"ok":true,"v":' .. v .. '}')
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
	if luci.http.formvalue("nocdn") == "1" then cmd = cmd .. " --nocdn" end
	local kw = luci.http.formvalue("q")
	if kw and #kw <= 60 then cmd = cmd .. " --q " .. q(kw) end

	local out = luci.util.exec(cmd)
	if not out or out == "" then out = "[]" end
	luci.http.write(out)
end
