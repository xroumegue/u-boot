#! /usr/bin/env bash

set -ex

usage(){
  echo $0 uboot_dir fw_dir
  exit 1
}
fatal() {
  echo $0
  exit 1
}
[ $# == 2 ] || usage

srctree="$1"
fwdir=$(realpath "$2")

echo "Using ${fwdir}  as firmware directory"

[ -d ${srctree} ] || fatal "${srctree} does not exist"
[ -d ${fwdir} ] || mkdir -p "$2"

ahab_img=firmware-ele-imx-2.0.2-89161a8.bin
ddr_phy=firmware-imx-8.28-994fa14.bin
ddr_phy_version=v202409
arm_none_version=13.3.rel1
arm_none_tc=arm-gnu-toolchain-${arm_none_version}-x86_64-arm-none-eabi.tar.xz
export TOOLS=${fwdir}


clone_repo() {
  url="$1"
  branch="$2"
  name=$(basename "${url}")
  if [ ! -d "${name}" ]; then
    git clone -b ${branch} "${url}"
  else
    echo "Skipping existing repo ${name}"
  fi
}

download_firmwares() {
  cd "${fwdir}"

  if [ ! -f ${ahab_img} ]; then
    wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/${ahab_img}
  else
    echo "Skipping ${ahab_img}"
  fi

  if [ ! -f ${ddr_phy} ]; then
    wget https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/${ddr_phy}
  else
    echo "Skipping ${ddr_phy}"
  fi

  if [ ! -f ${arm_none_tc} ]; then
    wget https://developer.arm.com/-/media/Files/downloads/gnu/${arm_none_version}/binrel/${arm_none_tc}
  else
    echo "Skipping ${arm_none_tc}"
  fi

  clone_repo https://github.com/nxp-imx/imx-oei master
  clone_repo https://github.com/nxp-imx/imx-sm master
  clone_repo https://github.com/nxp-imx/imx-atf lf_v2.12

  cd -
}

install_firmwares() {
  cd "${fwdir}"
  ahab_dir="$(basename "${ahab_img}" .bin)"
  if [ ! -d  "${ahab_dir}" ]; then
    sh "${ahab_img}" --auto-accept
  else
    echo "Skipping ${ahab_img} decompression"
  fi
  cp "${ahab_dir}"/mx95b0-ahab-container.img "${srctree}"

  ddr_phy_dir="$(basename "${ddr_phy}" .bin)"
  if [ ! -d  "${ddr_phy_dir}" ]; then
    sh "${ddr_phy}" --auto-accept
  else
    echo "Skipping ${ddr_phy} decompression"
  fi
  cp "${ddr_phy_dir}"/firmware/ddr/synopsys/lpddr5*"${ddr_phy_version}".bin "${srctree}"

  cd -
}

install_toolchain() {
  cd "${fwdir}"
  arm_tc_dir=$(basename "${arm_none_tc}" .tar.xz)
  if [ ! -d ${arm_tc_dir} ]; then
    tar -xJvf "${arm_none_tc}"
  else
    echo "Skipping toolchain ${arm_tc_dir} decompression"
  fi
}

build_oei() {
  make -C "${fwdir}/imx-oei" board=mx95lp5 oei=ddr DEBUG=1 r=B0 all
  cp "${fwdir}"/imx-oei/build/mx95lp5/ddr/oei-m33-ddr.bin "${srctree}"
}

build_sm() {
  make -C "${fwdir}/imx-sm" config=mx95evk all
  cp "${fwdir}"/imx-sm/build/mx95evk/m33_image.bin "${srctree}"
}

build_atf() {
  make CROSS_COMPILE=aarch64-linux-gnu- -C "${fwdir}/imx-atf" PLAT=imx95 bl31 
  cp "${fwdir}"/imx-atf/build/imx95/release/bl31.bin "${srctree}"
}

build_uboot() {
  make CROSS_COMPILE=aarch64-linux-gnu- -C "${srctree}" imx95_19x19_evk_defconfig
  make -j"$(nproc)" CROSS_COMPILE=aarch64-linux-gnu- -C "${srctree}" 
  echo "sudo dd if=flash.bin of=/dev/sd[x] bs=1k seek=32 conv=fsync"
}

download_firmwares
install_firmwares
install_toolchain
build_oei
build_sm
build_atf
build_uboot
