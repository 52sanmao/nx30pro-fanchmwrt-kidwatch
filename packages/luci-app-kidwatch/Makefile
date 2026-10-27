include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-kidwatch
PKG_VERSION:=1.3.4
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

  Also ships a rebuilt copy of the firmware's own dashboard page (same data,
  same IDs) with a cockpit-style layout: WAN status, router vitals and port
  LEDs on the top deck; live traffic plus active apps / visiting URLs in the
  middle; category pie and per-device traffic ranking below; and a filterable
  client table at the bottom. Fully responsive down to phone width using
  plain CSS -- the stock page carried a hard min-width:800px that scrolled
  the whole page sideways. Also chart empty states, pie labels moved out of
  the plot into a DOM legend, and a fix for the memory ring showing 0 MB.
  The stock file is backed up before the swap and restored on uninstall.

  And a patched device-list page: the Signal / Session columns are hidden by
  a single table-level class shared by <th> and <td> (they used to be toggled
  independently, so the whole table shifted two columns to the left), plus
  offline MAC OUI vendor lookup, device-type icons and inline renaming.
endef

define Build/Compile
endef

define Package/luci-app-kidwatch/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/kidwatch
	$(INSTALL_DIR) $(1)/usr/lib/kidwatch
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DATA) ./luasrc/controller/kidwatch.lua $(1)/usr/lib/lua/luci/controller/kidwatch.lua
	$(INSTALL_DATA) ./luasrc/view/kidwatch/main.htm  $(1)/usr/lib/lua/luci/view/kidwatch/main.htm
	# 固件页面的替换版本 + 套用脚本（原版由脚本首次运行时自行留存）
	$(INSTALL_DATA) ./root/usr/lib/kidwatch/fwx-dashboard.htm      $(1)/usr/lib/kidwatch/fwx-dashboard.htm
	$(INSTALL_DATA) ./root/usr/lib/kidwatch/fwx-user-status.htm    $(1)/usr/lib/kidwatch/fwx-user-status.htm
	$(INSTALL_BIN)  ./root/usr/lib/kidwatch/dashboard-patch.sh     $(1)/usr/lib/kidwatch/dashboard-patch.sh
	$(INSTALL_BIN)  ./root/etc/uci-defaults/96-kidwatch-dashboard  $(1)/etc/uci-defaults/96-kidwatch-dashboard
endef

define Package/luci-app-kidwatch/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /usr/lib/kidwatch/dashboard-patch.sh
exit 0
endef

define Package/luci-app-kidwatch/prerm
#!/bin/sh
# 卸载时把固件原版仪表板还原，不留一个"孤儿"改版页面
[ -n "$${IPKG_INSTROOT}" ] || /usr/lib/kidwatch/dashboard-patch.sh restore
exit 0
endef

$(eval $(call BuildPackage,luci-app-kidwatch))
