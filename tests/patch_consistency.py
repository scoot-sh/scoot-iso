#!/usr/bin/env python3
"""Consistency check for the scoot-iso installer patch (runs in CI via
`nix flake check`): the target files, the mirror module and the patch
script must agree, so drift fails fast instead of shipping a broken
installer."""

import re
import sys

flake_path, config_path, lock_path, hw_path, mirror_path, live_path, patch_path, item_path, location_path, netprobe_path, qemu_path, docker_path, ci_path, repo_path = sys.argv[1:]

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
netprobe = open(netprobe_path).read()
qemu = open(qemu_path).read()
docker = open(docker_path).read()
ci = open(ci_path).read()

NIXPKGS_REV = "8ce4ef6cb6f871616146b9fe26d2a5ae594e94fe"
SCOOT_REV = "d7de6eafa630685bbe385db7ad8d9c93de124a1b"
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
check("programs.scootbar" in config and "enable = true" in config, "target configuration.nix lost scootbar.enable")
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
# Network modes: online installs use the normal substituters (no
# substitute=false); only offline installs pin the shipped store.
check("scoot_netmode" in patch, "patch script lost the network-mode decision")
check("/tmp/scoot-netmode" in patch, "patch script lost the pre-partition probe handoff read")
check("urlopen" in patch and "nix-cache-info" in patch, "patch script lost the live substituter probe fallback")
check("scoot install network mode" in patch, "patch script lost the mode log line")
check('"--option", "substitute", "false"' in patch, "patch script lost substitute=false for the offline install")
check("nixosInstallCmd.extend" in patch, "patch script lost the install-command extension")
# Offline pre-flight: eval the target toplevel, check its closure
# against the live store, and fail with the missing-path list before
# nixos-install writes anything.
check('"nix", "path-info", "-r", "--offline"' in patch, "patch script lost the pre-flight closure check")
check('"nix", "derivation", "show"' in patch, "patch script lost the missing-path enrichment (dry-run outputs)")
check("could not be evaluated from the ISO" in patch, "patch script lost the eval-failure refusal")
check('startswith("/nix/store/")' in patch, "patch script lost the store-path-only closure parse (warnings must not pollute it)")
check("scoot install needs the network" in patch, "patch script lost the offline-refusal title")
check("Connect to the network" in patch, "patch script lost the connect-to-the-network message")
# The scoot branch writes its own greeter files (ReGreet, never
# autologin): a ticked autologin box must warn, not vanish silently.
check('gs.value("autoLoginUser")' in patch, "patch script lost the autologin read")
check("ignores the automatic-login choice" in patch, "patch script lost the autologin-ignored warning")
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

# Pre-partition network probe: a shellprocess instance that records
# online/offline in /tmp/scoot-netmode before partition runs, and can
# never fail the job (the verdict is data).
check("dontChroot: true" in netprobe, "netprobe conf must run on the host (dontChroot)")
check("exit 0" in netprobe, "netprobe conf must always exit 0 (verdict is data, never a job failure)")
check("/tmp/scoot-netmode" in netprobe, "netprobe conf lost the /tmp/scoot-netmode handoff")
check("https://cache.nixos.org/nix-cache-info" in netprobe, "netprobe conf lost the cache.nixos.org probe")
check("https://scoot-sh.cachix.org/nix-cache-info" in netprobe, "netprobe conf lost the scoot Cachix probe")
check("netprobe_file" in patch and "out_netprobe" in patch, "patch script lost the netprobe in/out args")
check("scoot-netprobe.conf" in patch, "patch script lost the netprobe config file")
check("shellprocess@scoot-netprobe" in patch, "patch script lost the pre-partition probe sequence entry")
check("module:   shellprocess" in patch, "patch script lost the shellprocess instance entry")

# Installed bar: each look's own example layout (not just colors),
# in the template for every look and mirrored for the canonical one.
# The live-only Welcome button stays on the live session.
for _look in ("moonrise", "music-desk", "radial-burst", "vinyl-sunset"):
    check(f"{_look} = {{" in config, f"template lost the {_look} bar layout")
for _color in ("#2B3648", "#FCFBFB", "#fdef1d", "#271A1F"):
    check(_color in config, f"template lost the example bar color {_color}")
