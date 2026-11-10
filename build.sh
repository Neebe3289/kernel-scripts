#!/usr/bin/env bash

set -euo pipefail

KDIR=$(pwd)
OUT_DIR=$KDIR/out
BUILD_LOG=$OUT_DIR/buildlog-$(date +"%H%M").log
TOOLS_DIR=$KDIR/../tools
CLANG_DIR=$TOOLS_DIR/clang-llvm
GCC64_DIR=$TOOLS_DIR/gcc64
GCC32_DIR=$TOOLS_DIR/gcc32
AK3_DIR=$TOOLS_DIR/AnyKernel3
PATCH_DIR=$TOOLS_DIR/kernel_patches

DEFCONFIG=begonia_user_defconfig

msg() { echo -e "\e[1;32m$*\e[0m"; }
err() { echo -e "\e[1;31m$*\e[0m"; }

#### Parsing parameters ####

if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
    err "- Missing BOT_TOKEN or CHAT_ID!"
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -b|--build)     kernelsu=false ;;
        -k|--ksu)       kernelsu=true ;;
        -a|--all)       build_all=true ;;
        -r|--regen)     regen_defconfig=true ;;
        -c|--clean)     cleanup=true ;;
        -h|--help|*)
            [ "$1" != "-h" ] && [ "$1" != "--help" ] && err "Unknown operate: $1\n"
            cat << EOF
Usage: $0 <operate>
operate:
  -b, --build       : Build normal kernel + KPatch fixes
  -k, --ksu         : Build KernelSU kernel
  -a, --all         : Build both Normal and KernelSU kernels
  -r, --regen       : Regenerate defconfig
  -c, --clean       : Clean build outputs and temporary artifacts
  -h, --help        : Show this help message
EOF
            exit 1
            ;;
    esac
    shift
done

#### Preparation ####

doSetupTools() {
    msg "- Setup dependencies"
    mkdir -p $TOOLS_DIR

    if [ ! -d $CLANG_DIR/bin ]; then
        msg "- Downloading Clang"
        rm -rf $CLANG_DIR
        mkdir -p $CLANG_DIR
        aria2c -s16 -x16 -k1M "https://github.com/Neebe3289/aosp-clang/releases/download/clang-23.0.1-16836431/clang-23.0.1-16836431.tar.gz" -o clang.tar.gz
        tar -C $CLANG_DIR -zxf clang.tar.gz && rm -f clang.tar.gz
    else
        msg "- Clang compiler found!"
    fi

    if [ ! -d $GCC64_DIR ]; then
        git clone --depth=1 -b lineage-19.1 https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 $GCC64_DIR
    fi

    if [ ! -d $GCC32_DIR ]; then
        git clone --depth=1 -b lineage-19.1 https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9 $GCC32_DIR
    fi

    if [ ! -d $AK3_DIR ]; then
        git clone --depth=1 -b begonia https://github.com/Neebe3289/AnyKernel3 $AK3_DIR
    fi

    if [ ! -d $PATCH_DIR ]; then
        git clone --depth=1 https://github.com/Neebe3289/kernel_patches $PATCH_DIR
    fi
}

doExportEnv() {
    export TZ=Asia/Jakarta
    export ARCH=arm64
    export SUBARCH=arm64
    export KBUILD_BUILD_USER=Neebe3289
    export KBUILD_BUILD_HOST=build-host

    export KBUILD_COMPILER_STRING=$("$CLANG_DIR/bin/clang" --version | head -n 1)
    export PATH=$CLANG_DIR/bin:$GCC64_DIR/bin:$GCC32_DIR/bin:$PATH
    export LD_LIBRARY_PATH=$CLANG_DIR/lib:${LD_LIBRARY_PATH:-}
}

doSendMsg() {
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id=$CHAT_ID -d parse_mode=HTML --data-urlencode text="$1" >/dev/null || true
}

doSendFile() {
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        -F chat_id=$CHAT_ID -F document=@"$1" -F caption="$2" >/dev/null || true
}

