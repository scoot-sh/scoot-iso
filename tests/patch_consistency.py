#!/usr/bin/env python3
"""Consistency check for the scoot-iso installer patch (runs in CI via
`nix flake check`): the target files, the mirror module and the patch
script must agree, so drift fails fast instead of shipping a broken
installer."""

import re
import sys

flake_path, config_path, lock_path, hw_path, mirror_path, live_path, patch_path, item_path, location_path, qemu_path, docker_path = sys.argv[1:]

failures = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


flake = open(flake_path).read()
config = open(config_path).read()
lock = open(lock_path).read()
hw = open(hw_path).read()
mirror = open(mirror_path).read()
live = open(live_path).read()
patch = open(patch_path).read()
item = open(item_path).read()
location = open(location_path).read()
qemu = open(qemu_path).read()
docker = open(docker_path).read()

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

# Target flake.lock: the same revs as flake.nix, github-only, no
# placeholders or path: overrides (it is written verbatim; the install
# runs --no-write-lock-file so it stays pristine).
import json as _json

lock_data = _json.loads(lock)
for _node in ("nixpkgs", "scoot", "home-manager"):
    _locked = lock_data["nodes"][_node]["locked"]
    check(_locked.get("type") == "github", f"target flake.lock node {_node} is not github-pinned")
    check(_locked["rev"] in flake, f"target flake.lock rev {_locked['rev']} not in target flake.nix")
check('"type": "path"' not in lock, "target flake.lock must not contain path: overrides")
check("@@" not in lock, "target flake.lock must not contain placeholders")

# Target configuration.nix: flake-style module with the desktop profile.
check("{ config, pkgs, inputs, ... }:" in config, "target configuration.nix lost its flake-module header")
check("{ config, pkgs, inputs, ... }:" in config, "target configuration.nix lost its flake-module header")
check("inputs.scoot.nixosModules.scoot" in config, "target configuration.nix lost the scoot NixOS module import")
check("inputs.scoot.nixosModules.scootbar" in config, "target configuration.nix lost the scootbar NixOS module import")
check("inputs.home-manager.nixosModules.home-manager" in config, "target configuration.nix lost the home-manager import")
check("desktop.enable = true" in config, "target configuration.nix lost desktop.enable")
check("session.enable = true" in config, "target configuration.nix lost session.enable")
check("greeter.enable = true" in config, "target configuration.nix lost greeter.enable")
check("programs.scootbar.enable = true" in config, "target configuration.nix lost scootbar.enable")
check("programs.nh" in config and "enable = true" in config, "target configuration.nix lost nh.enable")
check('@@SCOOT_NH_FLAKE@@' in config, "target configuration.nix lost its @@SCOOT_NH_FLAKE@@ marker")
check('"git"' in config or " git\n" in config, "target configuration.nix lost git for the nixos-config repo")
check("services.qemuGuest.enable = true" in config, "target configuration.nix lost qemuGuest")
check("services.qemuGuest.enable = true" in mirror, "mirror lost qemuGuest")
check("environment.systemPackages" in config and "foot" in config, "target configuration.nix lost foot")
check("environment.systemPackages" in mirror and "foot" in mirror, "mirror lost foot")
check("inputs.scoot.homeModules.scoot" in patch, "patch HM stanza lost the scoot home module")
check("inputs.scoot.homeModules.scootbar" in patch, "patch HM stanza lost the scootbar home module")
check(CACHIX_URL in config and CACHIX_KEY in config, "target configuration.nix lost the Cachix substituter")
check("experimental-features" in config and "flakes" in config, "target configuration.nix lost experimental-features (nh needs it)")
check("experimental-features" in mirror and "flakes" in mirror, "mirror lost experimental-features")
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

# Static QEMU hardware: deterministic (device paths, no UUIDs), shared
# by the reference target and the test. It travels into the guest as a
# qemu-ga argv arg, so it must not contain single quotes (it rides
# inside a single-quoted argv word through two shells).
check("qemu-guest.nix" in hw, "hardware file lost the qemu-guest profile import")
check('device = "/dev/vda2"' in hw and 'fsType = "ext4"' in hw, "hardware file lost the vda2 ext4 root")
check('device = "/dev/vda1"' in hw and 'fsType = "vfat"' in hw, "hardware file lost the vda1 vfat /boot")
check("by-uuid" not in hw and "UUID=" not in hw, "hardware file must not contain UUIDs (non-deterministic)")
check("hostName" not in hw, "hardware file must not set the hostname (configuration.nix owns it)")
check("'" not in hw, "hardware file must not contain single quotes (it travels as a single-quoted argv arg)")
check("systemd-boot" in hw, "hardware file lost systemd-boot")
check("../iso/target/hardware-configuration.nix" in mirror, "mirror lost the static-hardware import")
check("uid = 1000" in mirror and 'group = "users"' in mirror, "mirror lost the pinned install uid/gid")

# Patch script carries every placeholder and the install mechanism.
for token in ("@@SCOOT_HM_USER@@", "@@SCOOT_USERS@@", "@@SCOOT_LOOK@@", "@@SCOOT_NH_FLAKE@@", "HM_USER_STANZA", "USERS_STANZA"):
    check(token in patch, f"patch script lost {token}")
