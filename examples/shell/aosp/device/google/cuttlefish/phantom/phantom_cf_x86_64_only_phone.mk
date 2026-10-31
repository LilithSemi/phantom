# Phantom UI shell image for the x86_64-only Cuttlefish device.
$(call inherit-product, device/google/cuttlefish/vsoc_x86_64_only/phone/aosp_cf.mk)

PRODUCT_NAME := phantom_cf_x86_64_only_phone
PRODUCT_MODEL := Phantom UI Cuttlefish x86_64 phone
PRODUCT_BRAND := Phantom

PRODUCT_PACKAGES += \
    PhantomSystemUI \
    PhantomShellProvider \
    phantom_shell_overlay_frameworks_base_core
