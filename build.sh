#!/bin/bash
set -e

# ==========================================
# Konoha Kernel Build Script
# Usage: ./build.sh [key=value ...]
#   hz=100|250|1000       Timer frequency (default: 250)
#   hardened=on|off       CPU mitigations (default: off)
#   variant=stock|root|susfs  Build variant (default: stock)
#   root=ksu-next|sukisu|resukisu|mambosu  Root solution (default: ksu-next)
#   lto=thin|full|none    LTO type (default: thin)
#   autofdo=on|off        AutoFDO (default: off)
# ==========================================

# Parse CLI arguments (key=value)
for arg in "$@"; do
    case "$arg" in
        hz=*)       HZ="${arg#*=}" ;;
        hardened=*) HARDENED="${arg#*=}" ;;
        variant=*)  VARIANT="${arg#*=}" ;;
        root=*)     ROOT="${arg#*=}" ;;
        lto=*)      LTO_TYPE="${arg#*=}" ;;
        autofdo=*)  AUTOFDO="${arg#*=}" ;;
    esac
done

# ==========================================
# Paths
# ==========================================
KERNEL_DIR=$(pwd)
MAIN=$(readlink -f "$KERNEL_DIR/..")
CLANG_DIR="$MAIN/toolchains/clang"
OUT_DIR="$KERNEL_DIR/out"
ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
MODULES_DIR="$KERNEL_DIR/.root_modules"
BUILD_START=$(date +"%s")

# ==========================================
# Interactive Menus (only if not set via CLI/env)
# ==========================================

# 1. Timer Frequency
if [ -z "$HZ" ]; then
    echo "=========================================="
    echo "         Select Timer Frequency           "
    echo "=========================================="
    echo " 1) 100 HZ  (powersave)"
    echo " 2) 250 HZ  (balance - default)"
    echo " 3) 1000 HZ (performance)"
    read -p "Enter choice [1-3] (default 2): " _c
    case "${_c:-2}" in 1) HZ=100 ;; 3) HZ=1000 ;; *) HZ=250 ;; esac
fi

# 2. Hardened Security
if [ -z "$HARDENED" ]; then
    echo "=========================================="
    echo "         Hardened Security Mode           "
    echo "=========================================="
    echo " 1) OFF (default - better performance)"
    echo " 2) ON  (CPU mitigations enabled)"
    read -p "Enter choice [1-2] (default 1): " _c
    [ "${_c:-1}" == "2" ] && HARDENED="on" || HARDENED="off"
fi

# 3. Build Variant
if [ -z "$VARIANT" ]; then
    echo "=========================================="
    echo "          Select Build Variant            "
    echo "=========================================="
    echo " 1) Non-Root (Stock - default)"
    echo " 2) Root Only"
    echo " 3) Root + SUSFS"
    read -p "Enter choice [1-3] (default 1): " _c
    case "${_c:-1}" in 2) VARIANT="root" ;; 3) VARIANT="susfs" ;; *) VARIANT="stock" ;; esac
fi

# 4. Root Solution (only for root/susfs)
if [ "$VARIANT" != "stock" ] && [ -z "$ROOT" ]; then
    echo "=========================================="
    echo "         Select Root Solution             "
    echo "=========================================="
    echo " 1) KernelSU-Next (default)"
    echo " 2) Sukisu"
    echo " 3) ReSukiSU"
    echo " 4) MamboSU"
    read -p "Enter choice [1-4] (default 1): " _c
    case "${_c:-1}" in 2) ROOT="sukisu" ;; 3) ROOT="resukisu" ;; 4) ROOT="mambosu" ;; *) ROOT="ksu-next" ;; esac
fi

# 5. LTO Type
if [ -z "$LTO_TYPE" ]; then
    echo "=========================================="
    echo "           Select LTO Type                "
    echo "=========================================="
    echo " 1) THIN (default - faster build)"
    echo " 2) FULL (slower, slightly better perf)"
    echo " 3) NONE (no LTO)"
    read -p "Enter choice [1-3] (default 1): " _c
    case "${_c:-1}" in 2) LTO_TYPE="full" ;; 3) LTO_TYPE="none" ;; *) LTO_TYPE="thin" ;; esac
fi

# ==========================================
# Resolve Root Solution
# ==========================================
case "$ROOT" in
    sukisu)   ROOT_REPO="https://github.com/sukisu-ultra/sukisu-ultra.git"; REPO_NAME="sukisu-ultra"; BRANCH="main" ;;
    resukisu) ROOT_REPO="https://github.com/ReSukiSU/ReSukiSU.git"; REPO_NAME="ReSukiSU"; BRANCH="main" ;;
    mambosu)  ROOT_REPO="https://github.com/RapliVx/KernelSU.git"; REPO_NAME="MamboSU"; BRANCH="master" ;;
    *)        ROOT_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev"; ROOT="ksu-next" ;;
esac

# ==========================================
# Print Config Summary
# ==========================================
echo ""
echo "=========================================="
echo "          Build Configuration             "
echo "=========================================="
echo " Timer:     ${HZ} HZ"
echo " Hardened:  ${HARDENED^^}"
[ "$VARIANT" != "stock" ] && echo " Variant:   ${VARIANT} ($REPO_NAME)" || echo " Variant:   stock"
echo " LTO:       ${LTO_TYPE^^}"
echo "=========================================="
echo ""

