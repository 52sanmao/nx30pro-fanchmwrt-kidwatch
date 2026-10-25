#!/bin/sh
# 把 fanchmwrt 自带的仪表板页面换成我们重构过的版本
#   /usr/lib/kidwatch/fwx-dashboard.htm       我们的版本（含布局重构与 bug 修复）
#   /usr/lib/kidwatch/fwx-dashboard.orig.htm  固件原版（首次套用时自动留存）
#
# 该文件归 luci-app-fwx-dashboard 所有，固件升级会把它覆盖回原版，
# 所以 kidwatch 服务每次开机都会调一次本脚本重新套用；卸载时用 restore 还原。

SRC=/usr/lib/kidwatch/fwx-dashboard.htm
BAK=/usr/lib/kidwatch/fwx-dashboard.orig.htm
DST=/usr/lib/lua/luci/view/fwx_dashboard/dashboard.htm

restore() {
	[ -f "$BAK" ] || exit 0
	cmp -s "$BAK" "$DST" && exit 0
	cp "$BAK" "$DST" || exit 1
	rm -rf /tmp/luci-modulecache
	exit 0
}

[ "$1" = "restore" ] && restore

[ -f "$SRC" ] || exit 0
[ -f "$DST" ] || exit 0

# 首次套用前把固件原版存一份，之后不再覆盖（避免把我们的版本存成"原版"）
if [ ! -f "$BAK" ]; then
	cp "$DST" "$BAK" 2>/dev/null
fi

cmp -s "$SRC" "$DST" && exit 0

cp "$SRC" "$DST" || exit 1
rm -rf /tmp/luci-modulecache
exit 0
