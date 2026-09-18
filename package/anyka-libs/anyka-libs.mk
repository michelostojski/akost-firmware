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
	$(INSTALL) -D -m 0644 $(@D)/etc/isp_f37p_mipi_1lane_h3b.conf \
		$(TARGET_DIR)/etc/isp_f37p_mipi_1lane_h3b.conf
endef

$(eval $(generic-package))
