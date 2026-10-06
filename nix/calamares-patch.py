#!/usr/bin/env python3
"""Splice the scoot choice into calamares-nixos-extensions at ISO build time.

The scoot choice writes a flake-based target (flake.nix + flake.lock +
configuration.nix from this repo, into ~/nixos-config by default or
/etc/nixos) and installs it with `nixos-install --flake`.

The graphical install needs the network. Calamares' Welcome page
requires `internet` (the pinned welcome.conf; asserted below), so
Next stays disabled offline, and a GUI install's generated hardware
file, user, host, timezone and locale never match the canonical
closure the ISO ships. The install uses the normal substituters
(cache.nixos.org plus the scoot Cachix the flake already trusts);
nixos-install also substitutes from the live store, so paths the ISO
ships copy locally instead of downloading.

The offline branch (`nix flake archive --to` for the flake inputs,
`nix copy --to` for the target closure, `substitute=false`) exists
for the canonical config the QEMU test installs (scripts/qemu-test.sh)
and as a guard for a network lost after the Welcome page: the
scoot-netprobe shellprocess step records the mode before partitioning,
and when it is offline a pre-flight (target toplevel eval plus a
live-store closure check) refuses with the missing paths. In the GUI
that refusal comes after the partition and mount jobs and after this
module has written the generated and flake configs, but before
nixos-install writes anything to the target store. The installed
flake.lock is never rewritten (--no-write-lock-file), and
`--no-channel-copy` holds in both modes. Everything else (hostname,
user, timezone, locale, firefox) mirrors the stock classic path's
variables.

Every anchor is asserted to occur exactly once, so a nixpkgs re-pin that
changes the upstream files fails the ISO build loudly instead of silently
dropping scoot. Never touches upstream: the patch is carried in this repo.

Usage:
  calamares-patch.py <ext-src> <target-flake> <target-config> \\
      <target-lock> <look-items> <location-conf> <netprobe-conf> <system> \\
      <out-main.py> <out-packagechooser.conf> <out-settings.conf> \\
      <out-location.conf> <out-netprobe.conf>
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


def welcome_required(welcome_conf: str):
    """The `requirements.required:` item list of welcome.conf, or None
    when there is no such block (comments and blank lines skipped)."""
    items = None
    for line in welcome_conf.splitlines():
        code = line.split("#", 1)[0].rstrip()
        if not code.strip():
            continue
        if code.strip() == "required:":
            items = []
            continue
        if items is not None:
            if code.strip().startswith("- "):
                items.append(code.strip()[2:].strip())
            else:
                break
    return items


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
  # The installed bar draws the look's example layout (scootBarLayouts
  # in configuration.nix, selected by the installed desktop.look, the
  # same expression the system half uses), whichever unit the session
  # starts: without this, the home unit's empty config shadows the
  # system unit (same unit name, home wins) and the installed desktop
  # shows the bar binary's clock-only default. The home unit itself
  # stays off, so exactly one daemon runs: the system one, whose
  # config names /etc/scootbar/bar.toml explicitly.
  home-manager.users."@@username@@".programs.scootbar.settings =
    scootBarLayouts.${config.programs.scoot.desktop.look} or scootBarLayouts.moonrise;
  home-manager.users."@@username@@".programs.scootbar.systemd.enable = false;
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
        netprobe_file,
        system,
        out_main,
        out_packagechooser,
        out_settings,
        out_location,
        out_netprobe,
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
    with open(netprobe_file) as f:
        netprobe_text = f.read()
    with open(f"{ext_src}/src/config/modules/welcome.conf") as f:
        welcome_text = f.read()

    # The README and the refusal text say the graphical install needs
    # the network because the Welcome page REQUIRES `internet` (Next
    # stays disabled without it). A re-pin that drops it from
    # `required:` would make those words false, so fail the build.
    # `- internet` also sits under `check:`, so read the required block
    # itself: its indented `- ` items up to the next key.
    required = welcome_required(welcome_text)
    if required is None or "internet" not in required:
        raise SystemExit("welcome.conf no longer requires internet; the online-only install docs need revisiting")

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
        "- id:       scoot-location\n  module:   packagechooser\n  config:   scoot-location.conf\n"
        "- id:       scoot-netprobe\n  module:   shellprocess\n  config:   scoot-netprobe.conf\n"
        + location_anchor_instances,
        1,
    )
    # The netprobe step runs FIRST in the exec phase, before partition:
    # it only records the network verdict, so it never fails the job
    # (bounded by `timeout 20`, inside the step's 30 s limit).
    exec_anchor_probe = "- exec:\n  - partition\n"
    if settings.count(exec_anchor_probe) != 1:
        raise SystemExit("settings.conf exec anchor not found exactly once; upstream changed, update the patch")
    settings = settings.replace(
        exec_anchor_probe,
        "- exec:\n  - shellprocess@scoot-netprobe\n  - partition\n",
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
    if "dontChroot: true" not in netprobe_text:
        raise SystemExit("netprobe conf must run on the host (dontChroot: true)")
    if "exit 0" not in netprobe_text:
        raise SystemExit("netprobe conf must always exit 0 (the verdict is data, never a job failure)")
    if "/tmp/scoot-netmode" not in netprobe_text:
        raise SystemExit("netprobe conf lost the /tmp/scoot-netmode handoff")
    if "rm -f /tmp/scoot-netmode" not in netprobe_text:
        raise SystemExit("netprobe conf must drop a stale verdict before probing")
    if "timeout 20 python3" not in netprobe_text or "timeout: 30" not in netprobe_text:
        raise SystemExit("netprobe conf must cap the probe (timeout 20) inside the step's 30 s limit")

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
        # The scoot branch writes its own greeter files (ReGreet, never
        # autologin), so the stock autologin snippet never lands — the
        # safe direction, but loud: the user's tick must not vanish
        # silently (mirrors the no-user warnings below).
        '        if gs.value("autoLoginUser") is not None:\n'
        '            libcalamares.utils.warning("scoot install ignores the automatic-login choice: the installed system always greets with ReGreet and never autologins")\n'
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
        '        else:\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "init", "-b", "main"])\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "add", "-A"])\n'
        '            subprocess.check_output(["git", "-C", scoot_flakedir, "-c", "user.name=root", "-c", "user.email=root@localhost", "commit", "-m", "Initial scoot system (scoot-iso installer)"])\n'
        "    else:\n"
        "        " + anchor_write.lstrip()
    )
    main_py = replace_once(main_py, anchor_write, writer, "target writer")

    # 3. Install the flake choice. With the network up, the install
    # uses the normal substituters (cache.nixos.org plus the scoot
    # Cachix the target config already trusts), so real hardware —
    # whose closure differs from the ISO's shipped reference — installs
    # like any other NixOS. Only when offline does the install use the
    # shipped store: every input source the installed flake needs rides
    # the ISO (resolved from its own lock at ISO build time), so no
    # --override-input is needed and the installed flake.lock stays
    # pristine. Offline, substitute=false makes any gap loud instead of
    # phoning home; the lock is never rewritten (--no-write-lock-file).
    # The legacy channel is skipped in both modes (--no-channel-copy):
    # the target is a pure flake system (registry pins, nh.flake,
    # pristine lock) and never reads <nixpkgs> channels; copying the
    # channel into an empty target store with substitute=false fails
    # (proven in CI: the channel path is only in the live store, and
    # `nix-env --set --store` does not copy across). Offline, the flake
    # inputs are archived into the target store first (`nix flake
    # archive --to`: `nix build --store` fetches inputs into the build
    # store, which is empty) and the target's closure is pre-copied
    # from the live store (`nix copy --to`: building into the target
    # store does not consult the live store). Both copies pass
    # --no-check-sigs: ISO store paths are valid but locally built ones
    # carry no signatures, and the target store starts empty with
    # require-sigs on; trust comes from the ISO itself, and
    # substitute=false still bars the network. The toplevel is already
    # in the ISO store for the reference target (the reference target
    # in nix/target-machine.nix names the exact system the test
    # installs; its toplevel rides isoImage.storeContents), so the
    # copies are pure disk I/O and the build that follows is a no-op.
    # The network mode comes from the pre-partition probe
    # (/tmp/scoot-netmode, written by the shellprocess step this patch
    # sequences before partition), falling back to a live probe of the
    # substituters here when the file is missing. The mode is logged;
    # offline, a pre-flight (target toplevel eval plus a live-store
    # closure check) refuses when the target needs paths the ISO does
    # not ship, naming them. A GUI install only gets here offline if
    # the network dropped after the Welcome page's internet check; by
    # then the disk is partitioned and mounted and the configs above
    # are written, but nothing is in the target store, so the message
    # says exactly that and sends the user back to the start.
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
        + '        scoot_flake_dir = root_mount_point + "/home/" + scoot_cmd_user + "/nixos-config" if scoot_cmd_loc == "home" else root_mount_point + "/etc/nixos"\n'
        + '        scoot_netmode = "offline"\n'
        + '        try:\n'
        + '            with open("/tmp/scoot-netmode") as _scoot_nm:\n'
        + '                if _scoot_nm.read().strip() == "online":\n'
        + '                    scoot_netmode = "online"\n'
        + '        except OSError:\n'
        + '            pass\n'
        + '        if scoot_netmode != "online":\n'
        + '            try:\n'
        + '                import urllib.request as _scoot_urlreq\n'
        + '                for _scoot_probe in ("https://cache.nixos.org/nix-cache-info", "https://scoot-sh.cachix.org/nix-cache-info"):\n'
        + '                    try:\n'
        + '                        if _scoot_urlreq.urlopen(_scoot_probe, timeout=8).read(32):\n'
        + '                            scoot_netmode = "online"\n'
        + '                            break\n'
        + '                    except Exception:\n'
        + '                        pass\n'
        + '            except Exception:\n'
        + '                pass\n'
        + '        libcalamares.utils.debug("scoot install network mode: " + scoot_netmode)\n'
        + '        if scoot_netmode != "online":\n'
        + '            _scoot_ev = subprocess.run(["nix", "eval", "--offline", "--option", "substitute", "false", "--no-write-lock-file", "--raw", scoot_flake_dir + "#nixosConfigurations.scoot.config.system.build.toplevel"], capture_output=True, text=True)\n'
        + '            if _scoot_ev.returncode != 0:\n'
        + '                return (_("scoot install needs the network"), _("The network is down and the installed system could not be evaluated from the ISO ({}). The target partitions are already formatted and the configuration is written, but no system was installed and nothing is bootable yet. Connect to the network and run the installer again.").format((_scoot_ev.stderr or "")[-500:]))\n'
        + '            scoot_toplevel = _scoot_ev.stdout.strip().split()[-1]\n'
        + '            try:\n'
        + '                _scoot_pi = subprocess.run(["nix", "path-info", "-r", "--offline", scoot_toplevel], capture_output=True, text=True)\n'
        + '                if _scoot_pi.returncode != 0:\n'
        + '                    raise subprocess.CalledProcessError(_scoot_pi.returncode, "nix path-info")\n'
        + '                scoot_closure = [p for p in _scoot_pi.stdout.split() if p.startswith("/nix/store/")]\n'
        + '                scoot_missing = [p for p in scoot_closure if not os.path.exists(p)]\n'
        + '            except subprocess.CalledProcessError:\n'
        + '                scoot_missing = [scoot_toplevel]\n'
        + '                try:\n'
        + '                    _scoot_dry = subprocess.run(["nix", "build", "--dry-run", "--offline", "--option", "substitute", "false", "--no-link", scoot_flake_dir + "#nixosConfigurations.scoot.config.system.build.toplevel"], capture_output=True, text=True, timeout=300)\n'
        + '                    for _scoot_line in ((_scoot_dry.stderr or "") + "\\n" + (_scoot_dry.stdout or "")).splitlines():\n'
        + '                        _scoot_line = _scoot_line.strip()\n'
        + '                        if _scoot_line.startswith("/nix/store/") and _scoot_line.endswith(".drv"):\n'
        + '                            try:\n'
        + '                                _scoot_show = subprocess.run(["nix", "derivation", "show", _scoot_line], capture_output=True, text=True, timeout=120)\n'
        + '                                for _scoot_out in re.findall(r"/nix/store/[a-z0-9]+-[^\\"\\s]+", _scoot_show.stdout or ""):\n'
        + '                                    if _scoot_out not in scoot_missing and not os.path.exists(_scoot_out):\n'
        + '                                        scoot_missing.append(_scoot_out)\n'
        + '                            except Exception:\n'
        + '                                pass\n'
        + '                except Exception:\n'
        + '                    pass\n'
        + '            if scoot_missing:\n'
        + '                scoot_shown = ", ".join(sorted(scoot_missing)[:8])\n'
        + '                if len(scoot_missing) > 8:\n'
        + '                    scoot_shown += " (and {} more)".format(len(scoot_missing) - 8)\n'
        + '                return (_("scoot install needs the network"), _("The network is down and this system needs {} store paths that are not on the ISO ({}). The target partitions are already formatted and the configuration is written, but no system was installed and nothing is bootable yet. Connect to the network and run the installer again.").format(len(scoot_missing), scoot_shown))\n'
        + '            subprocess.check_output(["nix", "flake", "archive", "--to", root_mount_point, "--offline", "--no-check-sigs", scoot_flake_dir], stderr=subprocess.STDOUT)\n'
        + '            subprocess.check_output(["nix", "copy", "--to", root_mount_point, "--no-check-sigs", scoot_toplevel], stderr=subprocess.STDOUT)\n'
        + "        nixosInstallCmd.extend(\n"
        + "            [\n"
        + '                "--flake",\n'
        + '                scoot_flake_ref,\n'
        + '                "--no-write-lock-file",\n'
        + '                "--no-channel-copy",\n'
        + "            ]\n"
        + "        )\n"
        + '        if scoot_netmode != "online":\n'
        + '            nixosInstallCmd.extend(["--option", "substitute", "false"])\n'
    )
    main_py = replace_once(main_py, anchor_cmd, cmd_patch, "install command")

    # 4. After a successful install, hand the home-folder tree to its
    # user. The repo is committed root-owned (so nix reads it as root
    # during install without tripping libgit2 ownership validation) and
    # only now chowned to the pinned uid/gid. System-wide installs stay
    # root-owned and need nothing here.
    post_anchor = '    libcalamares.job.setprogress(INSTALL_PROGRESS_END)\n    return None\n'
    post_block = (
        '    scoot_post_choice = gs.value("packagechooser_packagechooser")\n'
        '    if scoot_post_choice in ' + repr(sorted(SCOOT_LOOKS)) + ':\n'
        '        scoot_post_loc = gs.value("packagechooser_scoot-location")\n'
        '        if scoot_post_loc not in ("home", "system"):\n'
        '            scoot_post_loc = "home"\n'
        '        scoot_post_user = variables.get("username")\n'
        '        if scoot_post_loc == "home" and not scoot_post_user:\n'
        '            scoot_post_loc = "system"\n'
        '        if scoot_post_loc == "home":\n'
        '            subprocess.check_output(["chown", "-R", "1000:100", os.path.join(root_mount_point, "home", scoot_post_user)])\n'
        + post_anchor
    )
    main_py = replace_once(main_py, post_anchor, post_block, "post-install chown")

    with open(out_main, "w") as f:
        f.write(main_py)
    with open(out_packagechooser, "w") as f:
        f.write(chooser)
    with open(out_settings, "w") as f:
        f.write(settings)
    with open(out_location, "w") as f:
        f.write(location_text)
    with open(out_netprobe, "w") as f:
        f.write(netprobe_text)


if __name__ == "__main__":
    main()
