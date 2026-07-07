#!/bin/bash
set -o pipefail

# ============================================================
# warm — Infinity-X 16 build script for Crave
# Usage: bash build_infinity.sh
# ============================================================

DEVICE="warm"
BUILD_TYPE="userdebug"
BUILD_LOG="build.log"
START_TIME=$(date +%s)

print_step() {
    echo "===================================================="
    echo "  $1"
    echo "===================================================="
}

# ---- Optional Telegram notifications (skip if no token) ----
TG_MSG_ID=""
telegram_reply() {
    [ -z "$TG_TOKEN" ] && return 0
    local TEXT="$(date +"%d %b %Y %I:%M %p"): $1"
    curl -sS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "parse_mode=Markdown" \
        --data-urlencode "text=${TEXT}" >/dev/null 2>&1 || true
}

telegram_send_document() {
    [ -z "$TG_TOKEN" ] && return 0
    curl -sS -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
        -F "chat_id=${TG_CHAT}" \
        -F "document=@${1}" \
        -F "parse_mode=Markdown" \
        -F "caption=${2}" >/dev/null 2>&1 || true
}

sourceforge_upload() {
    local FILE="$1"
    if [ -f "$FILE" ] && [ -n "$SF_USER" ] && [ -n "$SF_PROJECT" ]; then
        scp "$FILE" "${SF_USER}@frs.sourceforge.net:/home/frs/project/${SF_PROJECT}/" 2>/dev/null && \
            echo "https://sourceforge.net/projects/${SF_PROJECT}/files/$(basename "$FILE")/download"
    fi
}

# ============================================================
# STEP 1 — Repo init + local manifest
# ============================================================
print_step "Removing old local manifests"
rm -rf .repo/local_manifests

print_step "Repo init (Infinity-X 16)"
repo init --no-repo-verify --git-lfs --depth 1 \
    -u https://github.com/ProjectInfinity-X/manifest \
    -b 16 \
    -g default,-mips,-darwin,-notdefault

print_step "Creating local manifest"
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/warm.xml << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="shyam" fetch="https://github.com/" />
  <remote name="bitstash" fetch="https://github.com/" />
  <remote name="niyush" fetch="https://github.com/" />
  <remote name="lineage" fetch="https://github.com/" />
  <project path="device/xiaomi/warm" name="Shyam-vadgama/device_xiaomi_warm" remote="shyam" revision="infinity" />
  <project path="vendor/xiaomi/warm" name="bitstash-io/vendor_xiaomi_warm" remote="bitstash" revision="lineage-23.2" />
  <project path="device/xiaomi/warm-kernel" name="Niyush-04/warm_kernel" remote="niyush" revision="hos3" />
  <project path="hardware/xiaomi" name="LineageOS/android_hardware_xiaomi" remote="lineage" revision="lineage-23.2" />
</manifest>
XMLEOF

# ============================================================
# STEP 2 — Sync
# ============================================================
print_step "Syncing source"
/opt/crave/resync.sh

# Verify vendor tree was synced
print_step "Verifying vendor tree"
if [ ! -f vendor/xiaomi/warm/warm-vendor.mk ]; then
    echo "vendor/xiaomi/warm/warm-vendor.mk not found after sync — fetching directly"
    mkdir -p vendor/xiaomi/warm
    git clone --depth=1 https://github.com/bitstash-io/vendor_xiaomi_warm.git \
        -b lineage-23.2 vendor/xiaomi/warm 2>&1 || {
        echo "ERROR: Failed to fetch vendor tree"
        exit 1
    }
fi

# ============================================================
# STEP 3 — Add pitti to qcom-caf
# ============================================================
print_step "Adding pitti to qcom-caf platform lists"
QCOM_DIR="hardware/qcom-caf/common"
if ! grep -q "QCOM_BOARD_PLATFORMS += pitti" "$QCOM_DIR/qcom_boards.mk"; then
    sed -i "/QCOM_BOARD_PLATFORMS += volcano/a\QCOM_BOARD_PLATFORMS += pitti" "$QCOM_DIR/qcom_boards.mk"
fi
if grep -q "UM_6_1_FAMILY := pineapple volcano" "$QCOM_DIR/qcom_defs.mk"; then
    sed -i "s/UM_6_1_FAMILY := pineapple volcano/UM_6_1_FAMILY := pineapple volcano pitti/" "$QCOM_DIR/qcom_defs.mk"
fi

# ============================================================
# STEP 4 — Apply Niyush-04 audio tree
# ============================================================
print_step "Downloading Niyush-04 audio branch files"
curl -sLo device/xiaomi/warm/BoardConfig.mk \
    https://raw.githubusercontent.com/Niyush-04/device_xiaomi_warm/audio/BoardConfig.mk
curl -sLo device/xiaomi/warm/device.mk \
    https://raw.githubusercontent.com/Niyush-04/device_xiaomi_warm/audio/device.mk
