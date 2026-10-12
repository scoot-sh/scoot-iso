# The scoot live system: a graphical NixOS installer ISO that boots
# straight into a scoot session (full desktop profile, ginger-night
# look) with autologin (live media only: standard for installer ISOs;
# the installed system never autologins, it gets ReGreet).
#
# The live nixos user is managed by home-manager (see flake.nix: the
# live system imports the home-manager module with the scoot home
# modules for nixos), the way the installed target manages its user:
# the compositor config (the look's appearance and wallpaper), the
# keymap binds (including the launcher on Super+d) and the themed
# launcher script all come from the desktop profile. A hand-seeded
# config.toml here used to bypass that half entirely, so the live
# session had the launcher binary on PATH but no bind that spawned
# it, and a hand-rolled minimal bar instead of the look's layout.
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

  # The live bar: the ginger-night example layout
  # (docs/examples/ginger-night/bar.toml in the pinned scoot) plus the
  # live-only Welcome button, so the live session wears the look's
  # floating rounded bar with its icons and launcher buttons instead
  # of a hand-rolled minimal one. Values are the example's verbatim
  # (icons are Nerd Font PUA glyphs, via JSON: Nix strings have no \U
  # escape); the bar's face is the desktop profile's own UI face
  # (DroidSansM Nerd Font Propo: DejaVu Sans has no Nerd glyphs, so a
  # DejaVu face left every module icon a tofu box). Shared by the
  # system bar and the live user's home-manager half below, so
  # whichever unit the session starts draws the same layout; the home
  # unit stays off so exactly one daemon runs (the installed target
  # mirrors this pattern in nix/target-machine.nix).
  liveBar =
    let
      font = "${pkgs.nerd-fonts.droid-sans-mono}/share/fonts/opentype/NerdFonts/DroidSansM/DroidSansMNerdFontPropo-Regular.otf";
      execScripts = pkgs.runCommand "scootbar-exec-scripts" { } ''
        mkdir -p $out/bin
        cp ${scoot.outPath}/docs/examples/ginger-night/load.sh $out/bin/load.sh
        cp ${scoot.outPath}/docs/examples/ginger-night/cpu.sh $out/bin/cpu.sh
        chmod +x $out/bin/*
      '';
      glyph = pair: builtins.fromJSON ("\"" + pair + "\"");
    in
    {
      left = [
        "workspaces"
        "window-title"
        "welcome"
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
        background = "#0E0E0E";
        foreground = "#F5EAD6";
        accent = "#E57F29";
        hover = "#FFB14B";
        dim = "#8F7A63";
        urgent = "#E05A4E";
      };
      workspaces = {
        pill-shape = "circle";
        pill-inset = 7;
        item-gap = 3;
        margin = 8;
        disc = true;
        inactive-color = "#8F7A63";
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
      power = {
        icon = glyph "\\udb81\\udc25";
        on-click = "popup";
      };
    };

  # Live compositor autostart for the nixos user: the welcome opener.
  # The look's appearance and wallpaper, the keymap binds and the
  # launcher script arrive through the home-manager profile below, so
  # no hand-written config.toml is seeded here (the previous one owned
  # only appearance, wallpaper and autostart: no [binds], so Super+d
  # did nothing). Binds stay the profile's.
  liveAutostart = [ "spawn ${welcomeFirstRun}" ];

  welcomeLauncher = pkgs.writeTextDir "share/applications/scoot-welcome.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Welcome to scoot
    Comment=Getting started with the scoot desktop
    Exec=${pkgs.firefox}/bin/firefox --new-window file:///etc/scoot-welcome/index.html
    Icon=help-about
    Categories=System;
  '';

  # The welcome page ships as a DIRECTORY (/etc/scoot-welcome symlinks
  # to it): Firefox opens file:///etc/scoot-welcome/index.html, so the
  # hero's relative <img src> and the display font's relative url()
  # resolve beside it. A single-file etc entry lands in the store as a
  # lone file, and no sibling asset sits beside it there: the hero
  # rendered as its alt text in a box. The hero is the scoot.sh cat art
  # (site/public/hero-cat-960.jpg in the pinned scoot) and the headings
  # wear the wordmark face (League Spartan 900, self-hosted woff2, OFL
  # 1.1 — credited in the page footer): no CDN, no Google Fonts, the
  # page works with no network. The build itself fails if any local
  # <img src> or url() in the page is not shipped in this directory
  # (mirrored by the fast patch-consistency gate, so it fails in
  # seconds, not at ISO build).
  scootWelcomePage = pkgs.runCommand "scoot-welcome" { } ''
    mkdir -p $out
    cp ${../iso/welcome/index.html} $out/index.html
    cp ${../iso/welcome/hero-cat-960.jpg} $out/hero-cat-960.jpg
    cp ${../iso/welcome/league-spartan-latin-900.woff2} $out/league-spartan-latin-900.woff2
    ${pkgs.python3}/bin/python3 - $out ${../iso/welcome/index.html} <<'PYEOF'
    import os, re, sys
    outdir, page = sys.argv[1], open(sys.argv[2]).read()
    srcs = re.findall(r'<img[^>]+src="([^"]+)"', page)
    assert srcs, "welcome page has no <img src> to check"
    fonts = [u for u in re.findall(r'url\(["\']?([^"\')]+)["\']?\)', page) if "://" not in u and not u.startswith("data:")]
    assert fonts, "welcome page has no local font url() to check"
    missing = [s for s in srcs + fonts if "://" not in s and not os.path.isfile(os.path.join(outdir, s))]
    if missing:
        raise SystemExit("welcome asset not shipped beside index.html: " + ", ".join(missing))
    print("welcome assets OK: " + ", ".join(srcs + fonts))
    PYEOF
  '';
in
{
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-graphical-calamares.nix" ];

  config = {
    isoImage.edition = lib.mkDefault "scoot";

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

    # The full desktop profile with the ginger-night look, the session
    # entry and the bar (the profile themes it through programs.scootbar
    # when that module is imported, which it is here: the bar's face
    # is the look's DroidSansM Nerd Font Propo, not DejaVu, so the
    # module icons render instead of tofu).
    programs.scoot = {
      enable = true;
      package = scootPkgs.scoot;
      desktop.enable = true;
      desktop.look = "ginger-night";
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
      settings = liveBar;
    };

    # The live user's desktop profile through home-manager: this half
    # owns the compositor config file (the look's appearance and
    # wallpaper, the keymap binds including the launcher, the themed
    # launcher script), the way the installed target owns its user.
    # Without it the live session had every launcher tool on PATH but
    # no bind that ran one. The installed system keeps the profile's
    # idle policy; the live session must never lock or blank (see the
    # system half above), so the user half switches it off too (the
    # two halves read separate option trees: the system half alone
    # leaves the home swayidle unit running).
    home-manager.users.nixos.programs.scoot = {
      enable = true;
      desktop.enable = true;
      desktop.look = "ginger-night";
      settings.autostart.commands = liveAutostart;
      desktop.idle.enable = false;
      desktop.idle.lock.enable = false;
      desktop.idle.mediaInhibit.enable = false;
    };
    # The live bar draws the same layout whichever unit the session
    # starts; the home unit itself stays off, so exactly one daemon
    # runs. Mirrors the installed target (nix/target-machine.nix).
    home-manager.users.nixos.programs.scootbar.enable = true;
    home-manager.users.nixos.programs.scootbar.settings = liveBar;
    home-manager.users.nixos.programs.scootbar.systemd.enable = false;
    home-manager.users.nixos.home.stateVersion = "25.11";

    # The dconf service home-manager's dconf activation needs (the
    # look's dark-mode signal): without it the home-manager unit fails
    # with no session bus and the user config never links (no binds,
    # no wallpaper). Mirrors the installed target.
    programs.dconf.enable = true;

    # Nerd-glyph surfaces beyond the bar file: foot's FiraCode Nerd
    # Font (the bar's terminal button names it) resolves through
    # fontconfig, so it rides fonts.packages exactly as on the
    # installed target (the bar's own face is the file above).
    fonts.packages = with pkgs; [
      nerd-fonts.droid-sans-mono
      nerd-fonts.fira-code
    ];

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

    environment.etc."scoot-welcome".source = scootWelcomePage;

    # Seed the live welcome-browser profile at boot (the live home is
    # ephemeral; the NixOS module owns binaries and the login entry,
    # the home-manager profile owns the compositor and bar configs).
    # Firefox 155's default-profile auto-creation fails in the live
    # session (empty HOME, no profiles.ini: "Profile Missing" dialog,
    # proven across CI and local runs — while an existing profile,
    # even freshly seeded, loads and populates fine). Seeding here,
    # before greetd starts the session, is deterministic; the user.js
    # also silences first-run tabs so the welcome page opens alone.
    systemd.services.scoot-live-seed = {
      description = "Seed the live welcome-browser profile";
      wantedBy = [ "multi-user.target" ];
      before = [ "greetd.service" ];
      after = [ "home-manager-nixos.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        mkdir -p /home/nixos/.mozilla/firefox/welcome.default
        cat > /home/nixos/.mozilla/firefox/profiles.ini <<'EOF'
        [Profile0]
        Name=default
        IsRelative=1
        Path=welcome.default
        Default=1

        [General]
        StartWithLastProfile=1
        Version=2
        EOF
        cat > /home/nixos/.mozilla/firefox/installs.ini <<'EOF'
        [DEFAULT]
        Default=welcome.default
        Locked=1
        EOF
        cat > /home/nixos/.mozilla/firefox/welcome.default/user.js <<'EOF'
        user_pref("browser.aboutwelcome.enabled", false);
        user_pref("datareporting.policy.firstRunURL", "");
        user_pref("trailhead.firstrun.didSeeAboutWelcome", true);
        user_pref("browser.startup.homepage_override.mstone", "ignore");
        user_pref("datareporting.policy.dataSubmissionEnabled", false);
        EOF
        # The live home must belong to nixos wholesale: the autostarted
        # Firefox populates its profile under it on first login, and
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
