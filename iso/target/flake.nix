# Written by the scoot-iso installer (Calamares, scoot choice) to
# /etc/nixos/flake.nix on the target. Same revs the ISO was built from
# (see README "What the installer writes"); `@@SYSTEM@@` is substituted
# at ISO build time with the ISO's own system (x86_64-linux or
# aarch64-linux). After install, with network:
#   nixos-rebuild switch --flake /etc/nixos#scoot
{
  description = "scoot on NixOS (written by the scoot-iso installer)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe";
    scoot.url = "github:scoot-sh/scoot/39c3a5ea131f956de4207522273c0946bebe2f1d";
    home-manager.url = "github:nix-community/home-manager/f53f3267f5d009dd8f99443505e609389d7ff267";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, scoot, home-manager }:
    {
      nixosConfigurations.scoot = nixpkgs.lib.nixosSystem {
        system = "@@SYSTEM@@";
        modules = [ ./configuration.nix ];
      };
    };
}
