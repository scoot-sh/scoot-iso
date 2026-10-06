# Written by the scoot-iso installer (Calamares, scoot choice) to the
# target's nixos-config: /home/<user>/nixos-config/ for the home-folder
# choice (owned by the user, a git repo, /etc/nixos symlinked to it) or
# /etc/nixos/ itself for the system-wide choice (root-owned git repo).
# Beside it land flake.nix, flake.lock (pinned github revs, never the
# installer's path: overrides) and hardware-configuration.nix.
# Installed with
#   nixos-install --flake <config-dir>#scoot --root <root> --no-root-passwd
#   --no-write-lock-file --no-channel-copy
# over the network: the normal substituters (cache.nixos.org plus the
# scoot Cachix below), with paths the ISO already ships copied from the
# live system's store instead of downloaded.
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

let
  # The status bar layouts: each look's own example bar layout
  # (docs/examples/<look>/bar.toml in the pinned scoot) — workspaces
  # and window title left, clock center, system modules and launcher
  # buttons right. Shared by the system bar (programs.scootbar below)
  # and the home-manager half (the installer patch's HM stanza),
  # so whichever bar unit the session starts draws the same layout:
  # the home unit is disabled in favor of the system one, whose
  # config names /etc/scootbar/bar.toml explicitly. The live-only
  # Welcome button stays on the live session (nix/live.nix). Values
  # are the examples' verbatim (icons are Nerd Font PUA glyphs, via
  # JSON: Nix strings have no \U escape). The bar's face is the
  # desktop profile's own UI face (DroidSansM Nerd Font Propo from
  # pkgs.nerd-fonts.droid-sans-mono: scoot's nix/modules/scootbar.nix
  # themes this same file through its fontFile helper for
  # fonts.ui, and nix/modules/desktop.nix names it as every look's
  # fonts.ui). DejaVu Sans has no Nerd glyphs, so a DejaVu bar face
  # left every module icon a tofu box; the Propo carries them.
  scootBarLayouts =
    let
        font = "${pkgs.nerd-fonts.droid-sans-mono}/share/fonts/opentype/NerdFonts/DroidSansM/DroidSansMNerdFontPropo-Regular.otf";
        execScripts = pkgs.runCommand "scootbar-exec-scripts" { } ''
          mkdir -p $out/bin
          cp ${inputs.scoot.outPath}/docs/examples/moonrise/load.sh $out/bin/load.sh
          cp ${inputs.scoot.outPath}/docs/examples/moonrise/cpu.sh $out/bin/cpu.sh
          chmod +x $out/bin/*
        '';
        glyph = pair: builtins.fromJSON ("\"" + pair + "\"");
        icons = {
          app = glyph "\\udb82\\udcc6"; # U+F08C6 application
          clock = glyph "\\udb80\\udd50"; # U+F0150
          load = glyph "\\udb81\\ude1a"; # U+F061A
          cpu = glyph "\\udb83\\udee0"; # U+F0EE0
          wifi = map glyph [
            "\\udb82\\udd1f" # U+F091F weakest
            "\\udb82\\udd22" # U+F0922
            "\\udb82\\udd25" # U+F0925
            "\\udb82\\udd28" # U+F0928 strongest
          ];
          ethernet = glyph "\\udb80\\ude00"; # U+F0200
          battery = map glyph [
            "\\udb80\\udc8e" # U+F008E empty
            "\\udb80\\udc7b" # U+F007B
            "\\udb80\\udc7e" # U+F007E
            "\\udb80\\udc81" # U+F0081
            "\\udb80\\udc79" # U+F0079 full
          ];
          charging = glyph "\\udb80\\udc84"; # U+F0084
          terminal = glyph "\\udb80\\udd8d"; # U+F018D
          browser = glyph "\\udb80\\udeaf"; # U+F02AF
          power = glyph "\\udb81\\udc25"; # U+F0425
          brightness = map glyph [
            "\\udb80\\udcdd" # U+F00DD dim
            "\\udb80\\udcde" # U+F00DE
            "\\udb80\\udcdf" # U+F00DF
            "\\udb80\\udce0" # U+F00E0 bright
          ];
          bluetoothOff = glyph "\\udb80\\udcb2"; # U+F00B2
          bluetoothOn = glyph "\\udb80\\udcaf"; # U+F00AF
          bluetoothConnected = glyph "\\udb80\\udcb1"; # U+F00B1
        };
        stdRight = [
          "load"
          "cpu"
          "network"
          "volume"
          "battery"
          "terminal"
          "browser"
          "power"
        ];
        stdModules = maxWidth: {
          window-title = {
            icon = icons.app;
            show-app-id = false;
            max-width = maxWidth;
          };
          clock = {
            format = "%-I:%M %P";
            icon = icons.clock;
          };
          exec.load = {
            command = [ "${execScripts}/bin/load.sh" ];
            icon = icons.load;
          };
          exec.cpu = {
            command = [ "${execScripts}/bin/cpu.sh" ];
            icon = icons.cpu;
          };
          network = {
            icon-wifi = icons.wifi;
            icon-ethernet = icons.ethernet;
            show-text = false;
          };
          battery = {
            icon = icons.battery;
            icon-charging = icons.charging;
            icon-full = builtins.elemAt icons.battery 4;
          };
          button.terminal = {
            icon = icons.terminal;
            on-click.exec = [
              "foot"
              "--font=FiraCode Nerd Font:size=10"
            ];
          };
          button.browser = {
            icon = icons.browser;
            on-click.exec = [ "firefox" ];
          };
          power = {
            icon = icons.power;
            on-click = "popup";
          };
        };
        layouts = {
          moonrise = {
            left = [
              "workspaces"
              "window-title"
            ];
            center = [ "clock" ];
            right = stdRight;
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
          } // stdModules 360;
          music-desk = {
            left = [
              "workspaces"
              "window-title"
            ];
            center = [ "clock" ];
            right = stdRight;
            bar = {
              inherit font;
              height = 40;
              margin = 0;
              radius = 0;
              popup-radius = 14;
              opacity = 0.7;
              font-size = 13;
              padding = 10;
              spacing = 8;
              separator = 1;
            };
            colors = {
              background = "#FCFBFB";
              foreground = "#1A2032";
              accent = "#3D579A";
              hover = "#5D7AB0";
              dim = "#C9CBD0";
              urgent = "#EE6F5E";
            };
            workspaces = {
              pill-shape = "circle";
              pill-inset = 7;
              item-gap = 3;
              margin = 8;
              disc = true;
              inactive-color = "#9AA0B0";
            };
          } // stdModules 320;
          radial-burst = {
            left = [
              "workspaces"
              "window-title"
            ];
            center = [ "clock" ];
            right = [
              "network"
              "volume"
              "brightness"
              "bluetooth"
              "battery"
              "power"
            ];
            bar = {
              inherit font;
              height = 40;
              margin = 12;
              radius = 16;
              opacity = 0.88;
              font-size = 17;
              padding = 12;
              spacing = 14;
            };
            colors = {
              background = "#241721";
              foreground = "#fdef1d";
              accent = "#31a9e5";
              dim = "#99911d";
              urgent = "#bf128d";
            };
            workspaces = {
              pill-shape = "circle";
              pill-inset = 7;
              item-gap = 4;
            };
            window-title = {
              icon = icons.app;
              show-app-id = false;
              max-width = 320;
            };
            clock = {
              format = "%-I:%M %P";
              icon = icons.clock;
            };
            network = {
              icon-wifi = icons.wifi;
              icon-ethernet = icons.ethernet;
              show-text = false;
            };
            brightness.icon = icons.brightness;
            bluetooth = {
              icon-off = icons.bluetoothOff;
              icon-on = icons.bluetoothOn;
              icon-connected = icons.bluetoothConnected;
            };
            battery = {
              icon = icons.battery;
              icon-charging = icons.charging;
              icon-full = builtins.elemAt icons.battery 4;
            };
            power = {
              icon = icons.power;
              on-click = "popup";
            };
          };
          vinyl-sunset = {
            left = [
              "workspaces"
              "window-title"
            ];
            center = [ "clock" ];
            right = stdRight;
            bar = {
              inherit font;
              height = 38;
              margin = "10,14";
              radius = 12;
              opacity = 0.78;
              font-size = 13;
              padding = 10;
              spacing = 8;
              separator = 1;
            };
            colors = {
              background = "#271A1F";
              foreground = "#F1E3C6";
              accent = "#E59560";
              hover = "#FDC58B";
              dim = "#604F50";
              urgent = "#C76B47";
            };
            workspaces = {
              pill-shape = "circle";
              pill-inset = 7;
              item-gap = 3;
              margin = 8;
              disc = true;
              inactive-color = "#A08C7A";
            };
          } // stdModules 360;
        };
    in
    layouts;
in

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
    # The installed system is a flake (~/nixos-config): `nix flake`
    # and `nh` must work out of the box.
    experimental-features = [
      "nix-command"
      "flakes"
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

  # Every other Nerd-glyph surface resolves its face through
  # fontconfig, not a file: foot's `--font=FiraCode Nerd Font`
  # (the bar's launcher buttons and every look's foot.ini name it)
  # and the greeter session alike. Both Nerd faces therefore ride
  # fonts.packages (the bar's own face is the file above; this makes
  # the same family resolvable everywhere else too, and puts the
  # faces in the closure the ISO ships). fc-list is on PATH by default
  # (nixpkgs' fontconfig module installs it), which the QEMU test's
  # font proof relies on.
  fonts.packages = with pkgs; [
    nerd-fonts.droid-sans-mono
    nerd-fonts.fira-code
  ];

  # VM integration (QEMU guest agent: clipboard/host integration, and
  # the guest-exec channel the QEMU test drives `scoot msg` through).
  services.qemuGuest.enable = true;

  # dconf, for the desktop profile's dark-mode signal: the look writes
  # `org.gnome.desktop.interface color-scheme` through home-manager's
  # dconf module, and home-manager requires `programs.dconf.enable`
  # on NixOS (its dconf activation runs `dconf load`, which needs the
  # `ca.desrt.dconf` service this provides). Without it the
  # home-manager unit fails at boot AND at `nh os switch` (no session
  # bus in either place), the activation aborts mid-way, the user's
  # scoot config (wallpaper included) never links, and the switch
  # fails. Proven in QEMU: failed before, active after.
  programs.dconf.enable = true;

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

  # The status bar, wearing the installed look's example layout
  # (scootBarLayouts above, selected by the installed desktop.look).
  programs.scootbar = {
    enable = true;
    settings = scootBarLayouts.${config.programs.scoot.desktop.look} or scootBarLayouts.moonrise;
  };


  # The login screen wears the chosen look too: ReGreet's backdrop is
  # the look's wallpaper (vinyl-sunset ships no image, so its greeter
  # keeps the dark theme and accent CSS with no backdrop), with a dark
  # GTK theme and accent CSS in the look's palette through nixpkgs' own
  # ReGreet options. No extra daemons: a theme package, a CSS file and
  # a background path. Everything derives from the installed
  # desktop.look, so all four looks are themed by construction (the
  # render matrix asserts each one).
  programs.scoot.greeter.background =
    let
      greeterWallpapers = {
        moonrise = inputs.scoot.outPath + "/docs/assets/wallpapers/moonrise.png";
        music-desk = inputs.scoot.outPath + "/docs/assets/wallpapers/music-desk.png";
        radial-burst = inputs.scoot.outPath + "/docs/assets/wallpapers/radial-burst.png";
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
      # ReGreet's own hooks (0.5.0): the Login button carries
      # suggested-action, the cards are frames. Unknown selectors are
      # ignored, so this degrades to the plain theme, never a broken
      # greeter.
      extraCss = ''
        button.suggested-action { background: ${accent}; }
      '';
    };

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
