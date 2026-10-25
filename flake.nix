{
  description = "scoot-iso: a NixOS live + installer ISO with the scoot desktop";

  # Pinned to the same nixpkgs revision as scoot itself, so the live
  # environment, the installer target, and the compositor agree on every
  # library (scoot v0.6.2 flake.lock: 02c087f3fe673c9e317f206a627cb6b910336dbe,
  # verified 2026-10-24 against the release tag's pinned nixpkgs source).
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";
    # Pinned to the scoot v0.6.2 release (one default build with the GPU
    # scanout tier compiled in via a runtime gbm stub, xwayland compiled in,
    # Mocu as the default cursor theme, nightly retired, installer takes
    # tagged releases only; looks as a catalog with the declared default
    # at programs.scoot.look, the greeter following it at build time).
    scoot.url = "github:scoot-sh/scoot/v0.6.4";
    # Pinned to home-manager master at f53f3267 (2026-10-05), for the
    # installed user's desktop-profile half.
    home-manager.url = "github:nix-community/home-manager/f53f3267f5d009dd8f99443505e609389d7ff267";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [ "https://scoot-sh.cachix.org" ];
    extra-trusted-public-keys = [
      "scoot-sh.cachix.org-1:QMj7CMw8uqZxrvqqm6SggdxTHz6Q4prt30ydDcXJXCo="
    ];
  };

  outputs =
    { self, nixpkgs, scoot, home-manager }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEach = f: nixpkgs.lib.genAttrs systems (system: f system);
      flakeInputs = { inherit nixpkgs scoot home-manager; };
      # Every source tree the INSTALLED flake must resolve offline,
      # read from its own lock (direct and transitive alike): the ISO
      # build fetches each once, and they ride isoImage.storeContents
      # so the network-cut install (and later offline rebuilds) never
      # fetch. The install therefore needs no --override-input at all,
      # and the installed flake.lock stays pristine github pins.
      targetInputSrcs =
        let
          lock = builtins.fromJSON (builtins.readFile ./iso/target/flake.lock);
          githubNodes = builtins.filter (n: (n.locked or { }).type or "" == "github") (
            builtins.attrValues lock.nodes
          );
          fetchNode = n: builtins.fetchTree {
            type = "github";
            owner = n.locked.owner;
            repo = n.locked.repo;
            rev = n.locked.rev;
            narHash = n.locked.narHash;
          };
        in
        map fetchNode githubNodes;
      # Calamares with the scoot desktop choice, carried as a patch in
      # this repo (never upstream). Anchors are asserted exactly-once
      # by the patch script, so a nixpkgs re-pin that changes upstream
      # fails loudly. Shared by the live ISO (overlay) and exposed as
      # packages so CI proves the patch applies AND the package builds
      # on every PR.
      mkPatchedExtSrc =
        pkgs: system:
        pkgs.stdenv.mkDerivation {
          name = "calamares-nixos-extensions-scoot-src";
          buildCommand = ''
            cp -r ${nixpkgs}/pkgs/by-name/ca/calamares-nixos-extensions $out
            chmod -R +w $out
            ${pkgs.python3}/bin/python3 ${./nix/calamares-patch.py} \
              $out \
              ${./iso/target/flake.nix} \
              ${./iso/target/configuration.nix} \
              ${./iso/target/flake.lock} \
              ${./nix/packagechooser-scoot.conf} \
              ${./nix/packagechooser-scoot-location.conf} \
              ${./nix/scoot-netprobe.conf} \
              ${system} \
              $out/src/modules/nixos/main.py \
              $out/src/config/modules/packagechooser.conf \
              $out/src/config/settings.conf \
              $out/src/config/modules/scoot-location.conf \
              $out/src/config/modules/scoot-netprobe.conf
          '';
        };
      # Note the /src suffix: the package's src is the src/
      # subdirectory (modules/, config/, branding/), not the extension
      # root (package.nix: src = ./src, installPhase copies modules/).
      mkCalamaresOverlay =
        patchedSrc: final: prev: {
          calamares-nixos-extensions =
            prev.calamares-nixos-extensions.overrideAttrs (_old: {
              src = patchedSrc + "/src";
            });
          # The Install entry must survive pkexec's environment scrub
          # on the Wayland-only live session: without WAYLAND_DISPLAY
          # Qt falls back to xcb and aborts (no X server on live
          # media), so the icon and any bare `sudo calamares` never
          # open. --replace-fail keeps this exactly-once: an upstream
          # Exec change fails the build instead of silently restoring
          # the abort. (The terminal path keeps working through
          # `sudo -E`; see the welcome page.)
          calamares =
            prev.calamares.overrideAttrs (old: {
              postInstall = (old.postInstall or "") + ''
                substituteInPlace $out/share/applications/calamares.desktop \
                  --replace-fail 'Exec=sh -c "pkexec calamares"' \
                  'Exec=sh -c "pkexec env DISPLAY=$DISPLAY WAYLAND_DISPLAY=$WAYLAND_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR calamares"'
              '';
            });
        };
      calamaresFor = system: mkPatchedExtSrc nixpkgs.legacyPackages.${system} system;
    in
    {
      nixosConfigurations =
        let
          liveSystem = system:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                scoot.nixosModules.scoot
                scoot.nixosModules.scootbar
                home-manager.nixosModules.home-manager
                ./nix/live.nix
                {
                  # The live nixos user's desktop-profile half (binds,
                  # launcher script, themed configs): without these
                  # imports nix/live.nix's home-manager user settings
                  # declare an option no module owns. Mirrors the
                  # installed target below.
                  home-manager.users.nixos.imports = [
                    scoot.homeModules.scoot
                    scoot.homeModules.scootbar
                  ];
                }
              ];
              specialArgs = {
                inherit scoot flakeInputs targetInputSrcs;
                calamaresOverlay = mkCalamaresOverlay (calamaresFor system);
                targetToplevel =
                  self.nixosConfigurations."scoot-target-${system}".config.system.build.toplevel;
              };
            };
          # Reference target machine (stub hardware): its closure ships
          # in the ISO for the network-cut install. Mirrors
          # iso/target/configuration.nix's scoot options; the installed
          # files come from iso/target/* by construction.
          targetSystem = system:
            nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                scoot.nixosModules.scoot
                scoot.nixosModules.scootbar
                home-manager.nixosModules.home-manager
                ./nix/target-machine.nix
                {
                  home-manager.users.scoot.imports = [
                    scoot.homeModules.scoot
                    scoot.homeModules.scootbar
                  ];
                }
              ];
              # The mirror names the look's greeter wallpaper out of the
              # scoot tree, like the installed template does.
              specialArgs = {
                inherit scoot;
              };
            };
        in
        builtins.foldl'
          (acc: system: acc // {
            "scoot-live-${system}" = liveSystem system;
            "scoot-target-${system}" = targetSystem system;
          })
          { }
          systems;

      # One command: `nix build github:scoot-sh/scoot-iso#iso`
      # (pick `.iso.x86_64-linux` / `.iso.aarch64-linux` explicitly when
      # evaluating on macOS). Apple Silicon Macs need the Asahi installer,
      # not this ISO.
      packages = forEach (
        system:
        let
          live = self.nixosConfigurations."scoot-live-${system}";
        in
        {
          iso = live.config.system.build.isoImage;
          # The exact target files the patched Calamares writes, as
          # store paths, so the QEMU test installs byte-for-byte what
          # the GUI would write. (Plain file copies: packages must be
          # derivations, and these pin the exact bytes the patch
          # embeds.)
          target-flake = nixpkgs.legacyPackages.${system}.runCommand "scoot-target-flake.nix" { }
            "cp ${./iso/target/flake.nix} $out";
          target-configuration =
            nixpkgs.legacyPackages.${system}.runCommand "scoot-target-configuration.nix" { }
              "cp ${./iso/target/configuration.nix} $out";
          # The static QEMU hardware the test installs (byte-identical
          # every run; see iso/target/hardware-configuration.nix). The
          # reference target imports this same file, so the shipped
          # closure matches the installed system exactly.
          target-hardware =
            nixpkgs.legacyPackages.${system}.runCommand "scoot-target-hardware-configuration.nix" { }
              "cp ${./iso/target/hardware-configuration.nix} $out";
          calamares-ext-patched-src = calamaresFor system;
          # The overlaid package itself (file copies only): proves the
          # patched source keeps the package's expected layout.
          calamares-nixos-scoot =
            nixpkgs.legacyPackages.${system}.calamares-nixos-extensions.overrideAttrs (_old: {
              src = calamaresFor system + "/src";
            });
          default = live.config.system.build.isoImage;
        }
      );

      checks = forEach (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          patch-consistency = pkgs.runCommand "calamares-patch-consistency" { } ''
            ${pkgs.python3}/bin/python3 ${./tests/patch_consistency.py} \
              ${./iso/target/flake.nix} \
              ${./iso/target/configuration.nix} \
              ${./iso/target/flake.lock} \
              ${./iso/target/hardware-configuration.nix} \
              ${./nix/target-machine.nix} \
              ${./nix/live.nix} \
              ${./nix/calamares-patch.py} \
              ${./nix/packagechooser-scoot.conf} \
              ${./nix/packagechooser-scoot-location.conf} \
              ${./nix/scoot-netprobe.conf} \
              ${./scripts/qemu-test.sh} \
              ${./scripts/build-iso-docker.sh} \
              ${./.github/workflows/ci.yml} \
              ${./.} && touch $out
          '';
        }
      );
    };
}