# ==========================================
# Prepare Root Module
# ==========================================
rm -rf "$KERNEL_DIR/drivers/kernelsu"
if [ "$VARIANT" == "stock" ]; then
    mkdir -p "$KERNEL_DIR/drivers/kernelsu"
    touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
    touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
else
    mkdir -p "$MODULES_DIR"
    if [ ! -d "$MODULES_DIR/$REPO_NAME" ]; then
        echo "[+] Cloning $REPO_NAME..."
        git clone -b "$BRANCH" "$ROOT_REPO" "$MODULES_DIR/$REPO_NAME"
    else
        echo "[+] Updating $REPO_NAME..."
        (cd "$MODULES_DIR/$REPO_NAME" && git reset --hard && git pull || true)
    fi

    # Apply SUSFS
    if [ "$VARIANT" == "susfs" ]; then
        SUSFS_DIR="$MODULES_DIR/susfs4ksu"
        if [ ! -d "$SUSFS_DIR" ]; then
            git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6-dev "$SUSFS_DIR"
        else
            (cd "$SUSFS_DIR" && git reset --hard && git pull || true)
        fi

        # Layout detection + SUSFS version
        if [ -d "$MODULES_DIR/$REPO_NAME/kernel/core" ]; then
            (cd "$SUSFS_DIR" && git reset --hard 6b1badb)
        else
            (cd "$SUSFS_DIR" && git reset --hard 89b1422)
        fi

        echo "[+] Injecting SUSFS kernel sources..."
        cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"
        cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"
        [ -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" ] && \
            cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

        echo "[+] Patching $REPO_NAME for SUSFS..."
        (cd "$MODULES_DIR/$REPO_NAME" && \
         patch -p1 --forward -f --reject-file=- < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true)

        echo "[+] Running SUSFS compatibility fixup..."
        bash "$KERNEL_DIR/ksu_susfs_fixup.sh" "$MODULES_DIR/$REPO_NAME/kernel"
    fi

    echo "[+] Symlinking $REPO_NAME to drivers/kernelsu..."
    ln -sf "$MODULES_DIR/$REPO_NAME/kernel" "$KERNEL_DIR/drivers/kernelsu"
fi

# ==========================================
# Toolchain Setup
# ==========================================
check_clang() {
    if [ -n "$CLANG_PATH" ] && [ -f "$CLANG_PATH/bin/clang" ]; then
        export PATH="$CLANG_PATH/bin:$PATH"
        CLANG_BIN="$CLANG_PATH/bin/clang"
    elif [ -d "$CLANG_DIR" ] && [ -f "$CLANG_DIR/bin/clang" ]; then
        export PATH="$CLANG_DIR/bin:$PATH"
        CLANG_BIN="$CLANG_DIR/bin/clang"
    elif command -v clang > /dev/null 2>&1; then
        CLANG_BIN=$(command -v clang)
    else
        return 1
    fi
    COMPILER_VER=$("$CLANG_BIN" --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
    export KBUILD_COMPILER_STRING="$COMPILER_VER"
    echo "Found Clang: $KBUILD_COMPILER_STRING"
    return 0
}

export ARCH=arm64 SUBARCH=arm64

EXTREME_CLANG_FLAGS=(
    -O2 -mcpu=cortex-x4 -mtune=cortex-x4 -mno-fmv -mno-outline-atomics -Wno-all
    -fomit-frame-pointer -fslp-vectorize -fmerge-all-constants -fdelete-null-pointer-checks
    -moutline -mharden-sls=none -mbranch-protection=none -fno-semantic-interposition
    -fno-stack-protector -fno-math-errno -fno-trapping-math -fno-signed-zeros
    -fassociative-math -freciprocal-math
)
KERNEL_KCFLAGS="-w ${EXTREME_CLANG_FLAGS[*]}"
KERNEL_LDFLAGS="-O2 --icf=all -mllvm -enable-new-pm=1"

if ! check_clang; then
    echo "[-] No Clang toolchain found!"
    exit 1
fi

# ==========================================
# Kernel Config
# ==========================================
mkdir -p "$OUT_DIR"
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="$KERNEL_KCFLAGS" LDFLAGS="$KERNEL_LDFLAGS" konoha_defconfig || exit 1

# Root config
case "$VARIANT" in
    stock) scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU -d CONFIG_KSU_SUSFS ;;
    root)  scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU -d CONFIG_KSU_SUSFS ;;
    susfs) scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_SUS_MAP ;;
esac

# HZ config
case "$HZ" in
    100)  scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_1000 -e CONFIG_HZ_100 --set-val CONFIG_HZ 100 -e CONFIG_RCU_LAZY ;;
    1000) scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_100 -e CONFIG_HZ_1000 --set-val CONFIG_HZ 1000 -d CONFIG_RCU_LAZY ;;
    *)    scripts/config --file "$OUT_DIR/.config" -d CONFIG_HZ_300 -d CONFIG_HZ_1000 -d CONFIG_HZ_100 -e CONFIG_HZ_250 --set-val CONFIG_HZ 250 ;;
