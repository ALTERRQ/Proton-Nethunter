#!/bin/bash
#
# Flopster's build script.
# Based on build script for Quicksilver, by Ghostrider.
# Copyright (C) 2020-2021 Adithya R. (original version)
# Copyright (C) 2022-2024 Flopster101 (rewrite)

## Vars
# Toolchains
AOSP_REPO="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+/refs/heads/master"
AOSP_ARCHIVE="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master"
PC_REPO="https://github.com/kdrag0n/proton-clang"
LZ_REPO="https://gitlab.com/Jprimero15/lolz_clang.git"

# Other
DEFAULT_DEFCONFIG="proton_exynos2100-r9sxxx_defconfig"
KERNEL_URL="https://github.com/ProtonKernel/Proton"
AK3_URL="https://github.com/ProtonKernel/AnyKernel3"
SECONDS=0 # builtin bash timer
DATE="$(date '+%Y%m%d-%H%M')"
BUILD_HOST="$USER@$(hostname)"

# Workspace
if [ -d /workspace ]; then
    WP="/workspace"
    IS_GP=1
else
    IS_GP=0
fi
if [ -z "$WP" ]; then
    echo -e "$RED\nERROR: Environment not Gitpod! Please set the WP env var...\n$ENDCOLOR"
    exit 1
fi

if [ ! -d drivers ]; then
    echo -e "$RED\nERROR: Please exec from top-level kernel tree\n$ENDCOLOR"
    exit 1
fi

if [ "$IS_GP" = "1" ]; then
    export KBUILD_BUILD_USER="Flopster101"
    export KBUILD_BUILD_HOST="buildbot"
fi

export PATH="$(pwd)/build/bin:$PATH"

# Directories
TC_DIR="$WP/toolchains"
AC_DIR="$TC_DIR/aospclang"
PC_DIR="$TC_DIR/protonclang"
LZ_DIR="$TC_DIR/lolzclang"
AK3_DIR="$WP/AK3-r9s"
AK3_BRANCH="r9s"
KDIR="$(readlink -f .)"

# Ensure the toolchains directory exists
if [[ ! -d "$TC_DIR" ]]; then
    mkdir -p "$TC_DIR"
fi

## Inherited paths
OUTDIR="$KDIR/out"
MOD_OUTDIR="$KDIR/modules_out"
TMPDIR="$KDIR/build/tmp"
IN_VBOOT="$KDIR/build/vboot"
RAMDISK_DIR="$TMPDIR/vboot_ramdisk"
PREBUILT_RAMDISK="$KDIR/build/boot/ramdisk"
MODULES_DIR="$RAMDISK_DIR/lib/modules"
OUT_KERNEL="$OUTDIR/arch/arm64/boot/Image"
OUT_BOOTIMG="$KDIR/build/boot.img"
OUT_VENDORBOOTIMG="$KDIR/build/vendor_boot.img"
OUT_DTBIMAGE="$TMPDIR/dtb.img"
# Tools
MKBOOTIMG="$(pwd)/build/mkbootimg/mkbootimg.py"
MKDTBOIMG="$(pwd)/build/dtb/mkdtboimg.py"

# DTS files
DTS_DEFAULT="$KDIR/arch/arm64/boot/dts/exynos/exynos2100.dts"
DTS_BALANCED="$KDIR/arch/arm64/boot/dts/exynos/exynos2100_balanced.dts"
DTS_BATTERY="$KDIR/arch/arm64/boot/dts/exynos/exynos2100_battery.dts"
DTS_OC="$KDIR/arch/arm64/boot/dts/exynos/exynos2100_oc.dts"

# Dependencies
UB_DEPLIST="lz4 brotli flex bc cpio kmod ccache zip binutils-aarch64-linux-gnu device-tree-compiler"
if grep -q "Ubuntu" /etc/os-release; then
    sudo apt install $UB_DEPLIST -y
else
    echo -e "$BLUE\nINFO: Your distro is not Ubuntu, skipping dependencies installation...$ENDCOLOR"
    echo -e "$BLUE INFO: Make sure you have these dependencies installed before proceeding: $UB_DEPLIST $ENDCOLOR"
fi

