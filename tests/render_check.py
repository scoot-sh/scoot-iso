#!/usr/bin/env python3
"""Execute the shipped Calamares writer for a matrix of choices and assert
what lands (runs in CI, needs root for the installer's chown).

Unlike patch_consistency.py (which checks the patch sources agree), this
runs the GENERATED main.py's scoot branch with stubbed Calamares globals,
exactly as the installer would: look x location x user presence. It asserts
the rendered files (look, nh.flake, no leftover markers, user stanzas),
the flake.lock bytes, the git repo with its first commit, ownership, and
the /etc/nixos symlink (home) or real dir (system).

Then the canonical check: render the exact config scripts/qemu-test.sh
installs (scoot-moonrise, home folder, user scoot, host scoot, UTC,
en_US.UTF-8, 25.11, static QEMU hardware) and assert it evaluates to the
same toplevel as nix/target-machine.nix (drvPath match). The ISO ships
that toplevel in isoImage.storeContents, and the offline install
(substitute=false into an empty target store) only works if the two are
identical — so any drift fails here in seconds, not after a 45-minute
QEMU run. SYSTEM env selects the platform (default x86_64-linux, as in
CI's check job); evaluation only, no builds.

Usage (CI runs it with sudo after building calamares-ext-patched-src):
  sudo python3 tests/render_check.py <generated-main.py> <repo-iso-target-dir>
"""

import os
import re
import shutil
import subprocess
import sys
import textwrap

main_py_path, target_dir = sys.argv[1:]

CAN_CHOWN = os.geteuid() == 0
chown_calls = []
_real_check_output = subprocess.check_output


def _check_output(cmd, **kw):
    # Local runs are rarely root: record the installer's chown instead of
    # performing it, and assert on the recorded call. Under sudo (CI) the
    # real chown runs and ownership itself is asserted.
    if cmd[0] == "chown" and not CAN_CHOWN:
        chown_calls.append(tuple(cmd))
        return b""
    return _real_check_output(cmd, **kw)


class FakeSubprocess:
    check_output = staticmethod(_check_output)

src = open(main_py_path).read()
start = src.index('    scoot_choice = gs.value("packagechooser_packagechooser")')
endmark = '    else:\n        libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", config], None, cfg)'
end = src.index(endmark)
branch = textwrap.dedent(src[start:end])
post_start = src.index('    scoot_post_choice = gs.value("packagechooser_packagechooser")')
post_endmark = '    libcalamares.job.setprogress(INSTALL_PROGRESS_END)'
post_end = src.index(post_endmark)
post_branch = textwrap.dedent(src[post_start:post_end])

warnings = []


class FakeGS:
    def __init__(self, choice, loc):
        self.choice, self.loc = choice, loc

    def value(self, k):
        return {
            "packagechooser_packagechooser": self.choice,
            "packagechooser_scoot-location": self.loc,
        }.get(k)


class FakeCal:
    class utils:
        @staticmethod
        def host_env_process_output(cmd, unused, text):
            assert cmd[:2] == ["cp", "/dev/stdin"]
            os.makedirs(os.path.dirname(cmd[2]), exist_ok=True)
            open(cmd[2], "w").write(text)

        @staticmethod
        def warning(msg):
            warnings.append(msg)


