#!/bin/sh
# 把 fanchmwrt 自带的几个页面换成我们修过的版本。
#
#   源文件 /usr/lib/kidwatch/<name>.htm      我们的版本（随包安装）
#   备份   /usr/lib/kidwatch/<name>.orig.htm 固件原版（首次套用时自动留存）
#   目标   见下方 PAGES 表
#
# 固件升级会把这些页面覆盖回原版，所以 kidwatch 服务每次开机都会重跑一次；
# 卸载时用 restore 还原，不留"孤儿"改版页面。

CHANGED=0

apply_one() {
	src="$1"; bak="$2"; dst="$3"
	[ -f "$src" ] || return 0
	[ -f "$dst" ] || return 0
	if [ ! -f "$bak" ]; then
		# 首次套用：当前位置就是固件原版
		cp "$dst" "$bak" 2>/dev/null
	elif ! cmp -s "$src" "$dst" && ! cmp -s "$bak" "$dst"; then
		# dst 既不是我们的版本、也和旧备份不一样 —— 说明刷了新固件，
		# 这个页面已经被固件换成新版了。旧备份此时是上一代固件的页面，
		# 拿它 restore 会把旧页面倒灌回新固件（语法/接口都可能对不上），
		# 所以用当前这份重新存。
		cp "$dst" "$bak" 2>/dev/null
	fi
	cmp -s "$src" "$dst" && return 0
	cp "$src" "$dst" || return 1
	CHANGED=1
}

restore_one() {
	bak="$1"; dst="$2"
	[ -f "$bak" ] || return 0
	[ -f "$dst" ] || return 0
	cmp -s "$bak" "$dst" && return 0
	cp "$bak" "$dst" || return 1
	CHANGED=1
}

PAGES="
/usr/lib/kidwatch/fwx-dashboard.htm|/usr/lib/kidwatch/fwx-dashboard.orig.htm|/usr/lib/lua/luci/view/fwx_dashboard/dashboard.htm
/usr/lib/kidwatch/fwx-user-status.htm|/usr/lib/kidwatch/fwx-user-status.orig.htm|/usr/lib/lua/luci/view/user/user_status.htm
"

for line in $PAGES; do
	src="${line%%|*}"
	rest="${line#*|}"
	bak="${rest%%|*}"
	dst="${rest#*|}"
	if [ "$1" = "restore" ]; then
		restore_one "$bak" "$dst"
	else
		apply_one "$src" "$bak" "$dst"
	fi
done

# 页面模板变了要清 modulecache，否则 uhttpd 还拿旧编译结果
[ "$CHANGED" = "1" ] && rm -rf /tmp/luci-modulecache

exit 0
