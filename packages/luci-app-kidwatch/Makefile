include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-kidwatch
PKG_VERSION:=1.0.0
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
endef

define Build/Compile
endef

define Package/luci-app-kidwatch/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/kidwatch
	$(INSTALL_DATA) ./luasrc/controller/kidwatch.lua $(1)/usr/lib/lua/luci/controller/kidwatch.lua
	$(INSTALL_DATA) ./luasrc/view/kidwatch/main.htm  $(1)/usr/lib/lua/luci/view/kidwatch/main.htm
endef

$(eval $(call BuildPackage,luci-app-kidwatch))