CASES = [
    # (desktop id, location id, variables, expected layout, expected look, expected nh.flake, user stanza?)
    ("scoot-moonrise", "home", {"hostname": "t", "username": "u", "fullname": "U T", "timezone": "Etc/UTC", "LANG": "en_US.UTF-8", "nixosversion": "25.11"},
     "home", "moonrise", "/home/u/nixos-config", True),
    ("scoot-vinyl-sunset", "home", {"hostname": "t", "username": "u", "fullname": "U T", "timezone": "Etc/UTC", "LANG": "en_US.UTF-8", "nixosversion": "25.11"},
     "home", "vinyl-sunset", "/home/u/nixos-config", True),
    ("scoot-music-desk", "system", {"hostname": "t", "username": "u", "fullname": "U T", "timezone": "Etc/UTC", "LANG": "en_US.UTF-8", "nixosversion": "25.11"},
     "system", "music-desk", "/etc/nixos", True),
    ("scoot-radial-burst", "system", {"hostname": "nixos", "nixosversion": "25.11"},
     "system", "radial-burst", "/etc/nixos", False),
    # Fallbacks: home without a user, and an unknown location, both land system-wide.
    ("scoot-moonrise", "home", {"hostname": "nixos", "nixosversion": "25.11"},
     "system", "moonrise", "/etc/nixos", False),
    ("scoot-moonrise", "bogus", {"hostname": "t", "username": "u", "fullname": "U T", "nixosversion": "25.11"},
     "home", "moonrise", "/home/u/nixos-config", True),
]

failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)
        print("FAIL:", msg)


check("--override-input" not in src, "generated main.py must not carry --override-input")
check('"substitute"' in src, "generated main.py lost substitute=false")


for choice, loc, variables, layout, look, nh_flake, want_user in CASES:
    tag = f"{choice}/{loc}/{'user' if 'username' in variables else 'nouser'}"
    before = len(failures)
    root = f"/tmp/render-check-{choice}-{loc}-{ 'u' if 'username' in variables else 'n'}"
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root + "/etc/nixos", exist_ok=True)
    open(root + "/etc/nixos/configuration.nix", "w").write("# classic boilerplate\n")
    open(root + "/etc/nixos/hardware-configuration.nix", "w").write("{ }\n")
    g = {"gs": FakeGS(choice, loc), "libcalamares": FakeCal(),
         "root_mount_point": root, "variables": dict(variables),
         "os": os, "re": re, "subprocess": FakeSubprocess}
    warnings.clear()
    chown_calls.clear()
    exec(branch, g)  # noqa: S102 (test harness for generated installer code)
    exec(post_branch, g)  # post-install ownership handoff, same stubs
    flakedir = root + ("/home/u/nixos-config" if layout == "home" and "username" in variables else "/etc/nixos")
    if layout == "home" and "username" not in variables:
        flakedir = root + "/etc/nixos"
    for name in ("flake.nix", "configuration.nix", "flake.lock", "hardware-configuration.nix"):
        check(os.path.isfile(os.path.join(flakedir, name)), f"{tag}: missing {name}")
    config = open(os.path.join(flakedir, "configuration.nix")).read()
    check(config.count(f'desktop.look = "{look}"') == (2 if want_user else 1),
          f"{tag}: look {look} in wrong number of halves")
    check(f'flake = "{nh_flake}"' in config, f"{tag}: nh.flake {nh_flake} missing")
    check("@@" not in config, f"{tag}: leftover marker in configuration.nix")
    check('users.users."u"' in config if want_user else "users.users." not in config,
          f"{tag}: user stanza wrong")
    check(open(os.path.join(flakedir, "flake.lock")).read() == open(os.path.join(target_dir, "flake.lock")).read(),
          f"{tag}: flake.lock bytes differ from the shipped lock")
    # Themed greeter template: every render carries the per-look
    # wallpaper map, the dark/light ReGreet theme switch and the Login
    # accent CSS (values are asserted by evaluation below).
    check("programs.scoot.greeter.background" in config, f"{tag}: greeter background missing")
    check("greeterWallpapers" in config, f"{tag}: per-look wallpaper map missing")
    check("services.displayManager.regreet" in config, f"{tag}: ReGreet theme block missing")
    check("Adwaita-dark" in config and "application_prefer_dark_theme" in config, f"{tag}: dark GTK theme missing")
    check("suggested-action" in config, f"{tag}: Login accent CSS missing")
    if layout == "home":
        check(os.path.islink(root + "/etc/nixos"), f"{tag}: /etc/nixos is not a symlink")
        if CAN_CHOWN:
            st = os.stat(flakedir)
            check((st.st_uid, st.st_gid) == (1000, 100), f"{tag}: ownership {(st.st_uid, st.st_gid)} != (1000, 100)")
        else:
            check(chown_calls == [("chown", "-R", "1000:100", root + "/home/u")],
                  f"{tag}: chown call wrong (non-root run): {chown_calls}")
    else:
        check(not os.path.islink(root + "/etc/nixos"), f"{tag}: /etc/nixos should be a real dir")
        check(chown_calls == [], f"{tag}: system install must not chown: {chown_calls}")
    log = subprocess.check_output(["git", "-C", flakedir, "log", "--oneline"]).decode()
    check(len(log.strip().splitlines()) == 1 and "Initial scoot system" in log, f"{tag}: git first commit wrong: {log!r}")
    tracked = subprocess.check_output(["git", "-C", flakedir, "ls-files"]).decode().split()
    check(sorted(tracked) == ["configuration.nix", "flake.lock", "flake.nix", "hardware-configuration.nix"],
          f"{tag}: tracked files wrong: {tracked}")
    if len(failures) == before:
        print(f"case OK: {tag}")
    shutil.rmtree(root, ignore_errors=True)