check("window-title" in config, "template lost the window-title bar module")
check("button.terminal" in config and "button.browser" in config, "template lost the launcher buttons")
check("exec.load" in config and "exec.cpu" in config, "template lost the load/cpu exec modules")
check("load.sh" in config and "cpu.sh" in config, "template lost the exec helper scripts")
check("brightness" in config and "bluetooth" in config, "template lost the radial-burst-only modules")
check("button.welcome" not in config, "template must not carry the live-only Welcome button")
check("button.welcome" in live, "live session lost the Welcome button")
check("window-title" in mirror, "mirror lost the window-title bar module")
check("exec.load" in mirror and "load.sh" in mirror, "mirror lost the exec modules")
check("button.welcome" not in mirror, "mirror must not carry the live-only Welcome button")
# One layout, whichever unit wins: the home unit's empty config used
# to shadow the system unit (same unit name, home wins), leaving the
# installed desktop on the bar binary's clock-only default. Both
# halves now draw the same layout, and the home unit stays off so
# exactly one daemon runs.
check("scootBarLayouts" in config, "template lost the shared bar-layout binding")
check("scootBarLayouts" in patch, "patch HM stanza lost the shared bar-layout read")
check("systemd.enable = false" in patch, "patch HM stanza lost the home-unit off switch")
check("moonriseBar" in mirror, "mirror lost the shared moonrise bar binding")
check("systemd.enable = false" in mirror, "mirror lost the home-unit off switch")

# Mirror identity must equal the test's canonical render identity.
check('networking.hostName = "scoot"' in mirror, "mirror lost hostname scoot (test renders scoot)")
check('time.timeZone = "UTC"' in mirror, "mirror lost timeZone UTC (test renders UTC)")
check('users.users.scoot' in mirror, "mirror lost user scoot (test installs scoot)")
check('description = "scoot"' in mirror, "mirror lost description scoot (test renders fullname scoot)")

# Themed installed greeter: the look's wallpaper behind ReGreet plus a
# dark GTK theme and accent CSS through nixpkgs' ReGreet options, in
# the template for every look and mirrored for the canonical one.
for _side, _text in (("target configuration.nix", config), ("mirror", mirror)):
    check("programs.scoot.greeter.background" in _text, f"{_side} lost the greeter background (the look's wallpaper)")
    check("greeterWallpapers" in _text, f"{_side} lost the per-look wallpaper map")
    check("vinyl-sunset = null" in _text, f"{_side} lost the vinyl-sunset no-wallpaper case")
    check("services.displayManager.regreet" in _text, f"{_side} lost the ReGreet theme block")
    check("Adwaita-dark" in _text, f"{_side} lost the dark GTK theme")
    check("application_prefer_dark_theme" in _text, f"{_side} lost the dark-mode signal")
    check("suggested-action" in _text, f"{_side} lost the Login accent CSS")
    check("gnome-themes-extra" in _text, f"{_side} lost the theme package (must be a theme, no daemons)")
check('music-desk = inputs.scoot.outPath' in config, "template greeter wallpaper must come from the scoot tree (inputs.scoot.outPath)")
check('moonrise = scoot.outPath' in mirror, "mirror greeter wallpaper must come from the scoot tree (scoot.outPath)")
import os as _os
# The repo root arrives as an explicit argv (a store path in the
# sandbox, a checkout path locally): the other argv are all store
# files there, so no dirname walk can reach it.
_repo_root = repo_path
_root_flake = open(_os.path.join(_repo_root, "flake.nix")).read()
check("specialArgs" in _root_flake and "inherit scoot" in _root_flake, "flake.nix lost the mirror's scoot specialArg (greeter wallpaper)")

# Every local <img src> in the welcome page must resolve inside the
# shipped directory: either a file beside the page in iso/welcome/ or
# a name the live.nix directory derivation produces (e.g. the
# converted hero). Otherwise Firefox shows alt text in a box.
import re as _re
_welcome_page = open(_os.path.join(_repo_root, "iso/welcome/index.html")).read()
_welcome_srcs = [s for s in _re.findall(r'<img[^>]+src="([^"]+)"', _welcome_page) if "://" not in s]
check(_welcome_srcs, "welcome page has no local <img src> to pin (the hero must be in the shipped dir)")
for _src in _welcome_srcs:
    _beside = _os.path.isfile(_os.path.join(_repo_root, "iso/welcome", _src))
    check(_beside or _src in live, f"welcome <img src={_src}> resolves neither beside the page nor in the live derivation")
_welcome_fonts = [u for u in _re.findall(r'url\(["\']?([^"\')]+)["\']?\)', _welcome_page) if "://" not in u and not u.startswith("data:")]
check(_welcome_fonts, "welcome page has no local font url() to pin (the display face must be self-hosted)")
for _src in _welcome_fonts:
    _beside = _os.path.isfile(_os.path.join(_repo_root, "iso/welcome", _src))
    check(_beside or _src in live, f"welcome url({_src}) resolves neither beside the page nor in the live derivation")