if ! command -v dtc &>/dev/null; then
    echo -e "$RED\nERROR: 'dtc' (Device Tree Compiler) is not installed. Aborting...\n$ENDCOLOR"
    exit 1
fi

## Customizable vars
# Kernel version
K_VER="v5.2.1"
# Toggles
USE_CCACHE=1
DO_TAR="1"
DO_ZIP="1"

# Colors
RED="\e[1;31m"
GREEN="\e[1;32m"
BLUE="\e[1;34m"
ORANGE="\e[1;33m"
ENDCOLOR="\e[0m"

# Upload build log
BUILD_LOG=0

# Pick aosp, proton or lolz
CLANG_TYPE=aosp

## Info message
LINKER=ld.lld
DEVICE="Galaxy S21 Series"
CODENAME="exynos2100"

## Parse arguments
# Default values
DO_KSU=0
DO_NH=0
DO_CLEAN=0
DO_MENUCONFIG=0
IS_RELEASE=0
DO_TG=0
DO_OSHI=0
DO_FLTO=0
DO_REGEN=0
DEFCONFIG=$DEFAULT_DEFCONFIG
BUILD_VARIANT="default"

while [[ "$1" == -* ]]; do

    i=1
    while [ $i -lt ${#1} ]; do
        FLAG="${1:$i:1}"
        case $FLAG in
            m)
                echo -e "$BLUE\nINFO: menuconfig argument passed, kernel configuration menu will be shown...$ENDCOLOR"
                DO_MENUCONFIG=1
                ;;
            k)
                echo -e "$BLUE\nINFO: KernelSU argument passed, a KernelSU build will be made...$ENDCOLOR"
                DO_KSU=1
                ;;
            c)
                echo -e "$BLUE\nINFO: clean argument passed, output directory will be wiped...$ENDCOLOR"
                DO_CLEAN=1
                ;;
            R)
                echo -e "$BLUE\nINFO: Release argument passed, build marked as release$ENDCOLOR"
                IS_RELEASE=1
                ;;
            t)
                echo -e "$BLUE\nINFO: Telegram argument passed, build will be uploaded to CI$ENDCOLOR"
                DO_TG=1
                ;;
            o)
                echo -e "$BLUE\nINFO: bashupload.com argument passed, build will be uploaded to bashupload.com$ENDCOLOR"
                DO_OSHI=1
                ;;
            l)
                echo -e "$BLUE\nINFO: Full-LTO argument passed$ENDCOLOR"
                echo -e "$ORANGE+WARNING: Full-LTO is VERY resource heavy and may take a long time to compile$ENDCOLOR"
                DO_FLTO=1
                ;;
            r)
                echo -e "$BLUE\nINFO: config regeneration mode$ENDCOLOR"
                DO_REGEN=1
                ;;
            n)
                echo -e "$BLUE\nINFO: Build with Nethunter support $ENDCOLOR"
                DO_NH=1
                ;;
            *)
                echo -e "$RED\nERROR: Unknown flag '$FLAG'$ENDCOLOR"
                exit 1
                ;;
        esac
        i=$((i + 1))
    done
    shift 
done

if [ -n "$1" ]; then
    BUILD_VARIANT="$1"
fi

# Build type variables
BUILD_TYPE_DEFAULT=0
BUILD_TYPE_BALANCED=0
BUILD_TYPE_OC=0
BUILD_TYPE_BATTERY=0
BUILD_TYPE_STR=""

case "$BUILD_VARIANT" in
    default)
        BUILD_TYPE_DEFAULT=1
        ;;
    balanced)
        BUILD_TYPE_STR="Balanced"
        BUILD_TYPE_BALANCED=1
        ;;
    battery)
        BUILD_TYPE_STR="Battery"
        BUILD_TYPE_BATTERY=1
        ;;
    oc)
        BUILD_TYPE_STR="Overclock"
        BUILD_TYPE_OC=1
        ;;
    *)
        echo -e "$BLUE INFO: Unknown build variant: $BUILD_VARIANT, defaulting to 'default'$ENDCOLOR"
        BUILD_TYPE_DEFAULT=1
        ;;
esac

if [ $DO_TG -eq 1 ]; then
IDS="$WP/ids"
## Secrets
if ! [ -d "$IDS" ]; then
    git clone -q https://github.com/ProtonKernel/ids $IDS
