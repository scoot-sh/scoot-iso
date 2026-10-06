# Reference target machine: mirrors iso/target/configuration.nix's
# scoot options (same desktop profile, look, greeter, bar, cachix, no
# autologin) with the STATIC QEMU hardware scripts/qemu-test.sh installs
# to (iso/target/hardware-configuration.nix, imported here), so the ISO
# can ship its closure in isoImage.storeContents for the network-cut
# install. The installed files themselves come from iso/target/* by
# construction (the Calamares patch consumes those derivations); this
# module exists only to name the same option set for the closure.
# tests/patch_consistency.py asserts the mirrored lines stay identical
# in both places, and tests/render_check.py asserts the QEMU test's
# canonical render (user scoot, host scoot, UTC, en_US.UTF-8, 25.11,
# moonrise, home-folder layout) evaluates to this same toplevel
# (drvPath match), so the two cannot drift: with `substitute = false`
# the installed system's closure must already be in the ISO's store.
{ config, pkgs, ... }:

{
  imports = [ ../iso/target/hardware-configuration.nix ];

  networking.hostName = "scoot";
  networking.networkmanager.enable = true;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings = {
    extra-substituters = [ "https://scoot-sh.cachix.org" ];
    extra-trusted-public-keys = [
      "scoot-sh.cachix.org-1:QMj7CMw8uqZxrvqqm6SggdxTHz6Q4prt30ydDcXJXCo="
    ];
    experimental-features = [
      "nix-command"
      "flakes"
    ];
  };

  # The install account, exactly as the installer's USERS_STANZA
  # writes it for the canonical test user (uid/gid pinned so the
  # installer can chown before the user exists; see
  # nix/calamares-patch.py). The QEMU test installs as this same user.
  users.users.scoot = {
    isNormalUser = true;
    uid = 1000;
    group = "users";
    description = "scoot";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
  };

  programs.firefox.enable = true;

  environment.systemPackages = with pkgs; [
    foot
    git
  ];

  services.qemuGuest.enable = true;

  programs.nh = {
    enable = true;
    flake = "/home/scoot/nixos-config";
  };

  programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "moonrise";
    session.enable = true;
    greeter.enable = true;
  };

  programs.scootbar.enable = true;

  home-manager.users.scoot.programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "moonrise";
  };
  home-manager.users.scoot.programs.scootbar.enable = true;
  home-manager.users.scoot.home.stateVersion = "25.11";

  system.stateVersion = "25.11";
}