# scoot.sh brand tokens: true black ground, white type, the ginger
# accent, League Spartan display type, no card shadows or gradients.
for _token in ("#000000", "#FFFFFF", "#CB6F34", "League Spartan"):
    check(_token in _welcome_page, f"welcome page lost the brand token {_token}")
check("hero-cat-960.jpg" in _welcome_page, "welcome page lost the cat hero art")
check("box-shadow" not in _welcome_page and "linear-gradient" not in _welcome_page,
      "welcome page uses shadows or gradients (the brand is flat)")

# Live session seeds the welcome browser's profile (Firefox's
# default-profile auto-creation fails on live media: "Profile Missing").
check(".mozilla/firefox/welcome.default" in live, "live session lost the seeded firefox profile dir")
check("profiles.ini" in live and "installs.ini" in live, "live session lost the seeded profile registry")
check("browser.aboutwelcome.enabled" in live, "live session lost the first-run suppression")
check("scoot-firefox.log" in live, "live session lost the firefox stderr capture")
check("chown -R nixos:users /home/nixos" in live, "live session lost the recursive home chown")

# The welcome page ships as a DIRECTORY (Firefox opens
# file:///etc/scoot-welcome/index.html, so relative <img src> resolves
# beside it). A lone-file etc entry strands the image in the store with
# nothing beside the page: the hero rendered as alt text.
check('environment.etc."scoot-welcome".source' in live, "live session lost the welcome directory derivation")
check('"scoot-welcome/index.html".source' not in live, "live session still ships the lone-file welcome page (image 404s)")
# scoot.sh brand, offline: the cat hero art and the self-hosted
# wordmark face ride beside the page (no CDN, no Google Fonts), and
# the build-time check covers the font url() as well as <img src>.
check("hero-cat-960.jpg" in live, "live session lost the scoot.sh cat hero art")
check("league-spartan-latin-900.woff2" in live, "live session lost the self-hosted display font")
check("moonrise.jpg" not in live, "live session still converts the wallpaper hero (the cat replaced it)")
check("imagemagick" not in live, "live session still carries imagemagick (nothing converts images anymore)")
check("not shipped beside index.html" in live, "live session lost the build-time asset resolution check")
check("url(" in live, "live session lost the font url() resolution check")

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

# Real ReGreet login over the absolute pointer (hard, not best effort):
# the tablet device, the Login click that reveals the password field,
# the session proof, and the logged-in session's bar/wallpaper checks.
check("usb-tablet" in qemu, "qemu-test lost the usb-tablet (ReGreet needs a pointer)")
check("usb-kbd" in qemu, "qemu-test lost the usb-kbd (virt has no PS/2: password typing lands nowhere)")
check("input-send-event" in qemu, "qemu-test lost the QMP absolute-click login drive")
check("LOGIN-OK" in qemu, "qemu-test lost the hard login proof")
check("LOGIN-FAIL" in qemu, "qemu-test lost the login-failure exit (login must be hard, not best effort)")
check("--headless" not in qemu, "qemu-test still runs a headless stand-in instead of the real logged-in session")
check("BAR-SPACE-OK" in qemu, "qemu-test lost the bar-reserves-space proof (usable vs rect)")
check("BAR-PROC-OK" in qemu and "BG-PROC-OK" in qemu, "qemu-test lost the resident bar/wallpaper proof")
check("SCREENSHOT-OK" in qemu, "qemu-test lost the guest-side screenshot proof")

# Complete PNG fetch: small chunks until the first missing piece, then
# an exact byte-count match against the guest. The old loop broke on a
# ~100K base64-size guess and shipped 102,400-byte truncations (worse,
# its reassembly decoded the raw concatenation, which stops at the
# first chunk's base64 padding: one chunk, always).
check("split -b 32768" in qemu, "qemu-test lost the small screenshot chunks (large payloads truncate)")
check("piece per line" in qemu, "qemu-test lost the per-line piece decode (concatenated padding truncates)")
check("truncated fetch" in qemu, "qemu-test lost the exact byte-count fetch gate")
check("PNG-FETCH-WARN" not in qemu, "qemu-test still tolerates a truncated screenshot fetch")