if failures:
    print(f"render-check FAILED ({len(failures)} problems)")
    sys.exit(1)
print("render-check OK")

# --- greeter looks check: every look evaluates to its theme --------
# Re-exec the writer once per look and read back the evaluated greeter
# values (wallpaper, GTK theme, dark signal, background fit, accent
# CSS) with one nix eval each: the installed login screen must wear
# all four looks, and a typo'd wallpaper name only fails here.
import json as _json

LOOK_IDS = {
    "scoot-moonrise": ("moonrise", "moonrise.png", "Adwaita-dark", True, "#FFA45C"),
    "scoot-music-desk": ("music-desk", "music-desk.png", "Adwaita", False, "#3D579A"),
    "scoot-radial-burst": ("radial-burst", "radial-burst.png", "Adwaita-dark", True, "#31a9e5"),
    "scoot-vinyl-sunset": ("vinyl-sunset", None, "Adwaita-dark", True, "#E59560"),
}
for _choice, (_look, _wall, _theme, _dark, _accent) in LOOK_IDS.items():
    _root = f"/tmp/render-check-greeter-{_look}"
    shutil.rmtree(_root, ignore_errors=True)
    os.makedirs(_root + "/etc/nixos", exist_ok=True)
    open(_root + "/etc/nixos/configuration.nix", "w").write("# classic boilerplate\n")
    open(_root + "/etc/nixos/hardware-configuration.nix", "w").write("{ }\n")
    _vars = {"hostname": "t", "username": "u", "fullname": "U T", "timezone": "Etc/UTC",
             "LANG": "en_US.UTF-8", "nixosversion": "25.11"}
    _g = {"gs": FakeGS(_choice, "home"), "libcalamares": FakeCal(),
          "root_mount_point": _root, "variables": dict(_vars),
          "os": os, "re": re, "subprocess": FakeSubprocess}
    warnings.clear()
    exec(branch, _g)  # noqa: S102 (test harness for generated installer code)
    _flakedir = _root + "/home/u/nixos-config"
    shutil.copyfile(os.path.join(target_dir, "hardware-configuration.nix"),
                    os.path.join(_flakedir, "hardware-configuration.nix"))
    _expr = (
        'let f = builtins.getFlake "path:' + _flakedir + '"; '
        'c = f.nixosConfigurations.scoot.config; in { '
        'bg = c.programs.scoot.greeter.background; '
        'theme = c.services.displayManager.regreet.theme.name; '
        'dark = c.services.displayManager.regreet.settings.GTK.application_prefer_dark_theme; '
        'fit = c.services.displayManager.regreet.settings.background.fit; '
        'css = c.services.displayManager.regreet.extraCss; }'
    )
    _got = _json.loads(subprocess.check_output(
        ["nix", "eval", "--impure", "--json", "--expr", _expr],
        stderr=subprocess.DEVNULL).decode())
    if _wall is None:
        check(_got["bg"] is None, f"greeter/{_look}: background should be null (no wallpaper ships), got {_got['bg']}")
    else:
        check(_got["bg"] is not None and _got["bg"].endswith(_wall),
              f"greeter/{_look}: background {_got['bg']} is not the {_wall} wallpaper")
    check(_got["theme"] == _theme, f"greeter/{_look}: theme {_got['theme']} != {_theme}")
    check(_got["dark"] is _dark, f"greeter/{_look}: dark signal {_got['dark']} != {_dark}")
    check(_got["fit"] == "Cover", f"greeter/{_look}: background fit {_got['fit']} != Cover")
    check(_accent in _got["css"], f"greeter/{_look}: accent {_accent} missing from extraCss")
    if not [f for f in failures if f.startswith(f"greeter/{_look}")]:
        print(f"greeter OK: {_look} (bg={_got['bg']}, theme={_theme})")
    shutil.rmtree(_root, ignore_errors=True)

