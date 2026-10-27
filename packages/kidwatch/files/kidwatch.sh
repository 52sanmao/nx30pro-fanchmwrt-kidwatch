#!/bin/sh
# kidwatch —— 家长看板数据层
#   采集：conntrack + dnsmasq 日志 + 无线 airtime + 系统指标 -> SQLite
#   查询：一律输出 JSON，供 LuCI 前端直接消费
set -u

DB="${KWDB:-/etc/kidwatch/kw.db}"
SITES="${KWSITES:-/etc/kidwatch/sites.tsv}"
TMP="${KWTMP:-/tmp/kidwatch}"
DNSLOG="${KWDNS:-/tmp/kidwatch-dnsmasq.log}"
AWK=/usr/bin/awk

sq() { printf '%s' "${1-}" | sed "s/'/''/g"; }
now() { date +%s; }
nmid() { date -d "$1 00:00:00" +%s 2>/dev/null || date +%s; }

# 统一的 sqlite 调用（JSON 输出 / 静默执行）
sj() { sqlite3 -cmd ".timeout 5000" -json "$DB" "$1"; }
se() { sqlite3 -cmd ".timeout 5000" "$DB" "$1"; }

# ---------------------------------------------------------------- 建库
do_init() {
	mkdir -p /etc/kidwatch "$TMP"
	[ -f "$DB" ] || : > "$DB"
	# PRAGMA journal_mode / wal_autocheckpoint 会把 wal、256 打到 stdout，
	# 装包时 post-upgrade 调 init 就会在 apk 日志里冒出这两行，看着像出错。整段静默。
	sqlite3 "$DB" >/dev/null <<'EOF'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA wal_autocheckpoint=256;
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);

CREATE TABLE IF NOT EXISTS dev(
  mac  TEXT PRIMARY KEY,
  alias TEXT NOT NULL DEFAULT '',
  nick TEXT NOT NULL DEFAULT '',   -- 固件"终端列表"里给设备起的备注（nickname）
  role TEXT NOT NULL DEFAULT 'child',
  mode TEXT NOT NULL DEFAULT 'full',
  host TEXT NOT NULL DEFAULT '',
  ip   TEXT, first INTEGER, last INTEGER, base REAL
);

