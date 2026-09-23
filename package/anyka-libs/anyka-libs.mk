ANYKA_LIBS_VERSION = 1.0
ANYKA_LIBS_SITE = $(BR2_EXTERNAL_ANYKA_PATH)/package/anyka-libs
ANYKA_LIBS_SITE_METHOD = local

ANYKA_LIBS_INSTALL_STAGING = YES

define ANYKA_LIBS_INSTALL_STAGING_CMDS
	mkdir -p $(STAGING_DIR)/usr/lib
	cp -a $(@D)/lib/*.so* $(STAGING_DIR)/usr/lib/
endef

define ANYKA_LIBS_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib
	cp -a $(@D)/lib/*.so* $(TARGET_DIR)/usr/lib/
	mkdir -p $(TARGET_DIR)/etc
	cp -a $(@D)/etc/isp_*.conf $(TARGET_DIR)/etc/
endef

$(eval $(generic-package))
