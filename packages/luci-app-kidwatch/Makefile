include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-kidwatch
PKG_VERSION:=1.1.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=52sanmao <52sanmao@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-kidwatch
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI parent dashboard for KidWatch
  URL:=https://github.com/52sanmao/nx30pro-fanchmwrt-kidwatch
  DEPENDS:=+luci-base +luci-compat +luci-lua-runtime +kidwatch
  PKGARCH:=all
endef

define Package/luci-app-kidwatch/description
  Parent-facing dashboard (家长看板) on top of the kidwatch collector:
  per-device screen time, domain ranking, category mix, hourly heatmap,
  late-night usage guard and CPU/temperature history.

  Also reorganises the firmware's own dashboard page (设备在前、指标在右)
  through htdocs/luci-static/resources/kidwatch/dashsys.js, which is
  attached to the theme header on install.
endef

define Build/Compile
endef

define Package/luci-app-kidwatch/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/kidwatch
	$(INSTALL_DIR) $(1)/www/luci-static/resources/kidwatch
	$(INSTALL_DIR) $(1)/usr/lib/kidwatch
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DATA) ./luasrc/controller/kidwatch.lua $(1)/usr/lib/lua/luci/controller/kidwatch.lua
	$(INSTALL_DATA) ./luasrc/view/kidwatch/main.htm  $(1)/usr/lib/lua/luci/view/kidwatch/main.htm
	# 仪表板重排脚本：固件那一页不归我们管，只能在主题 header 里插一行引用
	$(INSTALL_DATA) ./htdocs/luci-static/resources/kidwatch/dashsys.js $(1)/www/luci-static/resources/kidwatch/dashsys.js
	$(INSTALL_BIN)  ./root/usr/lib/kidwatch/dashsys-inject.sh $(1)/usr/lib/kidwatch/dashsys-inject.sh
	$(INSTALL_BIN)  ./root/etc/uci-defaults/95-kidwatch-dashsys $(1)/etc/uci-defaults/95-kidwatch-dashsys
endef

define Package/luci-app-kidwatch/postinst
#!/bin/sh
# 装完立即挂上去，不用等下次重启
[ -n "$${IPKG_INSTROOT}" ] || /usr/lib/kidwatch/dashsys-inject.sh
exit 0
endef

define Package/luci-app-kidwatch/prerm
#!/bin/sh
# 卸载时把注入的那两行摘掉，别在主题里留一条 404
[ -n "$${IPKG_INSTROOT}" ] || {
	for f in /usr/share/ucode/luci/template/themes/*/header.ut \
	         /usr/lib/lua/luci/view/themes/*/header.htm; do
		[ -f "$$f" ] || continue
		grep -q 'kw-dashsys' "$$f" 2>/dev/null || continue
		grep -v 'kw-dashsys' "$$f" | grep -v 'kidwatch/dashsys\.js' > "$$f.kwnew" && cat "$$f.kwnew" > "$$f"
		rm -f "$$f.kwnew"
	done
	rm -rf /tmp/luci-modulecache
	rm -f  /tmp/luci-indexcache
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-kidwatch))
