#!/usr/bin/env bash
# archiso profile for the Loom install medium.
# shellcheck disable=SC2034

iso_name="loom"
iso_label="LOOM_$(date +%Y%m)"
# Written into the ISO9660 volume metadata, so `isoinfo -d` on the finished
# image says who built it.
iso_publisher="SpaceCrafter29 <https://github.com/SpaceCrafter29/loom>"
iso_application="Loom install medium"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')

# UEFI only, deliberately. The installed system uses unified kernel images and
# Secure Boot, neither of which exists under legacy BIOS, so an installer that
# booted in CSM mode could only produce a machine that does not match its own
# documentation. Dropping the syslinux boot modes also removes a whole
# bootloader from the build.
bootmodes=('uefi-x64.systemd-boot.esp' 'uefi-x64.systemd-boot.eltorito')

arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--long' '-19')

file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.bash_profile"]="0:0:644"
  ["/usr/local/bin/loom-install"]="0:0:755"
  ["/usr/share/loom-payload/scripts/bootstrap.sh"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/usr/local/bin/loomctl"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/usr/local/bin/loom-session"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/usr/local/bin/loom-gui"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/usr/local/bin/loom-sign-boot"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/usr/local/bin/loom-build-rescue"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/usr/share/loom/rescue/rescue.sh"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/etc/initcpio/install/loom-rescue"]="0:0:755"
  ["/usr/share/loom-payload/rootfs/etc/initcpio/hooks/loom-rescue"]="0:0:755"
)
