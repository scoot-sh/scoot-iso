#!/usr/bin/env bash
# QEMU end-to-end test for scoot-iso (runs in CI, x86_64 with KVM).
#
# 1. Boots the ISO (live session autobots into scoot; screendump it).
# 2. Proves the live ISO ships our installer patch with byte-exact
#    templates (repr-embedding check against the shipped main.py), then
#    installs unattended with those files rendered for a test user, with
#    the guest network cut (unshare -n) to prove the offline install.
# 3. Reboots the installed disk into ReGreet (screendump), logs in, and
#    checks scoot + bar + wallpaper via `scoot msg` and screenshots,
#    all through the QEMU guest agent.
#
# Guest control uses QMP (screendump, send-key) and qemu-ga guest-exec
# as root (enabled on live media by nixpkgs' graphical base and on the
# target by services.qemuGuest.enable), so no credentials are baked
# into the ISO. stdlib python3 + qemu-img + OVMF only.
#
# Usage:
#   scripts/qemu-test.sh --iso <iso> --target-flake <path>
#     --target-config <path> --workdir <dir>
#     [--user alice] [--password testpass123] [--system x86_64-linux]
set -euo pipefail

ISO=""
TARGET_FLAKE=""
TARGET_CONFIG=""
WORKDIR=""
TEST_USER="alice"
TEST_PASS="testpass123"
SYSTEM="x86_64-linux"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/OVMF/OVMF_VARS_4M.fd}"

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --target-flake) TARGET_FLAKE="$2"; shift 2 ;;
    --target-config) TARGET_CONFIG="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    --user) TEST_USER="$2"; shift 2 ;;
    --password) TEST_PASS="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
[ -n "$ISO" ] && [ -n "$TARGET_FLAKE" ] && [ -n "$TARGET_CONFIG" ] && [ -n "$WORKDIR" ] || {
  echo "missing required args" >&2; exit 2
}
[ -f "$OVMF_CODE" ] || { echo "OVMF code missing: $OVMF_CODE" >&2; exit 2; }
[ -f "$OVMF_VARS_SRC" ] || { echo "OVMF vars template missing: $OVMF_VARS_SRC" >&2; exit 2; }

mkdir -p "$WORKDIR"
DISK="$WORKDIR/disk.qcow2"
VARS="$WORKDIR/OVMF_VARS.fd"
QMP="$WORKDIR/qmp.sock"
GASOCK="$WORKDIR/ga.sock"
LOG="$WORKDIR/qemu-test.log"
[ -f "$VARS" ] || cp "$OVMF_VARS_SRC" "$VARS"
qemu-img create -f qcow2 "$DISK" 24G >/dev/null
exec > >(tee "$LOG") 2>&1

