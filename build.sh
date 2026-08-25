#!/usr/bin/env bash
#
# build.sh - begonia (Redmi Note 8 Pro, MT6785) kernel builder
#
# Builds an APatch-ready kernel with a pinned Android clang + GCC binutils
# toolchain and packages a flashable AnyKernel3 zip.
#
# The kernel image (Image.gz-dtb with appended DTB) is produced with
# CONFIG_KALLSYMS=y and CONFIG_KALLSYMS_ALL=y enabled in the defconfig so that
# APatch / KernelPatch can resolve symbols and be patched onto the boot image.
#
# Requirements: bash, curl, tar, unzip, zip, cpio, make, python3, git
#
# Environment overrides:
#   KERNEL_NAME   zip/kernel name (default: Begonia-APatch-Kernel)
#   CLANG_VER     android clang release (default: clang-r383902)
#   GCC_VER       android aosp release tag for binutils (default: android-11.0.0_r1)
#   TC_ROOT       directory where toolchains are stored (default: $HOME/toolchains)
#   OUT_DIR       kernel out directory (default: out)
#   DEFCONFIG     kernel defconfig (default: begonia_user_defconfig)
#   JOBS          build jobs (default: $(nproc))
#   SKIP_PACKAGE  set to 1 to skip making the flashable zip
#   KEEP_CUSTOM_FLAGS  set to 1 to keep CONFIG_LLVM_POLLY / CONFIG_INLINE_OPTIMIZATION
#   EXTRA_FLAGS   extra flags appended to both make invocations

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_NAME="${KERNEL_NAME:-Begonia-APatch-Kernel}"
CLANG_VER="${CLANG_VER:-clang-r383902}"
GCC_VER="${GCC_VER:-android-11.0.0_r1}"
TC_ROOT="${TC_ROOT:-$HOME/toolchains}"
OUT_DIR="${OUT_DIR:-out}"
JOBS="${JOBS:-$(nproc)}"
EXTRA_FLAGS="${EXTRA_FLAGS:-}"
DEFCONFIG="${DEFCONFIG:-begonia_user_defconfig}"
DATE="$(date +%Y%m%d-%H%M)"

ARCH=arm64
CC=clang
CLANG_TRIPLE=aarch64-linux-gnu-
CROSS_COMPILE=aarch64-linux-android-

CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/${GCC_VER}/${CLANG_VER}.tar.gz"
GCC_URL="https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/refs/tags/${GCC_VER}.tar.gz"
AK3_URL="https://github.com/osm0sis/AnyKernel3/archive/refs/heads/master.zip"

log() { printf '\033[1;32m[*] %s\033[0m\n' "$*"; }

mkdir -p "$TC_ROOT"

setup_clang() {
    if [[ -n "${CLANG_DIR:-}" ]]; then
        TC_CLANG="$CLANG_DIR"
        log "Using preinstalled clang at $TC_CLANG"
    elif [[ -x "$TC_ROOT/clang-$CLANG_VER/bin/clang" ]]; then
        TC_CLANG="$TC_ROOT/clang-$CLANG_VER"
        log "Using cached clang at $TC_CLANG"
    else
        log "Downloading clang $CLANG_VER ..."
        curl -L --fail --retry 3 -o "$TC_ROOT/clang.tar.gz" "$CLANG_URL"
        mkdir -p "$TC_ROOT/clang-$CLANG_VER"
        tar -xzf "$TC_ROOT/clang.tar.gz" -C "$TC_ROOT/clang-$CLANG_VER"
        rm -f "$TC_ROOT/clang.tar.gz"
        TC_CLANG="$TC_ROOT/clang-$CLANG_VER"
    fi
}

setup_gcc() {
    if [[ -n "${GCC_DIR:-}" ]]; then
        TC_GCC="$GCC_DIR"
        log "Using preinstalled binutils at $TC_GCC"
    elif [[ -x "$TC_ROOT/gcc-$GCC_VER/bin/aarch64-linux-android-ld" ]]; then
        TC_GCC="$TC_ROOT/gcc-$GCC_VER"
        log "Using cached binutils at $TC_GCC"
    else
        log "Downloading aarch64-linux-android-4.9 binutils ..."
        curl -L --fail --retry 3 -o "$TC_ROOT/gcc.tar.gz" "$GCC_URL"
        mkdir -p "$TC_ROOT/gcc-$GCC_VER"
        tar -xzf "$TC_ROOT/gcc.tar.gz" -C "$TC_ROOT/gcc-$GCC_VER"
        rm -f "$TC_ROOT/gcc.tar.gz"
        TC_GCC="$TC_ROOT/gcc-$GCC_VER"
    fi
}