esac

# Hardened config
if [ "$HARDENED" == "off" ]; then
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_CPU_MITIGATIONS -d CONFIG_MITIGATE_SPECTRE_BRANCH_HISTORY
fi

# LTO config
case "$LTO_TYPE" in
    full) scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_FULL ;;
    none) scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_CLANG -d CONFIG_LTO_CLANG_FULL -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_NONE ;;
    *)    scripts/config --file "$OUT_DIR/.config" -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_FULL -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_THIN ;;
esac

# AutoFDO
AFDO_PROFILE=""
if [ "$AUTOFDO" == "on" ]; then
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_AUTOFDO_CLANG
    AFDO_PROFILE="$KERNEL_DIR/android/gki/aarch64/afdo/kernel.afdo"
    [ ! -f "$AFDO_PROFILE" ] && { echo "[-] AutoFDO profile not found!"; exit 1; }
fi

# Debug reduction (GKI ABI-safe only)
scripts/config --file "$OUT_DIR/.config" -e CONFIG_DEBUG_INFO_REDUCED -d CONFIG_DEBUG_MISC

# KASAN runtime disable (can't compile out — ABI symbol kasan_flag_enabled)
CURRENT_CMDLINE=$(grep '^CONFIG_CMDLINE=' "$OUT_DIR/.config" | sed 's/^CONFIG_CMDLINE="//' | sed 's/"$//')
echo "$CURRENT_CMDLINE" | grep -q "kasan=off" || \
    scripts/config --file "$OUT_DIR/.config" --set-str CONFIG_CMDLINE "$CURRENT_CMDLINE kasan=off"

# Single olddefconfig to finalize all changes
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1

# ==========================================
# Build
# ==========================================
CPUS=$(nproc --all)
MAKE_ARGS=(
    "-j${CPUS}" "O=${OUT_DIR}" "CC=clang" "LD=ld.lld" "AR=llvm-ar" "NM=llvm-nm"
    "OBJCOPY=llvm-objcopy" "OBJDUMP=llvm-objdump" "STRIP=llvm-strip"
    "LLVM=1" "LLVM_IAS=1" "KCFLAGS=${KERNEL_KCFLAGS}" "LDFLAGS=${KERNEL_LDFLAGS}"
)
[ -n "$AFDO_PROFILE" ] && MAKE_ARGS+=("CLANG_AUTOFDO_PROFILE=${AFDO_PROFILE}")

echo "[+] Building with ${CPUS} threads..."
make "${MAKE_ARGS[@]}" || { echo "[-] Build failed!"; exit 1; }

# ==========================================
# Package
# ==========================================
find "$KERNEL_DIR" -maxdepth 1 -type f -name "Kono-Ha-*.zip" -exec rm -v {} \;
rm -rf "$KERNEL_DIR/Kono-Ha-Release"

TIME=$(date "+%Y%m%d-%H%M%S")
TEMP_DIR="$KERNEL_DIR/anykernel_temp"
rm -rf "$TEMP_DIR"

[ ! -d "$KERNEL_DIR/anykernel" ] && { echo "[-] anykernel directory not found!"; exit 1; }
cp -r "$KERNEL_DIR/anykernel" "$TEMP_DIR"

# Copy kernel image
for img in Image.gz-dtb Image.gz Image; do
    [ -f "$ZIMAGE_DIR/$img" ] && { cp -v "$ZIMAGE_DIR/$img" "$TEMP_DIR/"; break; }
done

# Build filename
ZIP_SUFFIX=""
[ "$VARIANT" == "root" ] && ZIP_SUFFIX="-$REPO_NAME"
[ "$VARIANT" == "susfs" ] && ZIP_SUFFIX="-$REPO_NAME-susfs-v2.1"

HZ_LABEL=""
case "$HZ" in 100) HZ_LABEL="-powersave" ;; 1000) HZ_LABEL="-performance" ;; *) HZ_LABEL="-balance" ;; esac

ZIP_NAME="Kono-Ha${ZIP_SUFFIX}${HZ_LABEL}-$TIME.zip"
cd "$TEMP_DIR" && zip -r9 "../$ZIP_NAME" * -x .git README.md *placeholder > /dev/null && cd ..
rm -rf "$TEMP_DIR"

# Copy to release dir for CI
mkdir -p "$KERNEL_DIR/Kono-Ha-Release"
cp "$KERNEL_DIR/$ZIP_NAME" "$KERNEL_DIR/Kono-Ha-Release/"

# GitHub Actions outputs
if [ "$GITHUB_ACTIONS" == "true" ]; then
    echo "ZIP_PATH=$KERNEL_DIR/$ZIP_NAME" >> "$GITHUB_ENV"
    echo "ZIP_NAME=$ZIP_NAME" >> "$GITHUB_ENV"
fi

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))
echo -e "\n=========================================="
echo "Build completed in $((DIFF / 60))m $((DIFF % 60))s"
echo "Output: $KERNEL_DIR/$ZIP_NAME"
echo "=========================================="