-- 设备实时状态：一律取自固件（get_all_users / visit_list），
-- 本地 dev 表只保留"用户设定"（别名/角色/统计方式），用 mac 关联。
CREATE TABLE IF NOT EXISTS devlive(
  mac TEXT PRIMARY KEY,
  host TEXT NOT NULL DEFAULT '',
  ip   TEXT NOT NULL DEFAULT '',
  ip6  TEXT NOT NULL DEFAULT '',
  online INTEGER NOT NULL DEFAULT 0,
  wl INTEGER NOT NULL DEFAULT 0,
  ts INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS site(
  dom  TEXT PRIMARY KEY,
  name TEXT NOT NULL DEFAULT '',
  cat  TEXT NOT NULL DEFAULT 'other',
  src  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS i_site_cat ON site(cat);

CREATE TABLE IF NOT EXISTS sess(
  id INTEGER PRIMARY KEY,
  mac TEXT NOT NULL, dom TEXT NOT NULL DEFAULT '', day INTEGER NOT NULL,
  ts0 INTEGER NOT NULL, ts1 INTEGER NOT NULL,
  dur INTEGER NOT NULL DEFAULT 0, up INTEGER NOT NULL DEFAULT 0,
  dn  INTEGER NOT NULL DEFAULT 0, n INTEGER NOT NULL DEFAULT 1,
  appid INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS i_sess_day ON sess(day, mac);
CREATE INDEX IF NOT EXISTS i_sess_dom ON sess(dom, day);

CREATE TABLE IF NOT EXISTS daily(
  day INTEGER NOT NULL, mac TEXT NOT NULL, dom TEXT NOT NULL DEFAULT '',
  dur INTEGER NOT NULL DEFAULT 0, up INTEGER NOT NULL DEFAULT 0,
  dn INTEGER NOT NULL DEFAULT 0, n INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(day, mac, dom)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS i_daily_dom ON daily(dom, day);

-- 每设备每日的真实字节数（固件 get_daily_top_users，当天累计值，每轮覆盖）。
-- 为什么要单独一张表：固件只到"设备"这一层，没有站点级字节；按域名看流量时
-- 用这张表的当日总量按各域名占用时长分摊（q_list），总量恒等于固件口径，
-- 不会出现"各站点加起来比设备总量还多"这种自相矛盾。
CREATE TABLE IF NOT EXISTS devday(
  day INTEGER NOT NULL, mac TEXT NOT NULL,
  up INTEGER NOT NULL DEFAULT 0, dn INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(day, mac)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS win(
  ts INTEGER NOT NULL, mac TEXT NOT NULL,
  air INTEGER NOT NULL DEFAULT 0, on_s INTEGER NOT NULL DEFAULT 0,
  fl INTEGER NOT NULL DEFAULT 0, dq INTEGER NOT NULL DEFAULT 0,
  by INTEGER NOT NULL DEFAULT 0, ent INTEGER NOT NULL DEFAULT 0,
  nd INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(ts, mac)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS sysm(
  ts INTEGER PRIMARY KEY, cpu REAL, load REAL, mem INTEGER,
  tc INTEGER, w24 INTEGER, w5 INTEGER
);
CREATE TABLE IF NOT EXISTS sysh(
  ts INTEGER PRIMARY KEY, cpu REAL, load REAL, mem INTEGER,
  tc INTEGER, w24 INTEGER, w5 INTEGER
);
INSERT OR IGNORE INTO meta(k,v) VALUES('schema','1');
EOF
	# 老库补列：CREATE TABLE IF NOT EXISTS 不会给已存在的表加字段。
	# 幂等——列已存在时 sqlite3 报 duplicate column，忽略即可。
	sqlite3 "$DB" "ALTER TABLE dev ADD COLUMN nick TEXT NOT NULL DEFAULT '';" 2>/dev/null
	import_sites
	# 站点库/关键词表扩容后，把历史上"当时没认出来"的域名补一次分类（幂等）
	KWDB="$DB" lua /usr/lib/kidwatch/poll.lua --reclass >/dev/null 2>&1
}

import_sites() {
	[ -f "$SITES" ] || return 0
	{ echo "BEGIN;"
	  awk -F'\t' 'NF>=3 && substr($1,1,1)!="#" {
	      printf "INSERT INTO site(dom,name,cat,src) VALUES('"'"'%s'"'"','"'"'%s'"'"','"'"'%s'"'"',0) " \
	             "ON CONFLICT(dom) DO UPDATE SET name=excluded.name, cat=excluded.cat WHERE site.src=0;\n", $1, $2, $3
	  }' "$SITES"
	  echo "COMMIT;"
	} | sqlite3 "$DB"
}

# ---------------------------------------------------------------- 采样
# 主数据源：fwx 守护进程的实时表（active_host / active_app / get_all_users）。
# 固件仪表板的"活跃网址"用的就是这份数据，这里只是定时取一次并累积成历史。
do_poll() {
	do_init >/dev/null 2>&1
	KWDB="$DB" KWIV="${KWIV:-180}" lua /usr/lib/kidwatch/poll.lua
}

# procd 常驻入口：系统指标每 60 秒一个点（系统页的曲线要密），
# 流量每 KWIV 秒（默认 180）取一次快照——间隔必须与 poll.lua 里累加的 dur 一致。
do_watch() {
	IV="${KWIV:-180}"
	step=$((IV / 60)); [ "$step" -lt 1 ] && step=1
	n=0
	next_maint=0
	while :; do
		# dnsmasq 的查询日志是 O_APPEND 打开的，除非有人动它否则一直涨。
		# /tmp 是 116MB 的 tmpfs，实测 24 小时涨 114MB —— 涨满之后 LuCI 的
		# 模板缓存、其他服务的临时文件全部写不进去，表现成"路由器莫名其妙卡住"。
		# 主数据源走的是 fwx 的 DPI 表，这份日志只剩原始查询明细这一个用途，
		# 所以到上限直接截断即可（不用重启 dnsmasq，它下次写会落在新末尾）。
		[ "$(wc -c < "$DNSLOG" 2>/dev/null || echo 0)" -gt "${KWDNSMAX:-4194304}" ] && : > "$DNSLOG"
		KWDB="$DB" lua /usr/lib/kidwatch/poll.lua --sys
		n=$((n + 1))
		[ $((n % step)) -eq 0 ] && do_poll

		# 每日维护。原先只有 collect.awk 会调 do_maint，而 collect 已经默认
		# 不再定时跑 —— 于是 sysm/sess/win 只增不减，实测约 340KB/天，
		# 38MB 的 overlay 撑不到 3 个月就会被写满。
		# 时间点记在 meta 表里而不是用循环计数：计数器每次重启都归零，
		# 路由器一周重启一次就永远等不到满 1440 轮。
		if [ "$next_maint" = 0 ]; then
			l=$(se "SELECT COALESCE((SELECT CAST(v AS INTEGER) FROM meta WHERE k='maint'),0);" 2>/dev/null | tr -dc '0-9')
			[ -z "$l" ] && l=0
			if [ "$l" -gt 0 ]; then
				next_maint=$(( l + ${KWMAINT:-86400} ))
			else
				# 从没维护过：开机 5 分钟后补一次，先把历史垃圾收掉
				next_maint=$(( $(now) + 300 ))
			fi
		fi
		if [ "$(now)" -ge "$next_maint" ]; then
			do_maint
			se "INSERT OR REPLACE INTO meta(k,v) VALUES('maint','$(now)');" >/dev/null 2>&1
			next_maint=$(( $(now) + ${KWMAINT:-86400} ))
		fi
		sleep 60
	done
}

# 遗留：解析 dnsmasq 日志 + conntrack 的老路子，默认不再定时执行。
# 只在需要"域名级原始明细"时手动跑一次。
do_collect() {
	do_init >/dev/null 2>&1
	rm -f "$TMP/emit.sql"
	KWDB="$DB" KWTMP="$TMP" KWDNS="$DNSLOG" exec "$AWK" -f /usr/lib/kidwatch/collect.awk
}

# ---------------------------------------------------------------- 范围
parse_range() {
	case "${1:-today}" in
		today)     F=$(nmid "$(date +%Y-%m-%d)"); T=$F ;;
		yesterday) T=$(nmid "$(date +%Y-%m-%d)"); F=$((T-86400)) ;;
		[0-9]*d)   N=${1%d}; T=$(nmid "$(date +%Y-%m-%d)"); F=$((T-(N-1)*86400)) ;;
		*,*)       F=${1%%,*}; T=${1#*,} ;;
		*)         F=$(nmid "$(date +%Y-%m-%d)"); T=$F ;;
	esac
}

