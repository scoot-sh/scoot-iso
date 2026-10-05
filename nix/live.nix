# The scoot live system: a graphical NixOS installer ISO that boots
# straight into a scoot session (full desktop profile, vinyl-sunset
# look) with autologin (live media only: standard for installer ISOs;
# the installed system never autologins, it gets ReGreet).
{
  config,
  pkgs,
  lib,
  modulesPath,
  scoot,
  flakeInputs,
  patchedExtSrc,
  targetToplevel,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  scootPkgs = scoot.packages.${system};

  # Calamares with the scoot desktop choice (patched source shared from
  # the flake: the same derivation CI builds as
  # packages.<system>.calamares-ext-patched-src).
  calamaresOverlay = final: prev: {
    calamares-nixos-extensions = prev.calamares-nixos-extensions.overrideAttrs (old: {
      src = patchedExtSrc;
    });
  };

  # First-login welcome: opens once per live boot, always reachable
  # later via the launcher entry and the bar's Welcome button.
  welcomeFirstRun = pkgs.writeShellScript "scoot-welcome-first-run" ''
    set -eu
    flag="$HOME/.cache/scoot-iso/welcomed"
    if [ ! -f "$flag" ]; then
      mkdir -p "$(dirname "$flag")"
      touch "$flag"
      exec ${pkgs.firefox}/bin/firefox --new-window "file:///etc/scoot-welcome/index.html"
    fi
  '';

  # Live compositor config for the nixos user: the vinyl-sunset look's
  # appearance (no wallpaper image ships in-repo for it, so the flat
  # background color shows) plus the welcome opener. Binds stay scoot's
  # defaults.
  liveConfig = pkgs.writeText "live-config.toml" ''
    [appearance]
    background_color = "#271A1F"
    focus_ring_active_color = "#E59560"
    focus_ring_inactive_color = "#423F51"

    [autostart]
    commands = ["spawn ${welcomeFirstRun}"]
  '';

  welcomeLauncher = pkgs.writeTextDir "share/applications/scoot-welcome.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Welcome to scoot
    Comment=Getting started with the scoot desktop
    Exec=${pkgs.firefox}/bin/firefox --new-window file:///etc/scoot-welcome/index.html
    Icon=help-about
    Categories=System;
  '';
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-graphical-calamares.nix" ];

  config = {
    isoImage.edition = lib.mkDefault "scoot";

    nixpkgs.overlays = [
      scoot.overlays.default
      calamaresOverlay
    ];

    # Prebuilt scoot binaries instead of compiling on the target.
    nix.settings = {
      extra-substituters = [ "https://scoot-sh.cachix.org" ];
      extra-trusted-public-keys = [
        "scoot-sh.cachix.org-1:QMj7CMw8uqZxrvqqm6SggdxTHz6Q4prt30ydDcXJXCo="
      ];
    };
    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];

    # The full desktop profile with the vinyl-sunset look, the session
    # entry and the bar (the profile themes it through programs.scootbar
    # when that module is imported, which it is here).
    programs.scoot = {
      enable = true;
      package = scootPkgs.scoot;
      desktop.enable = true;
      desktop.look = "vinyl-sunset";
      session.enable = true;
    };
    programs.scootbar = {
      enable = true;
      settings = {
        left = [
          "workspaces"
          "welcome"
        ];
        center = [ "clock" ];
        bar.height = 32;
        colors = {
          background = "#271A1F";
          foreground = "#F1E3C6";
          accent = "#E59560";
          hover = "#FDC58B";
          dim = "#604F50";
          urgent = "#C76B47";
        };
        bar.font = "${pkgs.dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf";
        button.welcome = {
          text = "Welcome";
          on-click = {
            exec = [
              "${pkgs.firefox}/bin/firefox"
              "--new-window"
              "file:///etc/scoot-welcome/index.html"
            ];
          };
        };
      };
    };

    # Boot straight into the scoot session on live media only. This is
    # greetd's initial session (not displayManager.autoLogin), and it
    # exists only on the ISO: the installed system gets ReGreet with no
    # autologin.
    services.greetd = {
      enable = true;
      settings.initial_session = {
        user = "nixos";
        command = "${scootPkgs.scoot}/bin/scoot-session";
      };
    };

    environment.systemPackages = with pkgs; [
      foot
      welcomeLauncher
    ];

    environment.etc."scoot-welcome/index.html".source = ../iso/welcome/index.html;

    # Seed the live user's compositor config at boot (the live home is
    # ephemeral; the NixOS module owns binaries and the login entry,
    # the config file is seeded here).
    systemd.services.scoot-live-seed = {
      description = "Seed the live scoot session config";
      wantedBy = [ "multi-user.target" ];
      before = [ "greetd.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /home/nixos/.config/scoot
        cp ${liveConfig} /home/nixos/.config/scoot/config.toml
        chown -R nixos:users /home/nixos/.config/scoot
      '';
    };

    # Offline install: ship the reference target closure in the ISO
    # store, so the network-cut nixos-install resolves locally. The
    # reference target mirrors iso/target/configuration.nix's scoot
    # options (see nix/target-machine.nix); sameness of the installed
    # files is by construction (the patch consumes the same derivations
    # exposed as scootIso.targetFlake/targetConfiguration).
    isoImage.storeContents = [
      config.system.build.toplevel
      targetToplevel
    ];
  };
}
