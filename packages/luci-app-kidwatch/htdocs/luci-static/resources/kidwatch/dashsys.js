/* 仪表板重排 v3 —— 设备在前，指标在右
 *
 * 依据用户原话：
 *   「"设备，负载趋势"应该放在最前面，联网状态也可以显示在它里面」
 *   「"在线APP / 在线用户 / 连接数 / 今日流量"这些内容就放在右边往下」
 *   「"网络"应该也合在前面或放在前面」
 *
 * 所以整页只有三个区块：
 *
 *   ┌────────────────────────────────┬──────────────┐
 *   │ 设备状态                        │ 在线 APP   3  │
 *   │  型号 · 固件 · 运行时长 · 已联网   │ 在线用户   3  │
 *   │  ◯CPU  ◯内存   负载趋势（120 点） │ 连接数  1061  │
 *   │  温度 ▓▓░  磁盘 ▓░░              │ 今日流量 5.7GB│
 *   │  WAN / LAN / 网关 / DNS          │ 正在访问      │
 *   │  网口 wan lan1 lan2 lan3          │              │
 *   ├──────────────────────┬──────────┴──────────────┤
 *   │ 实时流量 eth1         │ App 时长                │
 *   ├──────────────────────┴─────────────────────────┤
 *   │ 活跃终端                                        │
 *   └────────────────────────────────────────────────┘
 *
 * 为什么这样切：
 *   · 路由器的第一身份是"一台设备"，健康度（CPU/内存/温度/负载趋势）和
 *     联网状态本来就是一件事的两面，拆成六张 300px 小卡反而看不出因果；
 *   · 四个计数是"此刻有多少"，属于旁证，竖排一列读起来是自上而下的顺序，
 *     不需要横跨整页去占一条横幅；
 *   · 真正的"看见了什么"（流量曲线、应用构成、谁在用）放在下面，按
 *     "多快 → 花在哪 → 谁" 排列。
 *
 * 删掉的两张都是重复：
 *   · 「今日流量排行」= 终端表里每台的今日流量，同一批数字画两遍；
 *   · 「活跃网址」= 终端表"当前URL"那一列，完整可搜的清单在「上网详单」。
 *   终端表里"上传/下载流量"两列也一并去掉，速率列已经说明此刻在跑多快。
 *
 * 不改固件 DOM 语义，只搬容器 + 覆盖样式；固件自己的轮询、绘图、
 * 移动端布局照常工作（我们只是把节点挪到别处，值仍然写在原节点上）。
 *
 * 落地：装包时由 /usr/lib/kidwatch/dashsys-inject.sh 往每个主题的 header.htm
 * 追加一行 <script src="/luci-static/resources/kidwatch/dashsys.js?v=x" defer>，
 * 所以不需要改固件、也不需要手动推文件。第一行的 data-page 判断让别的页面
 * 直接 return，不会多跑一遍。
 */
