#!/usr/bin/env python3
"""Splice the scoot choice into calamares-nixos-extensions at ISO build time.

The scoot choice writes a flake-based target (flake.nix + flake.lock +
configuration.nix from this repo, into ~/nixos-config by default or
/etc/nixos) and installs it with `nixos-install --flake` and
substitute=false, so install works with the network cut: every input
source the installed flake needs rides the ISO (resolved from its own
lock at ISO build time). No --override-input, so the installed
flake.lock stays pristine github pins. Everything else (hostname, user,
timezone, locale, firefox) mirrors the stock classic path's variables.

Every anchor is asserted to occur exactly once, so a nixpkgs re-pin that
changes the upstream files fails the ISO build loudly instead of silently
dropping scoot. Never touches upstream: the patch is carried in this repo.

Usage:
  calamares-patch.py <ext-src> <target-flake> <target-config> \\
      <target-lock> <look-items> <location-conf> <system> \\
      <out-main.py> <out-packagechooser.conf> <out-settings.conf> \\
      <out-location.conf>
"""

import json
import sys


def replace_once(content: str, anchor: str, replacement: str, name: str) -> str:
    count = content.count(anchor)
    if count != 1:
        raise SystemExit(
            f"anchor {name!r} found {count} times (expected exactly 1); "
            "upstream changed, update the patch"
        )
    return content.replace(anchor, replacement, 1)


HM_USER_STANZA = """\
  # The same desktop profile for the installed user (the compositor
  # config file is the home-manager side's): look colors, wallpaper and
  # keymap defaults, per key beatable by values the user sets.
  home-manager.users."@@username@@".imports = [
    inputs.scoot.homeModules.scoot
    inputs.scoot.homeModules.scootbar
  ];
  home-manager.users."@@username@@".programs.scoot = {
    enable = true;
    desktop.enable = true;
    desktop.look = "@@SCOOT_LOOK@@";
  };
  home-manager.users."@@username@@".programs.scootbar.enable = true;
  home-manager.users."@@username@@".home.stateVersion = "25.11";
"""

USERS_STANZA = """\
  # Define the user account created during install. The uid/gid are
  # pinned (not auto-assigned) so the installer can chown the
  # home-folder nixos-config to exactly this user before it exists in
  # any passwd database; a collision would fail the install loudly.
  users.users."@@username@@" = {
    isNormalUser = true;
    uid = 1000;
    group = "users";
    description = "@@fullname@@";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
  };
"""

TIMEZONE_LINE = '  time.timeZone = "@@timezone@@";\n'
LOCALE_LINE = '  i18n.defaultLocale = "@@LANG@@";\n'

# Calamares Desktop-page entries this patch owns (ids), each naming the
# scoot look the installed system gets. moonrise is the default: its
# wallpaper ships in the pinned scoot under the Unsplash License, so the
# session shows a real illustration instead of a flat color.
SCOOT_LOOKS = {
    "scoot-moonrise": "moonrise",
    "scoot-music-desk": "music-desk",
    "scoot-radial-burst": "radial-burst",
    "scoot-vinyl-sunset": "vinyl-sunset",
}
SCOOT_DEFAULT = "scoot-moonrise"

# Second installer page: where the generated flake lives. A second
# packagechooser instance (packagechooser@scoot-location) is the
# lightest page mechanism Calamares offers: no new module code, just a
# module config plus an instances/sequence entry in the carried
# settings.conf (which already precedes this with notesqml@unfree).
# The GS key is "packagechooser_" + the instance id (upstream
# src/modules/packagechooser/Config.cpp make_gs_key). "home" (the
# default) is ~/nixos-config owned by the installed user with /etc/nixos
# symlinked to it; "system" is the classic root-owned /etc/nixos.
# Anything unset or unknown falls back to "home" in the writer, so a
# page that failed to load can never brick the install.
SCOOT_LOCATION_DEFAULT = "home"
SCOOT_LOCATION_IDS = ("home", "system")