curl -sLo device/xiaomi/warm/proprietary-files.txt \
    https://raw.githubusercontent.com/Niyush-04/device_xiaomi_warm/audio/proprietary-files.txt
curl -sLo device/xiaomi/warm/extract-files.py \
    https://raw.githubusercontent.com/Niyush-04/device_xiaomi_warm/audio/extract-files.py
mkdir -p device/xiaomi/warm/configs/audio
curl -sLo device/xiaomi/warm/configs/audio/audio_policy_configuration.xml \
    https://raw.githubusercontent.com/Niyush-04/device_xiaomi_warm/audio/configs/audio/audio_policy_configuration.xml

# Remove deprecated A16 flag + prebuilt audio HAL flag
# (audio.primary.pitti is built from source in hardware/qcom-caf/sm8650/audio/primary-hal)
sed -i '/BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES/d' device/xiaomi/warm/BoardConfig.mk
sed -i '/TARGET_PROVIDES_AUDIO_HAL/d' device/xiaomi/warm/BoardConfig.mk

# ============================================================
# STEP 5 — Re-apply fingerprint HAL vintf entry
# ============================================================
print_step "Re-applying fingerprint HAL vintf entry"
if ! grep -q "biometrics.fingerprint" device/xiaomi/warm/configs/vintf/manifest_pitti.xml; then
    sed -i '/<\/manifest>/i\    <hal format=\"aidl\">\n        <name>android.hardware.biometrics.fingerprint<\/name>\n        <version>4<\/version>\n        <fqname>IFingerprint\/default<\/fqname>\n    <\/hal>' device/xiaomi/warm/configs/vintf/manifest_pitti.xml
fi

# ============================================================
# STEP 6 — Set up Infinity-X product files
# ============================================================
print_step "Setting INFINITY_MAINTAINER"
sed -i "s/PRODUCT_NAME := lineage_warm/PRODUCT_NAME := infinity_warm/" device/xiaomi/${DEVICE}/infinity_warm.mk
grep -q "INFINITY_MAINTAINER" device/xiaomi/${DEVICE}/infinity_warm.mk || \
    echo 'INFINITY_MAINTAINER := Shyam-vadgama' >> device/xiaomi/${DEVICE}/infinity_warm.mk

# ============================================================
# STEP 7 — Build
# ============================================================
print_step "Setting up build environment"
source build/envsetup.sh
export BUILD_USERNAME="${BUILD_USERNAME:-shyam}"
export BUILD_HOSTNAME="${BUILD_HOSTNAME:-crave}"
export SKIP_ABI_CHECKS=true

print_step "Lunching infinity_warm-${BUILD_TYPE}"
lunch infinity_warm-${BUILD_TYPE}

print_step "Starting build (m bacon)"
telegram_reply "Build started for warm (Infinity-X)"
m bacon -j$(nproc --all) 2>&1 | tee "$BUILD_LOG"

# ============================================================
# STEP 8 — Post-build
# ============================================================
BUILD_DIFF=$(( $(date +%s) - START_TIME ))
if [ $BUILD_DIFF -ge 3600 ]; then
    BUILD_TIME="$((BUILD_DIFF/3600))h $(((BUILD_DIFF%3600)/60))min"
else
    BUILD_TIME="$((BUILD_DIFF/60)) min"
fi

if grep -q -E "ninja failed|failed to build some targets" "$BUILD_LOG"; then
    telegram_reply "Build failed after ${BUILD_TIME}"
    echo "BUILD FAILED after ${BUILD_TIME}"
    exit 1
fi

ROM_DIR="out/target/product/${DEVICE}"
ZIP_FILE=$(ls "$ROM_DIR" 2>/dev/null | grep -E -i "^InfinityX-.*-${DEVICE}-.*\.zip$" | tail -n 1)

if [ -n "$ZIP_FILE" ]; then
    echo "ROM: ${ROM_DIR}/${ZIP_FILE}"
    telegram_send_document "${ROM_DIR}/${ZIP_FILE}" "Infinity-X 16 — warm (${BUILD_TIME})"

    SF_URL=$(sourceforge_upload "${ROM_DIR}/${ZIP_FILE}")
    [ -n "$SF_URL" ] && echo "SourceForge: ${SF_URL}"

    REC_PATH="${ROM_DIR}/recovery.img"
    if [ -f "$REC_PATH" ]; then
        SF_REC_URL=$(sourceforge_upload "$REC_PATH")
        [ -n "$SF_REC_URL" ] && echo "Recovery: ${SF_REC_URL}"
    fi

    echo "BUILD SUCCEEDED after ${BUILD_TIME}"
else
    echo "ROM zip not found in ${ROM_DIR}"
    telegram_reply "Build completed but ROM zip not found (${BUILD_TIME})"
fi