# Prepare .config: disable custom MTK -mllvm flags if the toolchain rejects them.
prepare_config() {
    local test_src="$TC_ROOT/.tc-test.c"
    printf 'int x;\n' > "$test_src"
    if [[ "${KEEP_CUSTOM_FLAGS:-0}" == "1" ]]; then
        log "KEEP_CUSTOM_FLAGS=1 - keeping custom -mllvm flags"
        return
    fi
    if ! "$TC_CLANG/bin/clang" --target=aarch64-linux-gnu \
        -mllvm -polly -mllvm -polly-postopts=1 -mllvm -polly-ast-use-context \
        -mllvm -polly-detect-keep-going -mllvm -polly-vectorizer=stripmine \
        -mllvm -polly-invariant-load-hoisting -c "$test_src" -o /dev/null 2>/dev/null; then
        log "Toolchain lacks patched LLVM Polly - disabling CONFIG_LLVM_POLLY"
        ./scripts/config --file "$OUT_DIR/.config" --disable LLVM_POLLY
    fi
    if ! "$TC_CLANG/bin/clang" --target=aarch64-linux-gnu \
        -mllvm -unroll-threshold=1200 -mllvm -unroll-threshold=900 \
        -mllvm -inline-threshold=2000 -mllvm -inline-threshold=1300 \
        -c "$test_src" -o /dev/null 2>/dev/null; then
        log "Toolchain rejects repeated -mllvm thresholds - disabling CONFIG_INLINE_OPTIMIZATION"
        ./scripts/config --file "$OUT_DIR/.config" --disable INLINE_OPTIMIZATION
    fi
    make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS olddefconfig
}

build_kernel() {
    log "Building kernel (defconfig: $DEFCONFIG, jobs: $JOBS)"
    export PATH="$TC_CLANG/bin:$TC_GCC/bin:$PATH"
    mkdir -p "$ROOT_DIR/$OUT_DIR"
    cd "$ROOT_DIR"
    make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS "$DEFCONFIG"
    prepare_config
    make O="$OUT_DIR" ARCH="$ARCH" CC="$CC" \
        CLANG_TRIPLE="$CLANG_TRIPLE" CROSS_COMPILE="$CROSS_COMPILE" \
        $EXTRA_FLAGS -j"$JOBS"
    [[ -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" ]] || {
        echo "ERROR: Image.gz-dtb not produced" >&2
        exit 1
    }
    [[ -f "$OUT_DIR/arch/arm64/boot/Image" ]] || {
        echo "ERROR: Image not produced" >&2
        exit 1
    }
}



setup_anykernel() {
    local stage="$ROOT_DIR/$OUT_DIR/anykernel"
    rm -rf "$stage"
    mkdir -p "$stage"
    log "Downloading AnyKernel3 ..."
    curl -L --fail --retry 3 -o "$TC_ROOT/ak3.zip" "$AK3_URL"
    unzip -q "$TC_ROOT/ak3.zip" -d "$TC_ROOT/ak3-tmp"
    cp -r "$TC_ROOT/ak3-tmp"/AnyKernel3-master/. "$stage/"
    rm -rf "$TC_ROOT/ak3-tmp" "$TC_ROOT/ak3.zip"
}

package_zip() {
    if [[ "${SKIP_PACKAGE:-0}" == "1" ]]; then
        log "Skipping zip packaging (SKIP_PACKAGE=1)"
        return
    fi
    local stage="$ROOT_DIR/$OUT_DIR/anykernel"
    cp "$ROOT_DIR/$OUT_DIR/arch/arm64/boot/Image.gz-dtb" "$stage/Image.gz-dtb"
    cat > "$stage/anykernel.sh" <<EOF
# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
properties() { '
kernel.string=$KERNEL_NAME for Redmi Note 8 Pro (begonia) [APatch-ready]
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=begonia
device.name2=begonia_in
device.name3=begoniain
supported.versions=
supported.patchlevels=
'; } # end properties

## shell variables
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;

## AnyKernel install
dump_boot;

write_boot;

## end install
EOF
    local zip="$ROOT_DIR/$KERNEL_NAME-$DATE.zip"
    log "Creating flashable zip: $zip"
    (cd "$stage" && zip -r9 "$zip" . -x '*.git*')
}

main() {
    setup_clang
    setup_gcc
    build_kernel
    setup_anykernel
    package_zip
    log "Done."
    log "Kernel image:  $ROOT_DIR/$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
    if [[ -f "$ROOT_DIR/$KERNEL_NAME-$DATE.zip" ]]; then
        log "Flashable zip: $ROOT_DIR/$KERNEL_NAME-$DATE.zip"
    fi
    log "Note: patch the boot image with APatch / kptools (kptools-img2kptools) before flashing."
}

main "$@"
