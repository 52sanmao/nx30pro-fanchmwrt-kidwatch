include $(TOPDIR)/rules.mk

PKG_NAME:=kidwatch
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=52sanmao <52sanmao@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/kidwatch
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Per-device domain traffic accounting for the parent dashboard
  URL:=https://github.com/52sanmao/nx30pro-fanchmwrt-kidwatch
  DEPENDS:=+sqlite3-cli +iw
  PKGARCH:=all
endef

define Package/kidwatch/description
  Lightweight per-device, per-domain usage accounting for OpenWrt.

  Joins three cheap data sources -- the dnsmasq query log (IP to domain),
  nf_conntrack (per flow bytes and lifetime) and 802.11 station airtime --
  into a small SQLite database, then exposes it to the LuCI parent
  dashboard as JSON.  A single busybox-awk process does all the work, so
  there is no Python/Lua daemon and no measurable impact on forwarding.
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
