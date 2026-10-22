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
	sqlite3 "$DB" <<'EOF'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA wal_autocheckpoint=256;
CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);

CREATE TABLE IF NOT EXISTS dev(
  mac  TEXT PRIMARY KEY,
  alias TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL DEFAULT 'child',
  mode TEXT NOT NULL DEFAULT 'full',
  host TEXT NOT NULL DEFAULT '',
  ip   TEXT, first INTEGER, last INTEGER, base REAL
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
	import_sites
}

import_sites() {
	[ -f "$SITES" ] || return 0
	{ echo "BEGIN;"
	  awk -F'\t' 'NF>=3 && substr($1,1,1)!="#" {
	      printf "INSERT OR IGNORE INTO site(dom,name,cat,src) VALUES('"'"'%s'"'"','"'"'%s'"'"','"'"'%s'"'"',0);\n", $1, $2, $3
	  }' "$SITES"
	  echo "COMMIT;"
	} | sqlite3 "$DB"
}

# ---------------------------------------------------------------- 采集
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
	sj "
	WITH agg AS (
	  SELECT d.dom AS dom, SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	  FROM daily d LEFT JOIN site s ON s.dom=d.dom
	  WHERE $R GROUP BY d.dom)
	SELECT
	  (SELECT COALESCE(SUM(dur),0) FROM agg)                AS dur,
	  (SELECT COALESCE(SUM(by),0)  FROM agg)                AS by,
	  (SELECT COUNT(*) FROM agg)                            AS sites,
	  (SELECT COALESCE(SUM(n),0)   FROM agg)                AS visits,
	  (SELECT dom  FROM agg ORDER BY $O DESC, dur DESC LIMIT 1) AS top_dom,
	  (SELECT COALESCE($O,0) FROM agg ORDER BY $O DESC, dur DESC LIMIT 1) AS top_val,
	  (SELECT COALESCE((SELECT name FROM site WHERE dom=(SELECT dom FROM agg ORDER BY $O DESC, dur DESC LIMIT 1)),'')) AS top_name,
	  $F AS f, $T AS t;"
}

q_top() {
	R=$(cond); O=$(metric_sql "${MET:-dur}"); L=${LIM:-10}
	sj "
	SELECT d.dom AS dom,
	       COALESCE(s.name,'') AS name,
	       COALESCE(s.cat,'other') AS cat,
	       SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	FROM daily d LEFT JOIN site s ON s.dom=d.dom
	WHERE $R GROUP BY d.dom
	ORDER BY $O DESC, dur DESC LIMIT $L;"
}

q_cats() {
	R=$(cond)
	sj "
	SELECT COALESCE(s.cat,'other') AS cat,
	       SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	FROM daily d LEFT JOIN site s ON s.dom=d.dom
	WHERE $R GROUP BY cat ORDER BY dur DESC;"
}

q_hours() {
	MF=""; [ -n "${M:-}" ] && MF="AND t.mac='$(sq "$M")'"
	sj "
	SELECT CAST(strftime('%H', t.ts1, 'unixepoch', 'localtime') AS INTEGER) AS h,
	       COALESCE(s.cat,'other') AS cat,
	       SUM(t.dur) AS dur, SUM(t.up+t.dn) AS by
	FROM sess t LEFT JOIN site s ON s.dom=t.dom
	WHERE t.day>=$F AND t.day<=$T $MF
	GROUP BY h, cat ORDER BY h;"
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
	ROWS=$(sj "
	SELECT d.day AS day, d.mac AS mac,
	       COALESCE(NULLIF(dv.alias,''),NULLIF(dv.host,''),d.mac) AS who,
	       d.dom AS dom,
	       COALESCE(s.name,'') AS name,
	       COALESCE(s.cat,'other') AS cat,
	       SUM(d.dur) AS dur, SUM(d.up+d.dn) AS by, SUM(d.n) AS n
	FROM daily d
	LEFT JOIN site s ON s.dom=d.dom
	LEFT JOIN dev  dv ON dv.mac=d.mac
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

q_devs() {
	D=$(nmid "$(date +%Y-%m-%d)")
	sj "
	SELECT v.mac AS mac,
	       COALESCE(NULLIF(v.alias,''),NULLIF(v.host,''),v.mac) AS name,
	       v.role AS role, v.mode AS mode, v.host AS host, v.ip AS ip, v.last AS last,
	       COALESCE((SELECT SUM(dur) FROM daily WHERE mac=v.mac AND day=$D),0) AS dur,
	       COALESCE((SELECT SUM(up+dn) FROM daily WHERE mac=v.mac AND day=$D),0) AS by
	FROM dev v ORDER BY dur DESC, last DESC;"
}

q_night() {
	N=${NDAYS:-1}
	A=$((DAY + 22*3600 + 1800 - (N-1)*86400))
	B=$((DAY + 86400 + 6*3600))
	MF=""; [ -n "${M:-}" ] && MF="AND mac='$(sq "$M")'"
	sj "SELECT ts, mac, air, on_s, fl, dq, by, ent, nd FROM win
	    WHERE ts>=$A AND ts<$B $MF ORDER BY ts;"
}

q_base() {
	A=$((DAY + 22*3600 + 1800)); B=$((DAY + 86400 + 6*3600))
	BA=$((A - 7*86400)); BB=$((B - 7*86400))
	sj "
	SELECT mac, MAX(air) AS p90 FROM (
	  SELECT mac, air,
	         ROW_NUMBER() OVER (PARTITION BY mac ORDER BY air) AS rn,
	         COUNT(*)     OVER (PARTITION BY mac) AS c
	  FROM win WHERE ts>=$BA AND ts<$BB
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
		del)   se "DELETE FROM dev WHERE mac='$MAC'; DELETE FROM sess WHERE mac='$MAC'; DELETE FROM daily WHERE mac='$MAC'; DELETE FROM win WHERE mac='$MAC';" ;;
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
	DELETE FROM win  WHERE ts  < $(( $(now) - 21*86400 ));
	INSERT OR REPLACE INTO sysh(ts,cpu,load,mem,tc,w24,w5)
	  SELECT (ts/3600)*3600, AVG(cpu), AVG(load), AVG(mem), MAX(tc), MAX(w24), MAX(w5)
	  FROM sysm WHERE ts < $(( $(now) - 2*86400 )) GROUP BY ts/3600;
	DELETE FROM sysm WHERE ts < $(( $(now) - 7*86400 ));
	DELETE FROM sysh WHERE ts < $(( $(now) - 90*86400 ));
	PRAGMA wal_checkpoint(TRUNCATE);"
	sz=$(wc -c < "$DB")
	[ "$sz" -gt 25165824 ] && se "VACUUM;"
	do_sethost
}

do_rotate() {
	sz=$(wc -c < "$DNSLOG" 2>/dev/null || echo 0)
	if [ "$sz" -gt 25165824 ] || [ "${1:-}" = "force" ]; then
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		sleep 2
		/etc/init.d/kidwatch restart >/dev/null 2>&1
	fi
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
	maint)    do_maint ;;
	rotate)   do_rotate "${1:-}" ;;
	*) echo "usage: kidwatch {init|collect|query|setdev|setsite|maint|rotate}" ;;
esac