cond() {
	R="d.day>=$F AND d.day<=$T"
	[ -n "${M:-}" ] && R="$R AND d.mac='$(sq "$M")'"
	[ -n "${C:-}" ] && R="$R AND COALESCE(s.cat,'other')='$(sq "$C")'"
	[ -n "${Q:-}" ] && R="$R AND (d.dom LIKE '%$(sq "$Q")%' OR COALESCE(s.name,'') LIKE '%$(sq "$Q")%')"
	[ "${NOCDN:-0}" = 1 ] && R="$R AND COALESCE(s.cat,'other')<>'cdn'"
	printf '%s' "$R"
}

metric_sql() {
	case "${1:-dur}" in
		by|bytes|traffic) printf 'by' ;;
		n|visits)         printf 'n' ;;
		*)                printf 'dur' ;;
	esac
}

# ---------------------------------------------------------------- 查询
q_overview() {
	R=$(cond); O=$(metric_sql "${MET:-dur}")
	# agg 用于站点维度；perdev 给"上网时长"用——采样是把一轮时长摊到各站点，
	# 按设备累加后仍可能超过 24 小时（并发连接多），所以按设备封顶一天。
	sj "
	WITH agg AS (
	  SELECT d.dom AS dom, SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	  FROM daily d LEFT JOIN site s ON s.dom=d.dom
	  WHERE $R GROUP BY d.dom),
	perdev AS (
	  SELECT d.mac AS mac, SUM(d.dur) AS dw
	  FROM daily d LEFT JOIN site s ON s.dom=d.dom
	  WHERE $R GROUP BY d.mac),
	topx AS (
	  SELECT a.dom AS dom, a.dur AS dur, a.by AS by, a.n AS n
	  FROM agg a LEFT JOIN site s2 ON s2.dom=a.dom
	  WHERE a.dom<>'' AND COALESCE(s2.cat,'other')<>'cdn')
	SELECT
	  (SELECT COALESCE(SUM(MIN(dw,86400)),0) FROM perdev)   AS dur,
	  (SELECT COALESCE(SUM(by),0)  FROM agg)                AS by,
	  (SELECT COUNT(*) FROM agg WHERE dom<>'')              AS sites,
	  (SELECT COALESCE(SUM(n),0)   FROM agg)                AS visits,
	  (SELECT dom  FROM topx ORDER BY $O DESC, dur DESC LIMIT 1) AS top_dom,
	  (SELECT COALESCE($O,0) FROM topx ORDER BY $O DESC, dur DESC LIMIT 1) AS top_val,
	  (SELECT COALESCE((SELECT name FROM site WHERE dom=(SELECT dom FROM topx ORDER BY $O DESC, dur DESC LIMIT 1)),'')) AS top_name,
	  $F AS f, $T AS t;"
}

