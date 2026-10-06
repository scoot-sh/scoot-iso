# Static QEMU hardware for the scoot-iso offline-install test (see
# scripts/qemu-test.sh and nix/target-machine.nix).
#
# nixos-generate-config output is non-deterministic (filesystem UUIDs,
# host-detected initrd modules), which would make the exact target
# system the installer writes differ from the reference toplevel shipped
# (isoImage.storeContents) and break the network-cut install: with
# `substitute = false` every differing derivation would have to be built
# in an empty target store. Device paths (/dev/vdaN) are stable under
# the virtio-blk layout the test creates (512M ESP on vda1, root on
# vda2), so this file is byte-identical on every run, on x86_64 and
# aarch64 alike. The virtio initrd modules come from the qemu-guest
# profile (same import nixos-generate-config emits); ext4/vfat stay on
# their NixOS defaults.
#
# Real installs still use nixos-generate-config (real hardware varies);
# only the test uses this file, so the test proves the offline
# mechanism for one canonical config (see README "What the installer
# writes").
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  fileSystems."/" = {
    device = "/dev/vda2";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/vda1";
    fsType = "vfat";
  };

  swapDevices = [ ];
}
