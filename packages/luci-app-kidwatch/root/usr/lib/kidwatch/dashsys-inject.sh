#!/bin/sh
# 把 dashsys.js 挂到固件仪表板（admin/fwx/dashboard）上。
#
# 为什么必须在主题 header 里插一行：
#   仪表板是固件自己的页面，模板不在我们这个包里，我们没有它的控制权。
#   LuCI 渲染任何一页都会先渲染主题的 header —— 这是唯一"不改固件、热装 apk
#   即生效"的注入点。脚本第一行就判断 data-page 是不是仪表板，别的页面加载了
#   也只多一次 4KB 的请求。
#
# 两个路径都要扫，因为固件是 ucode 版 LuCI（模板 themes/<t>/header.ut），
# 但 luci-compat 的老式 Lua 主题（view/themes/<t>/header.htm）也可能存在：
#   /usr/share/ucode/luci/template/themes/*/header.ut   ← 本机实际用的
#   /usr/lib/lua/luci/view/themes/*/header.htm          ← 老路径，有就一起处理
#
# 幂等：
#   · 已经注入过就只把引用里的版本号改成当前版本（避免浏览器吃旧缓存）；
#   · apk 升级本包时 postinst 会再跑一次，主题包被升级覆盖后也能补回来；
#   · 找不到 header 文件（主题被换了）就静默退出，不影响装包。
#
# 改完必须清 LuCI 的模板缓存，否则页面还是旧的。

TAG='kw-dashsys'
SRC='/luci-static/resources/kidwatch/dashsys.js?v=1.1.1'
LINE="<script src=\"$SRC\" defer></script>"

inject_one() {
	f="$1"
	[ -f "$f" ] || return 0

	if grep -q 'kidwatch/dashsys\.js' "$f" 2>/dev/null; then
		sed -i "s|src=\"/luci-static/resources/kidwatch/dashsys\.js[^\"]*\"|src=\"$SRC\"|g" "$f"
		return 0
	fi

	if grep -q '</head>' "$f" 2>/dev/null; then
		# 用 cat 回写而不是 mv，保持原文件的 inode / 属主 / 权限不变
		awk -v tag="<!-- $TAG -->" -v line="$LINE" '
			!done && /<\/head>/ { printf "\t%s\n\t%s\n", tag, line; done = 1 }
			{ print }
		' "$f" > "$f.kwnew" 2>/dev/null && cat "$f.kwnew" > "$f" && rm -f "$f.kwnew"
	else
		printf '\n<!-- %s -->\n%s\n' "$TAG" "$LINE" >> "$f"
	fi
}

for d in /usr/share/ucode/luci/template/themes /usr/lib/lua/luci/view/themes; do
	[ -d "$d" ] || continue
	for f in "$d"/*/header.ut "$d"/*/header.htm; do
		inject_one "$f"
	done
done

# 模板缓存：ucode 版把编译结果放在 /tmp/luci-modulecache，Lua 版另有 indexcache
rm -rf /tmp/luci-modulecache 2>/dev/null
rm -f  /tmp/luci-indexcache* 2>/dev/null

exit 0
