ANYKA_MODULES_VERSION = stock
ANYKA_MODULES_SITE = $(BR2_EXTERNAL_ANYKA_PATH)/package/anyka-modules/files
ANYKA_MODULES_SITE_METHOD = local

define ANYKA_MODULES_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/ak_mci.ko $(TARGET_DIR)/lib/modules/ak_mci.ko
	mkdir -p $(TARGET_DIR)/usr/modules $(TARGET_DIR)/etc/config
	for f in $(@D)/*.ko; do \
		[ "$$(basename $$f)" = ak_mci.ko ] || $(INSTALL) -m 0644 $$f $(TARGET_DIR)/usr/modules/; \
	done
endef

$(eval $(generic-package))
