################################################################################
#
# ipcd — local RTSP/ONVIF/PTZ camera app (with the PTZ + IR patches)
#
################################################################################

IPCD_VERSION = local
IPCD_SITE = $(BR2_EXTERNAL_ANYKA_PATH)/package/ipcd/src
IPCD_SITE_METHOD = local

# ipcd links against the Anyka SDK blobs, so anyka-libs must be built and
# staged first.
IPCD_DEPENDENCIES = anyka-libs

# Link against the staged blobs (self-contained, reproducible — no external
# extraction path).
define IPCD_BUILD_CMDS
	$(TARGET_MAKE_ENV) \
		$(MAKE) -C $(@D) \
		TOOLCHAIN="$(HOST_DIR)/bin" \
		LIB_DIR="$(STAGING_DIR)/usr/lib"
endef

define IPCD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ipcd $(TARGET_DIR)/usr/bin/ipcd
endef
define IPCD_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ipcd $(TARGET_DIR)/usr/bin/ipcd
	$(INSTALL) -D -m 0755 $(STAGING_DIR)/usr/lib/librt.so $(TARGET_DIR)/lib/librt.so
endef

$(eval $(generic-package))
