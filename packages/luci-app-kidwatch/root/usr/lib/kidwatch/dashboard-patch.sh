#!/bin/sh
# 把 fanchmwrt 自带的几个页面换成我们修过的版本。
#
#   源文件   /usr/lib/kidwatch/<name>.htm         我们的版本（随包安装）
#   备份     /usr/lib/kidwatch/<name>.orig.htm    固件原版（首次套用时自动留存）
#   上一版   /usr/lib/kidwatch/<name>.shipped.htm 上次推上去的我们的版本
#   目标     见下方 PAGES 表
#
# 固件升级会把这些页面覆盖回原版，所以 kidwatch 服务每次开机都会重跑一次；
# 卸载时用 restore 还原，不留"孤儿"改版页面。
#
# 为什么要记"上一版"：我们自己也升级（1.3.4 → 1.3.5）。升级时 dst 已经不是
# 固件原版、也和 bak 不同，光看这两者分不清"用户刷了新固件"还是"我们换了新版"。
# 分不清就会把 .orig 覆盖成我们自己的旧版 —— 卸载时 restore 出来的就不是固件原版了。
# 有了 shipped 副本就能三者对照：dst == shipped 说明是我们自己换的，别动 bak。

CHANGED=0

apply_one() {
	src="$1"; bak="$2"; ship="$3"; dst="$4"
	[ -f "$src" ] || return 0
	[ -f "$dst" ] || return 0
	# /rom 是只读 squashfs，里面永远是固件原版；能读到就以它为准，
	# 比"猜当前位置是不是原版"可靠得多（1.3.4→1.3.5 那次就猜错过，
	# 把 .orig 覆盖成了我们自己的旧版）。
	rom="/rom$dst"
	seed() {
		if [ -f "$rom" ]; then cp "$rom" "$bak" 2>/dev/null
		else cp "$dst" "$bak" 2>/dev/null; fi
	}
	if [ ! -f "$bak" ]; then
		seed
	elif cmp -s "$dst" "$bak"; then
		: # dst 还是固件原版，备份有效
	elif [ -f "$ship" ] && cmp -s "$dst" "$ship"; then
		: # dst 是我们上次推上去的版本，bak 仍然代表固件原版
	elif [ -f "$rom" ] && ! cmp -s "$bak" "$rom" && ! cmp -s "$dst" "$rom"; then
		# 备份既不是固件原版、dst 也不是 —— 备份是坏的，用 /rom 重来
		cp "$rom" "$bak" 2>/dev/null
	else
		# 既不是固件原版、也不是我们推过的版本 —— 刷了新固件，用它重新存
		cp "$dst" "$bak" 2>/dev/null
	fi
	if cmp -s "$src" "$dst"; then
		cp "$src" "$ship" 2>/dev/null
		return 0
	fi
	cp "$src" "$dst" || return 1
	cp "$src" "$ship" 2>/dev/null
	CHANGED=1
}

restore_one() {
	bak="$1"; dst="$2"; ship="$3"
	rm -f "$ship" 2>/dev/null
	[ -f "$bak" ] || return 0
	[ -f "$dst" ] || return 0
	cmp -s "$bak" "$dst" && return 0
	cp "$bak" "$dst" || return 1
	CHANGED=1
}

PAGES="
/usr/lib/kidwatch/fwx-dashboard.htm|/usr/lib/kidwatch/fwx-dashboard.orig.htm|/usr/lib/kidwatch/fwx-dashboard.shipped.htm|/usr/lib/lua/luci/view/fwx_dashboard/dashboard.htm
/usr/lib/kidwatch/fwx-user-status.htm|/usr/lib/kidwatch/fwx-user-status.orig.htm|/usr/lib/kidwatch/fwx-user-status.shipped.htm|/usr/lib/lua/luci/view/user/user_status.htm
"

for line in $PAGES; do
	src="${line%%|*}"
	rest="${line#*|}"
	bak="${rest%%|*}"
	rest="${rest#*|}"
	ship="${rest%%|*}"
	dst="${rest#*|}"
	if [ "$1" = "restore" ]; then
		restore_one "$bak" "$dst" "$ship"
	else
		apply_one "$src" "$bak" "$ship" "$dst"
	fi
done

# 页面模板变了要清 modulecache，否则 uhttpd 还拿旧编译结果
[ "$CHANGED" = "1" ] && rm -rf /tmp/luci-modulecache

exit 0
