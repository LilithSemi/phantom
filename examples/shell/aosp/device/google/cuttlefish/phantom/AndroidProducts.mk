PRODUCT_MAKEFILES := \
    phantom_cf_arm64_only_phone:$(LOCAL_DIR)/phantom_cf_arm64_only_phone.mk \
    phantom_cf_x86_64_only_phone:$(LOCAL_DIR)/phantom_cf_x86_64_only_phone.mk

COMMON_LUNCH_CHOICES := \
    phantom_cf_arm64_only_phone-trunk_staging-userdebug \
    phantom_cf_x86_64_only_phone-trunk_staging-userdebug
