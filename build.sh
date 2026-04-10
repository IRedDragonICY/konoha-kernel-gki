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
# Interactive Config Setup
# ==========================================
if [ -z "$OPTIMIZATION_PROFILE" ]; then
    echo "=========================================="
    echo "      Select Optimization Profile         "
    echo "=========================================="
    echo " 1) Balance (250 HZ)"
    echo " 2) Performance (1000 HZ)"
    echo " 3) Battery (100 HZ)"
    read -p "Enter choice [1-3] (default 1): " OPTIMIZATION_PROFILE_CHOICE
    OPTIMIZATION_PROFILE=${OPTIMIZATION_PROFILE_CHOICE:-1}
fi

if [ -z "$BUILD_VARIANT" ]; then
    echo "=========================================="
    echo "          Select Build Variant            "
    echo "=========================================="
    echo " 1) Non-Root (Stock)"
    echo " 2) Root Only"
    echo " 3) Root + SUSFS"
    read -p "Enter choice [1-3] (default 1): " BUILD_VARIANT_CHOICE
    BUILD_VARIANT=${BUILD_VARIANT_CHOICE:-1}
fi

if [ "$BUILD_VARIANT" == "2" ] || [ "$BUILD_VARIANT" == "3" ]; then
    if [ -z "$ROOT_SOLUTION" ]; then
        echo "=========================================="
        echo "         Select Root Solution             "
        echo "=========================================="
        echo " 1) KernelSU-Next (KernelSU-Next)"
        echo " 2) Sukisu (sukisu-ultra)"
        echo " 3) ReSukiSU"
        echo " 4) MamboSU (RapliVx/KernelSU)"
        read -p "Enter choice [1-4] (default 1): " ROOT_SOLUTION_CHOICE
        ROOT_SOLUTION=${ROOT_SOLUTION_CHOICE:-1}
    fi

    case "$ROOT_SOLUTION" in
        2) ROOT_REPO="https://github.com/sukisu-ultra/sukisu-ultra.git"; REPO_NAME="sukisu-ultra"; BRANCH="main" ;;
        3) ROOT_REPO="https://github.com/ReSukiSU/ReSukiSU.git"; REPO_NAME="ReSukiSU"; BRANCH="main" ;;
        4) ROOT_REPO="https://github.com/RapliVx/KernelSU.git"; REPO_NAME="MamboSU"; BRANCH="master" ;;
        *) ROOT_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev" ;;
    esac

fi

# Prepare drivers/kernelsu
rm -rf "$KERNEL_DIR/drivers/kernelsu"
if [ "$BUILD_VARIANT" == "1" ]; then
    echo "[+] Setting up Non-Root environment..."
    mkdir -p "$KERNEL_DIR/drivers/kernelsu"
    touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
    touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
