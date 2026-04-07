#!/bin/bash
set -e

# Configuration
DIR=$(readlink -f .)
MAIN=$(readlink -f "${DIR}/..")
KERNEL_DEFCONFIG=konoha_defconfig
CLANG_DIR="$MAIN/toolchains/clang"
KERNEL_DIR=$(pwd)
OUT_DIR="$KERNEL_DIR/out"
ZIMAGE_DIR="$OUT_DIR/arch/arm64/boot"
DTB_DTBO_DIR="$ZIMAGE_DIR/dts/vendor/qcom"
BUILD_START=$(date +"%s")

# ==========================================
# Global Configs
# ==========================================
DISABLE_CPU_MITIGATIONS=true
ENABLE_AUTOFDO=true # Enable Google's AutoFDO for Android 15/16 (uses android/gki/aarch64/afdo/kernel.afdo)
LTO_TYPE="full" # Options: "thin", "full", or "none" (thin is recommended with AutoFDO)

# Function to check for existing Clang
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

    # Extracted to prevent quote parsing issues in some editors/shells
    COMPILER_VER=$("$CLANG_BIN" --version | head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
    export KBUILD_COMPILER_STRING="$COMPILER_VER"
    echo "Found existing Clang: $KBUILD_COMPILER_STRING"
    return 0
}

# Set up toolchain
export ARCH=arm64
export SUBARCH=arm64

# Clang optimization
EXTREME_CLANG_FLAGS=(
    -O2
    -mcpu=cortex-x4
    -mtune=cortex-x4
    # -fsplit-machine-functions (causes ld.lld orphaned section errors 'text.split.*')
    -mno-fmv
    -mno-outline-atomics
    -Wno-all
    
    # inline thresholds
    # -mllvm -inline-threshold=200
    # -mllvm -unroll-threshold=75
    # -falign-loops=32
    # -funroll-loops
    # -finline-functions
    -fomit-frame-pointer
    # functions & vectors
    # -ffunction-sections (causes ld.lld orphaned section errors in vmlinux)
    -fslp-vectorize
    # -fdata-sections // error is being placed in '.init.bss.cmdline.o' section, which is not supported by the current linker script
    -fmerge-all-constants
    -fdelete-null-pointer-checks
    -moutline 
    # No safeties (Raw Performance)
    -mharden-sls=none
    -mbranch-protection=none
    -fno-semantic-interposition
    -fno-stack-protector
    -fno-math-errno
    -fno-trapping-math
    -fno-signed-zeros
    -fassociative-math
    -freciprocal-math
    

    # polly flags
    # -Xclang -load -Xclang LLVMPolly.so
    # -mllvm -polly
    # -mllvm -polly-ast-use-context
    # -mllvm -polly-vectorizer=stripmine
    # -mllvm -polly-invariant-load-hoisting
    # -mllvm -polly-enable-simplify
    # -mllvm -polly-reschedule
    # -mllvm -polly-postopts
    # -mllvm -polly-tiling
    # -mllvm -polly-2nd-level-tiling
    # -mllvm -polly-register-tiling
    # -mllvm -polly-pattern-matching-based-opts
    # -mllvm -polly-matmul-opt
    # -mllvm -polly-tc-opt
    # -mllvm -polly-process-unprofitable
)

KERNEL_KCFLAGS="-w ${EXTREME_CLANG_FLAGS[*]}"
KERNEL_LDFLAGS="-O2 --icf=all -mllvm -enable-new-pm=1"

# ==========================================
# Output Setup
# ==========================================
mkdir -p "$OUT_DIR"

# Create config
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 KCFLAGS="$KERNEL_KCFLAGS" LDFLAGS="$KERNEL_LDFLAGS" $KERNEL_DEFCONFIG || exit 1

# Apply Global Configs
if [ "$DISABLE_CPU_MITIGATIONS" = "true" ]; then
    echo "=========================================="
    echo "[+] Disabling CPU & Spectre Mitigations..."
    echo "=========================================="
    scripts/config --file "$OUT_DIR/.config" \
        -d CONFIG_CPU_MITIGATIONS \
        -d CONFIG_MITIGATE_SPECTRE_BRANCH_HISTORY

    # Re-evaluate config after changes
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1
fi