doClean() {
    msg "- Cleaning up build artifacts"

    rm -rf $OUT_DIR

    if [ -d $AK3_DIR ]; then
        rm -f $AK3_DIR/Image* \
              $AK3_DIR/dtb \
              $AK3_DIR/dtbo.img \
              $AK3_DIR/*.zip
    fi

    if [ -d $AK3_DIR/.git ]; then
        git -C $AK3_DIR checkout . &>/dev/null || true
    fi
}

doApplyKPatch() {
    cd $KDIR
    msg "- Applying KPatch fixes"

    local files=(
        $PATCH_DIR/kernel_patch/kpatch_fix.patch
    )

    for kp in "${files[@]}"; do
        if [ -f $kp ]; then
            if patch -p1 -R --dry-run < $kp &>/dev/null; then
                msg "⚠️ Patch $(basename $kp) already applied, skipping..."
            elif patch -p1 < $kp; then
                msg "✅ Applied: $(basename $kp)"
            else
                err "❌ Failed to apply: $(basename $kp)"
                exit 1
            fi
        else
            err "❌ Patch file not found: $kp"
            exit 1
        fi
    done

    sed -i "s/# CONFIG_TMPFS_XATTR is not set/CONFIG_TMPFS_XATTR=y/g" arch/arm64/configs/$DEFCONFIG
    sed -i "s/# CONFIG_KALLSYMS_ALL is not set/CONFIG_KALLSYMS_ALL=y/g" arch/arm64/configs/$DEFCONFIG
}

doApplyKSU() {
    cd $KDIR
    msg "- Cleaning up existing KSU & NoMount environment"

    [ -f KernelSU/kernel/setup.sh ] && bash KernelSU/kernel/setup.sh --cleanup || true
    [ -f KernelSU-Next/kernel/setup.sh ] && bash KernelSU-Next/kernel/setup.sh --cleanup || true
    [ -f NoMount/kernel/setup.sh ] && bash NoMount/kernel/setup.sh --cleanup || true

    for sub in NoMount KernelSU KernelSU-Next; do
        if git config --file .gitmodules --get-regexp "path" 2>/dev/null | grep -q $sub; then
            git submodule deinit -f $sub &>/dev/null || true
            git rm -f $sub &>/dev/null || true
            rm -rf .git/modules/$sub
        fi
    done

    rm -rf KernelSU KernelSU-Next NoMount drivers/kernelsu fs/nomount

    msg "- Syncing KernelSU feat NoMount drivers"
    curl -LSs "https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh" | bash -
    curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s dev
}

doRegenConfig() {
    cd $KDIR
    msg "- Regenerating defconfig"
    make O=$OUT_DIR $DEFCONFIG
    make O=$OUT_DIR savedefconfig
    cp $OUT_DIR/defconfig arch/arm64/configs/$DEFCONFIG
    msg "- Defconfig saved to arch/arm64/configs/$DEFCONFIG"
}

doCompile() {
    cd $KDIR
    local build_type=${1:-normal}
    local kversion branch commits start_time end_time total_time date_time zipname elapsed md5csum

    kversion=$(make kernelversion)
    branch=$(git rev-parse --abbrev-ref HEAD)
    commits=$(git rev-parse --short HEAD)

    local cc_flag=clang
    command -v ccache &>/dev/null && cc_flag="ccache clang"

    local args=(
        CC="$cc_flag"
        LD=ld.lld AR=llvm-ar NM=llvm-nm LLVM=1 LLVM_IAS=1
        OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf STRIP=llvm-strip
        CLANG_TRIPLE=aarch64-linux-gnu-
        CROSS_COMPILE=aarch64-linux-android-
        CROSS_COMPILE_ARM32=arm-linux-androideabi-
    )

    start_time=$(date +"%s")

    doSendMsg "<b>====================================</b>
<b>• Date :</b> <code>$(date +"%A, %d %b %Y, %H:%M:%S")</code>
<b>• Device :</b> <code>Redmi Note 8 Pro</code>
<b>• Linux version :</b> <code>$kversion</code>
<b>• Branch :</b> <code>$branch</code>
<b>• Commit :</b> <code>$(git log -1 --pretty=format:"%h : %s")</code>
<b>====================================</b>"

    mkdir -p $OUT_DIR
    make O=$OUT_DIR $DEFCONFIG

    if [ "$build_type" = "ksu" ]; then
        msg "- Inject KernelSU + NoMount configs"
        $KDIR/scripts/config --file $OUT_DIR/.config \
            -e CONFIG_KSU \
            -e CONFIG_KSU_TAMPER_SYSCALL_TABLE \
            -e CONFIG_KSU_HOSTSREDIRECT \
            -e CONFIG_NOMOUNT \
            -e CONFIG_TMPFS_XATTR

        make O=$OUT_DIR olddefconfig
    fi

    msg "- Build kernel"
    make -j$(nproc --all) O=$OUT_DIR "${args[@]}" 2>&1 | tee $BUILD_LOG

    end_time=$(date +"%s")
    total_time=$((end_time - start_time))
    date_time=$(date +"%Y%m%d-%H%M")

    if [ -f $OUT_DIR/arch/arm64/boot/Image.gz-dtb ]; then
        msg "- Build completed!"
        cp $OUT_DIR/arch/arm64/boot/Image.gz-dtb $AK3_DIR/

        cd $AK3_DIR
        sed -i "s/kernel.string=.*/kernel.string=Perf Kernel for Redmi Note 8 Pro by $KBUILD_BUILD_USER/g" anykernel.sh

        if [ "$build_mode" = "ksu" ]; then
            zipname="Perf-KSU-$commits-begonia-$date_time.zip"
        else
            zipname="Perf-$commits-begonia-$date_time.zip"
        fi

        zip -r9 $zipname . -x ".git*" "README.md"

        elapsed="$((total_time / 60))m $((total_time % 60))s"
        md5csum=$(md5sum $zipname | cut -d" " -f1)

        doSendFile $zipname "✅ Build took: $elapsed for begonia | MD5: $md5csum"
        doClean
    else
        err "- Build failed!"
        doSendFile $BUILD_LOG "❌ Build failed!. Please check log."
        exit 1
    fi
}

if [ "${cleanup:-false}" = "true" ]; then
    doClean
    exit 0
fi

doSetupTools
doExportEnv

if [ "${regen_defconfig:-false}" = "true" ]; then
    doRegenConfig
elif [ "${build_all:-false}" = "true" ]; then
    msg "- Starting build all process"
    for type in "normal" "ksu"; do
        if [ "$type" = "ksu" ]; then
            doApplyKSU
            doCompile ksu
        else
            doApplyKPatch
            doCompile normal
        fi
    done
    msg "- All builds completed successfully!"
else
    if [ "${kernelsu:-false}" = "true" ]; then
        doApplyKSU
        doCompile ksu
    else
        doApplyKPatch
        doCompile normal
    fi
fi