fi
TELEGRAM_CHAT_ID="$(cat ../ids/chat_ci)"
TELEGRAM_BOT_TOKEN=$(cat ../ids/bot_token)
fi

if [[ "${IS_RELEASE}" = "1" ]]; then
    BUILD_TYPE="Release"
else
    echo -e "$BLUE\nINFO: Build marked as testing$ENDCOLOR"
    BUILD_TYPE="Testing"
fi

## Build type
LINUX_VER=$(make kernelversion 2>/dev/null)

FK_TYPE=""
if [ $DO_KSU -eq 1 -a $DO_NH -eq 1 ]; then
    FK_TYPE="KSU-Nethunter"
    echo -e "$BLUE\nINFO: KSU-Nethunter disables SUSFS support$ENDCOLOR"
    
elif [ $DO_KSU -eq 1 ]; then
    FK_TYPE="KSU"
    
elif [ $DO_NH -eq 1 ]; then
    FK_TYPE="Nethunter"
    
else
    FK_TYPE="Non-root"
    
fi

FK_TYPE="$BUILD_TYPE_STR-$FK_TYPE"

ZIP_PATH="$KDIR/build/ProtonPlus-$K_VER-$FK_TYPE-$CODENAME-$DATE.zip"
TAR_PATH="$KDIR/build/ProtonPlus-$K_VER-$FK_TYPE-$CODENAME-$DATE.tar"

echo -e "$BLUE\nINFO: Build info:$ENDCOLOR
- Device: $DEVICE ($CODENAME)
- Addons = $FK_TYPE
- Proton version: $K_VER
- Linux version: $LINUX_VER
- Defconfig: $DEFCONFIG
- Build date: $DATE
- Build type: $BUILD_TYPE
- Build variant: $BUILD_VARIANT
- Clean build = $DO_CLEAN
"

