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
{ config, pkgs, scoot, ... }:

let
  # The moonrise example bar layout (docs/examples/moonrise/bar.toml
  # in the pinned scoot), used by the system bar below and the
  # home-manager half alike, so whichever unit the session starts
  # draws the same layout. Mirrors the installer template's
  # scootBarLayouts.moonrise exactly (the drvPath gate holds). The
  # bar's face is the desktop profile's own UI face (DroidSansM Nerd
  # Font Propo: DejaVu has no Nerd glyphs, so a DejaVu face left
  # every module icon a tofu box).
  moonriseBar =
      let
        font = "${pkgs.nerd-fonts.droid-sans-mono}/share/fonts/opentype/NerdFonts/DroidSansM/DroidSansMNerdFontPropo-Regular.otf";
        execScripts = pkgs.runCommand "scootbar-exec-scripts" { } ''
          mkdir -p $out/bin
          cp ${scoot.outPath}/docs/examples/moonrise/load.sh $out/bin/load.sh
          cp ${scoot.outPath}/docs/examples/moonrise/cpu.sh $out/bin/cpu.sh
          chmod +x $out/bin/*
        '';
        glyph = pair: builtins.fromJSON ("\"" + pair + "\"");
      in
      {
        left = [
          "workspaces"
          "window-title"
        ];
        center = [ "clock" ];
        right = [
          "load"
          "cpu"
          "network"
          "volume"
          "battery"
          "terminal"
          "browser"
          "power"
        ];
        bar = {
          inherit font;
          height = 38;
          margin = "10,14";
          radius = 14;
          opacity = 0.82;
          font-size = 13;
          padding = 10;
          spacing = 8;
          separator = 1;
        };
        colors = {
          background = "#2B3648";
          foreground = "#F6EEDC";
          accent = "#FFA45C";
          hover = "#FFD54A";
          dim = "#9C8B95";
          urgent = "#E87F6A";
        };
        workspaces = {
          pill-shape = "circle";
          pill-inset = 7;
          item-gap = 3;
          margin = 8;
          disc = true;
          inactive-color = "#B595AD";
        };
        window-title = {
          icon = glyph "\\udb82\\udcc6";
          show-app-id = false;
          max-width = 360;
        };
        clock = {
          format = "%-I:%M %P";
          icon = glyph "\\udb80\\udd50";
        };
        exec.load = {
          command = [ "${execScripts}/bin/load.sh" ];
          icon = glyph "\\udb81\\ude1a";
        };
        exec.cpu = {
          command = [ "${execScripts}/bin/cpu.sh" ];
          icon = glyph "\\udb83\\udee0";
        };
        network = {
          icon-wifi = map glyph [
            "\\udb82\\udd1f"
            "\\udb82\\udd22"
            "\\udb82\\udd25"
            "\\udb82\\udd28"
          ];
          icon-ethernet = glyph "\\udb80\\ude00";
          show-text = false;
        };
        battery = {
          icon = map glyph [
            "\\udb80\\udc8e"
            "\\udb80\\udc7b"
            "\\udb80\\udc7e"
            "\\udb80\\udc81"
            "\\udb80\\udc79"
          ];
          icon-charging = glyph "\\udb80\\udc84";
          icon-full = glyph "\\udb80\\udc79";
        };
        button.terminal = {
          icon = glyph "\\udb80\\udd8d";
          on-click.exec = [
            "foot"
            "--font=FiraCode Nerd Font:size=10"
          ];
        };
        button.browser = {
          icon = glyph "\\udb80\\udeaf";
          on-click.exec = [ "firefox" ];
        };
        power = {
          icon = glyph "\\udb81\\udc25";
          on-click = "popup";
        };
      };
in

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

  # Nerd-glyph surfaces beyond the bar file: foot's FiraCode Nerd
  # Font and the greeter session resolve through fontconfig, so both
  # Nerd faces ride fonts.packages here exactly as in the template.
  fonts.packages = with pkgs; [
    nerd-fonts.droid-sans-mono
    nerd-fonts.fira-code
  ];

  services.qemuGuest.enable = true;

  # The dconf service home-manager's dconf activation needs (the
  # look's dark-mode signal): without it the home-manager unit fails
  # with no session bus, the user config never links, and `nh os
  # switch` fails. Mirrors the template exactly (drvPath gate holds).
  programs.dconf.enable = true;

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

  # The status bar: the moonrise example layout
  # (docs/examples/moonrise/bar.toml in the pinned scoot), exactly as
  # iso/target/configuration.nix renders for the canonical moonrise
  # install (same values, so the drvPath gate holds).
  programs.scootbar = {
    enable = true;
    settings = moonriseBar;
  };

  # Themed ReGreet, exactly as iso/target/configuration.nix renders
  # for the canonical moonrise install (same Nix code, so the drvPath
  # gate holds): the look's wallpaper behind a dark Adwaita login.
  programs.scoot.greeter.background =
    let
      greeterWallpapers = {
        moonrise = scoot.outPath + "/docs/assets/wallpapers/moonrise.png";
        music-desk = scoot.outPath + "/docs/assets/wallpapers/music-desk.png";
        radial-burst = scoot.outPath + "/docs/assets/wallpapers/radial-burst.png";
        vinyl-sunset = null;
      };
    in
    greeterWallpapers.${config.programs.scoot.desktop.look} or null;

  services.displayManager.regreet =
    let
      look = config.programs.scoot.desktop.look;
      dark = look != "music-desk";
      accents = {
        moonrise = "#FFA45C";
        music-desk = "#3D579A";
        radial-burst = "#31a9e5";
        vinyl-sunset = "#E59560";
      };
      accent = accents.${look} or "#FFA45C";
    in
    {
      theme = {
        package = pkgs.gnome-themes-extra;
        name = if dark then "Adwaita-dark" else "Adwaita";
      };
      settings.GTK.application_prefer_dark_theme = dark;
      settings.background.fit = "Cover";
      extraCss = ''
        button.suggested-action { background: ${accent}; }
      '';
    };

  home-manager.users.scoot.programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "moonrise";
  };
  # The installed bar draws the moonrise example layout (the same
  # moonrise block the system half uses above), whichever unit the
  # session starts; the home unit itself stays off, so exactly one
  # daemon runs. Mirrors the installer patch's HM stanza.
  home-manager.users.scoot.programs.scootbar.enable = true;
  home-manager.users.scoot.programs.scootbar.settings = moonriseBar;
  home-manager.users.scoot.programs.scootbar.systemd.enable = false;
  home-manager.users.scoot.home.stateVersion = "25.11";

  system.stateVersion = "25.11";
}
