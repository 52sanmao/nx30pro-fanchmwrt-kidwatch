# NX30 Pro · 家长看板（KidWatch）云编译

H3C Magic NX30 Pro（MT7981 / mediatek-filogic）上的**域名级家庭上网看板**，以 OpenWrt 软件包形式交付。

- `packages/kidwatch` — 采集后端：dnsmasq 查询日志 + nf_conntrack + 802.11 airtime → SQLite，单 busybox-awk 常驻进程
- `packages/luci-app-kidwatch` — LuCI 前端：「家长看板」单页

## 两个 workflow

| workflow | 作用 | 耗时 |
| --- | --- | --- |
| `build-packages.yml` | 只编译两个 `.apk`，用官方 SDK，装到现有固件上即可用 | ~10 分钟 |
| `build-image.yml` | 从 FanchmWrt 源码出整机固件（已内置看板） | ~2–3 小时 |

## 用法

只装包（推荐先走这步，不动系统）：

```bash
gh workflow run build-packages.yml -f sdk_version=25.12.4
gh run watch
gh run download <run-id> -n kidwatch-apk-25.12.4 -D out
```

出整机固件：

```bash
gh workflow run build-image.yml -f branch=fanchmwrt-25.12.4
```

## 目标设备

`mediatek/filogic` · `h3c_magic_nx30-pro` · 64 MiB UBI 布局（`sysupgrade` 直接刷入）。

`configs/nx30pro-packages.txt` 是设备当前固件的完整软件包清单（312 项），
整机构建时据此还原功能集，避免刷完丢功能。

## 数据落在哪

`/etc/kidwatch/kw.db`（overlay），保留：明细 14 天、日聚合 400 天、5 分钟窗口 21 天。
库超过 24 MB 自动 `VACUUM`，dnsmasq 日志超过 24 MB 自动轮转。