get_toolchain() {
    # AOSP Clang
    if [[ $1 = "aosp" ]]; then
        if ! [ -d "$AC_DIR" ]; then
        CURRENT_CLANG=$(curl $AOSP_REPO | grep -oE "clang-r[0-9a-f]+" | sort -u | tail -n1)
            echo -e "$BLUE\nINFO: AOSP Clang not found! Cloning to $AC_DIR..."
            if ! curl -LSsO "$AOSP_ARCHIVE/$CURRENT_CLANG.tar.gz"; then
                echo -e "$RED\nERROR: Cloning failed! Aborting...$ENDCOLOR"
                exit 1
            fi
            mkdir -p $AC_DIR && tar -xf ./*.tar.gz -C $AC_DIR && rm ./*.tar.gz && rm -rf clang
            touch $AC_DIR/bin/aarch64-linux-gnu-elfedit && chmod +x $AC_DIR/bin/aarch64-linux-gnu-elfedit
            touch $AC_DIR/bin/arm-linux-gnueabi-elfedit && chmod +x $AC_DIR/bin/arm-linux-gnueabi-elfedit
            rm -rf $CURRENT_CLANG
        fi
    fi

    # Proton Clang
    if [[ $1 = "proton" ]]; then
        if ! [ -d "$PC_DIR" ]; then
            echo -e "$BLUE\nINFO: Proton Clang not found! Cloning to $PC_DIR...$ENDCOLOR"
            if ! git clone -q --depth=1 $PC_REPO $PC_DIR; then
                echo -e "$RED\nERROR: Cloning failed! Aborting...$ENDCOLOR"
                exit 1
            fi
        fi
    fi

    # Lolz Clang
    if [[ $1 = "lolz" ]]; then
        if ! [ -d "$LZ_DIR" ]; then
            echo -e "$BLUE\nINFO: Lolz Clang not found! Cloning to $LZ_DIR...$ENDCOLOR"
            if ! git clone -q --depth=1 $LZ_REPO $LZ_DIR; then
                echo -e "$RED\nERROR: Cloning failed! Aborting...$ENDCOLOR"
                exit 1
            fi
        fi
    fi
}

prep_toolchain() {
    if [[ $1 = "aosp" ]]; then
        CLANG_DIR="$AC_DIR"
        CCARM64_PREFIX=aarch64-linux-gnu-
        echo -e "$BLUE\nINFO: Using AOSP Clang...$ENDCOLOR"
    elif [[ $1 = "proton" ]]; then
        CLANG_DIR="$PC_DIR"
        CCARM64_PREFIX=aarch64-linux-gnu-
        echo -e "$BLUE\nINFO: Using Proton Clang...$ENDCOLOR"
    elif [[ $1 = "lolz" ]]; then
        CLANG_DIR="$LZ_DIR"
        CCARM64_PREFIX=aarch64-linux-gnu-
        echo -e "$BLUE\nINFO: Using Lolz Clang...$ENDCOLOR"
    fi

    ## Set PATH
    export PATH="${CLANG_DIR}/bin:${PATH}"

    KBUILD_COMPILER_STRING=$("$CLANG_DIR"/bin/clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')
    export KBUILD_COMPILER_STRING
}

## Pre-build dependencies
get_toolchain $CLANG_TYPE
prep_toolchain $CLANG_TYPE

## Telegram info variables

CAPTION_BUILD="Build info:
*Device*: \`${DEVICE} [${CODENAME}]\`
*Kernel Version*: \`${LINUX_VER}\`
*Compiler*: \`${KBUILD_COMPILER_STRING}\`
*Linker*: \`$("$CLANG_DIR"/bin/${LINKER} -v | head -n1 | sed 's/(compatible with [^)]*)//' |
            head -n 1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')\`
*Build host*: \`${BUILD_HOST}\`
*Branch*: \`$(git rev-parse --abbrev-ref HEAD)\`
*Commit*: [($(git rev-parse HEAD | cut -c -7))]($(echo -e $KERNEL_URL)/commit/$(git rev-parse HEAD))
*Build type*: \`$BUILD_TYPE\`
*Build variant*: \`$BUILD_VARIANT\`
*Clean build*: \`$( [ "$DO_CLEAN" -eq 1 ] && echo -e Yes || echo -e No )\`
"

# Functions to send file(s) via Telegram's BOT api.
tgs() {
    MD5=$(md5sum "$1" | cut -d' ' -f1)
    curl -fsSL -X POST -F document=@"$1" https://api.telegram.org/bot"${TELEGRAM_BOT_TOKEN}"/sendDocument \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "parse_mode=Markdown" \
        -F "disable_web_page_preview=true" \
        -F "caption=${CAPTION_BUILD}*MD5*: \`$MD5\`" &>/dev/null
}

prep_build() {
    # Prepare ccache
    if [ "$USE_CCACHE" = "1" ]; then
        echo -e "$BLUE\nINFO: Using ccache\n$ENDCOLOR"
        if [ "$IS_GP" = "1" ]; then
            export CCACHE_DIR=$WP/.ccache
            ccache -M 10G
        else
            echo -e "$BLUE\nINFO: Environment is not Gitpod, please make sure you setup your own ccache configuration!\n $ENDCOLOR"
        fi
    fi

    # Show compiler information
    echo -e "$BLUE\nCompiler information:$ENDCOLOR"
    echo -e "$BLUE\nINFO: $KBUILD_COMPILER_STRING\n$ENDCOLOR"
}

build() {
    # Delete log.txt at the start
    rm -f log.txt

    # Not that necessary anymore, but still export it just in case.
    export PLATFORM_VERSION=11
    export ANDROID_MAJOR_VERSION=r
    export TARGET_SOC=exynos2100

    export LLVM=1
    export LLVM_IAS=1
    export ARCH=arm64
    VERSION_STR="\"-ProtonPlus-$K_VER\""
    if [ "$BUILD_TYPE_DEFAULT" != "1" ]; then
        VERSION_STR="\"-ProtonPlus-$K_VER-$BUILD_TYPE_STR\""
    fi

    # Delete leftovers
    rm -f $OUT_KERNEL
    rm -rf "$MOD_OUTDIR"

    make -j$(nproc --all) O=out CC="clang" CROSS_COMPILE="$CCARM64_PREFIX" $DEFCONFIG $([[ "$DO_KSU" == "1" ]] && echo -e "ksu.config") $([[ "$DO_NH" == "1" ]] && echo -e "nethunter.config") $([[ "$DO_NH" == "0" && "$DO_KSU" == "1" ]] && echo -e "susfs.config") 2>&1 | tee log.txt

    if [ $DO_MENUCONFIG = "1" ]; then
        make O=out menuconfig 2>&1 >> log.txt
    fi

    if [[ "$DO_REGEN" = "1" ]]; then
        if [[ "$DO_KSU" = "1" ]]; then
            echo -e "$RED\nERROR: Can't regenerate with KSU argument$ENDCOLOR"
            exit 1
        fi
        cp -f out/.config arch/arm64/configs/$DEFCONFIG
        echo -e "$BLUE\nINFO: Configuration regenerated. Check the changes!$ENDCOLOR"
        exit 0
    fi

    scripts/config --file "$KDIR/out/.config" --set-val LOCALVERSION "$VERSION_STR"

    if [[ "$DO_FLTO" == "1" ]]; then
        scripts/config --file "$KDIR/out/.config" --enable CONFIG_LTO_CLANG
        scripts/config --file "$KDIR/out/.config" --disable CONFIG_THINLTO
    fi

    if [ "$BUILD_TYPE_BALANCED" == "1" ]; then
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL0_UV 4
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL1_UV 4
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL2_UV 3
    fi

    if [ "$BUILD_TYPE_BATTERY" == "1" ]; then
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL0_UV 5
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL1_UV 4
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL2_UV 4
    fi

    if [ "$BUILD_TYPE_OC" == "1" ]; then
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL0_UV 0
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL1_UV 0
        scripts/config --file "$KDIR/out/.config" --set-val CONFIG_SOC_EXYNOS2100_CL2_UV 0
    fi
    ## Start the build
    echo -e "$BLUE\nINFO: Starting compilation...\n$ENDCOLOR"

    make -j$(nproc --all) O=out CC="clang" CROSS_COMPILE="$CCARM64_PREFIX" dtbs 2>&1 | tee -a log.txt
    if [ $USE_CCACHE = "1" ]; then
        make -j$(nproc --all) O=out CC="ccache clang" CROSS_COMPILE="$CCARM64_PREFIX" 2>&1 | tee -a log.txt
    else
        make -j$(nproc --all) O=out CC="clang" CROSS_COMPILE="$CCARM64_PREFIX" 2>&1 | tee -a log.txt
    fi
    make -j$(nproc --all) O=out CC="clang" CROSS_COMPILE="$CCARM64_PREFIX" INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" INSTALL_MOD_PATH="$MOD_OUTDIR" modules_install 2>&1 | tee -a log.txt
}

packing() {
    # # Build zip
    # if [ $DO_ZIP = 1 ]; then
    #     echo -e "$BLUE\nINFO: Building zip...$ENDCOLOR"
    #     cd "$(pwd)/build/zip"
    #     rm -f "$ZIP_PATH"
    #     brotli --quality=3 -c boot.img > boot.br
    #     brotli --quality=3 -c vendor_boot.img > vendor_boot.br
    #     zip -r9 -q "$ZIP_PATH" META-INF boot.br vendor_boot.br
    #     rm -f boot.br vendor_boot.br
    #     cd "$KDIR"
    #     echo -e "$BLUE INFO: Done! $BLUE\nINFO: Output: $ZIP_PATH\n$ENDCOLOR"
    # fi

    # Make an AnyKernel3-based zip
    if [ $DO_ZIP = 1 ]; then
        if [ -d $AK3_DIR ]; then
            echo -e "$BLUE\nINFO: Local AnyKernel3 dir was found$ENDCOLOR"
        else
            if ! git clone -q -b $AK3_BRANCH --depth=1 $AK3_URL $AK3_DIR; then
                echo -e "$RED\nERROR: Failed to clone AnyKernel3!$ENDCOLOR"
                exit 1
            fi
            echo -e "$BLUE\nINFO: Cloning AnyKernel3$ENDCOLOR"
        fi
        echo -e "$BLUE\nINFO: Building zip...$ENDCOLOR"
        cd "$AK3_DIR"
        cp -f "$OUT_VENDORBOOTIMG" vendor_boot.img
        cp -f "$OUT_KERNEL" .
        zip -r9 -q "$ZIP_PATH" * -x .git .github README.md
        cd "$KDIR"
        echo -e "$GREEN INFO: Done!$ENDCOLOR $BLUE\nINFO: Output: $ZIP_PATH\n$ENDCOLOR"
    fi

    # Build tar
    if [ $DO_TAR = 1 ]; then
        echo -e "$BLUE\nINFO: Building tar...$ENDCOLOR"
        cd "$(pwd)/build"
        rm -f "$TAR_PATH"
        lz4 -c -12 -B6 --content-size "$OUT_BOOTIMG" > boot.img.lz4 2>/dev/null
        lz4 -c -12 -B6 --content-size "$OUT_VENDORBOOTIMG" > vendor_boot.img.lz4 2>/dev/null
        tar -cf "$TAR_PATH" boot.img.lz4 vendor_boot.img.lz4
        rm -f boot.img.lz4 vendor_boot.img.lz4
        cd "$KDIR"
        echo -e "$GREEN INFO: Done! $BLUE\nINFO: Output: $TAR_PATH\n$ENDCOLOR"
    fi
}

post_build() {
    local MONTH="$(date +%Y-%m)"

    ## Check if the kernel binaries were built.
    if [ -f "out/arch/arm64/boot/Image" ]; then
        echo -e "$GREEN\nINFO: Kernel compiled succesfully!...\n $ENDCOLOR"
    else
        echo -e "$RED\nERROR: Kernel files not found! Compilation failed?$ENDCOLOR"
        exit 1
    fi

    ## Post build setup
    rm -rf "$TMPDIR"
    rm -f "$OUT_BOOTIMG"
    rm -f "$OUT_VENDORBOOTIMG"
    rm -rf "$RAMDISK_DIR"
    mkdir "$TMPDIR"
    mkdir "$RAMDISK_DIR"
    mkdir -p "$MODULES_DIR/0.0"

    ## Compile correct DTS for variant
    DTB_OUT="$TMPDIR/exynos2100.dtb"
    if [ "$BUILD_TYPE_DEFAULT" = "1" ]; then
        DTS_SRC="$DTS_DEFAULT"
    elif [ "$BUILD_TYPE_BALANCED" = "1" ]; then
        DTS_SRC="$DTS_BALANCED"
    elif [ "$BUILD_TYPE_BATTERY" = "1" ]; then
        DTS_SRC="$DTS_BATTERY"
    elif [ "$BUILD_TYPE_OC" = "1" ]; then
        DTS_SRC="$DTS_OC"
    fi
    echo -e "$BLUE\nINFO: Compiling DTS: $DTS_SRC -> $DTB_OUT\n$ENDCOLOR"
    dtc -I dts -O dtb -o "$DTB_OUT" "$DTS_SRC" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "$RED nERROR: dtc failed to compile $DTS_SRC\n$ENDCOLOR"
        exit 1
    fi

    cp -rf "$IN_VBOOT"/* "$RAMDISK_DIR/"

    # Handle compiled modules
    if ! find "$MOD_OUTDIR/lib/modules" -mindepth 1 -type d | read; then
        echo -e "$RED\nERROR: Unknown error!\n $ENDCOLOR"
        exit 1
    fi

    missing_modules=""

    # If any module from modules.load was not compiled, abort.
    for module in $(cat "$IN_VBOOT/lib/modules/modules.load"); do
        i=$(find "$MOD_OUTDIR/lib/modules" -name $module);
        if [ -f "$i" ]; then
            cp -f "$i" "$MODULES_DIR/0.0/$module"
        else
        missing_modules="$missing_modules $module"
        fi
    done

    if [ "$missing_modules" != "" ]; then
            echo -e "$RED ERROR: the following modules were not found: $missing_modules $ENDCOLOR"
        exit 1
    fi

    # Check for duplicate modules in modules.load
	if [ -f "$IN_VBOOT/lib/modules/modules.load" ]; then
		dupes=$(sort "$IN_VBOOT/lib/modules/modules.load" | uniq -d | xargs)
		if [ -n "$dupes" ]; then
			echo -e "$RED\nERROR: Duplicate module entries found in modules.load: $dupes\n$ENDCOLOR"
			exit 1
		fi
	fi

	# Warn for modules present but not in modules.load
	if [ -d "$MOD_OUTDIR/lib/modules" ] && [ -f "$IN_VBOOT/lib/modules/modules.load" ]; then
		all_built=$(find "$MOD_OUTDIR/lib/modules" -type f -name "*.ko" -exec basename {} \; | sort)
		all_load=$(sort "$IN_VBOOT/lib/modules/modules.load")
		not_in_load=$(comm -23 <(echo -e "$all_built") <(echo -e "$all_load") | xargs)
		if [ -n "$not_in_load" ]; then
			echo -e "$ORANGE\nWARNING: The following modules exist but are NOT in modules.load: $not_in_load\n$ENDCOLOR"
		fi
	fi

    # Prepare ramdisk
    depmod 0.0 -b "$RAMDISK_DIR"
    sed -i 's/\([^ ]\+\)/\/lib\/modules\/\1/g' "$MODULES_DIR/0.0/modules.dep"
    cd "$MODULES_DIR/0.0"
    for i in $(find . -name "modules.*" -type f); do
        if [ $(basename "$i") != "modules.dep" ] && [ $(basename "$i") != "modules.softdep" ] && [ $(basename "$i") != "modules.alias" ]; then
            rm -f "$i"
        fi
    done
    cd "$KDIR"

    cp -f "$IN_VBOOT/lib/modules/modules.load" "$MODULES_DIR/0.0/modules.load"
    mv "$MODULES_DIR/0.0"/* "$MODULES_DIR/"
    rm -rf "$MODULES_DIR/0.0"

    # Build the images
    echo -e "$BLUE\nINFO: Building dtb image..."
    python "$MKDTBOIMG" create "$OUT_DTBIMAGE" --custom0=0x00000000 --custom1=0xff000000 --version=0 --page_size=2048 "$TMPDIR/exynos2100.dtb" || exit 1

    echo -e "$BLUE\nINFO: Building boot image...$ENDCOLOR"
    $MKBOOTIMG --header_version 3 \
        --kernel "$OUT_KERNEL" \
        --output "$OUT_BOOTIMG" \
        --ramdisk "$PREBUILT_RAMDISK" \
        --os_version 11.0.0 \
        --os_patch_level "$MONTH" || exit 1
    echo -e "$GREEN INFO: Done!$ENDCOLOR"

    echo -e "$BLUE\nINFO: Building vendor_boot image...$ENDCOLOR"
    cd "$RAMDISK_DIR"
    find . | cpio --quiet -o -H newc -R root:root | gzip -9 > ../ramdisk.cpio.gz
    cd ..

    $MKBOOTIMG --header_version 3 \
        --vendor_boot "$OUT_VENDORBOOTIMG" \
        --vendor_cmdline "loop.max_part=7" \
        --dtb "$OUT_DTBIMAGE" \
        --vendor_ramdisk "$(pwd)/ramdisk.cpio.gz" \
        --os_version 11.0.0 \
        --os_patch_level "$MONTH" || exit 1

    cd "$KDIR"

    echo -e "$GREEN INFO: Done!$ENDCOLOR"

    packing
}

upload() {
    cd $KDIR
    if [[ "${DO_OSHI}" = "1" ]]; then
    echo -e "$BLUE\nINFO: Uploading to bashupload.com\n$ENDCOLOR"
    curl -T $ZIP_PATH bashupload.com; echo -e
    fi

    if [[ "${DO_TG}" = "1" ]]; then
            echo -e "$BLUE\nINFO: Uploading to Telegram\n$ENDCOLOR"
            tgs $ZIP_PATH
            echo -e "$GREEN Done!$ENDCOLOR"
    fi
    if [[ "${BUILD_LOG}" = "1" ]]; then
        echo -e "$BLUE\nINFO: Uploading log to bashupload.com\n$ENDCOLOR"
        curl -T log.txt bashupload.com
    fi
    # Delete any leftover zip files
    #rm -f $KDIR/build/*zip
}

clean() {
    make clean
    make mrproper
}

clean_tmp() {
    echo -e "$BLUE INFO: Cleaning after build...$ENDCOLOR"
    rm -rf "$TMPDIR"
    rm -rf "$MOD_OUTDIR"
    rm -f "${OUT_VENDORBOOTIMG}" "${OUT_BOOTIMG}"
}

# Do a clean build?
if [[ $DO_CLEAN = "1" ]]; then
    clean
fi
## Run build
prep_build
build
upload
post_build
clean_tmp
