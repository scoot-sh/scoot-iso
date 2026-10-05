# Reference target machine: mirrors iso/target/configuration.nix's
# scoot options (same desktop profile, look, greeter, bar, cachix, no
# autologin) with stub hardware, so the ISO can ship its closure in
# isoImage.storeContents for the network-cut install. The installed
# files themselves come from iso/target/* by construction (the Calamares
# patch consumes those derivations); this module exists only to name the
# same option set for the closure. tests/patch_consistency.py asserts
# the mirrored lines stay identical in both places.
{ config, pkgs, ... }:

{
  # Stub hardware: the real hardware-configuration.nix is generated on
  # the target by nixos-generate-config during install.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
  };
  swapDevices = [ ];

  networking.hostName = "scoot";
  networking.networkmanager.enable = true;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    extra-substituters = [ "https://scoot-sh.cachix.org" ];
    extra-trusted-public-keys = [
      "scoot-sh.cachix.org-1:QMj7CMw8uqZxrvqqm6SggdxTHz6Q4prt30ydDcXJXCo="
    ];
  };

  users.users.scoot = {
    isNormalUser = true;
    description = "scoot";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
  };

  programs.firefox.enable = true;

  environment.systemPackages = with pkgs; [ foot ];

  services.qemuGuest.enable = true;

  programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "vinyl-sunset";
    session.enable = true;
    greeter.enable = true;
  };

  programs.scootbar.enable = true;

  home-manager.users.scoot.programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "vinyl-sunset";
  };
  home-manager.users.scoot.programs.scootbar.enable = true;
  home-manager.users.scoot.home.stateVersion = "25.11";

  system.stateVersion = "25.11";
}