q_top() {
	R=$(cond); O=$(metric_sql "${MET:-dur}"); L=${LIM:-10}
	# cat='cdn' 是 CDN/统计/云服务等基础设施，不是"站点"，默认不进榜单，
	# 否则 Akamai/AWS/阿里CDN 会把真实站点全挤掉（占比仍在 cats 里体现）。
	RC=""
	if [ -z "${C:-}" ]; then
		RC="AND COALESCE(s.cat,'other')<>'cdn' AND d.dom<>''"
	fi
	sj "
	SELECT d.dom AS dom,
	       COALESCE(s.name,'') AS name,
	       COALESCE(s.cat,'other') AS cat,
	       SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	FROM daily d LEFT JOIN site s ON s.dom=d.dom
	WHERE $R $RC GROUP BY d.dom
	ORDER BY $O DESC, dur DESC LIMIT $L;"
}

q_cats() {
	R=$(cond)
	sj "
	SELECT COALESCE(s.cat,'other') AS cat,
	       SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	FROM daily d LEFT JOIN site s ON s.dom=d.dom
	WHERE $R AND d.dom<>'' GROUP BY COALESCE(s.cat,'other') ORDER BY dur DESC;"
}

q_hours() {
	MF=""; [ -n "${M:-}" ] && MF="AND t.mac='$(sq "$M")'"
	sj "
	SELECT CAST(strftime('%H', t.ts1, 'unixepoch', 'localtime') AS INTEGER) AS h,
	       COALESCE(s.cat,'other') AS cat,
	       SUM(t.dur) AS dur, SUM(t.up+t.dn) AS by
	FROM sess t LEFT JOIN site s ON s.dom=t.dom
	WHERE t.day>=$F AND t.day<=$T AND t.dom<>'' $MF
	GROUP BY h, COALESCE(s.cat,'other') ORDER BY h;"
}

q_days() {
	R=$(cond)
	sj "
	SELECT d.day AS day, SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	FROM daily d LEFT JOIN site s ON s.dom=d.dom
	WHERE $R GROUP BY d.day ORDER BY d.day;"
}