(function(){
  'use strict';

  var PAGE = (document.body && document.body.getAttribute('data-page')) || '';
  if (PAGE !== 'admin-fwx_dashboard' && PAGE !== 'admin-fwx-dashboard') return;

  var PRE = window.__KW_SYS__ || null;
  var S = { win: (PRE && PRE.win) || '1h', rows: (PRE && PRE.rows) || null, demo: !!(PRE && PRE.demo) };
  var charts = {};

  function dark(){
    var a = document.documentElement.getAttribute('data-darkmode');
    if (a == null) a = document.body.getAttribute('data-darkmode');
    return a === 'true';
  }
  function hhmm(ts){
    var d = new Date(ts * 1000);
    return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
  }
  function byId(id){ return document.getElementById(id); }
  function box(tag, cls, id){
    var d = document.createElement(tag || 'div');
    if (cls) d.className = cls;
    if (id) d.id = id;
    return d;
  }

  /* ---------------- 主题变量 ---------------- */
  var VARS =
    '--kx-ink:#111827;--kx-dim:#5b6472;--kx-faint:#949ba7;--kx-line:rgba(16,24,40,.085);' +
    '--kx-card:#fff;--kx-well:#f4f6f9;--kx-ac:#3b82f6;';
  var VARS_D =
    '--kx-ink:#e7e9ec;--kx-dim:#9aa3b2;--kx-faint:#6d7684;--kx-line:rgba(255,255,255,.10);' +
    '--kx-card:#171a1f;--kx-well:rgba(255,255,255,.055);--kx-ac:#5b9cf5;';

  /* ---------------- 样式 ---------------- */
  var CSS = [
    /* 三区块骨架。行高由内容决定，两列严格等高（stretch），不留半截空卡 */
    '.dash.kw-dash{display:grid;grid-template-columns:minmax(0,1fr) 266px;' +
      'grid-template-areas:"hero kpis" "traffic pie" "clients clients";' +
      'gap:14px;align-items:stretch;min-width:0;' + VARS + '}' +
    'html[data-darkmode="true"] .dash.kw-dash,body[data-darkmode="true"] .dash.kw-dash{' + VARS_D + '}' +
    /* 固件原骨架（.main-grid / .right-col / 搬空后的容器）一律不占位 */
    '.dash.kw-dash>*{display:none!important}' +
    '.dash.kw-dash>#kw-hero{display:flex!important}' +
    '.dash.kw-dash>#kw-kpis{display:flex!important}' +
    '.dash.kw-dash>#traffic-card{display:flex!important}' +
    '.dash.kw-dash>#pie-app-card{display:flex!important}' +
    '.dash.kw-dash>#active-clients-card{display:block!important}' +
    '#dashboard-mobile[data-kw-off]{display:none!important}' +

    /* 卡片底座 */
    '.dash.kw-dash .card{position:relative;box-sizing:border-box;margin:0;padding:13px 15px;' +
      'min-height:0!important;' +
      'border:1px solid var(--kx-line);border-radius:12px;background:var(--kx-card);' +
      'box-shadow:0 1px 2px rgba(16,24,40,.045);transition:border-color .18s,box-shadow .18s}' +
    '.dash.kw-dash .card:hover{box-shadow:0 3px 14px rgba(16,24,40,.07)}' +
    /* 标题：3px 竖条 + 13.5px，全站统一 */
    '#kw-hero .kp-t,#traffic-card .kp-t,#pie-app-card .kp-t,#active-clients-card .kp-t{position:relative;' +
      'margin:0;padding-left:9px;font-size:13.5px;font-weight:600;letter-spacing:0;' +
      'color:var(--kx-ink);line-height:1.4;display:flex;align-items:center;gap:8px}' +
    '#kw-hero .kp-t::before,#traffic-card .kp-t::before,#pie-app-card .kp-t::before,' +
    '#active-clients-card .kp-t::before{content:"";position:absolute;left:0;top:2px;width:3px;' +
      'height:12px;border-radius:2px;background:var(--kx-ac)}' +
    '#kw-hero .kp-t .sub,#traffic-card .kp-t .sub,#pie-app-card .kp-t .sub,' +
    '#active-clients-card .kp-t .sub{font-size:11px;font-weight:400;color:var(--kx-faint)}' +

    /* ============ ① 设备状态 ============ */
    '#kw-hero{grid-area:hero;flex-direction:column;min-width:0;padding:13px 16px 12px}' +
    '#kw-hero .kp-h{display:flex;align-items:center;gap:10px;min-height:20px}' +
    '#kw-hero .kx-live{margin-left:auto;display:inline-flex;align-items:center;font-size:11.5px;' +
      'font-weight:500;padding:2px 10px;border-radius:999px;background:var(--kx-well);' +
      'border:1px solid var(--kx-line);white-space:nowrap}' +
    /* 型号 / 主机名 / 固件 / 运行时长：从 sys-info-card 整块搬过来，横排成一条 meta */
    '#kw-hero .kx-meta{margin-top:6px}' +
    '#kw-hero .kx-meta .compact-kv{display:grid!important;grid-auto-flow:column!important;' +
      'grid-auto-columns:max-content!important;justify-content:start!important;' +
      'gap:2px 20px!important;padding:0!important;margin:0!important}' +
    '#kw-hero .kx-meta .compact-row{display:flex!important;align-items:baseline;gap:6px;' +
      'padding:0!important;background:none!important;border:0!important;margin:0!important;' +
      'width:auto!important;min-width:0;float:none!important}' +
    '#kw-hero .kx-meta .compact-row::after{display:none}' +
    '#kw-hero .kx-meta .compact-label{font-size:11px;color:var(--kx-faint);white-space:nowrap;' +
      'font-weight:400;min-width:0;width:auto!important;text-align:left;flex:none}' +
    '#kw-hero .kx-meta .compact-value{font-size:12px;font-weight:500;color:var(--kx-dim);' +
      'max-width:none;width:auto!important;text-align:left;overflow:visible;white-space:nowrap;' +
      'flex:0 1 auto}' +
    /* 主体：左 环+条，右 趋势 */
    '#kw-hero .kx-main{display:grid;grid-template-columns:226px minmax(0,1fr);gap:22px;' +
      'margin-top:11px;padding-top:11px;border-top:1px solid var(--kx-line);flex:1;min-height:0}' +
    '#kw-hero .kx-load{display:flex;flex-direction:column;justify-content:center;gap:11px;min-width:0}' +
    '#kw-hero .kx-trend{min-width:0;min-height:118px;display:flex}' +

    /* 运行状态：两个环并排 */
    '#kw-hero #running-status-card{border:0!important;background:transparent!important;' +
      'box-shadow:none!important;border-radius:0!important;padding:0!important;margin:0!important;' +
      'min-height:0!important;overflow:visible!important;position:static!important}' +
    '#kw-hero #running-status-card>div:first-child{display:none}' +
    '#kw-hero #running-status-card>div:last-child{display:flex!important;gap:18px!important;' +
      'justify-content:flex-start!important}' +
    '#kw-hero #running-status-card .circular-progress-wrapper{width:70px;height:70px;margin:0!important}' +
    '#kw-hero #running-status-card .circular-progress svg{width:70px;height:70px}' +
    '#kw-hero #running-status-card .circular-progress{width:70px;height:70px}' +
    /* 固件那两个环用的是青→白渐变，缩到 70px 之后在白底上几乎看不见进度。
       改成和趋势图同源的纯色：底环极浅、进度环一蓝一紫，两个环一眼分得开。 */
    '#kw-hero #running-status-card .progress-ring-bg{stroke:var(--kx-well)!important;stroke-width:6}' +
    '#kw-hero #running-status-card .progress-ring{stroke-width:6!important;stroke-linecap:round;' +
      'transition:stroke-dashoffset .5s}' +
    '#kw-hero #running-status-card .circular-progress.cpu .progress-ring{stroke:#378ADD!important}' +
    '#kw-hero #running-status-card .circular-progress.mem .progress-ring{stroke:#8B5CF6!important}' +
    '#kw-hero #running-status-card .circular-progress-text{font-size:12px!important;font-weight:600;' +
      'font-variant-numeric:tabular-nums}' +
    '#kw-hero #running-status-card .circular-progress-label{margin-top:4px!important;font-size:11px;' +
      'color:var(--kx-dim)}' +
    /* 温度 / 磁盘：两条细 meter，压到环下面 */
    '#kw-hero #env-storage-card{border:0!important;background:transparent!important;' +
      'box-shadow:none!important;border-radius:0!important;padding:0!important;margin:0!important;' +
      'min-height:0!important;overflow:visible!important;position:static!important}' +
    '#kw-hero #env-storage-card .env-row{gap:4px;padding:0;margin:0}' +
    '#kw-hero #env-storage-card .env-row+.env-row{margin-top:9px}' +
    '#kw-hero #env-storage-card .env-head{display:flex;justify-content:flex-start;' +
      'align-items:baseline;gap:8px;font-size:11px;color:var(--kx-dim)}' +
    '#kw-hero #env-storage-card .env-label{font-size:11px;font-weight:400;color:var(--kx-dim);' +
      'min-width:0;width:auto!important;text-align:left;flex:none;white-space:nowrap}' +
    '#kw-hero #env-storage-card .env-value{font-size:10.5px;font-weight:600;color:var(--kx-ink);' +
      'font-variant-numeric:tabular-nums;text-align:left;margin-left:0!important;max-width:none;' +
      'white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
    '#kw-hero #env-storage-card .meter{height:4px;border-radius:999px;background:var(--kx-well);' +
      'overflow:hidden;margin-top:3px}' +
    '#kw-hero #env-storage-card .meter .bar{height:4px;border-radius:999px;min-width:2px}' +

    /* 底部：联网状态 + 网口 */
    '#kw-hero .kx-net{margin-top:11px;padding-top:10px;border-top:1px solid var(--kx-line)}' +
    '#kw-hero .kx-netkv .compact-kv{display:grid!important;grid-auto-flow:column!important;' +
      'grid-auto-columns:max-content!important;justify-content:start!important;' +
      'gap:2px 22px!important;padding:0!important;margin:0!important}' +
    '#kw-hero .kx-netkv .compact-row{display:flex!important;align-items:baseline;gap:6px;' +
      'padding:0!important;background:none!important;border:0!important;margin:0!important;' +
      'width:auto!important;min-width:0;float:none!important}' +
    '#kw-hero .kx-netkv .compact-row::after{display:none}' +
    '#kw-hero .kx-netkv .compact-label{font-size:11px;color:var(--kx-faint);font-weight:400;' +
      'width:auto!important;min-width:0;text-align:left;white-space:nowrap;flex:none}' +
    '#kw-hero .kx-netkv .compact-value{font-size:11.5px;font-weight:500;color:var(--kx-dim);' +
      'max-width:none;width:auto!important;text-align:left;overflow:visible;white-space:nowrap;' +
      'font-variant-numeric:tabular-nums;flex:0 1 auto}' +
    '#kw-hero .kx-ports{margin-top:9px}' +
    '#kw-hero #port-status-card{border:0!important;background:transparent!important;' +
      'box-shadow:none!important;border-radius:0!important;padding:0!important;margin:0!important;' +
      'min-height:0!important;position:static!important;overflow:visible!important}' +
    '#kw-hero #port-status-card>.mini-title{display:none!important}' +
    '#kw-hero #port-status-grid,#kw-hero .port-grid{display:flex!important;flex-wrap:wrap;gap:6px!important}' +
    '#kw-hero .port-item{display:inline-flex!important;flex-direction:row;align-items:center;gap:5px;' +
      'padding:3px 9px!important;border-radius:7px;background:var(--kx-well);border:0;' +
      'min-width:0;width:auto!important;line-height:1.5}' +
    '#kw-hero .port-item .port-icon{width:11px;height:11px;flex:none;margin:0!important;opacity:.7}' +
    '#kw-hero .port-item .port-name{font-size:11px;font-weight:600;color:var(--kx-ink);line-height:1.5;' +
      'max-width:none}' +
    '#kw-hero .port-item .port-speed{font-size:10.5px;color:var(--kx-faint);line-height:1.5;' +
      'margin:0!important;max-width:none;white-space:nowrap}' +
    '#kw-hero .port-item.port-down{opacity:.45}' +

    /* ============ ② 右栏指标 ============ */
    '#kw-kpis{grid-area:kpis;flex-direction:column;gap:0;min-width:0;box-sizing:border-box;' +
      'padding:3px 15px 0;border:1px solid var(--kx-line);border-radius:12px;' +
      'background:var(--kx-card);box-shadow:0 1px 2px rgba(16,24,40,.045);overflow:hidden}' +
    '#kw-kpis>.mini{flex:1 1 0;display:flex!important;flex-direction:column;justify-content:center;' +
      'gap:0;margin:0!important;padding:7px 0!important;border:0!important;border-radius:0!important;' +
      'background:none!important;box-shadow:none!important;min-height:0;text-decoration:none}' +
    '#kw-kpis>.mini+.mini{border-top:1px solid var(--kx-line)!important}' +
    '#kw-kpis>.mini:hover .stat-label{color:var(--kx-ink)}' +
    '#kw-kpis>.mini .stat-head{display:flex;align-items:center;justify-content:space-between;' +
      'margin:0;gap:8px}' +
    '#kw-kpis>.mini .stat-label{font-size:11.5px;font-weight:400;color:var(--kx-dim);' +
      'letter-spacing:.01em}' +
    '#kw-kpis>.mini .stat-icon{opacity:.3;flex:none;transform:scale(.82);transform-origin:right center}' +
    '#kw-kpis>.mini .top-stat-value{font-size:25px;line-height:1.14;font-weight:600;' +
      'letter-spacing:-.02em;color:var(--kx-ink);font-variant-numeric:tabular-nums;margin:1px 0 0}' +
    /* 正在访问：作为右栏最后一块，与上面四个计数同宽 */
    '#kw-kpis>#active-app-card{flex:0 0 auto;margin:0!important;padding:9px 0 11px!important;' +
      'border:0!important;border-top:1px solid var(--kx-line)!important;border-radius:0!important;' +
      'background:none!important;box-shadow:none!important;overflow:hidden}' +
    '#kw-kpis>#active-app-card>.kp-t{font-size:12px;margin-bottom:8px;padding-left:8px}' +
    '#kw-kpis>#active-app-card>.kp-t::before{height:10px}' +
    '#active-apps{display:flex!important;flex-wrap:wrap;gap:8px 6px!important;min-height:0;' +
      'padding:0!important;grid-template-columns:none!important;overflow:visible}' +
    '#active-apps .app-item{flex:0 0 42px!important;min-width:0}' +
    '#active-apps .app-icon-wrap{width:30px;height:30px;margin:0 auto}' +
    '#active-apps .app-icon{width:30px;height:30px;border-radius:8px}' +
    '#active-apps .app-name{width:100%;text-align:center;white-space:nowrap;overflow:hidden;' +
      'text-overflow:ellipsis;font-size:10.5px;line-height:1.6;color:var(--kx-dim);margin:1px 0 0}' +

    /* ============ ③ 实时流量 ============ */
    '#traffic-card{grid-area:traffic;flex-direction:column;min-width:0;min-height:236px}' +
    '#traffic-card .kp-ch{display:flex;align-items:center;gap:10px;margin-bottom:2px;min-height:20px}' +
    '#traffic-card #wan-realtime-rate{margin:0 0 0 auto!important;padding:0!important;' +
      'text-align:left!important;font-size:11.5px!important;display:flex;align-items:center;' +
      'gap:14px;color:var(--kx-dim);font-variant-numeric:tabular-nums}' +
    '#traffic-card #wan-realtime-rate>span:not([id]){display:none}' +
    '#traffic-card #wan-up-rate,#traffic-card #wan-down-rate{font-size:13px;font-weight:600;' +
      'color:var(--kx-ink);font-variant-numeric:tabular-nums;white-space:nowrap}' +
    '#traffic-card #wan-up-rate::before{content:"\\2191";color:#1D9E75;margin-right:4px;font-weight:700}' +
    '#traffic-card #wan-down-rate::before{content:"\\2193";color:#378ADD;margin-right:4px;font-weight:700}' +
    '#traffic-card #line-wan{flex:1 1 auto;height:auto!important;min-height:184px!important;' +
      'max-height:none!important;min-width:0;margin-top:4px}' +

    /* ============ ④ App 时长 ============ */
    '#pie-app-card{grid-area:pie;flex-direction:column;min-width:0;min-height:0!important}' +
    '#pie-app-card>.card-head,#pie-app-card>h3{margin-bottom:2px}' +
    /* 固件用「#pie-app-card .chart-container」压的 min-height:400，只能用 !important 拨回来 */
    '#pie-app-card .chart-container{height:168px!important;min-height:0!important;' +
      'max-height:none!important;flex:none!important;margin-top:2px}' +
    '#pie-app-card #pie-app{height:168px!important}' +

    /* ============ ⑤ 活跃终端 ============ */
    '#active-clients-card{grid-area:clients;min-width:0;overflow:hidden}' +
    '#active-clients-card>.kp-t{margin-bottom:9px}' +
    '#active-clients-card table{width:100%;border-collapse:collapse;table-layout:fixed}' +
    /* 第 5、6 列（上传/下载总量）下线，列宽按留下的六列排 */
    '#active-clients-card th:nth-child(5),#active-clients-card td:nth-child(5),' +
      '#active-clients-card th:nth-child(6),#active-clients-card td:nth-child(6)' +
      '{display:none!important}' +
    '#active-clients-card th:nth-child(1){width:26%}' +
    '#active-clients-card th:nth-child(2){width:15%}' +
    '#active-clients-card th:nth-child(3),#active-clients-card th:nth-child(4){width:11%}' +
    '#active-clients-card th:nth-child(7){width:15%}' +
    '#active-clients-card th:nth-child(8){width:22%}' +
    '#active-clients-card th{font-size:11px;font-weight:500;color:var(--kx-faint);' +
      'padding:0 10px 7px;text-align:left;border:0;white-space:nowrap;background:none}' +
    '#active-clients-card td{padding:7px 10px;font-size:12.5px;border-top:1px solid var(--kx-line);' +
      'font-variant-numeric:tabular-nums;color:var(--kx-ink);white-space:nowrap;' +
      'overflow:hidden;text-overflow:ellipsis}' +
    '#active-clients-card .list tr:hover td{background:var(--kx-well)}' +
    '#active-clients-card .dashboard-device-icon{width:19px;height:19px;flex:0 0 19px;' +
      'border-radius:5px;font-size:10.5px}' +

    /* ============ 降级 ============ */
    '@media (max-width:1180px){' +
      '.dash.kw-dash{grid-template-columns:minmax(0,1fr) 232px}' +
      '#kw-hero #running-status-card .circular-progress-wrapper,' +
      '#kw-hero #running-status-card .circular-progress svg,' +
      '#kw-hero #running-status-card .circular-progress{width:54px;height:54px}' +
      '#kw-kpis>.mini .top-stat-value{font-size:22px}' +
    '}' +
    /* 单列：hero 在顶，四个计数横成一行，其余上下排 */
    '@media (max-width:1040px){' +
      '.dash.kw-dash{grid-template-columns:minmax(0,1fr);' +
        'grid-template-areas:"hero" "kpis" "traffic" "pie" "clients"}' +
      '#kw-kpis{display:grid!important;grid-template-columns:repeat(4,minmax(0,1fr));gap:9px}' +
      '#kw-kpis>.mini{flex:none}' +
      '#kw-kpis>#active-app-card{grid-column:1/-1}' +
      '#active-apps .app-item{flex:0 0 46px!important}' +
      '#pie-app-card .chart-container,#pie-app-card #pie-app{height:200px!important}' +
    '}' +
    '@media (max-width:820px){' +
      '#kw-hero .kx-main{grid-template-columns:minmax(0,1fr);gap:12px}' +
      '#kw-hero .kx-load{flex-direction:row;align-items:center;gap:22px}' +
      '#kw-hero #env-storage-card{flex:1;min-width:120px}' +
      '#kw-hero .kx-trend{min-height:110px}' +
    '}' +
    '@media (max-width:720px){' +
      '#kw-kpis{grid-template-columns:repeat(2,minmax(0,1fr))}' +
      '#kw-kpis>.mini .top-stat-value{font-size:22px}' +
      /* 终端表拆成条目式，别在 400px 里硬挤六列 */
      '#active-clients-card thead{display:none}' +
      '#active-clients-card table,#active-clients-card tbody{display:block;width:100%}' +
      '#active-clients-card tr{display:grid;grid-template-columns:1fr 1fr;gap:2px 12px;' +
        'padding:9px 0;border-top:1px solid var(--kx-line)}' +
      '#active-clients-card tr:first-child{border-top:0}' +
      '#active-clients-card td{display:block!important;width:auto;border:0!important;' +
        'padding:0!important;white-space:normal!important;overflow:visible;text-overflow:clip}' +
      '#active-clients-card td::before{content:attr(data-label);color:var(--kx-faint);' +
        'font-size:10.5px;margin-right:5px}' +
      '#active-clients-card td:first-child{grid-column:1/-1;margin-bottom:1px}' +
      '#active-clients-card td:first-child::before{display:none}' +
      '#active-clients-card td[colspan]{grid-column:1/-1}' +
      '#active-clients-card td[colspan]::before{display:none}' +
    '}'
  ].join('\n');

  /* ---------------- 骨架 ---------------- */
  function layout(){
    var dash = document.querySelector('.dash');
    if (!dash) return;
    dash.classList.add('kw-dash');

    var top     = dash.querySelector('.top-stats'),
        traffic = byId('traffic-card'),
        apps    = byId('active-app-card'),
        pie     = byId('pie-app-card'),
        urls    = byId('active-url-card'),
        rank    = byId('bar-user-traffic-card'),
        clients = byId('active-clients-card'),
        sysi    = byId('sys-info-card'),
        net     = byId('network-card'),
        run     = byId('running-status-card'),
        env     = byId('env-storage-card'),
        ports   = byId('port-status-card');
    if (!traffic || !sysi) return;

    // 固件在 ≤768 会把卡片搬去 #dashboard-mobile；版式已被我们接管，那个容器留空
    var mob = byId('dashboard-mobile');
    if (mob && !mob.getAttribute('data-kw-off')) mob.setAttribute('data-kw-off', '1');

    // 两张重复的卡下线
    [urls, rank].forEach(function(el){
      if (el && !el.getAttribute('data-kw-drop')) el.setAttribute('data-kw-drop', '1');
    });

    // ① 设备英雄卡
    var hero = byId('kw-hero');
    if (!hero){
      hero = box('section', 'card', 'kw-hero');
      hero.innerHTML =
        '<div class="kp-h"><h3 class="kp-t">设备状态</h3><span class="kx-live" id="kx-live"></span></div>' +
        '<div class="kx-meta" id="kx-meta"></div>' +
        '<div class="kx-main">' +
          '<div class="kx-load"><div id="kx-rings"></div><div id="kx-env"></div></div>' +
          '<div class="kx-trend" id="kx-detail"></div>' +
        '</div>' +
        '<div class="kx-net"><div class="kx-netkv" id="kx-netkv"></div>' +
          '<div class="kx-ports" id="kx-ports"></div></div>';
      dash.appendChild(hero);
    }
    // 联网状态（原来是顶部第一个 KPI）搬进标题右侧
    var ist = byId('internet-status');
    if (ist && ist.parentNode !== byId('kx-live')){
      var shell = ist.closest ? ist.closest('a.mini') : null;
      byId('kx-live').appendChild(ist);
      if (shell && shell.classList.contains('mini')) shell.setAttribute('data-kw-drop', '1');
    }
    // 设备型号 / 主机名 / 固件 / 运行时长
    var kv = sysi.querySelector('.compact-kv');
    if (kv && kv.parentNode !== byId('kx-meta')) byId('kx-meta').appendChild(kv);
    // 运行状态环 + 温度磁盘
    if (run && run.parentNode !== byId('kx-rings')) byId('kx-rings').appendChild(run);
    if (env && env.parentNode !== byId('kx-env')) byId('kx-env').appendChild(env);
    // 联网状态（WAN / LAN / 网关 / DNS）+ 网口
    var nkv = net ? net.querySelector('.compact-kv') : null;
    if (nkv && nkv.parentNode !== byId('kx-netkv')) byId('kx-netkv').appendChild(nkv);
    if (ports && ports.parentNode !== byId('kx-ports')) byId('kx-ports').appendChild(ports);

    // ② 右栏指标：剩下四个计数 + 正在访问
    var kpis = byId('kw-kpis');
    if (!kpis){
      kpis = box('div', 'kx-kpis', 'kw-kpis');
      dash.appendChild(kpis);
    }
    if (top){
      Array.prototype.slice.call(top.querySelectorAll('a.mini')).forEach(function(a){
        if (a.getAttribute('data-kw-drop')) return;
        if (a.parentNode !== kpis) kpis.appendChild(a);
      });
      var holder = top.parentNode;
      if (holder && holder !== dash) holder.setAttribute('data-kw-drop', '1');
      top.setAttribute('data-kw-drop', '1');
    }
    if (apps && apps.parentNode !== kpis) kpis.appendChild(apps);

    // ③ 下面两块
    dash.appendChild(traffic);
    dash.appendChild(pie);
    if (clients) dash.appendChild(clients);

    // ④ 标题重写（保留固件原来的 h3 节点意义不大，直接换类名与文案）
    retitle(traffic, '实时流量', 'eth1 · 最近 60 秒');
    retitle(pie, '应用时长', '今日 · 按类目');
    retitle(clients, '活跃终端', '此刻在线');
    var ta = apps && apps.querySelector('h3');
    if (ta && ta.className !== 'kp-t'){ ta.className = 'kp-t'; ta.textContent = '正在访问'; }

    // ⑤ 速率读数搬进流量卡标题行
    if (traffic){
      var h3 = traffic.querySelector('h3');
      var ch = traffic.querySelector('.kp-ch');
      if (h3 && !ch){
        ch = box('div', 'kp-ch');
        traffic.insertBefore(ch, h3);
        ch.appendChild(h3);
        var rates = byId('wan-realtime-rate');
        if (rates) ch.appendChild(rates);
      }
    }

    if (!byId('kw-dash-css')){
      var st = document.createElement('style');
      st.id = 'kw-dash-css';
      st.textContent = CSS;
      document.head.appendChild(st);
    }
  }

  /* 卡片标题：统一成 .kp-t（固件原来的 h3 文案有的是旧叫法，顺手改掉） */
  function retitle(card, text, sub){
    if (!card) return;
    var h3 = card.querySelector('h3');
    if (!h3) return;
    if (h3.className !== 'kp-t') h3.className = 'kp-t';
    if (h3.getAttribute('data-kw-t') === text) return;
    h3.setAttribute('data-kw-t', text);
    h3.innerHTML = '';
    h3.appendChild(document.createTextNode(text));
    if (sub){
      var s = box('span', 'sub');
      s.textContent = sub;
      h3.appendChild(s);
    }
  }

  /* ---------------- 负载趋势 ---------------- */
  function series(rows, k){
    return rows.map(function(r){ return r[k] == null ? null : +r[k]; });
  }

  function load(win){
    if (S.rows && S.win === win){ render(S.rows); return; }
    var xhr = new XMLHttpRequest();
    xhr.open('GET', '/cgi-bin/luci/admin/kidwatch_api/call?fn=sys&win=' + win, true);
    xhr.onload = function(){
      var rows = [];
      try { rows = JSON.parse(xhr.responseText) || []; } catch(e){ rows = []; }
      S.rows = rows;
      render(rows);
    };
    xhr.onerror = function(){ render([]); };
    xhr.send();
  }

  function render(rows){
    rows = rows || [];
    var el = byId('kx-detail');
    if (!el) return;
    if (!rows.length){
      if (el.getAttribute('data-kw-empty') !== '1'){
        el.setAttribute('data-kw-empty', '1');
        el.innerHTML = '<div style="margin:auto;font-size:11.5px;color:var(--kx-faint)">' +
                       '还没有采样（每 60 秒记一个点）</div>';
      }
      return;
    }
    if (el.getAttribute('data-kw-empty') === '1'){
      el.removeAttribute('data-kw-empty');
      el.innerHTML = '';
    }
    syncRings(rows[rows.length - 1]);
    spark(rows);
  }

  /* 负载趋势：上下两条"跑道"（small multiples），而不是双轴叠在一张图上。
     CPU 与温度量纲不同，硬叠会让两条线互相穿过、谁也读不准；分成两条共用时间轴
     的窄带，形状可直接对比，标签写在各自左上角，省掉坐标轴与网格 —— 这一块要的是
     "最近一小时有没有异常"，不是查数。 */
  function spark(rows){
    var el = byId('kx-detail');
    if (!el || !window.echarts) return;
    var d = dark();
    var ink = d ? '#e7e9ec' : '#111827';
    var dim = d ? '#6d7684' : '#949ba7';
    var line = d ? 'rgba(255,255,255,.09)' : 'rgba(16,24,40,.07)';
    var lab = rows.map(function(x){ return hhmm(x.ts); });
    var cpu = series(rows, 'cpu'), tc = series(rows, 'tc');
    var last = rows[rows.length - 1] || {};
    var c = echarts.getInstanceByDom(el) || echarts.init(el, null, {renderer: 'svg'});
    charts.spark = c;

    var ticks = {};
    ticks[0] = 1; ticks[Math.floor((lab.length - 1) / 2)] = 1; ticks[lab.length - 1] = 1;

    c.setOption({
      animation: false,
      backgroundColor: 'transparent',
      // 标签用 title 画，不占 grid
      title: [
        {text: 'CPU', left: 0, top: 0, itemGap: 0,
         textStyle: {fontSize: 10.5, fontWeight: 400, color: dim, rich: {}}},
        {text: last.cpu == null ? '' : (+last.cpu).toFixed(0) + '%', left: 30, top: 0,
         textStyle: {fontSize: 11.5, fontWeight: 600, color: ink}},
        {text: '温度', left: 0, top: '53%', itemGap: 0,
         textStyle: {fontSize: 10.5, fontWeight: 400, color: dim}},
        {text: last.tc == null ? '' : (+last.tc).toFixed(0) + '°C', left: 30, top: '53%',
         textStyle: {fontSize: 11.5, fontWeight: 600, color: ink}}
      ],
      grid: [
        {left: 0, right: 2, top: 18, height: '33%'},
        {left: 0, right: 2, top: '66%', height: '22%'}
      ],
      tooltip: {
        trigger: 'axis',
        backgroundColor: d ? '#1f2430' : '#fff',
        borderColor: line,
        textStyle: {color: ink, fontSize: 12},
        axisPointer: {type: 'line', lineStyle: {color: line}},
        formatter: function(ps){
          var out = '<b>' + ps[0].axisValue + '</b>';
          ps.forEach(function(p){
            if (p.value == null) return;
            out += '<br/>' + p.marker + p.seriesName + ' ' + p.value +
                   (p.seriesName === '温度' ? ' °C' : ' %');
          });
          return out;
        }
      },
      xAxis: [
        {type: 'category', boundaryGap: false, gridIndex: 0, data: lab, show: false},
        {type: 'category', boundaryGap: false, gridIndex: 1, data: lab,
         axisLine: {lineStyle: {color: line}}, axisTick: {show: false}, axisLabel: {show: false}}
      ],
      yAxis: [
        {type: 'value', gridIndex: 0, min: 0, max: 100, show: false},
        {type: 'value', gridIndex: 1, scale: true, show: false,
         min: function(v){ return Math.max(0, Math.floor(v.min - 3)); }}
      ],
      series: [
        {name: 'CPU', type: 'line', smooth: true, showSymbol: false,
         xAxisIndex: 0, yAxisIndex: 0, data: cpu,
         lineStyle: {width: 1.5, color: '#378ADD'},
         areaStyle: {color: d ? 'rgba(55,138,221,.16)' : 'rgba(55,138,221,.11)'},
         itemStyle: {color: '#378ADD'}},
        {name: '温度', type: 'line', smooth: true, showSymbol: false,
         xAxisIndex: 1, yAxisIndex: 1, data: tc,
         lineStyle: {width: 1.2, color: '#BA7517'}, itemStyle: {color: '#BA7517'}}
      ]
    }, true);
    c.resize();
  }

  /* ---------------- 演示站：实时流量曲线 ----------------
   * 固件这张图靠页面轮询实时速率来画，离线快照没有数据源，永远是空的。
   * 演示站里用"今天每小时的实际流量"配一条曲线出来 —— 只为了让人能看清版式，
   * 标题旁会标注是样例。真机不执行这段（S.demo 为假）。
   */
  function demoTrend(){
    var FIX = window.__KW_FIX__ || {};
    var hrs = FIX['fn=hours&range=today'] || [];
    var w = {}, keys = [], now = new Date().getHours();
    hrs.forEach(function(x){
      if (x.cat === 'cdn') return;              // CDN 是后台，不算人的使用
      if (w[x.h] == null){ w[x.h] = 0; keys.push(x.h); }
      w[x.h] += (x.by || 0);
    });
    var peak = 0;
    keys.forEach(function(k){ if (w[k] > peak) peak = w[k]; });
    var cur = w[now] || peak || 1;

    // 锚点取页面上已经写好的速率，曲线末端才和标题旁的读数对得上
    var down = parseFloat(('' + (byId('wan-down-rate') || {}).textContent).replace(/[^\d.]/g, '')) || 5;
    var up = parseFloat(('' + (byId('wan-up-rate') || {}).textContent).replace(/[^\d.]/g, '')) || 1;

    var N = 60, seed = 20261025;
    function rnd(){ seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF; return seed / 0x7FFFFFFF; }
    var dn = [], upv = [], lab = [];
    var t = new Date();
    for (var i = N - 1; i >= 0; i--){
      var d = new Date(t.getTime() - i * 60000);
      lab.push(('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2));
    }
    var level = 0.55;
    for (var k = 0; k < N; k++){
      // 慢漂移 + 偶发尖峰，像真的无线环境，而不是一条正弦
      level += (rnd() - 0.5) * 0.14;
      if (level < 0.15) level = 0.15;
      if (level > 1.6) level = 1.6;
      var spike = rnd() > 0.94 ? 1.5 + rnd() * 1.6 : 1;
      var f = k / (N - 1);
      var shape = (cur / (peak || 1)) * (0.75 + 0.5 * Math.sin(f * 3.1));
      dn.push(+(down * level * spike * (0.7 + shape)).toFixed(2));
      upv.push(+(up * level * spike * (0.7 + shape * 0.6)).toFixed(2));
    }
    return { lab: lab, dn: dn, up: upv };
  }

  function drawDemoTraffic(){
    var el = byId('line-wan');
    if (!el || !window.echarts) return;
    if (el.getAttribute('data-kw-demo')) return;
    el.setAttribute('data-kw-demo', '1');
    var d = dark();
    var ink = d ? '#e7e9ec' : '#111827';
    var dim = d ? '#6d7684' : '#949ba7';
    var line = d ? 'rgba(255,255,255,.09)' : 'rgba(16,24,40,.07)';
    var T = demoTrend();
    var c = echarts.getInstanceByDom(el) || echarts.init(el, null, {renderer: 'svg'});
    c.setOption({
      animation: false,
      backgroundColor: 'transparent',
      grid: {left: 4, right: 8, top: 14, bottom: 2, containLabel: true},
      tooltip: {
        trigger: 'axis',
        backgroundColor: d ? '#1f2430' : '#fff',
        borderColor: line,
        textStyle: {color: ink, fontSize: 12},
        axisPointer: {type: 'line', lineStyle: {color: line}},
        formatter: function(ps){
          var s = '<b>' + ps[0].axisValue + '</b>';
          ps.forEach(function(p){
            s += '<br/>' + p.marker + p.seriesName + ' ' + p.value + ' KB/s';
          });
          return s;
        }
      },
      xAxis: {
        type: 'category', boundaryGap: false, data: T.lab,
        axisLine: {lineStyle: {color: line}}, axisTick: {show: false},
        axisLabel: {color: dim, fontSize: 10, hideOverlap: true, margin: 8}
      },
      yAxis: {
        type: 'value', axisLabel: {color: dim, fontSize: 10},
        splitLine: {lineStyle: {color: line}}, axisLine: {show: false}
      },
      series: [
        {name: '下载', type: 'line', smooth: true, showSymbol: false, data: T.dn,
         lineStyle: {width: 1.6, color: '#378ADD'},
         areaStyle: {color: d ? 'rgba(55,138,221,.14)' : 'rgba(55,138,221,.10)'},
         itemStyle: {color: '#378ADD'}},
        {name: '上传', type: 'line', smooth: true, showSymbol: false, data: T.up,
         lineStyle: {width: 1.2, color: '#1D9E75'}, itemStyle: {color: '#1D9E75'}}
      ]
    }, true);
    c.resize();

    var ch = document.querySelector('#traffic-card .kp-ch');
    if (ch && !ch.querySelector('.kx-tag')){
      var s = document.createElement('span');
      s.className = 'kx-tag';
      s.textContent = '演示站样例';
      s.style.cssText = 'font-size:10.5px;color:' + (d ? '#6d7684' : '#949ba7') +
        ';margin-left:8px;font-weight:400';
      ch.appendChild(s);
    }
  }

  /* 固件那张环形卡在离线/取不到数据时会显示 0%，用采样里的真值补一下 */
  function syncRings(r){
    var C = 219.911;
    var fix = function(tid, rid, pct, txt){
      var t = byId(tid), ring = byId(rid);
      if (!t) return;
      var cur = (t.textContent || '').trim();
      if (cur && cur !== '0%' && cur !== '0MB') return;   // 固件填的是真值就别动
      t.textContent = txt;
      if (ring && pct != null && isFinite(pct)){
        ring.style.strokeDashoffset =
          (C * (1 - Math.min(100, Math.max(0, pct)) / 100)).toFixed(3) + 'px';
      }
    };
    fix('cpu-text', 'cpu-ring', r.cpu, (r.cpu || 0).toFixed(0) + '%');
    syncStorageBar();
    // 内存总量固件没给，只补文字，环保持固件自己的比例
    fix('mem-text', null, null, (r.mem || 0) + 'MB');
  }

  /* 磁盘那条 meter 的宽度跟它右边的"(24%)"对不上（固件两处取自不同字段），
     按文字里的百分比补一次，免得条是空的、字说 24% */
  function syncStorageBar(){
    var t = byId('storage-overlay-text'), bar = byId('storage-overlay-bar');
    if (!t || !bar) return;
    var m = (t.textContent || '').match(/\(\s*(\d+(?:\.\d+)?)\s*%\)/);
    if (!m) return;
    var pct = Math.max(0, Math.min(100, parseFloat(m[1])));
    var cur = parseFloat((bar.style.width || '0').replace('%', '')) || 0;
    if (pct >= 3 && cur < pct - 3) bar.style.width = pct + '%';
  }

  /* 饼图兜底。
   * 固件这张图的外层写死 min-height:400px，我们把容器压到 168 之后，ECharts
   * 在 resize 时仍按旧高度算 radius（百分比换算成 123px > 84px 的画布半高），
   * 于是整块饼只剩边上一道弧。这里按容器的真实像素重设一次，并让 legend 待在底部。 */
  function fixPie(){
    var el = byId('pie-app');
    if (!el || !window.echarts) return;
    var i = echarts.getInstanceByDom(el);
    if (!i) return;
    var w = el.clientWidth, h = el.clientHeight;
    if (!w || !h) return;
    var r = Math.min(w, h) / 2;
    i.setOption({
      legend: {bottom: 0, top: 'auto', itemHeight: 7, itemWidth: 7,
               textStyle: {fontSize: 10.5}, itemGap: 8},
      series: [{radius: ['42%', '64%'], center: ['50%', '44%'],
                label: {show: false}, labelLine: {show: false}}]
    });
    i.resize();
  }

  /* ---------------- 图表跟随容器 ---------------- */
  function resizeCharts(){
    ['#line-wan', '#pie-app', '#kx-detail'].forEach(function(sel){
      var e = document.querySelector(sel);
      if (!e || !window.echarts) return;
      var i = echarts.getInstanceByDom(e);
      if (i){ try { i.resize(); } catch(err){} }
    });
    window.dispatchEvent(new Event('resize'));
  }

  function watchCharts(){
    if (!window.ResizeObserver) return;
    ['line-wan', 'pie-app', 'kx-detail'].forEach(function(id){
      var e = byId(id);
      if (!e || e.getAttribute('data-kw-ro')) return;
      e.setAttribute('data-kw-ro', '1');
      new ResizeObserver(function(){
        if (!window.echarts) return;
        var i = echarts.getInstanceByDom(e);
        if (i){ try { i.resize(); } catch(err){} }
      }).observe(e);
    });
  }

  /* ---------------- 启动 ---------------- */
  function pass(){
    layout();
    render(S.rows || []);
    if (!S.rows) load(S.win);
    window.setTimeout(function(){
      resizeCharts();
      watchCharts();
      fixPie();
      if (S.demo) window.setTimeout(drawDemoTraffic, 220);
    }, 260);
    // 固件自己在后面还会再画一次（它的 init 比我们晚），450ms 再钉一遍
    window.setTimeout(fixPie, 620);
  }

  function boot(){
    pass();
    // 固件的移动端布局会按 <768 把卡片搬去 #dashboard-mobile，切回来时卡片回到
    // 的是"原来那个父节点"（它的注释锚点在那儿），所以每次跨越断点都重排一遍。
    var mq = window.matchMedia('(max-width: 768px)');
    var onMq = function(){ window.setTimeout(pass, 60); };
    if (mq.addEventListener) mq.addEventListener('change', onMq);
    else if (mq.addListener) mq.addListener(onMq);
    window.addEventListener('resize', function(){
      Object.keys(charts).forEach(function(k){ if (charts[k]) charts[k].resize(); });
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else window.setTimeout(boot, 0);
})();
