# Phantom UI shell image for the ARM64-only Cuttlefish device.
$(call inherit-product, device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk)

PRODUCT_NAME := phantom_cf_arm64_only_phone
PRODUCT_MODEL := Phantom UI Cuttlefish arm64 phone
PRODUCT_BRAND := Phantom

PRODUCT_PACKAGES += \
    PhantomSystemUI \
    PhantomShellProvider \
    phantom_shell_overlay_frameworks_base_core