q_list() {
	R=$(cond); O=$(metric_sql "${MET:-dur}"); L=${LIM:-50}; P=${OFF:-0}
	TOT=$(sj "SELECT COUNT(*) AS c FROM (SELECT d.day,d.mac,d.dom FROM daily d LEFT JOIN site s ON s.dom=d.dom WHERE $R GROUP BY d.day,d.mac,d.dom);" | sed -n 's/.*"c":\([0-9]*\).*/\1/p')
	# 站点级字节：固件只给到"设备当日总量"，这里按各域名占用时长把总量摊下去。
	# 分摊后同一设备各域名加起来 == 这台设备的真实当日流量（不会凭空多出来），
	# 前端的数字一律带"≈"，别当成实测值。td 是这台设备当天的时长合计。
	ROWS=$(sj "
	WITH td AS (
	  SELECT d.day AS day, d.mac AS mac, SUM(d.dur) AS td
	  FROM daily d LEFT JOIN site s ON s.dom=d.dom
	  WHERE $R GROUP BY d.day, d.mac)
	SELECT d.day AS day, d.mac AS mac,
	       COALESCE(NULLIF(dv.alias,''),NULLIF(dv.nick,''),NULLIF(dv.host,''),d.mac) AS who,
	       d.dom AS dom,
	       COALESCE(s.name,'') AS name,
	       COALESCE(s.cat,'other') AS cat,
	       SUM(d.dur) AS dur,
	       CAST(COALESCE(SUM(CASE WHEN td.td > 0
	              THEN (COALESCE(dd.up,0)+COALESCE(dd.dn,0)) * d.dur * 1.0 / td.td
	              ELSE d.up + d.dn END),0) AS INTEGER) AS by,
	       SUM(d.n) AS n
	FROM daily d
	LEFT JOIN site s   ON s.dom=d.dom
	LEFT JOIN dev  dv  ON dv.mac=d.mac
	LEFT JOIN devday dd ON dd.day=d.day AND dd.mac=d.mac
	LEFT JOIN td       ON td.day=d.day AND td.mac=d.mac
	WHERE $R GROUP BY d.day, d.mac, d.dom
	ORDER BY $O DESC, dur DESC LIMIT $L OFFSET $P;")
	[ -z "$ROWS" ] && ROWS="[]"
	printf '{"total":%s,"rows":%s}' "${TOT:-0}" "$ROWS"
}

q_sess() {
	MF=""; [ -n "${M:-}" ] && MF="AND mac='$(sq "$M")'"
	sj "SELECT ts0, ts1, dur, up, dn, n FROM sess
	    WHERE day=$DAY AND dom='$(sq "${DOM:-}")' $MF
	    ORDER BY ts0 LIMIT 400;"
}

# 某个时间窗内（通常是某一小时）这台设备连过哪些域名，按开始时间排。
# 夜间时间带点开一格就用它：家长要看到的是"1 点这小时它连了哪几个站、各多久"。
# ts0/ts1 两头夹到窗口边界，免得显示成 00:50–01:10 这种跨格区间。
q_sesswin() {
	A=${F:-0}; B=${T:-0}
	[ "$A" -gt 0 ] 2>/dev/null || return 0
	[ "$B" -gt "$A" ] 2>/dev/null || return 0
	MF=""; [ -n "${M:-}" ] && MF="AND mac='$(sq "$M")'"
	sj "SELECT dom,
	           MAX(ts0,$A) AS t0, MIN(ts1,$B) AS t1,
	           SUM(dur) AS dur, SUM(n) AS n
	    FROM sess WHERE ts1>$A AND ts0<$B $MF
	    GROUP BY dom ORDER BY MIN(ts0) LIMIT 120;"
}

q_devs() {
	D=$(nmid "$(date +%Y-%m-%d)")
	# 设备清单以固件为准（devlive 来自 fwx 的 get_all_users / visit_list），
	# dev 只提供别名与角色；两表按 mac 关联，避免各存一份设备信息。
	# 名字优先级：本页别名 > 固件备注(nick) > 主机名 > MAC —— 用户在固件
	# "终端列表"里起的备注，在这里也要认，否则同一台机器两处叫两个名字。
	sj "
	WITH u AS (
	  SELECT l.mac AS mac,
	         COALESCE(NULLIF(v.alias,''),NULLIF(v.nick,''),NULLIF(v.host,''),NULLIF(l.host,''),l.mac) AS name,
	         COALESCE(v.role,'child') AS role,
	         COALESCE(v.mode,'full')  AS mode,
	         COALESCE(v.alias,'') AS alias,
	         COALESCE(v.nick,'')  AS nick,
	         l.host AS host, l.ip AS ip, l.online AS online, l.wl AS wl, l.ts AS last
	  FROM devlive l LEFT JOIN dev v ON v.mac=l.mac
	  UNION ALL
	  SELECT v.mac, COALESCE(NULLIF(v.alias,''),NULLIF(v.nick,''),NULLIF(v.host,''),v.mac),
	         v.role, v.mode, v.alias, COALESCE(v.nick,''), COALESCE(v.host,''), COALESCE(v.ip,''), 0, 0, COALESCE(v.last,0)
	  FROM dev v WHERE NOT EXISTS(SELECT 1 FROM devlive l WHERE l.mac=v.mac)
	)
	SELECT u.mac AS mac, u.name AS name, u.role AS role, u.mode AS mode,
	       u.alias AS alias, u.nick AS nick, u.host AS host,
	       u.ip AS ip, u.online AS online, u.wl AS wl, u.last AS last,
	       MIN(COALESCE((SELECT SUM(dur) FROM daily WHERE mac=u.mac AND day=$D),0),86400) AS dur,
	       COALESCE((SELECT SUM(up+dn) FROM daily WHERE mac=u.mac AND day=$D),0) AS by
	FROM u ORDER BY dur DESC, last DESC;"
}

# 夜间窗口固定 22:30 -> 次日 06:00（与前端 72 格 x 5 分钟对应）
# TOD 把 ts 换算成"当日秒数"，负数取模要补一圈，否则前一天 23 点会被漏掉。
# 注意：DAY 在参数解析后才赋值，所以表达式必须在函数内部拼。
tod_expr() { echo "((((ts - $DAY) % 86400) + 86400) % 86400)"; }
# 夜间窗口 22:00 → 次日 06:00。原来从 22:30 起算，前端改按整点分格后
# 半小时的首格没有意义，边界跟着整点走（采集端 win 表本身是 5 分钟一格，不受影响）。
night_expr() { local t; t=$(tod_expr); echo "($t >= 79200 OR $t < 21600)"; }

q_night() {
	N=${NDAYS:-1}
	A=$((DAY + 22*3600 - (N-1)*86400))
	B=$((DAY + 86400 + 6*3600))
	MF=""; [ -n "${M:-}" ] && MF="AND mac='$(sq "$M")'"
	sj "SELECT ts, mac, air, on_s, fl, dq, by, ent, nd FROM win
	    WHERE ts>=$A AND ts<$B AND $(night_expr) $MF ORDER BY ts;"
}

q_base() {
	# 过去 7 个夜晚（不含今晚，今晚数据尚不完整会拉低基线）
	BA=$((DAY - 7*86400)); BB=$((DAY + 22*3600 + 1800))
	sj "
	SELECT mac, MAX(air) AS p90 FROM (
	  SELECT mac, air,
	         ROW_NUMBER() OVER (PARTITION BY mac ORDER BY air) AS rn,
	         COUNT(*)     OVER (PARTITION BY mac) AS c
	  FROM win WHERE ts>=$BA AND ts<$BB AND $(night_expr)
	) WHERE rn = MAX(1, CAST(c*0.9 AS INTEGER)) GROUP BY mac;"
}

q_sys() {
	case "${RANGE:-1h}" in
		1h)  A=$(( $(now) - 3600 ));    TB=sysm ;;
		24h) A=$(( $(now) - 86400 ));   TB=sysm ;;
		7d)  A=$(( $(now) - 604800 ));  TB=sysm ;;
		30d) A=$(( $(now) - 2592000 )); TB=sysh ;;
		*)   A=$(( $(now) - 3600 ));    TB=sysm ;;
	esac
	sj "SELECT ts,cpu,load,mem,tc,w24,w5 FROM $TB WHERE ts>=$A ORDER BY ts;"
}

