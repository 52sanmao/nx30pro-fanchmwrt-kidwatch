# kidwatch 采集器（busybox awk 单进程常驻）
#
# 数据来源
#   1) /proc/net/nf_conntrack  每条 LAN 会话带 user_mac / appid / 双向 bytes
#   2) dnsmasq log-queries=extra 日志  还原 域名 -> IP
#   3) iw dev <if> station dump  rx/tx duration(us)  判断"是否真的在用"
#   4) /proc/stat + hwmon  CPU / 温度
#
# 输出：每轮把 SQL 批量写进 $TMP/emit.sql，凑够一批后单事务提交。
# 设计要点：全程常驻单进程，状态在 awk 数组里，不落临时状态文件。

function q(s) { gsub(/'/, "''", s); return "'" s "'" }
function prep() { if (!ndirty) { print "BEGIN;" > SQLF; ndirty = 1 } }

function strip0(s) { sub(/^0+/, "", s); return (s == "") ? "0" : s }

function normip(v,   L, R, nl, nr, l, r, i, out, n) {
    if (index(v, ":") == 0) return v
    v = tolower(v)
    if (index(v, "::")) {
        L = v; sub(/::.*/, "", L)
        R = v; sub(/^.*::/, "", R)
        nl = (L == "") ? 0 : split(L, l, ":")
        nr = (R == "") ? 0 : split(R, r, ":")
        out = ""
        for (i = 1; i <= nl; i++)  out = out ((out == "") ? "" : ":") strip0(l[i])
        for (i = 1; i <= 8 - nl - nr; i++) out = out ":0"
        for (i = 1; i <= nr; i++)  out = out ":" strip0(r[i])
        if (nl == 0) out = substr(out, 2)
        return out
    }
    n = split(v, l, ":")
    out = ""
    for (i = 1; i <= n; i++) out = out ((out == "") ? "" : ":") strip0(l[i])
    return out
}

function maindom(d,   a, n, sfx) {
    d = tolower(d)
    sub(/\.$/, "", d)
    if (index(d, ":") > 0) return d
    if (d !~ /\./) return d
    n = split(d, a, ".")
    if (n < 2) return d
    sfx = a[n-1] "." a[n]
    if (sfx in SLD2) {
        if (n < 3) return d
        return a[n-2] "." sfx
    }
    return sfx
}

function midnight(t,   a) {
    split(strftime("%H:%M:%S", t), a, ":")
    return t - (a[1] * 3600 + a[2] * 60 + a[3])
}

function pbucket(t) { return int(t / BUCKET) * BUCKET }
function bkey(t) { return sprintf("%d", t) }

function num(ln,   a) { split(ln, a, ":"); gsub(/[^0-9]/, "", a[2]); return a[2] + 0 }

function tempof(p,   v) {
    if (p == "") return 0
    v = 0
    if ((getline v < p) <= 0) v = 0
    close(p)
    return int((v + 0) / 1000)
}

function load1(   v, a) {
    v = "0"
    if ((getline v < "/proc/loadavg") <= 0) v = "0"
    close("/proc/loadavg")
    split(v, a, " ")
    return a[1] + 0
}

function memused(   line, a, total, avail) {
    total = 0; avail = 0
    while ((getline line < "/proc/meminfo") > 0) {
        if (line ~ /^MemTotal:/)          { split(line, a, " "); total = a[2] + 0 }
        else if (line ~ /^MemAvailable:/) { split(line, a, " "); avail = a[2] + 0 }
    }
    close("/proc/meminfo")
    if (total == 0) return 0
    return int((total - avail) / 1024)
}

function filesize(p,   c, s) {
    c = "wc -c < " q(p) " 2>/dev/null"
    s = "0"
    if ((c | getline s) <= 0) s = "0"
    close(c)
    return s + 0
}

# ---------------- 初始化 ----------------
function load_sites(   c, line, a, n) {
    c = "sqlite3 -separator '\\t' " q(DB) " 'SELECT dom,cat FROM site' 2>/dev/null"
    while ((c | getline line) > 0) {
        n = split(line, a, "\t")
        if (n >= 2) CAT[a[1]] = a[2]
    }
    close(c)
}

function load_modes(   c, line, a, n) {
    c = "sqlite3 -separator '\\t' " q(DB) " 'SELECT mac,mode FROM dev' 2>/dev/null"
    while ((c | getline line) > 0) {
        n = split(line, a, "\t")
        if (n >= 2) MODE[a[1]] = a[2]
    }
    close(c)
}

function find_radios(   c, line) {
    nradio = 0
    c = "iw dev 2>/dev/null"
    while ((c | getline line) > 0) {
        if (line ~ /^[ \t]*Interface /) {
            sub(/^[ \t]*Interface /, "", line)
            sub(/[ \t].*$/, "", line)
            if (line ~ /-ap[0-9]+$/ || line ~ /^phy[0-9]/) {
                nradio++
                RADIO[nradio] = line
            }
        }
    }
    close(c)
}

function find_hwmon(   c, line, nm, d) {
    S_CPU = ""; S_W24 = ""; S_W5 = ""
    c = "ls -d /sys/class/hwmon/hwmon* 2>/dev/null"
    while ((c | getline line) > 0) {
        d = line
        nm = ""
        if ((getline nm < (d "/name")) > 0) sub(/\n$/, "", nm)
        close(d "/name")
        if (nm == "cpu_thermal")        S_CPU = d "/temp1_input"
        else if (nm == "mt7915_phy0")   S_W24 = d "/temp1_input"
        else if (nm == "mt7915_phy1")   S_W5  = d "/temp1_input"
    }
    close(c)
}

# ---------------- DNS ----------------
function read_dns(now,   line, n, i, a, tok, cid, cli, nm, val, qi, ip) {
    while ((getline line < DNSLOG) > 0) {
        dnspos += length(line) + 1
        if (index(line, " query[") == 0 && index(line, " reply ") == 0) continue
        n = split(line, a, " ")
        qi = 0
        for (i = 1; i <= n; i++) {
            if (a[i] ~ /^query\[/) { qi = i; break }
            if (a[i] == "reply")   { qi = i; break }
        }
        if (!qi) continue
        cid = (qi > 1) ? a[qi-1] : ""
        cli = cid; sub(/\/.*$/, "", cli)
        if (a[qi] ~ /^query\[/) {
            nm = a[qi+1]
            if (nm != "" && cid != "") {
                PEND[cid] = nm
                DCNT[bkey(pbucket(now)) SUBSEP cli]++
            }
        } else {
            if (qi + 3 > n) continue
            nm  = a[qi+1]
            val = a[qi+3]
            if (val ~ /^<.*>$/) continue
            if (val !~ /^[0-9a-fA-F:.]+$/) continue
            if (nm == "") nm = PEND[cid]
            if (nm == "") continue
            ip = normip(val)
            IPDOM[ip] = nm
            IPTS[ip]  = now
        }
    }
}

# ---------------- 日志轮转 ----------------
function check_log(now,   s) {
    if (last_chk != 0 && now - last_chk < 60) return
    last_chk = now
    s = filesize(DNSLOG)
    if (dnspos > 0 && s < dnspos) { close(DNSLOG); dnspos = 0; return }
    if (s > 25165824) {
        system("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
    }
}

# ---------------- conntrack ----------------
function scan_ct(now,   line, n, i, a, t, fam, proto, sip, dip, sp, dp, up, dn, mac, app, nb, k, b) {
    close("/proc/net/nf_conntrack")
    while ((getline line < "/proc/net/nf_conntrack") > 0) {
        if (index(line, "user_mac=") == 0) continue
        n = split(line, a, " ")
        if (n < 5) continue
        fam = a[1]; proto = a[3]
        sip = dip = sp = dp = mac = ""; up = dn = 0; nb = 0; app = 0
        for (i = 4; i <= n; i++) {
            t = a[i]
            if (t ~ /^src=/)          { if (sip == "") sip = substr(t, 5); else dip = substr(t, 5) }
            else if (t ~ /^sport=/)   { if (sp == "") sp = substr(t, 7); else dp = substr(t, 7) }
            else if (t ~ /^dport=/)   { if (dp == "") dp = substr(t, 7) }
            else if (t ~ /^bytes=/)   { nb++; if (nb == 1) up = substr(t, 7) + 0; else dn = substr(t, 7) + 0 }
            else if (t ~ /^user_mac=/) { if (mac == "") mac = substr(t, 10) }
            else if (t ~ /^appid=/)   { app = substr(t, 7) + 0 }
        }
        if (mac == "" || sip == "" || dip == "") continue
        if (index(sip, ":") == 0 && sip !~ /^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)/) continue
        IPMAC[sip] = mac
        if (index(sip, ":")) IPMAC[normip(sip)] = mac
        k = fam "|" proto "|" sip "|" sp "|" dip "|" dp
        if (k in F_ts0) {
            if (up + dn != F_tot[k]) { F_act[k] = now; F_tot[k] = up + dn }
            F_up[k] = up; F_dn[k] = dn; F_seen[k] = cyc
        } else {
            F_ts0[k] = now; F_act[k] = now; F_tot[k] = up + dn
            F_up[k] = up; F_dn[k] = dn; F_seen[k] = cyc
            F_mac[k] = mac; F_rip[k] = dip; F_app[k] = app
            b = pbucket(now)
            FLW[bkey(b) SUBSEP mac]++
            BMAC[bkey(b) SUBSEP mac] = 1
        }
    }
    for (k in F_seen) if (F_seen[k] != cyc) close_flow(k, now)
}

function close_flow(k, now,   dom, cat, t0, t1) {
    t0 = F_ts0[k] + 0; t1 = F_act[k] + 0
    if (t1 < t0) t1 = t0
    dom = resolve(F_rip[k], now)
    cat = (dom in CAT) ? CAT[dom] : "other"
    addflow(F_mac[k], dom, t0, t1, F_up[k] + 0, F_dn[k] + 0, F_app[k] + 0, cat)
    delete F_ts0[k]; delete F_act[k]; delete F_tot[k]; delete F_up[k]; delete F_dn[k]
    delete F_seen[k]; delete F_mac[k]; delete F_rip[k]; delete F_app[k]
}

function resolve(ip, now) {
    if (ip == "") return ""
    if (index(ip, ":")) ip = normip(ip)
    if (!(ip in IPDOM)) return ""
    if (now - IPTS[ip] > DNS_TTL) { delete IPDOM[ip]; return "" }
    return bestdom(IPDOM[ip])
}

# 最长后缀命中站点库，否则退回 eTLD+1 启发式
function bestdom(d,   t) {
    d = tolower(d); sub(/\.$/, "", d)
    if (index(d, ":")) return d
    t = d
    while (1) {
        if (t in CAT) return t
        if (!sub(/^[^.]+\./, "", t)) break
        if (t == "") break
    }
    return maindom(d)
}

# ---------------- 会话聚合 ----------------
function addflow(mac, dom, t0, t1, up, dn, app, cat,   day, k, vk, s, e, b) {
    if (mac == "") return
    if (MODE[mac] == "ignore") return
    if (MODE[mac] == "summary") { dom = ""; cat = "other" }
    day = midnight(t1)
    k = mac SUBSEP dom SUBSEP day
    if (!(k in P_dur)) {
        P_dur[k] = 0; P_up[k] = 0; P_dn[k] = 0; P_n[k] = 0
        P_a0[k] = t0; P_a1[k] = t0
    }
    s = t0; e = t1
    if (s < P_a1[k]) s = P_a1[k]
    if (e > s) P_dur[k] += e - s
    if (e > P_a1[k]) P_a1[k] = e
    if (t0 < P_a0[k]) P_a0[k] = t0
    P_up[k] += up; P_dn[k] += dn
    vk = mac SUBSEP dom
    if (!(vk in V_last) || t1 - V_last[vk] > VISIT_GAP) P_n[k]++
    if (!(vk in V_last) || t1 > V_last[vk]) V_last[vk] = t1
    if (app > 0) P_app[k] = app

    b = bkey(pbucket(t1))
    BMAC[b SUBSEP mac] = 1
    W_by[b SUBSEP mac]  += up + dn
    if (cat == "video" || cat == "game" || cat == "social" || cat == "music" || cat == "novel")
        W_ent[b SUBSEP mac] += up + dn
    if (dom != "") W_dom[b SUBSEP mac SUBSEP dom] = 1
}

function flush_pending(now, force,   k, a) {
    for (k in P_dur) {
        if (!force && now - P_a1[k] < IDLE + GRACE) continue
        split(k, a, SUBSEP)
        emit_sess(a[1], a[2], a[3], P_a0[k], P_a1[k], P_dur[k], P_up[k], P_dn[k], P_n[k], (k in P_app) ? P_app[k] : 0)
        delete P_dur[k]; delete P_up[k]; delete P_dn[k]; delete P_n[k]
        delete P_a0[k]; delete P_a1[k]; delete P_app[k]
    }
}

function emit_sess(mac, dom, day, t0, t1, dur, up, dn, n, app) {
    if (dur < 1 && up + dn < 1024) return
    if (dur < CYC && up + dn > 0) dur = CYC   # 采样粒度下限，向上取整到 10 秒
    if (n < 1) n = 1
    prep()
    printf("INSERT INTO sess(mac,dom,day,ts0,ts1,dur,up,dn,n,appid) VALUES(%s,%s,%d,%d,%d,%d,%d,%d,%d,%d);\n",
           q(mac), q(dom), day, t0, t1, dur, up, dn, n, app) > SQLF
    printf("INSERT INTO daily(day,mac,dom,dur,up,dn,n) VALUES(%d,%s,%s,%d,%d,%d,%d) " \
           "ON CONFLICT(day,mac,dom) DO UPDATE SET dur=dur+excluded.dur,up=up+excluded.up," \
           "dn=dn+excluded.dn,n=n+excluded.n;\n", day, q(mac), q(dom), dur, up, dn, n) > SQLF
    printf("INSERT INTO dev(mac,last) VALUES(%s,%d) ON CONFLICT(mac) DO UPDATE SET last=excluded.last;\n",
           q(mac), t1) > SQLF
    ndirty = 1
}

# ---------------- 5 分钟窗口 ----------------
function flush_bucket(bts,   k, mac, a, nd, d, pre, nk) {
    pre = bkey(bts) SUBSEP
    # 先把 DNS 计数按 IP 归并到设备
    for (k in DCNT) {
        if (index(k, pre) != 1) continue
        split(k, a, SUBSEP)
        mac = (a[2] in IPMAC) ? IPMAC[a[2]] : ""
        if (mac != "") { DQ[bkey(bts) SUBSEP mac] += DCNT[k]; BMAC[bkey(bts) SUBSEP mac] = 1 }
        delete DCNT[k]
    }
    nk = 0
    for (k in BMAC) {
        if (index(k, pre) != 1) continue
        split(k, a, SUBSEP); mac = a[2]
        nd = 0
        for (d in W_dom) if (index(d, k SUBSEP) == 1) nd++
        prep()
        printf("INSERT OR REPLACE INTO win(ts,mac,air,on_s,fl,dq,by,ent,nd) VALUES(%d,%s,%d,%d,%d,%d,%d,%d,%d);\n",
               bts, q(mac), AIR[k] + 0, ON[k] + 0, FLW[k] + 0, DQ[k] + 0,
               W_by[k] + 0, W_ent[k] + 0, nd) > SQLF
        delete BMAC[k]; delete W_by[k]; delete W_ent[k]
        delete AIR[k]; delete ON[k]; delete FLW[k]; delete DQ[k]
        nk++
    }
    for (d in W_dom) if (index(d, pre) == 1) delete W_dom[d]
    if (nk > 0) ndirty = 1
}

# ---------------- airtime ----------------
function read_air(now,   i, ln, mac, rx, tx, con, cmd, b) {
    b = pbucket(now)
    for (i = 1; i <= nradio; i++) {
        mac = ""; rx = 0; tx = 0; con = 0
        cmd = "iw dev " RADIO[i] " station dump 2>/dev/null"
        while ((cmd | getline ln) > 0) {
            if (ln ~ /^Station /) {
                if (mac != "") account_air(mac, rx, tx, con, b)
                mac = ln; sub(/^Station /, "", mac); sub(/[ \t].*$/, "", mac)
                rx = 0; tx = 0; con = 0
            } else if (ln ~ /^[ \t]*rx duration:/)   rx  = num(ln)
            else if (ln ~ /^[ \t]*tx duration:/)     tx  = num(ln)
            else if (ln ~ /^[ \t]*connected time:/)  con = num(ln)
        }
        close(cmd)
        if (mac != "") account_air(mac, rx, tx, con, b)
    }
}

function account_air(mac, rx, tx, con, b,   t, dair, dcon) {
    t = rx + tx
    dair = (mac in A_prev && t >= A_prev[mac]) ? t - A_prev[mac] : 0
    dcon = (mac in C_prev && con >= C_prev[mac]) ? con - C_prev[mac] : 0
    A_prev[mac] = t; C_prev[mac] = con
    if (mac == "") return
    AIR[bkey(b) SUBSEP mac] += int(dair / 1000)
    ON[bkey(b) SUBSEP mac]  += dcon
    BMAC[bkey(b) SUBSEP mac] = 1
}

# ---------------- 系统指标 ----------------
function read_sys(now,   line, a, u, nn, s, idle, tot, cpu) {
    line = ""
    if ((getline line < "/proc/stat") <= 0) { close("/proc/stat"); return }
    close("/proc/stat")
    split(line, a, " ")
    u = a[2] + 0; nn = a[3] + 0; s = a[4] + 0; idle = a[5] + 0
    tot = u + nn + s + idle
    if (prev_tot > 0 && tot > prev_tot) {
        cpu = (1 - (idle - prev_idle) / (tot - prev_tot)) * 100
        if (cpu < 0) cpu = 0
        if (cpu > 100) cpu = 100
        prep()
        printf("INSERT OR REPLACE INTO sysm(ts,cpu,load,mem,tc,w24,w5) VALUES(%d,%.1f,%.2f,%d,%d,%d,%d);\n",
               int(now / 60) * 60, cpu, load1(), memused(),
               tempof(S_CPU), tempof(S_W24), tempof(S_W5)) > SQLF
        ndirty = 1
    }
    prev_idle = idle; prev_tot = tot
}

# ---------------- 落盘 ----------------
function commit(   rc) {
    if (!ndirty) return
    print "COMMIT;" > SQLF
    close(SQLF)
    rc = system("sqlite3 " q(DB) " < " q(SQLF) " 2>>" q(TMP "/err.log"))
    if (rc != 0) system("cat " q(SQLF) " >> " q(TMP "/failed.sql"))
    ndirty = 0
}

# ================= 主循环 =================
BEGIN {
    split("com.cn net.cn org.cn gov.cn edu.cn ac.cn com.hk net.hk org.hk edu.hk " \
          "com.tw net.tw org.tw com.mo com.uk co.uk org.uk ac.uk gov.uk " \
          "co.jp ne.jp or.jp co.kr or.kr com.au net.au com.sg com.my co.id " \
          "com.vn com.ph com.br co.in", _s, " ")
    for (_i in _s) SLD2[_s[_i]] = 1

    DB    = ENVIRON["KWDB"];  if (DB == "")  DB  = "/etc/kidwatch/kw.db"
    TMP   = ENVIRON["KWTMP"]; if (TMP == "") TMP = "/tmp/kidwatch"
    DNSLOG= ENVIRON["KWDNS"]; if (DNSLOG == "") DNSLOG = "/tmp/kidwatch-dnsmasq.log"
    SQLF  = TMP "/emit.sql"

    CYC       = 10
    IDLE      = (ENVIRON["KW_IDLE"] != "") ? ENVIRON["KW_IDLE"] + 0 : 120
    GRACE     = (ENVIRON["KW_GRACE"] != "") ? ENVIRON["KW_GRACE"] + 0 : 60
    VISIT_GAP = 300
    BUCKET    = (ENVIRON["KW_BUCKET"] != "") ? ENVIRON["KW_BUCKET"] + 0 : 300
    DNS_TTL   = 7200
    AIR_EVERY = 60
    SYS_EVERY = 60

    system("mkdir -p " TMP)
    load_sites(); load_modes(); find_radios(); find_hwmon()

    cyc = 0; ndirty = 0; dnspos = 0
    last_air = 0; last_sys = 0; last_flush = 0; last_bkt = 0
    last_reload = 0; last_maint = 0; last_chk = 0
    prev_idle = -1; prev_tot = -1

    now = systime()
    last_bkt = pbucket(now)

    while (1) {
        now = systime()
        cyc++
        read_dns(now)
        scan_ct(now)

        if (last_air == 0 || now - last_air >= AIR_EVERY) { read_air(now); last_air = now }
        if (prev_idle < 0 || now - last_sys >= SYS_EVERY)  { read_sys(now); last_sys = now }
        if (now - last_flush >= 60) {
            flush_pending(now, 0)
            check_log(now)
            if (now - last_reload >= 300) { load_modes(); load_sites(); system("/usr/bin/kidwatch sethost >/dev/null 2>&1"); last_reload = now }
            if (now - last_maint >= 21600) { system("/usr/bin/kidwatch maint >/dev/null 2>&1"); last_maint = now }
            last_flush = now
        }

        bs = pbucket(now)
        if (bs != last_bkt) { flush_bucket(last_bkt); last_bkt = bs }

        commit()
        system("sleep " CYC " 2>/dev/null")
    }
}
