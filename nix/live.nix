# The scoot live system: a graphical NixOS installer ISO that boots
# straight into a scoot session (full desktop profile, moonrise
# look) with autologin (live media only: standard for installer ISOs;
# the installed system never autologins, it gets ReGreet).
{
  config,
  pkgs,
  lib,
  modulesPath,
  scoot,
  flakeInputs,
  targetInputSrcs,
  calamaresOverlay,
  targetToplevel,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  scootPkgs = scoot.packages.${system};

  # First-login welcome: opens once per live boot, always reachable
  # later via the launcher entry and the bar's Welcome button. HOME/USER
  # are exported explicitly: the greetd initial session arrives with a
  # near-empty environment (observed: firefox inherits no HOME and fails
  # with "profile cannot be loaded"), and the welcome browser needs HOME
  # to create its profile.
  welcomeFirstRun = pkgs.writeShellScript "scoot-welcome-first-run" ''
    set -eu
    export HOME=/home/nixos USER=nixos LOGNAME=nixos
    env | sort > /tmp/scoot-welcome-env.txt
    flag="$HOME/.cache/scoot-iso/welcomed"
    if [ ! -f "$flag" ]; then
      mkdir -p "$(dirname "$flag")"
      touch "$flag"
      # Firefox's own stderr goes to a file: autostart children have no
      # journal to speak into, and the profile service's errors (e.g.
      # "profile cannot be loaded") only appear there.
      exec ${pkgs.firefox}/bin/firefox --new-window "file:///etc/scoot-welcome/index.html" > /tmp/scoot-firefox.log 2>&1
    fi
  '';

  # Live compositor config for the nixos user: the moonrise look's
  # appearance and its shipped wallpaper (docs/assets/wallpapers/
  # moonrise.png in the pinned scoot, under the Unsplash License),
  # plus the welcome opener. Binds stay scoot's defaults.
  liveConfig = pkgs.writeText "live-config.toml" ''
    [appearance]
    background_color = "#2B3648"
    focus_ring_active_color = "#FF9A49"
    focus_ring_inactive_color = "#5E4B5B"

    [wallpaper]
    image = "${scoot}/docs/assets/wallpapers/moonrise.png"
    mode = "fill"

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

    # TEMP DEBUG (revert before merge): SSH into the QEMU guest to
    # diagnose the silent guest agent. Password login for nixos on the
    # user-mode NIC the test script adds.
    users.users.nixos.password = "debug123";
    services.openssh.enable = true;
    services.openssh.settings.PasswordAuthentication = true;
    services.openssh.openFirewall = true;

    # No Plymouth splash: on the hosted-runner QEMU (virtio-gpu, KVM) the
    # boot hung in sysinit at "Show Plymouth Boot Screen" (identical
    # frames 11 minutes apart, guest agent never starting because
    # sysinit never finished), while installer media has no use for a
    # splash to begin with. Text console stays visible instead, which is
    # also what the QEMU test screenshots to diagnose boot problems.
    boot.plymouth.enable = lib.mkForce false;

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

    # The full desktop profile with the moonrise look, the session
    # entry and the bar (the profile themes it through programs.scootbar
    # when that module is imported, which it is here).
    programs.scoot = {
      enable = true;
      package = scootPkgs.scoot;
      desktop.enable = true;
      desktop.look = "moonrise";
      session.enable = true;
      # The installed system keeps the profile's idle policy (dim, lock,
      # screens off: a laptop that never locks is not daily-drivable),
      # but the live session must never lock or blank the screen: an
      # install runs far longer than any idle timeout, and a locked or
      # dark live session would stall Calamares, hide the welcome window
      # and break the installer mid-write. Live media is physically
      # present and ephemeral, so there is nothing to protect.
      desktop.idle.enable = false;
      desktop.idle.lock.enable = false;
      desktop.idle.mediaInhibit.enable = false;
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
          background = "#2B3648";
          foreground = "#F6EEDC";
          accent = "#FFA45C";
          hover = "#FFD54A";
          dim = "#9C8B95";
          urgent = "#E87F6A";
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
    # autologin. Note default_session.command below is parse-only:
    # greetd 0.10.3 refuses to start when default_session has no command
    # (greetd/src/config/mod.rs: "default_session contains no command"),
    # even though the initial-session path never runs it; agreety is the
    # honest fallback (a text greeter that would start the same session).
    # HOME/USER/LOGNAME ride on the command because the initial session
    # arrives with a near-empty environment, and everything spawned in
    # the session (terminal, installer, browser) needs HOME.
    services.greetd = {
      enable = true;
      settings.default_session = {
        command = "${pkgs.greetd}/bin/agreety --cmd ${scootPkgs.scoot}/bin/scoot-session";
      };
      settings.initial_session = {
        user = "nixos";
        command = "${pkgs.coreutils}/bin/env HOME=/home/nixos USER=nixos LOGNAME=nixos ${scootPkgs.scoot}/bin/scoot-session";
      };
    };

    environment.systemPackages = with pkgs; [
      foot
      welcomeLauncher
      # The QEMU install test drives its installer-equivalence checks
      # (template embedding, target render, override extraction) with
      # python3 inside the guest; stage it on the ISO rather than
      # reaching the network.
      python3
    ];

    environment.etc."scoot-welcome/index.html".source = ../iso/welcome/index.html;
    # The welcome page's hero banner: the same moonrise illustration the
    # session shows as its wallpaper (shipped in the pinned scoot under
    # the Unsplash License; ~400 KB on an ISO measured in gigabytes).
    environment.etc."scoot-welcome/moonrise.png".source =
      "${scoot}/docs/assets/wallpapers/moonrise.png";

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
        # The live home must belong to nixos wholesale: the autostarted
        # Firefox creates its profile under it on first login, and
        # anything root-owned (previously even .config itself, which
        # mkdir -p creates as root) breaks sandboxed writers.
        chown -R nixos:users /home/nixos
      '';
    };

    # Offline install: ship the reference target closure in the ISO
    # store, so the network-cut nixos-install resolves locally. The
    # reference target mirrors iso/target/configuration.nix's scoot
    # options (see nix/target-machine.nix); sameness of the installed
    # files is by construction (the patch consumes the same derivations
    # exposed as scootIso.targetFlake/targetConfiguration). The
    # installed flake's input sources ride along too (resolved from its
    # own lock at ISO build time), so no --override-input is needed and
    # the installed flake.lock stays pristine.
    isoImage.storeContents = [
      config.system.build.toplevel
      targetToplevel
    ] ++ targetInputSrcs;
  };
}
