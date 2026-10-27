#!/usr/bin/lua
--[[
KidWatch 采样器 —— 数据全部来自 fwx 守护进程，不解析任何日志。

为什么不用 dnsmasq 日志 + conntrack：
  固件仪表板上的"活跃网址"就是 fwx 已经维护好的实时表（active_host），
  带真实连接的 Host/URL；"应用识别"（active_app）还带 appid 和应用名，
  类目表（class_list）也是现成的。自己再去解析 DNS 日志等于重复造轮子，
  而且 DNS 只是解析记录（预取、失败、CDN 调度都算），不代表真的在用。

每轮采样做三件事：
  1. active_host 里每个 (设备, host) 记一次命中 -> daily.dur += 间隔
  2. 命中 host 若能被 active_app/class_list 识别，把应用名和类目写进 site（只在库里没有时兜底）
  3. 刷新设备在线/主机名/IP（devlive），设备清单以固件为准
]]

local jsonc = require "luci.jsonc"

local DB = os.getenv("KWDB") or "/etc/kidwatch/kw.db"
local IV = tonumber(os.getenv("KWIV") or "180") -- 采样间隔（秒），必须与 cron 周期一致
local NOW = os.time()
-- 与 kidwatch.sh 的 nmid 对齐：当天 00:00 的 unixtime（本地时区），不是 %Y%m%d
local DAY = os.time({
  year = tonumber(os.date("%Y")),
  month = tonumber(os.date("%m")),
  day = tonumber(os.date("%d")),
  hour = 0, min = 0, sec = 0,
})

-- 固件 class_list 的中文类目 -> 本地 cat 代码。
-- 这张表和 luci-app-kidwatch 的 controller 里那张必须一一对应：
-- 采集层写进 sess 的 cat 与前端"应用视角"的分类一旦对不上，
-- 时段分布图的配色就会和列表打架。改这里记得同步改那边
-- （controller 里还多一张 NAMECAT，按应用名纠固件的误分类）。
local CATMAP = {
  ["聊天"] = "social", ["社交"] = "social",
  ["游戏"] = "game", ["视频"] = "video", ["音乐"] = "music",
  ["购物"] = "shop", ["教育"] = "study", ["学习"] = "study",
  ["小说"] = "novel", ["阅读"] = "novel",
  ["新闻"] = "news", ["资讯"] = "news", ["常用网站"] = "news",
  ["工具"] = "tool", ["办公"] = "tool",
  ["招聘"] = "tool", ["金融"] = "tool", ["旅游"] = "tool", ["生活"] = "tool",
}