check("--flake" in patch, "patch script lost the flake install command")
check('"--override-input"' not in patch, "patch script must not carry --override-input (inputs ship in the ISO instead)")
check('"--no-write-lock-file"' in patch, "patch script lost --no-write-lock-file (the installed lock must stay github-pinned)")
check('"--no-channel-copy"' in patch, "patch script lost --no-channel-copy (the channel cannot copy offline; a flake system needs none)")
check('"nix", "flake", "archive", "--to"' in patch, "patch script lost the flake archive (the build fetches inputs into the empty target store)")
check('"nix", "copy", "--to"' in patch, "patch script lost the closure pre-copy (building into the target store does not consult the live store)")
check('"--no-check-sigs"' in patch, "patch script lost --no-check-sigs (ISO paths carry no signatures into the fresh target store)")
check("nixos-rebuild build --flake /etc/nixos#scoot" in qemu, "qemu-test lost the user-run offline rebuild")
check("nh os switch" in qemu, "qemu-test lost the nh switch")
check("config.system.build.toplevel" in patch, "patch script lost the pre-copy toplevel eval")
check('\"substitute\"' in patch and '\"false\"' in patch, "patch script lost substitute=false (gaps must fail loud offline)")
check('"/home/" + scoot_cmd_user + "/nixos-config#scoot"' in patch, "patch script lost the home-folder install ref")
check('"/etc/nixos#scoot"' in patch, "patch script lost the system-wide install ref")
check("setprogress(INSTALL_PROGRESS_END)" in patch, "patch script lost the post-install anchor (ownership handoff)")
check('"1000:100"' in patch, "patch script lost the pinned ownership handoff")
check('"scoot_lock_text"' in patch or "scoot_lock_text = " in patch, "patch script lost the embedded flake.lock")
check("scoot-location.conf" in patch, "patch script lost the location page config")
check("packagechooser@scoot-location" in patch, "patch script lost the location page sequence entry")
check("packagechooser_scoot-location" in patch, "patch script lost the location GS key read")
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

# Location page: the two choices, home default, one sentence each.
check("default: home" in location, "location page lost its home default")
for _loc in ("home", "system"):
    check(f"- id: {_loc}" in location, f"location page lost id: {_loc}")
check("mode: required" in location, "location page lost mode: required")
check("method: legacy" in location, "location page lost method: legacy")
check("nh os switch" in location, "location page lost the rebuild instruction")

# Mirror identity must equal the test's canonical render identity.
check('networking.hostName = "scoot"' in mirror, "mirror lost hostname scoot (test renders scoot)")
check('time.timeZone = "UTC"' in mirror, "mirror lost timeZone UTC (test renders UTC)")
check('users.users.scoot' in mirror, "mirror lost user scoot (test installs scoot)")
check('description = "scoot"' in mirror, "mirror lost description scoot (test renders fullname scoot)")

# Live session seeds the welcome browser's profile (Firefox's
# default-profile auto-creation fails on live media: "Profile Missing").
check(".mozilla/firefox/welcome.default" in live, "live session lost the seeded firefox profile dir")
check("profiles.ini" in live and "installs.ini" in live, "live session lost the seeded profile registry")
check("browser.aboutwelcome.enabled" in live, "live session lost the first-run suppression")
check("scoot-firefox.log" in live, "live session lost the firefox stderr capture")
check("chown -R nixos:users /home/nixos" in live, "live session lost the recursive home chown")

# No debug scaffolding ships: no guest password, no openssh on the
# live image, no sshpass anywhere near the test.
check("debug123" not in live and "debug123" not in qemu, "debug password leaked in")
check("sshpass" not in qemu, "sshpass leaked into the test")
check("services.openssh" not in live, "live session must not enable openssh (was debug scaffolding)")

# QEMU test installs the canonical config only (else the shipped
# closure would not match): user/host/timezone pinned to the mirror.
check("python3 - '$TEST_USER' 'scoot' 'scoot' 'UTC' 'en_US.UTF-8' '25.11'" in qemu, "qemu-test lost the canonical render identity (must match the mirror)")
check('--target-hardware) TARGET_HARDWARE="$2"' in qemu, "qemu-test lost the --target-hardware arg")
check("[ -n \"$TARGET_HARDWARE\" ]" in qemu, "qemu-test lost the --target-hardware required-arg gate")
check("nixos-generate-config --root" not in qemu, "qemu-test must not run nixos-generate-config (non-deterministic hardware breaks the closure match)")
check("hardware-configuration.nix', 'w').write(hardware)" in qemu, "qemu-test lost the static-hardware write")
check("HW_CONTENT=$(cat \"$TARGET_HARDWARE\")" in qemu, "qemu-test lost the host-side hardware read")
check("mkdir -p /mnt/boot" in qemu, "qemu-test lost the /mnt/boot mkdir (the ESP mount needs it)")
check("nix copy --to /mnt" in qemu, "qemu-test lost the closure pre-copy")
check("nix flake archive --to /mnt" in qemu, "qemu-test lost the flake archive (inputs must reach the empty target store)")
check("--no-check-sigs" in qemu, "qemu-test lost --no-check-sigs (ISO paths carry no signatures)")
check("--no-channel-copy" in qemu, "qemu-test lost --no-channel-copy")
check('QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"' in qemu, "qemu-test lost the QEMU_BIN override (aarch64 runs)")
check('QEMU_MACHINE="${QEMU_MACHINE:-q35,accel=kvm:tcg}"' in qemu, "qemu-test lost the QEMU_MACHINE override")
check('QEMU_MEM="${QEMU_MEM:-4G}"' in qemu, "qemu-test lost the QEMU_MEM override")

# Docker one-command build: image pinned by digest (never :latest),
# check mode for fast plumbing validation, caller-owned output.
check('DIGEST_AMD64="sha256:' in docker and 'DIGEST_ARM64="sha256:' in docker, "docker script lost the per-arch digest pins")
check("nixos/nix@$DIGEST" in docker, "docker script lost the digest-pinned image ref")
check(":latest" not in docker, "docker script must not use :latest")
check("--check" in docker, "docker script lost check mode")
check("CALLER_UID" in docker, "docker script lost the caller-ownership handoff")

if failures:
    print("patch-consistency FAILED:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("patch-consistency OK")
