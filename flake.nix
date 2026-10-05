{
  description = "scoot-iso: a NixOS live + installer ISO with the scoot desktop";

  # Pinned to the same nixpkgs revision as scoot itself, so the live
  # environment, the installer target, and the compositor agree on every
  # library (scoot flake.lock: 8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe,
  # verified 2026-10-05 against the pinned nixpkgs source).
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    # Pinned to scoot main at 39c3a5e (post-#432, so
    # `programs.scoot.desktop` with the look registry exists; idle/lock
    # #435 is still in flight and its slots stay inert until it merges).
    scoot.url = "github:scoot-sh/scoot/39c3a5ea131f956de4207522273c0946bebe2f1d";
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
      # Calamares with the scoot desktop choice, carried as a patch in
      # this repo (never upstream). Anchors are asserted exactly-once
      # by the patch script, so a nixpkgs re-pin that changes upstream
      # fails loudly. Shared by the live ISO (overlay) and exposed as a
      # package so CI proves the patch applies on every PR.
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
              ${./nix/packagechooser-scoot.conf} \
              ${nixpkgs} \
              ${scoot} \
              ${home-manager} \
              ${system} \
              $out/src/modules/nixos/main.py \
              $out/src/config/modules/packagechooser.conf
          '';
        };
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
                ./nix/live.nix
              ];
              specialArgs = {
                inherit scoot flakeInputs;
                patchedExtSrc =
                  mkPatchedExtSrc nixpkgs.legacyPackages.${system} system;
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
          calamares-ext-patched-src =
            mkPatchedExtSrc nixpkgs.legacyPackages.${system} system;
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
              ${./nix/target-machine.nix} \
              ${./nix/calamares-patch.py} \
              ${./nix/packagechooser-scoot.conf} && touch $out
          '';
        }
      );
    };
}
