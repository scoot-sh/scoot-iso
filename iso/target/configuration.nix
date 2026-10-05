# Written by the scoot-iso installer (Calamares, scoot choice) to
# /etc/nixos/configuration.nix on the target, beside flake.nix and
# hardware-configuration.nix. Installed with
#   nixos-install --flake /etc/nixos#scoot --root <root> --no-root-passwd
#   --override-input nixpkgs/scoot/home-manager path:<ISO store paths>
# so install works with the network cut (the target closure is in the
# ISO's store; the override paths are baked at ISO build time).
# `hostname`, `timezone`, `LANG` and `nixosversion` here are Calamares'
# stock variables (same names and defaults as
# calamares-nixos-extensions' classic path: hostname falls back to
# "nixos"; unset timezone/locale stanzas are dropped).
# The SCOOT_USERS (the account created during install) and SCOOT_HM_USER
# (its home-manager desktop profile) markers are the installer patch's
# own, filled from Calamares' username/fullname when a user was created,
# dropped with a warning when none was. The installed system never
# autologins: the greeter below is always ReGreet.
{ config, pkgs, inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    inputs.scoot.nixosModules.scoot
    inputs.scoot.nixosModules.scootbar
    inputs.home-manager.nixosModules.home-manager
  ];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "@@hostname@@";
  networking.networkmanager.enable = true;

  # @@TIMEZONE@@
  # @@LOCALE@@

  # Pull binaries instead of compiling: scoot's public cache, appended to
  # the default cache.nixos.org entries (scoot docs/nix.md
  # "Prebuilt binaries: the Cachix cache").
  nix.settings = {
    extra-substituters = [ "https://scoot-sh.cachix.org" ];
    extra-trusted-public-keys = [
      "scoot-sh.cachix.org-1:QMj7CMw8uqZxrvqqm6SggdxTHz6Q4prt30ydDcXJXCo="
    ];
  };

  # @@SCOOT_USERS@@

  # Install firefox.
  programs.firefox.enable = true;

  # A terminal for the default super+Return bind.
  environment.systemPackages = with pkgs; [ foot ];

  # VM integration (QEMU guest agent: clipboard/host integration, and
  # the guest-exec channel the QEMU test drives `scoot msg` through).
  services.qemuGuest.enable = true;

  # The scoot desktop profile with the chosen look, the session entry and
  # the ReGreet greeter (programs.scoot.greeter: greetd running ReGreet
  # under cage; never autologin on an installed system).
  programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "vinyl-sunset";
    session.enable = true;
    greeter.enable = true;
  };

  # The status bar, themed by the look through the desktop profile.
  programs.scootbar.enable = true;

  # @@SCOOT_HM_USER@@

  system.stateVersion = "@@nixosversion@@";
}
