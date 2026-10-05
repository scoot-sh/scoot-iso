# Written by the scoot-iso installer (Calamares, scoot choice) to the
# target's nixos-config: /home/<user>/nixos-config/ for the home-folder
# choice (owned by the user, a git repo, /etc/nixos symlinked to it) or
# /etc/nixos/ itself for the system-wide choice (root-owned git repo).
# Beside it land flake.nix, flake.lock (pinned github revs, never the
# installer's path: overrides) and hardware-configuration.nix.
# Installed with
#   nixos-install --flake <config-dir>#scoot --root <root> --no-root-passwd
#   --no-write-lock-file --option substitute false
# so install works with the network cut: every input source the flake
# needs rides the ISO (resolved from its own lock at ISO build time),
# and any gap fails loud instead of phoning home.
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

  # A terminal for daily use and the git the nixos-config repo needs.
  environment.systemPackages = with pkgs; [
    foot
    git
  ];

  # VM integration (QEMU guest agent: clipboard/host integration, and
  # the guest-exec channel the QEMU test drives `scoot msg` through).
  services.qemuGuest.enable = true;

  # The scoot desktop profile with the chosen look, the session entry and
  # the ReGreet greeter (programs.scoot.greeter: greetd running ReGreet
  # under cage; never autologin on an installed system). The look line
  # below names the Desktop-page default; the installer patch substitutes
  # the picked look there at install time and asserts the line is intact.
  programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "@@SCOOT_LOOK@@";
    session.enable = true;
    greeter.enable = true;
  };

  # The status bar, themed by the look through the desktop profile.
  programs.scootbar.enable = true;

  # nh, the rebuild helper: NH_FLAKE points at this very flake, so
  # `nh os switch` rebuilds it. @@SCOOT_NH_FLAKE@@ is the flake's home:
  # /home/<user>/nixos-config for the home-folder choice (with
  # /etc/nixos symlinked to it), /etc/nixos for the system-wide choice.
  programs.nh = {
    enable = true;
    flake = "@@SCOOT_NH_FLAKE@@";
  };

  # @@SCOOT_HM_USER@@

  system.stateVersion = "@@nixosversion@@";
}