-- ---------------------------------------------------------------- 系统指标
-- 系统页要的是 CPU/温度/内存，和"谁在上网"无关，所以单独一个 60 秒实例跑。
-- 只读 /proc 和 /sys，不起进程、不调 ubus，开销基本为零。
local function readf(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function cpu_stat()
  local s = readf("/proc/stat") or ""
  local v = s:match("^cpu%s+([%d%s]+)")
  if not v then return nil end
  local total, idle = 0, 0
  local i = 0
  for n in v:gmatch("%d+") do
    i = i + 1
    total = total + tonumber(n)
    if i == 4 or i == 5 then idle = idle + tonumber(n) end  -- idle + iowait
  end
  return total, idle
end

local function cpu_pct()
  local t1, i1 = cpu_stat()
  if not t1 then return nil end
  os.execute("sleep 1")   -- busybox sleep 只认整数秒，0.3 会直接报错
  local t2, i2 = cpu_stat()
  if not t2 or t2 <= t1 then return nil end
  local pct = (1 - (i2 - i1) / (t2 - t1)) * 100
  if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
  return math.floor(pct * 10) / 10
end

local function temp_c()
  for i = 0, 4 do
    local s = readf("/sys/class/thermal/thermal_zone" .. i .. "/temp")
    if s then
      local v = tonumber(s:match("%-?%d+"))
      if v then
        if v > 1000 then v = v / 1000 end
        if v > -40 and v < 150 then return math.floor(v + 0.5) end
      end
    end
  end
  local p = io.popen("cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -1")
  if p then
    local s = p:read("*l")
    p:close()
    local v = tonumber(s or "")
    if v and v > 1000 then v = v / 1000 end
    if v and v > -40 and v < 150 then return math.floor(v + 0.5) end
  end
  return nil
end

local function mem_mb()
  local s = readf("/proc/meminfo") or ""
  local tot = tonumber(s:match("MemTotal:%s+(%d+)"))
  local av = tonumber(s:match("MemAvailable:%s+(%d+)")) or tonumber(s:match("MemFree:%s+(%d+)"))
  if not tot or not av then return nil end
  return math.floor((tot - av) / 1024)
end

local function load1()
  local s = readf("/proc/loadavg") or ""
  return tonumber(s:match("^([%d%.]+)"))
end

local function collect_sys()
  local cpu, tc, mem, ld = cpu_pct(), temp_c(), mem_mb(), load1()
  if not cpu and not tc and not mem then return false end
  local sql = string.format(
    "INSERT OR REPLACE INTO sysm(ts,cpu,load,mem,tc,w24,w5) VALUES(%d,%s,%s,%s,%s,0,0);",
    os.time(),
    cpu and string.format("%.1f", cpu) or "NULL",
    ld and string.format("%.2f", ld) or "NULL",
    mem and tostring(mem) or "NULL",
    tc and tostring(tc) or "NULL")
  local p = io.popen("sqlite3 '" .. DB .. "' 2>/dev/null", "w")
  if p then p:write(sql, "\n"); p:close() end
  return true
end

if arg and arg[1] == "--sys" then
  collect_sys()
  os.exit(0)
end

local function ubus(api, data, extra)  local req = { api = api, data = data or {} }
  if extra then
    for k, v in pairs(extra) do req[k] = v end
  end
  local ok, s = pcall(jsonc.stringify, req)
  if not ok then return nil end
  local p = io.popen("ubus call fwx common '" .. s .. "' 2>/dev/null", "r")
  if not p then return nil end
  local out = p:read("*a") or ""
  p:close()
  local ok2, res = pcall(jsonc.parse, out)
  if not ok2 or type(res) ~= "table" or res.code ~= 2000 then return nil end
  return res.data
end

local function esc(v)
  if v == nil then return "" end
  v = tostring(v)
  if v == "" or v == "nil" then return "" end
  -- 单引号会断开 SQL 字面量；换行/制表会把拼出来的一条语句拆成两条 —— 都要去掉
  return (v:gsub("[\r\n\t]", " "):gsub("'", ""))
end

-- 一次聚合拿活跃网址/应用/系统，再补三次小接口
local dash = ubus("get_dashboard_common") or {}
local hosts = (dash.active_host or {}).list or {}
local apps = (dash.active_app or {}).list or {}
local users = ubus("get_all_users", { flag = 3, page = 1, page_size = 200 })
-- flag=3 才会带 hostname / nickname（不带参数是精简版，只有 mac 与在线状态）。
-- 万一这版固件不认 flag，退回精简版，别让设备列表整个空掉。
if not users or type(users.list) ~= "table" or #users.list == 0 then
  users = ubus("get_all_users") or {}
end
local vis = ubus("visit_list") or {}
local cls = ubus("class_list", {}, { CopyRight = "www.fanchmwrt.com" }) or {}

-- appid -> 类目 / 应用名
local aid_cat, aid_name = {}, {}
for _, c in ipairs(cls.class_list or {}) do
  local cat = CATMAP[c.name or ""] or "tool"
  for _, item in ipairs(c.app_list or {}) do
    local id, nm = tostring(item):match("^(%d+),(.*)$")
    if id then
      aid_cat[tonumber(id)] = cat
      aid_name[tonumber(id)] = nm
    end
  end
end

-- 域名 -> appid（active_app 带 domain）
local dom_aid = {}
for _, a in ipairs(apps) do
  if a.domain and a.domain ~= "" and a.id then
    dom_aid[a.domain] = tonumber(a.id)
  end
end

-- host 逐级去前缀找 appid：cdn.qq.com -> qq.com
local function lookup(host)
  local aid = dom_aid[host]
  if aid then return aid end
  local x = host
  for _ = 1, 5 do
    local p = x:match("^[^.]+%.(.+)$")
    if not p then break end
    x = p
    aid = dom_aid[x]
    if aid then return aid end
  end
  return nil
end

-- 归一到站点根：jp1-lx.777096.xyz / gb-lx.777096.xyz 是一家，不该占两行。
-- 二级后缀（com.cn / co.uk …）要保留三段，否则 apple.com.cn 会被截成 com.cn。
local SECOND = {
  ["com.cn"] = 1, ["net.cn"] = 1, ["org.cn"] = 1, ["gov.cn"] = 1,
  ["edu.cn"] = 1, ["com.hk"] = 1, ["com.tw"] = 1, ["co.uk"] = 1,
}
local function root(host)
  local p = {}
  for s in host:gmatch("[^.]+") do p[#p + 1] = s end
  local n = #p
  if n <= 2 then return host end
  local last2 = p[n - 1] .. "." .. p[n]
  if SECOND[last2] and n >= 3 then return p[n - 2] .. "." .. last2 end
  return last2
end

-- 长尾兜底：站点库里没有的域名，按关键词判一类。
-- 只用来止损"DNS/CDN 调度域名占满类目"，宁可判成基础设施，也不要一堆"未分类"。
local CDN_KEY = {
  "cdn", "dns", "glb", "akamai", "cloudfront", "amazonaws", "qcloud",
  "aliyun", "kunlun", "bdstatic", "gstatic", "static", "doubleclick",
  "googlesyndication", "miaozhen", "umeng", "sentry",
}

-- 站点库里没有的品牌域名，按域名里的品牌词判类。
-- 这张表是"特征库"的兜底：实测有大量二级域名（pddpic.com、biliimg.com、
-- bytegecko.com 之类）永远进不了人工维护的 sites.tsv，靠关键词能一次判对。
-- 只放辨识度足够高的词，宁可漏判成"未分类"，也别把 CDN 误判成视频。
-- 顺序有意义：先命中先返回，所以更具体的词要排在前面。
local KEYCAT = {
  -- 视频/直播
  { "douyin", "video" }, { "kuaishou", "video" }, { "ixigua", "video" },
  { "bilibili", "video" }, { "biliimg", "video" }, { "hdslb", "video" },
  { "iqiyi", "video" }, { "youku", "video" }, { "mgtv", "video" },
  { "wetv", "video" }, { "tiktok", "video" }, { "youtube", "video" },
  { "netflix", "video" }, { "qqvideo", "video" }, { "bilivideo", "video" },
  -- 游戏
  { "steam", "game" }, { "epicgames", "game" }, { "riotgames", "game" },
  { "blizzard", "game" }, { "minecraft", "game" }, { "garena", "game" },
  { "4399", "game" }, { "7k7k", "game" }, { "taptap", "game" },
  -- 社交
  { "weibo", "social" }, { "zhihu", "social" }, { "xiaohongshu", "social" },
  { "douban", "social" }, { "weixin", "social" }, { "wechat", "social" },
  { "instagram", "social" }, { "facebook", "social" }, { "twitter", "social" },
  -- 购物
  { "taobao", "shop" }, { "tmall", "shop" }, { "pinduoduo", "shop" },
  { "yangkeduo", "shop" }, { "suning", "shop" }, { "jd.com", "shop" },
  { "amazon", "shop" }, { "pddpic", "shop" },
  -- 学习
  { "xueersi", "study" }, { "zuoyebang", "study" }, { "yuanfudao", "study" },
  { "17zuoye", "study" }, { "chaoxing", "study" }, { "icourse163", "study" },
  { "zhihuishu", "study" }, { "khanacademy", "study" }, { "duolingo", "study" },
  -- 音乐
  { "kugou", "music" }, { "kuwo", "music" }, { "migu", "music" },
  { "ximalaya", "music" }, { "qishui", "music" }, { "spotify", "music" },
  -- 资讯
  { "sina", "news" }, { "sohu", "news" }, { "ifeng", "news" },
  { "thepaper", "news" }, { "cctv", "news" }, { "people.com", "news" },
  { "toutiao", "news" }, { "36kr", "news" },
  -- 工具/云/AI
  { "openai", "tool" }, { "deepseek", "tool" }, { "anthropic", "tool" },
  { "github", "tool" }, { "bing.com", "tool" }, { "office", "tool" },
  { "wps", "tool" }, { "qianwen", "tool" },
}

local function guess_cat(host)
  local h = host:lower()
  for _, k in ipairs(CDN_KEY) do
    if h:find(k, 1, true) then return "cdn" end
  end
  for _, p in ipairs(KEYCAT) do
    if h:find(p[1], 1, true) then return p[2] end
  end
  return nil
end

--[[ 存量站点补分类（--reclass，幂等）

分类是在"第一次见到某个域名"那一刻算出来并写进 site 的。可关键词表 KEYCAT 和
sites.tsv 是后来才加上去的 —— 老域名早就以"没条目"的样子躺在库里，详单里永远
显示未分类。这个模式拿现有 sess 里出现过的域名重跑一遍 guess_cat，只补没有条目的，
绝不覆盖用户手改（src=1）与站点库（src=0）。init 之后跑一次即可，重复跑无副作用。
]]
if arg and arg[1] == "--reclass" then
  local have = {}
  local p = io.popen("sqlite3 '" .. DB .. "' \"SELECT dom FROM site\" 2>/dev/null")
  if p then
    for line in p:lines() do if line ~= "" then have[line] = true end end
    p:close()
  end
  local out, n = { "BEGIN;" }, 0
  local q = io.popen("sqlite3 '" .. DB .. "' \"" ..
    "SELECT dom FROM sess WHERE dom<>'' GROUP BY dom\" 2>/dev/null")
  if q then
    for dom in q:lines() do
      if dom ~= "" and not have[dom] then
        local c = guess_cat(dom)
        -- cdn 不进库：这类条目只记次数不记时长，写进去反而让类目分布多一堆噪音
        if c and c ~= "cdn" then
          out[#out + 1] = string.format(
            "INSERT OR IGNORE INTO site(dom,name,cat,src) VALUES('%s','','%s',3);",
            esc(dom), c)
          n = n + 1
        end
      end
    end
    q:close()
  end
  out[#out + 1] = "COMMIT;"
  local w = io.popen("sqlite3 '" .. DB .. "' 2>/dev/null", "w")
  if w then w:write(table.concat(out, "\n"), "\n"); w:close() end
  print(string.format("reclass ok: %d sites added", n))
  os.exit(0)
end

-- 设备在线状态（get_all_users 是终端列表的同一份数据）
-- 顺手把固件里给设备起的备注（nickname）捞出来：固件"终端列表"显示的就是它，
-- 我们这边以前只认自己的 alias，结果同一台机器在两边叫两个名字。
local online, wl = {}, {}
local nick_of = {}
local ulist = users.list or users.dev_list or {}
for _, u in ipairs(ulist) do
  if u.mac then
    online[u.mac] = tonumber(u.online) or 0
    wl[u.mac] = tonumber(u.is_wireless) or 0
    -- 只在该字段真实存在时记录：空串也要记，用户在固件里删掉备注时这边跟着清空
    if type(u.nickname) == "string" then nick_of[u.mac] = esc(u.nickname) end
  end
end

-- 主机名 / IP 来自 visit_list（和终端列表同源）
local host_of, ip_of, ip6_of = {}, {}, {}
for _, d in ipairs(vis.dev_list or {}) do
  if d.mac then
    host_of[d.mac] = esc(d.hostname)
    ip_of[d.mac] = esc(d.ip)
    ip6_of[d.mac] = esc(d.ipv6)
    if online[d.mac] == nil then online[d.mac] = 0 end
  end
end

local sql = { "BEGIN;" }
local n_hit, n_new, n_cdn = 0, 0, 0
local seen = {}

-- 先把站点库读进内存：判断一个 host 是不是"基础设施"（CDN/DNS/广告统计）。
-- 这类连接几乎每轮都在（后台推送、心跳），算进"上网时长"会把真实使用淹没，
-- 所以只记次数不记时长，榜单和类目分布里都不会出现。
local cat_of = {}
do
  local p = io.popen("sqlite3 -separator '|' '" .. DB .. "' \"SELECT dom,cat FROM site\" 2>/dev/null")
  if p then
    for line in p:lines() do
      local d, c = line:match("^([^|]+)|(.+)$")
      if d then cat_of[d] = c end
    end
    p:close()
  end
end

-- 用户点过"删除"的终端：固件还在报它们，但我们既不记也不再建条目。
-- 只读一次，后面三个循环都拿它过滤（站点、在线快照、日流量）。
local hidden = {}
do
  local p = io.popen("sqlite3 '" .. DB .. "' \"SELECT mac FROM devhide\" 2>/dev/null")
  if p then
    for line in p:lines() do
      if line ~= "" then hidden[line] = true end
    end
    p:close()
  end
end

-- 第一遍：按设备把本轮的活跃站点归并起来。
-- 关键：一轮 10 分钟是"设备的 10 分钟"，不是"每个域名的 10 分钟"。
-- 若每个域名都记满 IV，一天下来能算出 50 多个小时，这种数没人信。
local per, order = {}, {}
for _, h in ipairs(hosts) do
  local mac, raw = esc(h.mac), esc(h.host)
  local host = raw ~= "" and root(raw) or ""
  -- 同一站点每轮只记一次：手机上 10 条连接不等于用了 10 倍时间
  local key = mac .. "|" .. host
  if mac ~= "" and host ~= "" and not seen[key] and not hidden[mac] then
    seen[key] = true
    local aid = lookup(raw) or lookup(host)
    local nm, cat = "", ""
    if aid then
      nm, cat = aid_name[aid] or "", aid_cat[aid] or "tool"
    end
    if nm == "" then
      cat = cat_of[host] or cat_of[raw] or guess_cat(host) or "other"
    end
    if cat == "cdn" then
      n_cdn = n_cdn + 1
    else
      if not per[mac] then per[mac] = {}; order[#order + 1] = mac end
      local l = per[mac]
      l[#l + 1] = { host = host, aid = tonumber(aid) or 0, nm = nm, cat = cat }
      n_hit = n_hit + 1
    end
    if host_of[mac] == nil or host_of[mac] == "" then
      host_of[mac] = esc(h.hostname)
    end
  end
end

-- 第二遍：这一轮的时长按站点数平摊，并补进 sess 供"一天里的节奏"按小时铺开
for _, mac in ipairs(order) do
  local l = per[mac]
  local share = math.max(1, math.floor(IV / math.max(1, #l)))
  for _, it in ipairs(l) do
    sql[#sql + 1] = string.format(
      "INSERT INTO daily(day,mac,dom,dur,up,dn,n) VALUES(%d,'%s','%s',%d,0,0,1) " ..
      "ON CONFLICT(day,mac,dom) DO UPDATE SET dur=dur+%d, n=n+1;",
      DAY, mac, it.host, share, share)
    sql[#sql + 1] = string.format(
      "INSERT INTO sess(mac,dom,day,ts0,ts1,dur,up,dn,n,appid) " ..
      "VALUES('%s','%s',%d,%d,%d,%d,0,0,1,%d);",
      mac, it.host, DAY, NOW - share, NOW, share, it.aid)
    if it.aid > 0 and it.nm ~= "" then
      -- 只在库里没有条目时兜底，内置库/用户改过的优先
      sql[#sql + 1] = string.format(
        "INSERT INTO site(dom,name,cat,src) VALUES('%s','%s','%s',2) " ..
        "ON CONFLICT(dom) DO UPDATE SET name=excluded.name, cat=excluded.cat WHERE site.src>=2;",
        it.host, it.nm, it.cat)
      n_new = n_new + 1
    elseif not cat_of[it.host] then
      local gc = guess_cat(it.host)
      if gc then
        sql[#sql + 1] = string.format(
          "INSERT INTO site(dom,name,cat,src) VALUES('%s','','%s',3) " ..
          "ON CONFLICT(dom) DO UPDATE SET cat=excluded.cat WHERE site.src>=3;", it.host, gc)
        n_new = n_new + 1
      end
    end
  end
end

-- ---------------------------------------------------------------- 夜间窗口（5 分钟桶）
-- 夜间守卫要回答的是"这一格设备是不是真的在用"，所以只能记增量，不能记累计值。
-- 三样都来自固件本身，不解析 dnsmasq 日志：
--   air  ← iw station dump 的 rx/tx duration 差分（微秒，真射频占用）
--   on_s ← connected time 差分（有线上不了无线就一直是 0）
--   by   ← get_daily_top_users 的字节差分
-- 活跃站点数 / 域名数直接取本轮聚合结果（per），不需要另一套扫描。
--
-- 差分基线放 /tmp：重启后第一轮全部记 0（宁可漏一格，也不要凭空造一个尖峰）。
local WIN_STATE = "/tmp/kidwatch/win.state"

local function win_state()
  local t = {}
  local f = io.open(WIN_STATE, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^(%S+)%s+(%-?%d+)$")
      if k then t[k] = tonumber(v) end
    end
    f:close()
  end
  return t
end

-- 每个无线接口 station dump 一次，取三行：rx duration / tx duration / connected time
local function read_stations()
  local air, conn = {}, {}
  local ifs = {}
  local p = io.popen("iw dev 2>/dev/null | awk '/Interface/{print $2}'")
  if p then
    for l in p:lines() do if l ~= "" then ifs[#ifs + 1] = l end end
    p:close()
  end
  for _, dev in ipairs(ifs) do
    local q = io.popen("iw dev " .. dev .. " station dump 2>/dev/null")
    if q then
      local mac
      for line in q:lines() do
        local m = line:match("^Station%s+(%S+)")
        if m then
          mac = m:lower()
        elseif mac then
          local v = line:match("^%s*rx duration:%s*(%d+)")
          if v then air[mac] = (air[mac] or 0) + tonumber(v) end
          v = line:match("^%s*tx duration:%s*(%d+)")
          if v then air[mac] = (air[mac] or 0) + tonumber(v) end
          v = line:match("^%s*connected time:%s*(%d+)")
          if v then conn[mac] = tonumber(v) end
        end
      end
      q:close()
    end
  end
  return air, conn
end

local USED = win_state()
local AIR, CONN = read_stations()

-- 每设备当日累计字节（含上下行拆分）。既用于 win 的差分，也原样落进 devday：
-- 站点级流量固件没有，只能拿这个总量在查询时按域名时长分摊。
local bu, bu_up, bu_dn = {}, {}, {}
do
  local du = ubus("get_daily_top_users") or {}
  for _, u in ipairs(du.users or {}) do
    local m = esc(u.mac)
    if m ~= "" then
      -- 必须 floor：JSON 里的大整数在 Lua 里可能是浮点，string.format("%d")
      -- 遇到"没有整数表示"的浮点会直接抛错（整轮采样作废）。
      local uu = math.floor(tonumber(u.up_bytes) or 0)
      local dd = math.floor(tonumber(u.down_bytes) or 0)
      bu_up[m], bu_dn[m] = uu, dd
      bu[m] = uu + dd
    end
  end
  for m in pairs(bu) do
    if hidden[m] then bu[m] = nil end
  end
  for m in pairs(bu) do
    -- 这里必须用 %.0f 而不是 %d：本机 Lua 是 5.1（double），string.format("%d")
    -- 只认 C 的 int，字节数一旦超过 2^31 就抛 "integer expected, got number"，
    -- 整轮采样直接崩掉（踩过一次，别改回去）。
    sql[#sql + 1] = string.format(
      "INSERT INTO devday(day,mac,up,dn) VALUES(%d,'%s',%.0f,%.0f) " ..
      "ON CONFLICT(day,mac) DO UPDATE SET up=excluded.up, dn=excluded.dn;",
      DAY, m, bu_up[m] or 0, bu_dn[m] or 0)
  end
end

local BKT = NOW - (NOW % 300)
local ENT = { video = 1, game = 1, social = 1, music = 1, novel = 1 }

-- 候选设备 = 本轮在线的 + 本轮有活跃站点的 + 无线有 airtime 增量的
local cand, ncan = {}, 0
local function add(mac)
  if mac ~= "" and not hidden[mac] and not cand[mac] then cand[mac] = true; ncan = ncan + 1 end
end
for mac in pairs(online) do if online[mac] == 1 then add(mac) end end
for _, mac in ipairs(order) do add(mac) end
for mac in pairs(AIR) do add(mac) end

for mac in pairs(cand) do
  local a, on, by = 0, 0, 0

  if AIR[mac] then
    local cur, prev = AIR[mac], USED["air:" .. mac]
    if prev and cur >= prev then a = math.floor((cur - prev) / 1000) end
    USED["air:" .. mac] = cur
  end

  if CONN[mac] then
    local cur, prev = CONN[mac], USED["on:" .. mac]
    -- 封顶 300：设备重连时 connected time 会跳，别让它变成一个假的高活跃
    if prev and cur >= prev then on = math.min(300, cur - prev) end
    USED["on:" .. mac] = cur
  end

  if bu[mac] then
    local cur, prev = bu[mac], USED["by:" .. mac]
    if prev and cur >= prev then by = cur - prev end
    USED["by:" .. mac] = cur
  end

  local l = per[mac] or {}
  local nd, tot, ne, doms = 0, 0, 0, {}
  for _, it in ipairs(l) do
    if not doms[it.host] then doms[it.host] = true; nd = nd + 1 end
    tot = tot + 1
    if ENT[it.cat] then ne = ne + 1 end
  end
  -- 娱乐类目的流量份额：类目是按站点记的，流量只按设备记，
  -- 所以用"娱乐站点占本轮活跃站点的比例"把字节折过去，是个明确的近似。
  local ent_by = (tot > 0) and math.floor(by * ne / tot) or 0

  if a > 0 or on > 0 or by > 0 or #l > 0 then
    sql[#sql + 1] = string.format(
      "INSERT INTO win(ts,mac,air,on_s,fl,dq,by,ent,nd) VALUES(%d,'%s',%d,%d,%d,0,%d,%d,%d) " ..
      "ON CONFLICT(ts,mac) DO UPDATE SET air=air+excluded.air, on_s=on_s+excluded.on_s, " ..
      "fl=fl+excluded.fl, by=by+excluded.by, ent=ent+excluded.ent, " ..
      "nd=MAX(nd,excluded.nd);",
      BKT, mac, a, on, #l, by, ent_by, nd)
  end
end

do
  local f = io.open(WIN_STATE, "w")
  if f then
    for k, v in pairs(USED) do f:write(k, " ", v, "\n") end
    f:close()
  end
end

-- 设备在线快照：即使本轮没有任何活跃连接，也要更新"下线"状态
for _, u in ipairs(ulist) do
  local mac = esc(u.mac)
  if mac ~= "" and not hidden[mac] then
    sql[#sql + 1] = string.format(
      "INSERT INTO devlive(mac,host,ip,ip6,online,wl,ts) VALUES('%s','%s','%s','%s',%d,%d,%d) " ..
      "ON CONFLICT(mac) DO UPDATE SET host=excluded.host, ip=excluded.ip, ip6=excluded.ip6, " ..
      "online=excluded.online, wl=excluded.wl, ts=excluded.ts;",
      mac, host_of[mac] or "", ip_of[mac] or "", ip6_of[mac] or "",
      online[mac] or 0, wl[mac] or 0, NOW)
    -- 固件备注同步进 dev.nick：页面取名时排在 alias 之后、hostname 之前
    if nick_of[mac] ~= nil then
      sql[#sql + 1] = string.format(
        "INSERT INTO dev(mac,nick) VALUES('%s','%s') " ..
        "ON CONFLICT(mac) DO UPDATE SET nick=excluded.nick;", mac, nick_of[mac])
    end
  end
end

sql[#sql + 1] = string.format(
  "INSERT INTO meta(k,v) VALUES('last_poll','%d') ON CONFLICT(k) DO UPDATE SET v=excluded.v;", NOW)
sql[#sql + 1] = "COMMIT;"

local p = io.popen("sqlite3 '" .. DB .. "' 2>/dev/null", "w")
if p then
  p:write(table.concat(sql, "\n"), "\n")
  p:close()
end

collect_sys()   -- 顺手留一个点，万一 60 秒实例没起来，系统页也不至于全空

print(string.format("poll ok: %d content, %d infra skipped, %d new sites, %d devs, iv=%ds",
  n_hit, n_cdn, n_new, #ulist, IV))
