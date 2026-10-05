#!/usr/bin/env python3
"""Consistency check for the scoot-iso installer patch (runs in CI via
`nix flake check`): the target files, the mirror module and the patch
script must agree, so drift fails fast instead of shipping a broken
installer."""

import re
import sys

flake_path, config_path, mirror_path, patch_path, item_path = sys.argv[1:]

failures = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


flake = open(flake_path).read()
config = open(config_path).read()
mirror = open(mirror_path).read()
patch = open(patch_path).read()
item = open(item_path).read()

NIXPKGS_REV = "8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe"
SCOOT_REV = "79aa76127d1670209e489ed08ff451056d95e932"
HM_REV = "f53f3267f5d009dd8f99443505e609389d7ff267"
CACHIX_URL = "https://scoot-sh.cachix.org"
CACHIX_KEY = "scoot-sh.cachix.org-1:QMj7CMw8uqZxrvqqm6SggdxTHz6Q4prt30ydDcXJXCo="
LOOK = 'desktop.look = "moonrise"'
LOOK_MARKER = "@@SCOOT_LOOK@@"
SCOOT_IDS = [
    "scoot-moonrise",
    "scoot-music-desk",
    "scoot-radial-burst",
    "scoot-vinyl-sunset",
]

# Target flake.nix: same revs, system baked at ISO build, scoot attr.
check(f"nixpkgs/{NIXPKGS_REV}" in flake, "target flake.nix lost the pinned nixpkgs rev")
check(f"scoot-sh/scoot/{SCOOT_REV}" in flake, "target flake.nix lost the pinned scoot rev")
check(f"home-manager/{HM_REV}" in flake, "target flake.nix lost the pinned home-manager rev")
check("@@SYSTEM@@" in flake, "target flake.nix lost its @@SYSTEM@@ placeholder")
check("nixosConfigurations.scoot" in flake, "target flake.nix lost nixosConfigurations.scoot")

# Target configuration.nix: flake-style module with the desktop profile.
check("{ config, pkgs, inputs, ... }:" in config, "target configuration.nix lost its flake-module header")
check("inputs.scoot.nixosModules.scoot" in config, "target configuration.nix lost the scoot NixOS module import")
check("inputs.scoot.nixosModules.scootbar" in config, "target configuration.nix lost the scootbar NixOS module import")
check("inputs.home-manager.nixosModules.home-manager" in config, "target configuration.nix lost the home-manager import")
check("desktop.enable = true" in config, "target configuration.nix lost desktop.enable")
check("session.enable = true" in config, "target configuration.nix lost session.enable")
check("greeter.enable = true" in config, "target configuration.nix lost greeter.enable")
check("programs.scootbar.enable = true" in config, "target configuration.nix lost scootbar.enable")
check("services.qemuGuest.enable = true" in config, "target configuration.nix lost qemuGuest")
check("services.qemuGuest.enable = true" in mirror, "mirror lost qemuGuest")
check("environment.systemPackages" in config and "foot" in config, "target configuration.nix lost foot")
check("environment.systemPackages" in mirror and "foot" in mirror, "mirror lost foot")
check("inputs.scoot.homeModules.scoot" in patch, "patch HM stanza lost the scoot home module")
check("inputs.scoot.homeModules.scootbar" in patch, "patch HM stanza lost the scootbar home module")
check(CACHIX_URL in config and CACHIX_KEY in config, "target configuration.nix lost the Cachix substituter")
check("autoLogin" not in config and "autologinUser" not in config, "target configuration.nix must never autologin")
for marker in ("@@TIMEZONE@@", "@@LOCALE@@", "@@SCOOT_USERS@@", "@@SCOOT_HM_USER@@", LOOK_MARKER):
    check(marker in config, f"target configuration.nix lost marker {marker}")

# Mirror module agrees on the load-bearing lines. The template carries
# the look only via the @@SCOOT_LOOK@@ marker (once, in the NixOS half;
# the home-manager half lives in the patch stanza, also as the marker);
# the mirror resolves both halves inline to moonrise.
check(config.count(LOOK_MARKER) == 1, "target configuration.nix should hold @@SCOOT_LOOK@@ exactly once")
check(config.count("desktop.look = ") == 1, "target configuration.nix should hold one desktop.look line (the marker)")
check(LOOK in mirror, "mirror lost the look")
check("inputs.scoot.homeModules.scoot" in patch and LOOK_MARKER in patch, "patch HM stanza lost the look marker")
check(mirror.count(LOOK) == 2, "mirror should hold the look twice (system + user)")
check(CACHIX_URL in mirror and CACHIX_KEY in mirror, "mirror lost the Cachix substituter")
check("greeter.enable = true" in mirror, "mirror lost greeter.enable")
check("session.enable = true" in mirror, "mirror lost session.enable")
check("desktop.enable = true" in mirror, "mirror lost desktop.enable")
check("autoLogin" not in mirror, "mirror must never autologin")
check("home-manager.users.scoot.programs.scoot" in mirror, "mirror lost the home-manager user profile")

# Patch script carries every placeholder and the install mechanism.
for token in ("@@SCOOT_HM_USER@@", "@@SCOOT_USERS@@", "@@SCOOT_LOOK@@", "HM_USER_STANZA", "USERS_STANZA"):
    check(token in patch, f"patch script lost {token}")
check("--flake" in patch and "--override-input" in patch, "patch script lost the flake install command")
check("SCOOT_DEFAULT" in patch, "patch script lost the default-desktop constant")
check('"scoot-moonrise"' in patch, "patch script lost the moonrise default")
for item_id in SCOOT_IDS:
    check(f'"{item_id}"' in patch, f"patch script lost chooser id {item_id}")
    check(f"- id: {item_id}" in item, f"packagechooser item lost id: {item_id}")
for anchor in ("host_env_process_output", "build-dir", "packagechooser_packagechooser"):
    check(anchor in patch, f"patch script lost anchor {anchor}")

# Desktop list items: exactly the four scoot looks, moonrise first.
check("name: scoot" in item, "packagechooser item lost name: scoot")
check(item.count("- id: scoot-") == 4, "packagechooser item should hold exactly the four scoot looks")

if failures:
    print("patch-consistency FAILED:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("patch-consistency OK")