q_stat() {
	sj "SELECT
	      (SELECT COUNT(*) FROM dev WHERE mode<>'ignore') AS devs,
	      (SELECT COALESCE(SUM(dur),0) FROM daily WHERE day=$(( $(now) / 86400 * 86400 - 28800 ))) AS dur,
	      (SELECT COUNT(*) FROM site) AS sites,
	      (SELECT COALESCE((SELECT v FROM meta WHERE k='size'),0)) AS sz,
	      (SELECT MAX(ts) FROM sysm) AS last_sys,
	      (SELECT MAX(ts) FROM win)  AS last_win,
	      (SELECT MAX(ts1) FROM sess) AS last_sess;"
}

q_sites() {
	L=${LIM:-300}
	W=""
	[ -n "${Q:-}" ] && W="WHERE dom LIKE '%$(sq "$Q")%' OR name LIKE '%$(sq "$Q")%'"
	sj "SELECT dom,name,cat,src FROM site $W ORDER BY src DESC, dom LIMIT $L;"
}

# ---------------------------------------------------------------- 写入
do_setdev() {
	do_init >/dev/null 2>&1
	MAC="$(sq "${1:-}")"; shift || true
	K="${1:-}"; V="$(sq "${2:-}")"
	[ -z "$K" ] && { echo '{"ok":false}'; return; }
	case "$K" in
		alias) se "INSERT INTO dev(mac,alias) VALUES('$MAC','$V') ON CONFLICT(mac) DO UPDATE SET alias='$V';" ;;
		role)  se "INSERT INTO dev(mac,role)  VALUES('$MAC','$V') ON CONFLICT(mac) DO UPDATE SET role='$V';" ;;
		mode)  se "INSERT INTO dev(mac,mode)  VALUES('$MAC','$V') ON CONFLICT(mac) DO UPDATE SET mode='$V';" ;;
		# 删除这台设备的全部痕迹。devlive 也要删，否则"设备清单以固件为准"
		# 那一支会立刻把它从 devlive 重新拼出来，看着像没删掉。
		del)   se "DELETE FROM dev WHERE mac='$MAC'; DELETE FROM devlive WHERE mac='$MAC';
		           DELETE FROM sess WHERE mac='$MAC'; DELETE FROM daily WHERE mac='$MAC';
		           DELETE FROM win WHERE mac='$MAC'; DELETE FROM devday WHERE mac='$MAC';" ;;
		*) return ;;
	esac
	echo '{"ok":true}'
}