def main() -> None:
    (
        ext_src,
        target_flake,
        target_config,
        target_lock,
        item_file,
        location_file,
        system,
        out_main,
        out_packagechooser,
        out_settings,
        out_location,
    ) = sys.argv[1:]

    with open(f"{ext_src}/src/modules/nixos/main.py") as f:
        main_py = f.read()
    with open(f"{ext_src}/src/config/modules/packagechooser.conf") as f:
        chooser = f.read()
    with open(f"{ext_src}/src/config/settings.conf") as f:
        settings = f.read()
    with open(target_flake) as f:
        flake_text = f.read()
    with open(target_config) as f:
        config_text = f.read()
    with open(target_lock) as f:
        lock_text = f.read()
    with open(item_file) as f:
        item_text = f.read()
    with open(location_file) as f:
        location_text = f.read()

    if "@@SYSTEM@@" not in flake_text:
        raise SystemExit("target flake.nix lost its @@SYSTEM@@ placeholder")
    flake_baked = flake_text.replace("@@SYSTEM@@", system)
    if "@@SYSTEM@@" in flake_baked:
        raise SystemExit("target flake.nix still has an unsubstituted @@SYSTEM@@")

    for placeholder in ("@@TIMEZONE@@", "@@LOCALE@@", "@@SCOOT_USERS@@", "@@SCOOT_HM_USER@@", "@@SCOOT_LOOK@@", "@@SCOOT_NH_FLAKE@@"):
        if placeholder not in config_text:
            raise SystemExit(f"target configuration.nix lost {placeholder}")
    if "@@SCOOT_LOOK@@" in flake_baked:
        raise SystemExit("target flake.nix must not contain @@SCOOT_LOOK@@")

    # The shipped flake.lock: real upstream inputs at the ISO's pinned
    # revs, never path: overrides. It is written verbatim to the target
    # (and the install runs --no-write-lock-file), so the installed
    # system keeps a normal, maintainable flake afterwards.
    try:
        lock = json.loads(lock_text)
    except ValueError as e:
        raise SystemExit(f"target flake.lock is not JSON: {e}")
    for node in ("nixpkgs", "scoot", "home-manager"):
        locked = lock.get("nodes", {}).get(node, {}).get("locked", {})
        if locked.get("type") != "github":
            raise SystemExit(f"target flake.lock node {node} is not a github input: {locked}")
    for rev in (
        lock["nodes"]["nixpkgs"]["locked"]["rev"],
        lock["nodes"]["scoot"]["locked"]["rev"],
        lock["nodes"]["home-manager"]["locked"]["rev"],
    ):
        if rev not in flake_text:
            raise SystemExit(f"target flake.lock rev {rev} not in target flake.nix (re-pin drift)")
    if '"type": "path"' in lock_text or "@@" in lock_text:
        raise SystemExit("target flake.lock must not contain path: overrides or placeholders")

    # 1. The desktop list: the four scoot looks first, moonrise default
    # selected. One entry per look (packagechooser is single-select, so
    # the look rides the desktop id: scoot-<look>).
    chooser = replace_once(chooser, "default: gnome", f"default: {SCOOT_DEFAULT}", "chooser default")
    chooser = replace_once(chooser, "items:", f"items:\n{item_text}", "chooser items")
    for item_id in SCOOT_LOOKS:
        if f"- id: {item_id}" not in chooser:
            raise SystemExit(f"packagechooser item {item_id} missing after splice")

    # 1b. The location page: a second packagechooser instance with its
    # own config, sequenced right after the Desktop page.
    location_anchor_instances = "- module:   nixos\n  weight:   48"
    if settings.count(location_anchor_instances) != 1:
        raise SystemExit("settings.conf instances anchor not found exactly once; upstream changed, update the patch")
    settings = settings.replace(
        location_anchor_instances,
        "- id:       scoot-location\n  module:   packagechooser\n  config:   scoot-location.conf\n" + location_anchor_instances,
        1,
    )
    settings = replace_once(
        settings,
        "  - packagechooser\n",
        "  - packagechooser\n  - packagechooser@scoot-location\n",
        "show sequence packagechooser",
    )
    for loc_id in SCOOT_LOCATION_IDS:
        if f"- id: {loc_id}" not in location_text:
            raise SystemExit(f"location item {loc_id} missing from the location template")
    if "default: home" not in location_text:
        raise SystemExit("location template lost its home default")

    # 2. When scoot is chosen, write our flake files instead of the
    # classic configuration.nix. The stock `variables` dict (hostname,
    # username, locale, nixosversion, ...) is reused with the same
    # fallbacks as the classic path. The flake's home comes from the
    # Config-location page (home default, system fallback without a
    # user): ~/nixos-config owned by the user with /etc/nixos symlinked
    # to it, or the classic root-owned /etc/nixos. Either way the files
    # land in a git repo with a first commit (flakes only see tracked
    # files), and the shipped flake.lock goes with them verbatim so the
    # installed system keeps a normal github-pinned flake.
    anchor_write = '    libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", config], None, cfg)\n'
    writer = (
        '    scoot_choice = gs.value("packagechooser_packagechooser")\n'
        '    scoot_looks = ' + repr(SCOOT_LOOKS) + '\n'
        '    if scoot_choice in scoot_looks:\n'
        '        scoot_look = scoot_looks[scoot_choice]\n'
        '        scoot_loc = gs.value("packagechooser_scoot-location")\n'
        '        if scoot_loc not in ("home", "system"):\n'
        '            scoot_loc = "home"\n'
        "        scoot_config_text = " + repr(config_text) + "\n"
        "        scoot_flake_text = " + repr(flake_baked) + "\n"
        "        scoot_lock_text = " + repr(lock_text) + "\n"
        '        scoot_vars = dict(variables)\n'
        '        scoot_vars.setdefault("hostname", "nixos")\n'
        '        if scoot_loc == "home" and "username" not in scoot_vars:\n'
        '            libcalamares.utils.warning("scoot home-folder config needs a user: using system-wide /etc/nixos instead")\n'
        '            scoot_loc = "system"\n'
        '        if scoot_loc == "home":\n'
        '            scoot_flakedir = os.path.join(root_mount_point, "home", scoot_vars["username"], "nixos-config")\n'
        '            scoot_nh_flake = "/home/" + scoot_vars["username"] + "/nixos-config"\n'
        '        else:\n'
        '            scoot_flakedir = os.path.join(root_mount_point, "etc/nixos")\n'
        '            scoot_nh_flake = "/etc/nixos"\n'
        '        scoot_config_text = scoot_config_text.replace("@@SCOOT_LOOK@@", scoot_look)\n'
        '        scoot_config_text = scoot_config_text.replace("@@SCOOT_NH_FLAKE@@", scoot_nh_flake)\n'
        '        if "timezone" in scoot_vars:\n'
        '            scoot_config_text = scoot_config_text.replace(\n'
        '                "  # @@TIMEZONE@@\\n", ' + repr(TIMEZONE_LINE) + ')\n'
        "        else:\n"
        '            scoot_config_text = scoot_config_text.replace("  # @@TIMEZONE@@\\n", "")\n'
        '        if "LANG" in scoot_vars:\n'
        '            scoot_config_text = scoot_config_text.replace(\n'
        '                "  # @@LOCALE@@\\n", ' + repr(LOCALE_LINE) + ')\n'
        "        else:\n"
        '            scoot_config_text = scoot_config_text.replace("  # @@LOCALE@@\\n", "")\n'
        '        if "username" in scoot_vars:\n'
        "            scoot_hm = " + repr(HM_USER_STANZA) + "\n"
        "            scoot_users = " + repr(USERS_STANZA) + "\n"
        '            scoot_hm = scoot_hm.replace("@@SCOOT_LOOK@@", scoot_look)\n'
        "            for _key, _val in scoot_vars.items():\n"
        '                scoot_hm = scoot_hm.replace("@@" + _key + "@@", str(_val))\n'
        '                scoot_users = scoot_users.replace("@@" + _key + "@@", str(_val))\n'
        '            scoot_config_text = scoot_config_text.replace("  # @@SCOOT_HM_USER@@", scoot_hm)\n'
        '            scoot_config_text = scoot_config_text.replace("  # @@SCOOT_USERS@@", scoot_users)\n'
        "        else:\n"
        '            libcalamares.utils.warning("scoot install without a user: skipping the user and home-manager stanzas")\n'
        '            scoot_config_text = scoot_config_text.replace("  # @@SCOOT_HM_USER@@\\n", "")\n'
        '            scoot_config_text = scoot_config_text.replace("  # @@SCOOT_USERS@@\\n", "")\n'
        "        for _key, _val in scoot_vars.items():\n"
        '            scoot_config_text = scoot_config_text.replace("@@" + _key + "@@", str(_val))\n'
        "        _leftover = re.findall(r\"@@\\\\w+@@\", scoot_config_text)\n"
        "        if _leftover:\n"
        '            libcalamares.utils.warning("scoot target left unsubstituted: {}".format(sorted(set(_leftover))))\n'
        '        os.makedirs(scoot_flakedir, exist_ok=True)\n'
        '        libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", os.path.join(scoot_flakedir, "configuration.nix")], None, scoot_config_text)\n'
        '        libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", os.path.join(scoot_flakedir, "flake.nix")], None, scoot_flake_text)\n'
        '        libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", os.path.join(scoot_flakedir, "flake.lock")], None, scoot_lock_text)\n'
        '        if scoot_loc == "home":\n'
        '            scoot_hw_src = os.path.join(root_mount_point, "etc/nixos/hardware-configuration.nix")\n'
        '            with open(scoot_hw_src) as _hw_in:\n'
        '                _hw_text = _hw_in.read()\n'
        '            with open(os.path.join(scoot_flakedir, "hardware-configuration.nix"), "w") as _hw_out:\n'
        '                _hw_out.write(_hw_text)\n'
        '            os.remove(os.path.join(root_mount_point, "etc/nixos/configuration.nix"))\n'
        '            os.remove(scoot_hw_src)\n'
        '            os.rmdir(os.path.join(root_mount_point, "etc/nixos"))\n'
        '            os.symlink("/home/" + scoot_vars["username"] + "/nixos-config", os.path.join(root_mount_point, "etc/nixos"))\n'
        '            scoot_fullname = scoot_vars.get("fullname") or scoot_vars["username"]\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "init", "-b", "main"])\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "add", "-A"])\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "-c", "user.name=" + str(scoot_fullname), "-c", "user.email=" + scoot_vars["username"] + "@localhost", "commit", "-m", "Initial scoot system (scoot-iso installer)"])\n'
        '            subprocess.check_output(["chown", "-R", "1000:100", scoot_flakedir])\n'
        '        else:\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "init", "-b", "main"])\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "add", "-A"])\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "-c", "user.name=root", "-c", "user.email=root@localhost", "commit", "-m", "Initial scoot system (scoot-iso installer)"])\n'
        "    else:\n"
        "        " + anchor_write.lstrip()
    )
    main_py = replace_once(main_py, anchor_write, writer, "target writer")

    # 3. Install the flake choice offline: every input source the
    # installed flake needs rides the ISO (resolved from its own lock at
    # ISO build time), so no --override-input is needed and the
    # installed flake.lock stays pristine. substitute=false makes any
    # gap loud instead of phoning home; the lock is never rewritten
    # (--no-write-lock-file).
    anchor_cmd = (
        '            "--option",\n'
        '            "build-dir",\n'
        '            "/nix/var/nix/builds",\n'
        "        ]\n"
        "    )\n"
    )
    cmd_patch = (
        anchor_cmd
        + '    scoot_cmd_loc = gs.value("packagechooser_scoot-location")\n'
        + '    if scoot_cmd_loc not in ("home", "system"):\n'
        + '        scoot_cmd_loc = "home"\n'
        + '    scoot_cmd_user = variables.get("username")\n'
        + '    if scoot_cmd_loc == "home" and not scoot_cmd_user:\n'
        + '        scoot_cmd_loc = "system"\n'
        + '    if gs.value("packagechooser_packagechooser") in '
        + repr(sorted(SCOOT_LOOKS)) + ':\n'
        + '        if scoot_cmd_loc == "home":\n'
        + '            scoot_flake_ref = root_mount_point + "/home/" + scoot_cmd_user + "/nixos-config#scoot"\n'
        + '        else:\n'
        + '            scoot_flake_ref = root_mount_point + "/etc/nixos#scoot"\n'
        + "        nixosInstallCmd.extend(\n"
        + "            [\n"
        + '                "--flake",\n'
        + '                scoot_flake_ref,\n'
        + '                "--no-write-lock-file",\n'
        + '                "--option",\n'
        + '                "substitute",\n'
        + '                "false",\n'
        + "            ]\n"
        + "        )\n"
    )
    main_py = replace_once(main_py, anchor_cmd, cmd_patch, "install command")

    with open(out_main, "w") as f:
        f.write(main_py)
    with open(out_packagechooser, "w") as f:
        f.write(chooser)
    with open(out_settings, "w") as f:
        f.write(settings)
    with open(out_location, "w") as f:
        f.write(location_text)


if __name__ == "__main__":
    main()