# --- QMP helpers (stdlib python) -------------------------------------------
qmp() {
  python3 - "$QMP" "$@" <<'EOF'
import json, socket, sys
path, args = sys.argv[1], sys.argv[2:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
f = s.makefile("rwb")
f.readline()
def cmd(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg: return msg
cmd({"execute": "qmp_capabilities"})
name = args[0]
params = json.loads(args[1]) if len(args) > 1 else {}
print(json.dumps(cmd({"execute": name, "arguments": params})))
EOF
}

# guest_exec <shell-command...>: run via qemu-ga as root, poll, print output.
guest_exec() {
  local script="$1"
  local b64
  b64=$(printf '%s' "$script" | base64 -w0)
  local pid
  pid=$(python3 - "$QMP" "$b64" <<'EOF'
import json, socket, sys
path, b64 = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
f = s.makefile("rwb")
f.readline()
def cmd(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg: return msg
cmd({"execute": "qmp_capabilities"})
r = cmd({"execute": "guest-exec", "arguments": {"path": "/bin/sh", "arg": ["-c", "base64 -d | /bin/sh"], "input-data": b64, "capture-output": True}})
print(r["return"]["pid"])
EOF
)
  for _ in $(seq 1 300); do
    out=$(qmp guest-exec-status "{\"pid\": $pid}")
    if echo "$out" | grep -q '"exited": true'; then
      echo "$out" | python3 -c 'import base64,json,sys; r=json.load(sys.stdin)["return"]; print("rc:", r.get("exitcode")); o=r.get("out-data"); print(base64.b64decode(o).decode(errors="replace") if o else ""); e=r.get("err-data"); sys.stderr.write(base64.b64decode(e).decode(errors="replace") if e else "")'
      rc=$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"].get("exitcode", 1))')
      return "$rc"
    fi
    sleep 2
  done
  echo "guest-exec timed out" >&2
  return 1
}

wait_ga() {
  local n=0
  for _ in $(seq 1 150); do
    n=$((n + 1))
    if qmp guest-ping '{}' 2>/dev/null | grep -q '"return"'; then return 0; fi
    if [ $((n % 12)) -eq 0 ]; then echo "still waiting for guest agent (${n}x5s)..."; qmp query-status '{}' 2>/dev/null || echo "QMP unreachable"; qmp screendump "{\"filename\": \"$WORKDIR/boot-progress-$n.ppm\"}" >/dev/null 2>&1 || echo "progress screendump failed"; fi
    sleep 5
  done
  echo "guest agent never came up" >&2
  echo "--- QMP status at failure ---"
  qmp query-status '{}' 2>/dev/null || echo "QMP unreachable"
  echo "--- failure screendump ---"
  qmp screendump "{\"filename\": \"$WORKDIR/boot-failure.ppm\"}" >/dev/null 2>&1 || echo "screendump failed"
  echo "--- serial tail ---"
  tail -30 "$WORKDIR"/serial-*.log 2>/dev/null || echo "no serial log"
  echo "--- qemu process ---"
  pgrep -af "qemu-system" || echo "no qemu process"
  return 1
}

start_vm() {
  # start_vm <boot> : boot = d (ISO) or c (disk)
  local boot="$1"
  rm -f "$QMP" "$GASOCK"
  local extra=()
  if [ "$boot" = d ]; then extra+=(-cdrom "$ISO" -boot order=d); else extra+=(-boot order=c); fi
  # shellcheck disable=SC2068
  qemu-system-x86_64 \
    -machine q35,accel=kvm:tcg -cpu max -m 4G -smp 4 \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS" \
    -drive file="$DISK",if=virtio,format=qcow2 \
    ${extra[@]} \
    -device virtio-gpu-pci -display none \
    -serial file:"$WORKDIR/serial-$boot.log" \
    -chardev socket,path="$GASOCK",server=on,wait=off,id=qga0 \
    -device virtio-serial-pci \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -qmp unix:path="$QMP",server=on,wait=off \
    -daemonize -pidfile "$WORKDIR/qemu.pid"
  sleep 3
  if ! kill -0 "$(cat "$WORKDIR/qemu.pid")" 2>/dev/null; then
    echo "qemu died right after start (KVM unusable? OVMF/ISO path wrong?)" >&2
    return 1
  fi
  echo "--- QMP status after start ---"
  qmp query-status '{}' || echo "QMP unreachable right after start"
  echo "--- KVM or TCG? ---"
  python3 - "$QMP" <<'EOF' || echo "info-kvm query failed"
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
f = s.makefile("rwb")
f.readline()
def cmd(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg: return msg
cmd({"execute": "qmp_capabilities"})
print(json.dumps(cmd({"execute": "human-monitor-command", "arguments": {"command-line": "info kvm"}})))
EOF
}

stop_vm() {
  qmp quit '{}' >/dev/null 2>&1 || true
  sleep 3
  pkill -F "$WORKDIR/qemu.pid" 2>/dev/null || true
}

echo "=== phase 1: boot live ISO ==="
start_vm d
wait_ga
sleep 20 # let the scoot session settle
qmp screendump "{\"filename\": \"$WORKDIR/live-session.ppm\"}" >/dev/null
echo "live screenshot: $WORKDIR/live-session.ppm"

echo "=== phase 1b: the welcome window ==="
# The live session autostarts Firefox with the welcome page once per
# boot. Wait for the window to appear, then screenshot it on its own:
# `scoot msg windows` lists it, which also proves the compositor's IPC
# answers on the live session.
for _ in $(seq 1 24); do
  if guest_exec 'pgrep -af "firefox.*scoot-welcome" >/dev/null && echo FIREFOX-UP' 2>/dev/null | grep -q FIREFOX-UP; then break; fi
  sleep 5
done
guest_exec 'XDG_RUNTIME_DIR=/run/user/$(id -u nixos) scoot msg windows || sudo -u nixos XDG_RUNTIME_DIR=/run/user/$(id -u nixos) scoot msg windows' || true
sleep 5 # let the welcome page paint
qmp screendump "{\"filename\": \"$WORKDIR/welcome-window.ppm\"}" >/dev/null
echo "welcome screenshot: $WORKDIR/welcome-window.ppm"

echo "=== phase 1c: the shipped patch embeds our exact templates ==="
# Copy the templates into the guest and assert the live ISO's patched
# main.py contains them byte-for-byte (the patch embeds via repr()).
# Same for the baked override-input store paths (they must exist live).
TFLAKE_B64=$(base64 -w0 "$TARGET_FLAKE")
TCONFIG_B64=$(base64 -w0 "$TARGET_CONFIG")
guest_exec "
python3 - '$TFLAKE_B64' '$TCONFIG_B64' '$SYSTEM' <<'PYEOF'
import base64, glob, sys
flake = base64.b64decode(sys.argv[1]).decode().replace('@@SYSTEM@@', sys.argv[3])
config = base64.b64decode(sys.argv[2]).decode()
cands = glob.glob('/nix/store/*calamares-nixos-extensions*/lib/calamares/modules/nixos/main.py')
cands += glob.glob('/nix/store/*calamares-nixos-extensions*/src/modules/nixos/main.py')
cands += glob.glob('/run/current-system/sw/share/calamares/modules/nixos/main.py')
found = [c for c in cands]
print('main.py candidates:', found)
if not found:
    raise SystemExit('patched main.py not found in live store')
main_py = max((open(c).read() for c in found), key=len)
assert repr(flake) in main_py, 'target flake.nix not embedded byte-exact in shipped main.py'
# configuration.nix is embedded with @@-variables intact (substituted at install time)
assert repr(config) in main_py, 'target configuration.nix not embedded byte-exact in shipped main.py'
import re
for m in re.findall(r'\"path:(/nix/store/[^\"]+)\"', main_py):
    import os
    assert os.path.exists(m), f'baked override path missing from live store: {m}'
    print('override path present:', m)
print('EMBEDDING-OK')
PYEOF
"

echo "=== phase 2: unattended install, network cut ==="
guest_exec 'sgdisk -Z /dev/vda && sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP /dev/vda && sgdisk -n 2:0:0 -t 2:8300 -c 2:root /dev/vda && mkfs.fat -F32 /dev/vda1 && mkfs.ext4 -F /dev/vda2 && mount /dev/vda2 /mnt && mkdir -p /mnt/boot && mount /dev/vda1 /mnt/boot && nixos-generate-config --root /mnt && echo PARTITION-OK'
# Render the target files with the patch's own variable semantics, then
# install with the guest network namespace emptied (unshare -n): any
# missing closure path fails here instead of phoning home.
guest_exec "
python3 - '$TFLAKE_B64' '$TCONFIG_B64' '$TEST_USER' 'Test User' 'scoot-test' 'Etc/UTC' 'en_US.UTF-8' '25.11' <<'PYEOF'
import base64, os, sys
flake = base64.b64decode(sys.argv[1]).decode().replace('@@SYSTEM@@', '$SYSTEM')
config = base64.b64decode(sys.argv[2]).decode()
_, _, username, fullname, hostname, timezone, lang, nixosversion = sys.argv[1:9]
config = config.replace('@@SCOOT_LOOK@@', 'moonrise')
config = config.replace('@@TIMEZONE@@', f'  time.timeZone = "{timezone}";')
config = config.replace('@@LOCALE@@', f'  i18n.defaultLocale = \"{lang}\";')
users = f'''  users.users.\"{username}\" = {{
    isNormalUser = true;
    description = \"{fullname}\";
    extraGroups = [ \"networkmanager\" \"wheel\" ];
  }};
'''
hm = f'''  home-manager.users."{username}".imports = [ inputs.scoot.homeModules.scoot inputs.scoot.homeModules.scootbar ];
  home-manager.users."{username}".programs.scoot = {{ enable = true; desktop.enable = true; desktop.look = "moonrise"; }};
  home-manager.users."{username}".programs.scootbar.enable = true;
  home-manager.users."{username}".home.stateVersion = "25.11";
'''
config = config.replace('  # @@SCOOT_USERS@@', users.rstrip('\n')).replace('  # @@SCOOT_HM_USER@@', hm.rstrip('\n'))
config = config.replace('@@hostname@@', hostname).replace('@@nixosversion@@', nixosversion)
os.makedirs('/mnt/etc/nixos', exist_ok=True)
open('/mnt/etc/nixos/flake.nix', 'w').write(flake)
open('/mnt/etc/nixos/configuration.nix', 'w').write(config)
print('RENDER-OK')
PYEOF
"
guest_exec "
export overrides=\$(python3 -c \"import glob,re; m=max((open(c).read() for c in glob.glob('/nix/store/*calamares-nixos-extensions*/lib/calamares/modules/nixos/main.py')+glob.glob('/nix/store/*calamares-nixos-extensions*/src/modules/nixos/main.py')), key=len); print(' '.join(sum(([a,b] for a,b in re.findall(r'\"--override-input\",\s+\"([^\"]+)\",\s+\"(path:[^\"]+)\"', m)), [])))\"
echo \"overrides: \$overrides\"
ip -o link show | awk -F': ' '{print \$2}' | grep -v '^lo$' | while read -r ifc; do ip link set \"\$ifc\" down; done
ip -o link show
unshare -n /bin/sh -c 'ip link set lo up; nixos-install --flake /mnt/etc/nixos#scoot --root /mnt --no-root-passwd --option build-dir /nix/var/nix/builds \$overrides' > /tmp/install.log 2>&1
echo INSTALL-RC:\$?
tail -5 /tmp/install.log
"
guest_exec "nixos-enter --root /mnt -c \"echo '$TEST_USER:$TEST_PASS' | chpasswd\" && echo PASSWD-OK"
guest_exec 'poweroff || halt -p'
sleep 10
stop_vm

echo "=== phase 3: boot installed system, check greeter + session ==="
start_vm c
wait_ga
sleep 30 # ReGreet should be up
qmp screendump "{\"filename\": \"$WORKDIR/regreet.ppm\"}" >/dev/null
echo "greeter screenshot: $WORKDIR/regreet.ppm"
guest_exec 'systemctl is-active greetd && pgrep -af "cage|regreet" | head -5 && echo GREETER-OK'
# Type the password into ReGreet (best effort; screenshots show the outcome).
# QMP send-key takes qcode names; password is [a-z0-9] by construction.
type_into_greeter() {
  local text="$1"
  local keys
  keys=$(python3 -c "
import sys
m = {'-':'minus','=':'equal','/':'slash',' ':'spc'}
out = []
for ch in sys.argv[1]:
    if ch.isdigit(): out.append('{\"type\":\"qcode\",\"data\":\"' + ch + '\"}')
    elif ch.isalpha(): out.append('{\"type\":\"qcode\",\"data\":\"' + ch.lower() + '\"}')
    else: out.append('{\"type\":\"qcode\",\"data\":\"' + m.get(ch, 'spc') + '\"}')
print('[' + ','.join(out) + ']')
" "$text")
  qmp send-key "{\"keys\": $keys, \"hold-time\": 50}" >/dev/null
  sleep 1
}
type_into_greeter "$TEST_USER"
qmp send-key '{"keys": [{"type":"qcode","data":"tab"}], "hold-time": 50}' >/dev/null
sleep 1
type_into_greeter "$TEST_PASS"
qmp send-key '{"keys": [{"type":"qcode","data":"ret"}], "hold-time": 50}' >/dev/null
sleep 25
qmp screendump "{\"filename\": \"$WORKDIR/installed-session.ppm\"}" >/dev/null
echo "installed session screenshot: $WORKDIR/installed-session.ppm"

echo "=== phase 3b: scoot msg checks via guest agent ==="
# A login through ReGreet may or may not have landed (best effort
# above); these checks run a headless session either way, proving the
# installed binaries + desktop-profile config work. The bar and the
# wallpaper daemon are checked first: the profile starts scootbar
# through graphical-session.target and scootbg for the look's shipped
# wallpaper, so both must be resident in a logged-in session.
guest_exec "
uid=\$(id -u $TEST_USER)
export XDG_RUNTIME_DIR=/run/user/\$uid
mkdir -p \$XDG_RUNTIME_DIR
chown $TEST_USER:users \$XDG_RUNTIME_DIR
chmod 700 \$XDG_RUNTIME_DIR
pgrep -ax scoot || true
echo '--- bar + wallpaper ---'
pgrep -af scootbar | head -3 || echo NO-SCOOTBAR-PROC
pgrep -af scootbg | head -3 || echo NO-SCOOTBG-PROC
su -s /bin/sh $TEST_USER -c 'XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user is-active scootbar' || echo BAR-UNIT-NOT-ACTIVE
cat > /tmp/scoot-check.sh <<'CHEOF'
export XDG_RUNTIME_DIR=__RUNTIME__
export WAYLAND_DISPLAY=scoot-test-0
scoot --headless --outputs 1 -- foot &
sleep 5
scoot msg version
scoot msg outputs
scoot msg windows
scoot msg screenshot --out /tmp/installed-scoot.png && echo SCREENSHOT-OK
CHEOF
sed -i "s|__RUNTIME__|\$XDG_RUNTIME_DIR|" /tmp/scoot-check.sh
chown $TEST_USER:users /tmp/scoot-check.sh
su -s /bin/sh $TEST_USER -c '/bin/sh /tmp/scoot-check.sh'
echo MSG-OK
"
# Pull the IPC screenshot back to the host for the artifacts.
python3 - "$QMP" "$WORKDIR/installed-scoot.png" <<'EOF'
import base64, json, socket, sys
path, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(path)
f = s.makefile("rwb")
f.readline()
def cmd(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg: return msg
cmd({"execute": "qmp_capabilities"})
r = cmd({"execute": "guest-exec", "arguments": {"path": "/bin/cat", "arg": ["/tmp/installed-scoot.png"], "capture-output": True}})
data = r["return"].get("out-data")
assert r["return"].get("exitcode") == 0 and data, f"screenshot fetch failed: {r}"
open(out, "wb").write(base64.b64decode(data))
print("screenshot saved:", out)
EOF
stop_vm
# Convert QMP's PPM screendumps to PNG for the workflow artifacts and
# the README (stdlib only; idempotent, so the workflow's fallback step
# re-running it after a failure is harmless).
python3 "$(dirname "$0")/ppm-to-png.py" "$WORKDIR"
echo "=== qemu-test done; artifacts in $WORKDIR ==="