do_setsite() {
	do_init >/dev/null 2>&1
	DOM="$(sq "${1:-}")"; NAM="$(sq "${2:-}")"; CAT="$(sq "${3:-other}")"
	se "INSERT INTO site(dom,name,cat,src) VALUES('$DOM','$NAM','$CAT',1)
	    ON CONFLICT(dom) DO UPDATE SET name='$NAM', cat='$CAT', src=1;"
	echo '{"ok":true}'
}

do_sethost() {
	[ -f /tmp/dhcp.leases ] || exit 0
	do_init >/dev/null 2>&1
	{ echo "BEGIN;"
	  while read -r exp mac ip host cid; do
	      [ -n "${mac:-}" ] || continue
	      [ "${host:-}" = "*" ] && host=""
	      printf "INSERT INTO dev(mac,host,ip,last) VALUES('%s','%s','%s',%s) ON CONFLICT(mac) DO UPDATE SET host=CASE WHEN excluded.host<>'' THEN excluded.host ELSE host END, ip=excluded.ip;\n" \
	             "$mac" "$(printf '%s' "$host" | sed "s/'/''/g")" "$ip" "$(now)"
	  done < /tmp/dhcp.leases
	  echo "COMMIT;"
	} | sqlite3 "$DB"
}

# ---------------------------------------------------------------- 维护
do_maint() {
	do_init >/dev/null 2>&1
	D=$(nmid "$(date +%Y-%m-%d)")
	se "
	DELETE FROM sess WHERE day < $((D - 14*86400));
	DELETE FROM daily WHERE day < $((D - 400*86400));
	DELETE FROM devday WHERE day < $((D - 400*86400));
	DELETE FROM win  WHERE ts  < $(( $(now) - 21*86400 ));
	INSERT OR REPLACE INTO sysh(ts,cpu,load,mem,tc,w24,w5)
	  SELECT (ts/3600)*3600, AVG(cpu), AVG(load), AVG(mem), MAX(tc), MAX(w24), MAX(w5)
	  FROM sysm WHERE ts < $(( $(now) - 2*86400 )) GROUP BY ts/3600;
	DELETE FROM sysm WHERE ts < $(( $(now) - 7*86400 ));
	DELETE FROM sysh WHERE ts < $(( $(now) - 90*86400 ));
	PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
	# 上面那句的 stdout 是 wal_checkpoint 的返回值（0|0|N），
	# 不重定向会被 procd 收进 syslog，看着像报错。
	sz=$(wc -c < "$DB")
	[ "$sz" -gt 25165824 ] && se "VACUUM;"
	do_sethost
}