else
        # Clone or Update Repo inside the repository
        MODULES_DIR="$KERNEL_DIR/.root_modules"
        mkdir -p "$MODULES_DIR"
        if [ ! -d "$MODULES_DIR/$REPO_NAME" ]; then
            echo "[+] Cloning $REPO_NAME..."
            git clone -b "$BRANCH" "$ROOT_REPO" "$MODULES_DIR/$REPO_NAME"
        else
            echo "[+] Updating $REPO_NAME..."
            (cd "$MODULES_DIR/$REPO_NAME" && git reset --hard && git pull || true)
        fi
        
        # Apply SUSFS patches to the module manager backend if Root + SUSFS
        if [ "$BUILD_VARIANT" == "3" ]; then
            SUSFS_DIR="$MODULES_DIR/susfs4ksu"
            if [ ! -d "$SUSFS_DIR" ]; then
                echo "[+] Cloning susfs4ksu..."
                git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android15-6.6-dev "$SUSFS_DIR"
            else
                echo "[+] Updating susfs4ksu..."
                (cd "$SUSFS_DIR" && git reset --hard && git pull || true)
            fi
            
            # Detect Root Manager source layout (New layout has "kernel/core" folder)
            if [ -d "$MODULES_DIR/$REPO_NAME/kernel/core" ]; then
            	LAYOUT="NEW"
            else
            	LAYOUT="OLD"
            fi

            # Switch between v2.1 and v2.0 based on Layout Compatibility
            if [ "$LAYOUT" == "OLD" ]; then
                echo "[+] Switching SUSFS to v2.1 (Legacy Layout Compatible)..."
                (cd "$SUSFS_DIR" && git reset --hard 89b1422)
            else
                echo "[+] Switching SUSFS to v2.1 (Latest/Modern Layout)..."
                (cd "$SUSFS_DIR" && git reset --hard 6b1badb)
            fi
            
            echo "[+] Injecting SUSFS kernel source files to local tree..."
            cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"
            cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"
            if [ -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" ]; then
                cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

            fi

            echo "[+] Applying SUSFS Patches to $REPO_NAME backend..."
            (cd "$MODULES_DIR/$REPO_NAME" && \
             patch -p1 --forward -f --reject-file=- < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" || true)
            
            # Fix tracepoint undefined symbol issue (patch removes tp_marker.h but SukiSU uses it)
            if grep -q "ksu_set_task_tracepoint_flag" "$MODULES_DIR/$REPO_NAME/kernel/policy/app_profile.c" 2>/dev/null; then
                if ! grep -q "hook/tp_marker.h" "$MODULES_DIR/$REPO_NAME/kernel/policy/app_profile.c"; then
                    echo "[+] Restoring tp_marker.h for app_profile.c..."
                    sed -i 's/#include "infra\/su_mount_ns.h"/#include "infra\/su_mount_ns.h"\n#include "hook\/tp_marker.h"/' "$MODULES_DIR/$REPO_NAME/kernel/policy/app_profile.c"
                fi
            fi
        fi

        echo "[+] Symlinking $REPO_NAME to drivers/kernelsu..."
        ln -sf "$MODULES_DIR/$REPO_NAME/kernel" "$KERNEL_DIR/drivers/kernelsu"
    fi

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

# Apply Root Configs
echo "=========================================="
echo "[+] Applying Root Configuration..."
echo "=========================================="
if [ "$BUILD_VARIANT" == "1" ]; then
    scripts/config --file "$OUT_DIR/.config" -d CONFIG_KSU -d CONFIG_KSU_SUSFS
elif [ "$BUILD_VARIANT" == "2" ]; then
    scripts/config --file "$OUT_DIR/.config" -e CONFIG_KSU -d CONFIG_KSU_SUSFS
elif [ "$BUILD_VARIANT" == "3" ]; then
    scripts/config --file "$OUT_DIR/.config" \
        -e CONFIG_KSU \
        -e CONFIG_KSU_SUSFS \
        -e CONFIG_KSU_SUSFS_SUS_MAP
fi
make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1

# Apply Optimization Profiles
echo "=========================================="
echo "[+] Applying Optimization Profile ($OPTIMIZATION_PROFILE)..."
echo "=========================================="
if [ "$OPTIMIZATION_PROFILE" == "1" ]; then
    # Balance Mode (250 HZ) - Default for Android
    scripts/config --file "$OUT_DIR/.config"         -d CONFIG_HZ_300         -d CONFIG_HZ_1000         -d CONFIG_HZ_100         -e CONFIG_HZ_250         --set-val CONFIG_HZ 250
elif [ "$OPTIMIZATION_PROFILE" == "2" ]; then
    # Performance Mode (1000 HZ)
    scripts/config --file "$OUT_DIR/.config"         -d CONFIG_HZ_300         -d CONFIG_HZ_250         -d CONFIG_HZ_100         -e CONFIG_HZ_1000         --set-val CONFIG_HZ 1000         -d CONFIG_RCU_LAZY
elif [ "$OPTIMIZATION_PROFILE" == "3" ]; then
    # Battery Mode (100 HZ)
    scripts/config --file "$OUT_DIR/.config"         -d CONFIG_HZ_300         -d CONFIG_HZ_250         -d CONFIG_HZ_1000         -e CONFIG_HZ_100         --set-val CONFIG_HZ 100         -e CONFIG_RCU_LAZY
fi

make O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig || exit 1

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

# Clean up old kernel output files
echo "Cleaning up old kernel files..."
find "$KERNEL_DIR" -maxdepth 1 -type f -name "Kono-Ha-*.zip" -exec rm -v {} \;
rm -rf "$KERNEL_DIR/Kono-Ha-Release"

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
ZIP_SUFFIX=""
if [ "$BUILD_VARIANT" == "2" ]; then
    ZIP_SUFFIX="-$REPO_NAME"
elif [ "$BUILD_VARIANT" == "3" ]; then
    ZIP_SUFFIX="-$REPO_NAME-susfs"
fi

PROFILE_SUFFIX=""
if [ "$OPTIMIZATION_PROFILE" == "1" ]; then
    PROFILE_SUFFIX="-balance"
elif [ "$OPTIMIZATION_PROFILE" == "2" ]; then
    PROFILE_SUFFIX="-perf"
elif [ "$OPTIMIZATION_PROFILE" == "3" ]; then
    PROFILE_SUFFIX="-battery"
fi

ZIP_NAME="Kono-Ha${ZIP_SUFFIX}${PROFILE_SUFFIX}-$TIME.zip"
cd "$TEMP_ANY_KERNEL_DIR"
# Do not zip inside the script, leave the folder ready for GitHub Actions' upload-artifact
cd ..
mv "$TEMP_ANY_KERNEL_DIR" "$KERNEL_DIR/Kono-Ha-Release"

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))

echo -e "\n=========================================="
echo "Build completed in $((DIFF / 60))m $((DIFF % 60))s"
echo "Output folder ready: $KERNEL_DIR/Kono-Ha-Release"
echo "=========================================="