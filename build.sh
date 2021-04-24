#! /usr/bin/env bash

set -eux

ROOTDIR=$(dirname $(realpath "$0"))
BINDIR=${ROOTDIR}/binaries
mkdir -p ${BINDIR}

function fatal()
{
    echo $1
    exit 1
}

### Build arm-trusted-firmware bl31.elf for rk3399
if [ ! -d arm-trusted-firmware ];
then
    git clone https://github.com/ARM-software/arm-trusted-firmware.git
fi

cd arm-trusted-firmware
git checkout v2.4
make realclean
make -j$(nproc) CROSS_COMPILE=aarch64-linux-gnu- PLAT=rk3399 bl31
cp build/rk3399/release/bl31/bl31.elf ${BINDIR}
export BL31=${BINDIR}/bl31.elf
cd -

### Build u-boot binaries
if [ ! -d arm-trusted-firmware ];
then
    git clone https://github.com/ARM-software/arm-trusted-firmware.git
fi

# Configure U-Boot
make mrproper
make rockpro64-rk3399_defconfig

make -j$(nproc) CROSS_COMPILE=aarch64-linux-gnu-

# Make idbloader.img
tools/mkimage -n rk3399 -T rkspi -d tpl/u-boot-tpl.bin:spl/u-boot-spl.bin spi_idbloader.img
tools/mkimage -n rk3399 -T rksd -d tpl/u-boot-tpl.bin:spl/u-boot-spl.bin mmc_idbloader.img

# Copy built-in env object and extract env data
cp env/built-in.o built_in_env.o
aarch64-linux-gnu-objcopy -O binary -j ".rodata.default_environment" built_in_env.o

# Replace null terminator in built-in env with newlines
tr '\0' '\n' < built_in_env.o | sed '/^$/d' > built_in_env.txt

# Make built-in env image with correct CRC
tools/mkenvimage -s 0x8000 -o default_env.img built_in_env.txt

# Copy built artifacts to artifact staging directory
mv *_idbloader.img ${BINDIR}
mv default_env.img ${BINDIR}

### Create single SPI image with u-boot.itb at 0x60000

padsize=$((0x60000 - 1))
img1size=$(wc -c <"${BINDIR}/spi_idbloader.img")
[ $img1size -le $padsize ] || fatal "SPI Image is too big"
dd if=/dev/zero of="${BINDIR}/spi_idbloader.img" conv=notrunc bs=1 count=1 seek=$padsize
cat "${BINDIR}/spi_idbloader.img" u-boot.itb > "${BINDIR}/spi_combined.img"

### Create SD card images to flash u-boot to SPI or erase SPI flash
tools/mkimage -C none -A arm -T script -d scripts/flash_spi.cmd ${BINDIR}/flash_spi.scr
tools/mkimage -C none -A arm -T script -d scripts/erase_spi.cmd ${BINDIR}/erase_spi.scr

SCRIPT_NAMES=(flash_spi erase_spi)
for script_name in ${SCRIPT_NAMES[@]};
do
    cp ${BINDIR}/${script_name}.scr boot.scr
    cp ${BINDIR}/spi_combined.img spi_combined.img
    dd if=/dev/zero of=boot.tmp bs=1M count=16
    mkfs.vfat -n uboot-scr boot.tmp
    mcopy -sm -i boot.tmp boot.scr ::
    mcopy -sm -i boot.tmp spi_combined.img ::
    dd if=/dev/zero of=${script_name}.img bs=1M count=32
    parted -s ${script_name}.img mklabel gpt
    parted -s ${script_name}.img unit s mkpart loader1 64 8063
    parted -s ${script_name}.img unit s mkpart loader2 16384 24575
    parted -s ${script_name}.img unit s mkpart boot fat16 24576 100%
    parted -s ${script_name}.img set 3 legacy_boot on
    dd if=${BINDIR}/mmc_idbloader.img of=${script_name}.img conv=notrunc seek=64
    dd if=u-boot.itb of=${script_name}.img conv=notrunc seek=16384
    dd if=boot.tmp of=${script_name}.img conv=notrunc seek=24576
    gzip ${script_name}.img
    mv ${script_name}.img.gz ${BINDIR}
done