do_rotate() {
	# 原来这里是「重启 dnsmasq + 重启采集」来腾日志空间，代价是断网一两秒，
	# 只为一个日志文件不值当。dnsmasq 以 O_APPEND 打开日志，截断后它会自己
	# 落在新末尾；collect.awk 那边有 dnspos 回退检测（s < dnspos 时重置）。
	: > "$DNSLOG"
}

# ---------------------------------------------------------------- 入口
cmd="${1:-}"; shift || true
case "$cmd" in
	init)     do_init ;;
	collect)  do_collect ;;
	query)
		fn="${1:-}"; shift || true
		F=0; T=0; M=""; C=""; Q=""; MET="dur"; LIM=""; OFF=""; DAY=0; DOM=""; RANGE="1h"; NDAYS=1
		while [ $# -gt 0 ]; do
			case "$1" in
				--range) parse_range "${2:-today}"; shift 2 ;;
				--from)  F=$2; shift 2 ;;
				--to)    T=$2; shift 2 ;;
				--mac)   M=$2; shift 2 ;;
				--cat)   C=$2; shift 2 ;;
				--q)     Q=$2; shift 2 ;;
				--met)   MET=$2; shift 2 ;;
				--lim)   LIM=$2; shift 2 ;;
				--nocdn) NOCDN=1; shift ;;
				--off)   OFF=$2; shift 2 ;;
				--day)   DAY=$2; shift 2 ;;
				--days)  NDAYS=$2; shift 2 ;;
				--dom)   DOM=$2; shift 2 ;;
				--win)   RANGE=$2; shift 2 ;;
				*) shift ;;
			esac
		done
		[ "$F" = "0" ] && [ "$T" = "0" ] && parse_range today
		[ "$DAY" = "0" ] && DAY=$(nmid "$(date +%Y-%m-%d)")
		case "$fn" in
			overview) q_overview ;;
			top)      q_top ;;
			cats)     q_cats ;;
			hours)    q_hours ;;
			days)     q_days ;;
			list)     q_list ;;
			sess)     q_sess ;;
			sesswin)  q_sesswin ;;
			devs)     q_devs ;;
			night)    q_night ;;
			base)     q_base ;;
			sys)      q_sys ;;
			stat)     q_stat ;;
			sites)    q_sites ;;
			*) echo '{"error":"unknown"}' ;;
		esac
		;;
	setdev)   do_setdev "$@" ;;
	setsite)  do_setsite "$@" ;;
	sethost)  do_sethost ;;
	poll)     do_poll ;;
	watch)    do_watch ;;
	sites)    import_sites ;;
	reclass)  import_sites
	          KWDB="$DB" lua /usr/lib/kidwatch/poll.lua --reclass ;;
	maint)    do_maint ;;
	rotate)   do_rotate "${1:-}" ;;
	*) echo "usage: kidwatch {init|poll|collect|query|setdev|setsite|sites|maint|rotate}" ;;
esac
