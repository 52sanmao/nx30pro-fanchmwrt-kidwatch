include $(TOPDIR)/rules.mk

PKG_NAME:=kidwatch
PKG_VERSION:=1.1.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=52sanmao <52sanmao@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/kidwatch
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Per-device usage accounting for the parent dashboard
  URL:=https://github.com/52sanmao/nx30pro-fanchmwrt-kidwatch
  DEPENDS:=+sqlite3-cli +iw +lua +luci-lib-jsonc
  PKGARCH:=all
endef

define Package/kidwatch/description
  Per-device usage accounting for OpenWrt, built on data the firmware
  already maintains.

  The primary source is the fwx daemon's own live tables -- the same ones
  behind the stock dashboard's "Active URLs" card: active_host (real
  connection Host/URL), active_app (appid + app name), class_list
  (app categories), get_all_users (device list / online state) and
  get_daily_top_users (per-device bytes).  A tiny Lua poller snapshots
  them every few minutes into a small SQLite database, so no log parsing
  and no extra daemon are needed.

  An optional legacy collector (dnsmasq log + nf_conntrack) can still be
  run by hand when raw per-domain detail is required.
endef

define Build/Compile
endef

define Package/kidwatch/conffiles
/etc/config/kidwatch
endef

define Package/kidwatch/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/usr/lib/kidwatch
	$(INSTALL_DIR) $(1)/etc/kidwatch
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN)  ./files/kidwatch.sh     $(1)/usr/bin/kidwatch
	$(INSTALL_DATA) ./files/poll.lua        $(1)/usr/lib/kidwatch/poll.lua
	$(INSTALL_DATA) ./files/collect.awk     $(1)/usr/lib/kidwatch/collect.awk
	$(INSTALL_DATA) ./files/sites.tsv       $(1)/etc/kidwatch/sites.tsv
	$(INSTALL_BIN)  ./files/kidwatch.init   $(1)/etc/init.d/kidwatch
	$(INSTALL_BIN)  ./files/kidwatch.prep   $(1)/etc/init.d/kidwatch-prep
	$(INSTALL_DATA) ./files/kidwatch.config $(1)/etc/config/kidwatch
	$(INSTALL_BIN)  ./files/90-kidwatch     $(1)/etc/uci-defaults/90-kidwatch
	# 升级固件时保住历史数据（sysupgrade 默认只留 keep.d 里列出的文件）
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/kidwatch.keep   $(1)/lib/upgrade/keep.d/kidwatch
endef

define Package/kidwatch/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/kidwatch-prep enable
	/etc/init.d/kidwatch enable
	/etc/init.d/kidwatch restart
}
exit 0
endef

$(eval $(call BuildPackage,kidwatch))