# Network modes, installer-equivalent: the probe runs before
# partitioning, offline installs pre-flight the closure, and the tweak
# proves both halves (refusal offline, success online).
check("SCOOT-NETMODE" in qemu, "qemu-test lost the network-mode probe marker")
check("nix-cache-info" in qemu, "qemu-test lost the substituter probe")
check("TWEAK-DIFFERS-OK" in qemu, "qemu-test lost the tweak-changes-closure guard")
check("ISO-shipped reference" in qemu, "tweak comment must avoid single quotes (it rides a single-quoted argv word)")
check("CLOSURE-PREFLIGHT-OK" in qemu, "qemu-test lost the canonical pre-flight pass")
check("OFFLINE-CLOSURE-INCOMPLETE" in qemu, "qemu-test lost the offline-refusal message")
check("connect to the network" in qemu.lower() or "Connect to the network" in qemu, "qemu-test lost the connect-to-the-network remedy")
check("TWEAK-OFFLINE-REFUSAL-OK" in qemu, "qemu-test lost the before-partitioning refusal proof")
check("DISK-UNTOUCHED-OK" in qemu, "qemu-test lost the disk-untouched proof")
check("TWEAK-ONLINE-LOGIN-OK" in qemu, "qemu-test lost the network-up tweak success proof")
check("TWEAK-FROM-NETWORK-OK" in qemu, "qemu-test lost the tweak-delta-came-over-the-network proof")
check("QEMU_TEST_ONLINE_TWEAK" in qemu, "qemu-test lost the online-tweak skip knob")
# Quoting discipline: guest code inside host double-quoted
# guest_exec "..." must escape every double quote (a bare one ends
# the host string and the guest receives mangled text). All three
# netmode probes therefore spell their python with escaped quotes.
check(qemu.count('mode = \\"offline\\"') == 3, "netmode probes lost their escaped quotes (bare quotes break the guest script)")
# Both installs partition their disk (canonical and tweak): two
# sgdisk wipes, two PARTITION markers. A dropped partition step
# silently installs into the live tmpfs until it fills.
check(qemu.count("sgdisk -Z /dev/vda") == 2, "qemu-test partition count wrong (canonical partition and tweak partition)")
check("range(2700)" in qemu, "qemu-test lost the 90-minute guest-exec ceiling (HVF installs outlast 30 minutes)")
check("echo PARTITION-OK" in qemu, "qemu-test lost the canonical PARTITION-OK")
check("echo TWEAK-PARTITION-OK" in qemu, "qemu-test lost the tweak TWEAK-PARTITION-OK")
check("TOOLS-UP" in qemu, "qemu-test lost the fresh-boot tool-readiness wait (partition raced activation)")
# Phase 4 must boot the ISO, not the now-bootable installed disk: the
# disk is unbooted first (its proofs are saved), and the ISO boot is
# asserted before anything is touched.
check("DISK-UNBOOTED-OK" in qemu, "qemu-test lost the verified disk zap (firmware may prefer the disk over the ISO)")
check("UNBOOT-VERIFY-FAIL" in qemu, "qemu-test lost the zap verification (a silent no-op must fail loudly)")
check("OVMF_VARS_4.fd" in qemu, "qemu-test lost the fresh vars file for the phase-4 ISO boot")
check("ISO-BOOT-OK" in qemu, "qemu-test lost the ISO-boot assertion")
# Installed bar content: the example layout, not the clock-only
# default, minus the live-only Welcome button.
check("BAR-CONTENT-OK" in qemu, "qemu-test lost the installed-bar content proof")
check("/etc/scootbar/bar.toml" in qemu, "qemu-test lost the installed bar.toml read")
check("BAR-NO-WELCOME-OK" in qemu, "qemu-test lost the no-live-Welcome-button proof")

# Docker one-command build: image pinned by digest (never :latest),
# check mode for fast plumbing validation, caller-owned output. The
# digest follows the EFFECTIVE platform (ISO_PLATFORM when set, else
# native): an arm64 digest under --platform linux/amd64 fails with a
# platform mismatch instead of emulating.
check('DIGEST_AMD64="sha256:' in docker and 'DIGEST_ARM64="sha256:' in docker, "docker script lost the per-arch digest pins")
check("nixos/nix@$DIGEST" in docker, "docker script lost the digest-pinned image ref")
check(":latest" not in docker, "docker script must not use :latest")
check("--check" in docker, "docker script lost check mode")
check("CALLER_UID" in docker, "docker script lost the caller-ownership handoff")
check("linux/amd64" in docker and "linux/arm64" in docker, "docker script lost the effective-platform digest map")
check("NATIVE_DIGEST" in docker, "docker script lost the native-arch digest fallback")

# CI: qemu-test waits for the KVM probe (a KVM-less runner must not
# pay the 30-minute ISO build before failing), and release ships the
# tested build-iso artifact instead of rebuilding (released bytes are
# literally the tested bytes).
check("[build-iso, kvm-probe]" in ci, "qemu-test must need [build-iso, kvm-probe]")
check("needs: [build-iso, qemu-test]" in ci, "release must need [build-iso, qemu-test] (only tested bytes ship)")
check(ci.count("nix build .#packages.x86_64-linux.iso") == 1, "only build-iso may build the ISO (release reuses its artifact)")

if failures:
    print("patch-consistency FAILED:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("patch-consistency OK")