# Apply LTO Configuration
if [ "$LTO_TYPE" = "full" ]; then
    echo "=========================================="
    echo "[+] Setting LTO Type to FULL..."
    echo "=========================================="
    scripts/config --file "$OUT_DIR/.config" \
        -d CONFIG_LTO_NONE \
        -d CONFIG_LTO_CLANG_THIN \
        -e CONFIG_LTO_CLANG \
        -e CONFIG_LTO_CLANG_FULL
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1
elif [ "$LTO_TYPE" = "thin" ]; then
    echo "=========================================="
    echo "[+] Setting LTO Type to THIN..."
    echo "=========================================="
    scripts/config --file "$OUT_DIR/.config" \
        -d CONFIG_LTO_NONE \
        -d CONFIG_LTO_CLANG_FULL \
        -e CONFIG_LTO_CLANG \
        -e CONFIG_LTO_CLANG_THIN
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1
elif [ "$LTO_TYPE" = "none" ]; then
    echo "=========================================="
    echo "[+] Disabling LTO..."
    echo "=========================================="
    scripts/config --file "$OUT_DIR/.config" \
        -d CONFIG_LTO_CLANG \
        -d CONFIG_LTO_CLANG_FULL \
        -d CONFIG_LTO_CLANG_THIN \
        -e CONFIG_LTO_NONE
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1
fi

# Apply AutoFDO Configuration
if [ "$ENABLE_AUTOFDO" = "true" ]; then
    echo "=========================================="
    echo "[+] Enabling AutoFDO for Android 15/16..."
    echo "=========================================="
    scripts/config --file "$OUT_DIR/.config" \
        -e CONFIG_AUTOFDO_CLANG
    make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1
    
    AFDO_PROFILE="$KERNEL_DIR/android/gki/aarch64/afdo/kernel.afdo"
    if [ ! -f "$AFDO_PROFILE" ]; then
        echo "[-] Error: AutoFDO profile not found at $AFDO_PROFILE!"
        exit 1
    fi
    echo "[+] Found AutoFDO profile at $AFDO_PROFILE!"
fi

# Build kernel
CPUS=$(nproc --all)
echo "[+] Starting build with $CPUS threads..."
MAKE_ARGS=(
    "-j${CPUS}"
    "O=${OUT_DIR}"
    "CC=clang"
    "LD=ld.lld"
    "AR=llvm-ar"
    "NM=llvm-nm"
    "OBJCOPY=llvm-objcopy"
    "OBJDUMP=llvm-objdump"
    "STRIP=llvm-strip"
    "LLVM=1"
    "LLVM_IAS=1"
    "KCFLAGS=${KERNEL_KCFLAGS}"
    "LDFLAGS=${KERNEL_LDFLAGS}"
)

if [ "$ENABLE_AUTOFDO" = "true" ]; then
    MAKE_ARGS+=("CLANG_AUTOFDO_PROFILE=${AFDO_PROFILE}")
fi

echo "[+] Starting build with ${CPUS} threads..."
make "${MAKE_ARGS[@]}" || {
    echo "[-] Build failed!"
    exit 1
}

# Clean up old kernel zip files
echo "Cleaning up old kernel zip files..."
find "$KERNEL_DIR" -maxdepth 1 -type f -name "Kono-Ha-*.zip" -exec rm -v {} \;

# Create temporary anykernel directory
TIME=$(date "+%Y%m%d-%H%M%S")
TEMP_ANY_KERNEL_DIR="$KERNEL_DIR/anykernel_temp"
rm -rf "$TEMP_ANY_KERNEL_DIR"

# Clone entire anykernel directory
echo "Cloning anykernel directory..."
if [ -d "$KERNEL_DIR/anykernel" ]; then
    cp -r "$KERNEL_DIR/anykernel" "$TEMP_ANY_KERNEL_DIR"
else
    echo "Error: anykernel directory not found!"
    exit 1
fi

# Copy kernel image
if [ -f "$ZIMAGE_DIR/Image.gz-dtb" ]; then
    cp -v "$ZIMAGE_DIR/Image.gz-dtb" "$TEMP_ANY_KERNEL_DIR/"
elif [ -f "$ZIMAGE_DIR/Image.gz" ]; then
    cp -v "$ZIMAGE_DIR/Image.gz" "$TEMP_ANY_KERNEL_DIR/"
elif [ -f "$ZIMAGE_DIR/Image" ]; then
    cp -v "$ZIMAGE_DIR/Image" "$TEMP_ANY_KERNEL_DIR/"
fi

# Create zip file in kernel root directory
echo "Creating zip package..."
ZIP_NAME="Kono-Ha-$TIME.zip"
cd "$TEMP_ANY_KERNEL_DIR"
zip -r9 "$KERNEL_DIR/$ZIP_NAME" ./*
cd ..

# Clean up temporary directory
rm -rf "$TEMP_ANY_KERNEL_DIR"

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))

ZIP_SIZE=$(du -h "$KERNEL_DIR/$ZIP_NAME" | awk '{print $1}')

echo -e "\n=========================================="
echo "Build completed in $((DIFF / 60))m $((DIFF % 60))s"
echo "Final zip: $KERNEL_DIR/$ZIP_NAME"
echo "Zip size: $ZIP_SIZE"
echo "=========================================="