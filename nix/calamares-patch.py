#!/usr/bin/env python3
"""Splice the scoot choice into calamares-nixos-extensions at ISO build time.

The scoot choice writes a flake-based target (flake.nix +
configuration.nix from this repo) and installs it with
`nixos-install --flake ... --override-input ... path:<ISO store>`, so
install works with the network cut. Everything else (hostname, user,
timezone, locale, firefox) mirrors the stock classic path's variables.

Every anchor is asserted to occur exactly once, so a nixpkgs re-pin that
changes the upstream files fails the ISO build loudly instead of silently
dropping scoot. Never touches upstream: the patch is carried in this repo.

Usage:
  calamares-patch.py <ext-src> <target-flake> <target-config> \\
      <packagechooser-item> <nixpkgs-store> <scoot-store> <hm-store> \\
      <system> <out-main.py> <out-packagechooser.conf>
"""

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
  # Define the user account created during install.
  users.users."@@username@@" = {
    isNormalUser = true;
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


def main() -> None:
    (
        ext_src,
        target_flake,
        target_config,
        item_file,
        nixpkgs_store,
        scoot_store,
        hm_store,
        system,
        out_main,
        out_packagechooser,
    ) = sys.argv[1:]

    with open(f"{ext_src}/src/modules/nixos/main.py") as f:
        main_py = f.read()
    with open(f"{ext_src}/src/config/modules/packagechooser.conf") as f:
        chooser = f.read()
    with open(target_flake) as f:
        flake_text = f.read()
    with open(target_config) as f:
        config_text = f.read()
    with open(item_file) as f:
        item_text = f.read()

    if "@@SYSTEM@@" not in flake_text:
        raise SystemExit("target flake.nix lost its @@SYSTEM@@ placeholder")
    flake_baked = flake_text.replace("@@SYSTEM@@", system)
    if "@@SYSTEM@@" in flake_baked:
        raise SystemExit("target flake.nix still has an unsubstituted @@SYSTEM@@")

    for placeholder in ("@@TIMEZONE@@", "@@LOCALE@@", "@@SCOOT_USERS@@", "@@SCOOT_HM_USER@@", "@@SCOOT_LOOK@@"):
        if placeholder not in config_text:
            raise SystemExit(f"target configuration.nix lost {placeholder}")
    if "@@SCOOT_LOOK@@" in flake_baked:
        raise SystemExit("target flake.nix must not contain @@SCOOT_LOOK@@")

    # 1. The desktop list: the four scoot looks first, moonrise default
    # selected. One entry per look (packagechooser is single-select, so
    # the look rides the desktop id: scoot-<look>).
    chooser = replace_once(chooser, "default: gnome", f"default: {SCOOT_DEFAULT}", "chooser default")
    chooser = replace_once(chooser, "items:", f"items:\n{item_text}", "chooser items")
    for item_id in SCOOT_LOOKS:
        if f"- id: {item_id}" not in chooser:
            raise SystemExit(f"packagechooser item {item_id} missing after splice")

    # 2. When scoot is chosen, write our flake files instead of the
    # classic configuration.nix. The stock `variables` dict (hostname,
    # username, locale, nixosversion, ...) is reused with the same
    # fallbacks as the classic path.
    anchor_write = '    libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", config], None, cfg)\n'
    writer = (
        '    scoot_choice = gs.value("packagechooser_packagechooser")\n'
        '    scoot_looks = ' + repr(SCOOT_LOOKS) + '\n'
        '    if scoot_choice in scoot_looks:\n'
        '        scoot_look = scoot_looks[scoot_choice]\n'
        "        scoot_config_text = " + repr(config_text) + "\n"
        "        scoot_flake_text = " + repr(flake_baked) + "\n"
        '        scoot_vars = dict(variables)\n'
        '        scoot_vars.setdefault("hostname", "nixos")\n'
        '        scoot_config_text = scoot_config_text.replace("@@SCOOT_LOOK@@", scoot_look)\n'
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
        '        libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", config], None, scoot_config_text)\n'
        '        flake_config = os.path.join(root_mount_point, "etc/nixos/flake.nix")\n'
        '        libcalamares.utils.host_env_process_output(["cp", "/dev/stdin", flake_config], None, scoot_flake_text)\n'
        "    else:\n"
        "        " + anchor_write.lstrip()
    )
    main_py = replace_once(main_py, anchor_write, writer, "target writer")

    # 3. Install the flake choice with baked override inputs (offline:
    # the inputs resolve to the ISO store, whose target closure ships in
    # isoImage.storeContents).
    anchor_cmd = (
        '            "--option",\n'
        '            "build-dir",\n'
        '            "/nix/var/nix/builds",\n'
        "        ]\n"
        "    )\n"
    )
    cmd_patch = (
        anchor_cmd
        + '    if gs.value("packagechooser_packagechooser") in '
        + repr(sorted(SCOOT_LOOKS)) + ':\n'
        + "        nixosInstallCmd.extend(\n"
        + "            [\n"
        + '                "--flake",\n'
        + '                root_mount_point + "/etc/nixos#scoot",\n'
        + '                "--override-input",\n'
        + '                "nixpkgs",\n'
        + f'                "path:{nixpkgs_store}",\n'
        + '                "--override-input",\n'
        + '                "scoot",\n'
        + f'                "path:{scoot_store}",\n'
        + '                "--override-input",\n'
        + '                "home-manager",\n'
        + f'                "path:{hm_store}",\n'
        + "            ]\n"
        + "        )\n"
    )
    main_py = replace_once(main_py, anchor_cmd, cmd_patch, "install command")

    with open(out_main, "w") as f:
        f.write(main_py)
    with open(out_packagechooser, "w") as f:
        f.write(chooser)


if __name__ == "__main__":
    main()