if failures:
    print(f"greeter-check FAILED ({len(failures)} problems)")
    sys.exit(1)
print("greeter-check OK")

# --- canonical check: the QEMU test's exact config == the mirror ------
# The patch bakes @@SYSTEM@@ at ISO build time, so the generated flake
# names its own system: read it back and compare against the mirror for
# that same system. (SYSTEM env overrides only when set explicitly, for
# manual runs against a re-targeted tree.)
CANON_VARS = {
    "hostname": "scoot",
    "username": "scoot",
    "fullname": "scoot",
    "timezone": "UTC",
    "LANG": "en_US.UTF-8",
    "nixosversion": "25.11",
}
canon_root = "/tmp/render-check-canonical"
shutil.rmtree(canon_root, ignore_errors=True)
os.makedirs(canon_root + "/etc/nixos", exist_ok=True)
open(canon_root + "/etc/nixos/configuration.nix", "w").write("# classic boilerplate\n")
open(canon_root + "/etc/nixos/hardware-configuration.nix", "w").write("{ }\n")
g = {"gs": FakeGS("scoot-moonrise", "home"), "libcalamares": FakeCal(),
     "root_mount_point": canon_root, "variables": dict(CANON_VARS),
     "os": os, "re": re, "subprocess": FakeSubprocess}
warnings.clear()
exec(branch, g)  # noqa: S102 (test harness for generated installer code)
canon_flakedir = canon_root + "/home/scoot/nixos-config"
# The test installs the static QEMU hardware, not the generator's
# output (see scripts/qemu-test.sh): same file the mirror imports.
shutil.copyfile(os.path.join(target_dir, "hardware-configuration.nix"),
                os.path.join(canon_flakedir, "hardware-configuration.nix"))
_flake = open(os.path.join(canon_flakedir, "flake.nix")).read()
check("@@SYSTEM@@" not in _flake, "canonical flake.nix has an unbaked @@SYSTEM@@")
canon_system = os.environ.get("SYSTEM") or re.search(r'system = "(x86_64-linux|aarch64-linux)"', _flake).group(1)
got = subprocess.check_output(
    ["nix", "eval", "--raw", canon_flakedir + "#nixosConfigurations.scoot.config.system.build.toplevel.drvPath"],
    stderr=subprocess.DEVNULL).decode().strip()
repo_root = os.path.abspath(os.path.join(target_dir, "..", ".."))
want = subprocess.check_output(
    ["nix", "eval", "--raw", repo_root + "#nixosConfigurations.scoot-target-" + canon_system + ".config.system.build.toplevel.drvPath"],
    stderr=subprocess.DEVNULL).decode().strip()
check(got == want, f"canonical toplevel drift: rendered {got} != mirror {want} ({canon_system})")
if failures:
    print(f"canonical-check FAILED ({len(failures)} problems)")
    sys.exit(1)
print(f"canonical-check OK ({canon_system}): {got}")
shutil.rmtree(canon_root, ignore_errors=True)
