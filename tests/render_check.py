#!/usr/bin/env python3
"""Execute the shipped Calamares writer for a matrix of choices and assert
what lands (runs in CI, needs root for the installer's chown).

Unlike patch_consistency.py (which checks the patch sources agree), this
runs the GENERATED main.py's scoot branch with stubbed Calamares globals,
exactly as the installer would: look x location x user presence. It asserts
the rendered files (look, nh.flake, no leftover markers, user stanzas),
the flake.lock bytes, the git repo with its first commit, ownership, and
the /etc/nixos symlink (home) or real dir (system).

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

src = open(main_py_path).read()
start = src.index('    scoot_choice = gs.value("packagechooser_packagechooser")')
endmark = '    else:\n        libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", config], None, cfg)'
end = src.index(endmark)
branch = textwrap.dedent(src[start:end])

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
    if layout == "home":
        check(os.path.islink(root + "/etc/nixos"), f"{tag}: /etc/nixos is not a symlink")
        if CAN_CHOWN:
            st = os.stat(flakedir)
            check((st.st_uid, st.st_gid) == (1000, 100), f"{tag}: ownership {(st.st_uid, st.st_gid)} != (1000, 100)")
        else:
            check(chown_calls == [("chown", "-R", "1000:100", flakedir)],
                  f"{tag}: chown call wrong (non-root run): {chown_calls}")
    else:
        check(not os.path.islink(root + "/etc/nixos"), f"{tag}: /etc/nixos should be a real dir")
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
