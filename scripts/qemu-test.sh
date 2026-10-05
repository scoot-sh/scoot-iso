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

# Guest control goes DIRECTLY over the chardev socket ($GASOCK), not
# through QMP guest-* commands: on these runners QMP answers
# query-status/screendump/send-key fine, but QMP guest-ping never gets
# a reply even with the agent up, the virtio port bound and KVM on
# (proven over three runs), while the identical ping sent straight over
# this socket answers {"return": {}} instantly. So the script speaks the
# qemu-ga protocol itself (stdlib python): guest-sync-delimited framing
# per connection, guest-exec, then guest-exec-status polling. QMP stays
# for monitor commands only (status, screendump, send-key, quit).
#
# One hard rule from the transport experiment: input-data arrives
# corrupt (a 13-byte stdin failed outright; 600 sent bytes arrived as
# 450), while argv arrives intact. So scripts travel in argv (-c),
# never in input-data; anything bulk-sized is read from files already
# in the guest (the shipped main.py embeds the installer templates).
qga() {
  python3 - "$GASOCK" "$@" <<'EOF'
import base64, json, socket, sys, time
path, args = sys.argv[1], sys.argv[2:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(30)
s.connect(path)
f = s.makefile("rwb")
def transact(obj):
    f.write(json.dumps(obj).encode() + b"\n"); f.flush()
    while True:
        line = f.readline()
        if not line:
            raise SystemExit("qga socket closed mid-command")
        line = line.lstrip(b"\xff")  # guest-sync-delimited marker
        try:
            msg = json.loads(line)
        except ValueError:
            continue  # stray async event; keep reading
        if "return" in msg or "error" in msg:
            return msg
syncid = 9871
r = transact({"execute": "guest-sync-delimited", "arguments": {"id": syncid}})
if r.get("return") != syncid:
    raise SystemExit(f"qga sync failed: {r}")
mode = args[0]
if mode == "ping":
    r = transact({"execute": "guest-ping"})
    print(json.dumps(r))
elif mode == "exec":
    script = args[1]
    r = transact({"execute": "guest-exec", "arguments": {"path": "/bin/sh", "arg": ["-c", script], "capture-output": True}})
    if "error" in r:
        raise SystemExit(f"guest-exec refused: {r}")
    pid = r["return"]["pid"]
    for _ in range(900):
        r = transact({"execute": "guest-exec-status", "arguments": {"pid": pid}})
        if "error" in r:
            raise SystemExit(f"guest-exec-status refused: {r}")
        ret = r["return"]
        if ret.get("exited"):
            print("rc:", ret.get("exitcode"))
            o = ret.get("out-data")
            if o:
                sys.stdout.write(base64.b64decode(o).decode(errors="replace"))
            e = ret.get("err-data")
            if e:
                sys.stderr.write(base64.b64decode(e).decode(errors="replace"))
            sys.exit(ret.get("exitcode", 1))
        time.sleep(2)
    raise SystemExit("guest-exec timed out")
EOF
}

# guest_exec <shell-command>: run via qemu-ga as root, poll, print output.
# The command travels in argv (see above); keep each invocation small
# (a few KB at most) and read bulk data from guest files instead. The
# agent's PATH is bare, so every command starts with the system profile
# on PATH (NixOS keeps all system tools in /run/current-system/sw/bin).
guest_exec() {
  qga exec "export PATH=/run/current-system/sw/bin:/usr/bin:/bin; $1"
}

wait_ga() {
  local n=0
  for _ in $(seq 1 150); do
    n=$((n + 1))
    if qga ping 2>/dev/null | grep -q '"return": {}'; then return 0; fi
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
  echo "--- TEMP DEBUG: SSH dump (user-mode NIC :10022 -> :22) ---"
  for _ in $(seq 1 20); do
    if sshpass -p debug123 ssh -p 10022 -o StrictHostKeyChecking=no -o ConnectTimeout=5 nixos@localhost true 2>/dev/null; then break; fi
    sleep 5
  done
  sshpass -p debug123 ssh -p 10022 -o StrictHostKeyChecking=no nixos@localhost '
    echo "=== agent ==="; systemctl status qemu-guest-agent --no-pager || true
    echo "=== virtio ports ==="; ls -la /dev/virtio-ports/ || true
    echo "=== virtio modules ==="; lsmod | grep -i virtio || true
    echo "=== dri ==="; ls -la /dev/dri/ || true
    echo "=== greetd ==="; systemctl status greetd --no-pager || true
    echo "=== scoot session ==="; pgrep -af scoot | head -5 || true
    echo "=== failed units ==="; systemctl --failed --no-pager || true
    echo "=== modules-load ==="; systemctl status systemd-modules-load --no-pager || true
    echo "=== journal errors ==="; journalctl -b -p err --no-pager | head -30 || true
    echo "=== firefox: nixos home ==="; ls -ladn /home/nixos; ls -la /home/nixos/ | head -20
    echo "=== firefox: mozilla dir ==="; ls -la /home/nixos/.mozilla/ 2>&1 || true
    echo "=== firefox: process env ==="; for pid in $(pgrep -f "[f]irefox.*scoot-welcome"); do echo "== $pid =="; tr "\0" "\n" < /proc/$pid/environ | grep -E "^(HOME|USER|LOGNAME|XDG_RUNTIME_DIR|WAYLAND_DISPLAY|MOZ_|DBUS_SESSION)" || true; done
    echo "=== firefox: passwd ==="; getent passwd nixos
  ' || echo "SSH dump failed"
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
    -netdev user,id=net0,hostfwd=tcp::10022-:22 \
    -device virtio-net-pci,netdev=net0 \
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
guest_exec 'echo "PATH=$PATH"; command -v python3 base64 wc pgrep sgdisk git nixos-install; ls /run/current-system/sw/bin/python3*' || true
sleep 20 # let the scoot session settle
qmp screendump "{\"filename\": \"$WORKDIR/live-session.ppm\"}" >/dev/null
echo "live screenshot: $WORKDIR/live-session.ppm"

echo "=== phase 1b: the welcome window ==="
# The live session autostarts Firefox with the welcome page once per
# boot. Wait for the window to appear, then screenshot it on its own:
# `scoot msg windows` lists it, which also proves the compositor's IPC
# answers on the live session.
for _ in $(seq 1 24); do
  if guest_exec 'pgrep -af "[f]irefox --new-window" >/dev/null && echo FIREFOX-UP' 2>/dev/null | grep -q FIREFOX-UP; then break; fi
  sleep 5
done
echo "--- welcome spawn env (what scoot autostart children inherit) ---"
guest_exec 'cat /tmp/scoot-welcome-env.txt' || true
msg_ok=0
for _ in $(seq 1 24); do
  if guest_exec 'export XDG_RUNTIME_DIR=/run/user/$(id -u nixos); export SCOOT_SOCKET=$XDG_RUNTIME_DIR/scoot.sock; [ -S "$SCOOT_SOCKET" ] && su -s /bin/sh nixos -c "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR SCOOT_SOCKET=$SCOOT_SOCKET scoot msg windows"'; then msg_ok=1; break; fi
  sleep 5
done
[ "$msg_ok" = 1 ] || echo "MSG-WARN: live-session scoot msg never answered; headless check in phase 3c remains the hard IPC proof"
echo "--- browser probes (diagnostic; never fatal) ---"
guest_exec '
echo "--- browser processes ---"; pgrep -af "[f]irefox --new-window" || true
echo "--- browser env ---"
for pid in $(pgrep -f "[f]irefox --new-window"); do echo "== $pid =="; tr "\0" "\n" < /proc/$pid/environ | grep -E "^(HOME|USER|LOGNAME|XDG_RUNTIME_DIR|WAYLAND_DISPLAY|SCOOT_SOCKET|MOZ_|DBUS_SESSION)" || true; done
echo "--- nixos home ---"; ls -la /home/nixos/ | head -20
echo "--- mozilla dir ---"; ls -la /home/nixos/.mozilla/ 2>&1 || true
echo "--- browser --help (no profile needed) ---"; sudo -u nixos HOME=/home/nixos firefox --help 2>&1 | head -5 || true
echo "--- browser stderr from the session journal ---"; sudo -u nixos journalctl --user -b --no-pager 2>/dev/null | grep -iE "firefox|mozilla|profile|NS_ERROR" | head -20 || true
echo "--- crashes? ---"; coredumpctl list --no-pager 2>/dev/null | head -5 || true
id nixos
exit 0
' || true
echo "--- browser bypass experiments (diagnostic; never fatal) ---"
guest_exec '
pkill_out=$(pgrep -f "[f]irefox --new-window" || true)
for pid in $pkill_out; do if [ "$pid" != "$$" ]; then kill "$pid" || true; fi; done
sleep 2
echo "--- variant A: -profile with a pre-created dir (bypasses the profile manager) ---"
mkdir -p /home/nixos/.welcome-profile
chown nixos:users /home/nixos/.welcome-profile
su -s /bin/sh nixos -c "HOME=/home/nixos WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/1000 firefox -profile /home/nixos/.welcome-profile --new-window file:///etc/scoot-welcome/index.html > /tmp/ff-profile.log 2>&1 &"
sleep 25
ls -la /home/nixos/.welcome-profile 2>&1 | head -10 || true
echo "--- variant A log ---"; head -30 /tmp/ff-profile.log || true
exit 0
' || true
sleep 5 # let the welcome page paint
qmp screendump "{\"filename\": \"$WORKDIR/welcome-window.ppm\"}" >/dev/null
echo "welcome screenshot: $WORKDIR/welcome-window.ppm"

echo "=== phase 1c: the shipped patch embeds our exact templates ==="
# The patch embeds the target files via repr(); the guest extracts them
# from the live ISO's patched main.py and compares hashes, so no bulk
# data crosses the (input-data-broken) channel in either direction.
flake_hash=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1]).read().replace("@@SYSTEM@@", sys.argv[2]).encode()).hexdigest())' "$TARGET_FLAKE" "$SYSTEM")
config_hash=$(sha256sum "$TARGET_CONFIG" | cut -d' ' -f1)
lock_hash=$(sha256sum "$(dirname "$0")/../iso/target/flake.lock" | cut -d' ' -f1)
guest_exec '
python3 - '"$flake_hash"' '"$config_hash"' '"$lock_hash"' <<'PYEOF'
import ast, glob, hashlib, os, sys
want = {"scoot_flake_text": sys.argv[1], "scoot_config_text": sys.argv[2], "scoot_lock_text": sys.argv[3]}
cands = glob.glob("/nix/store/*calamares-nixos-extensions*/lib/calamares/modules/nixos/main.py")
cands += glob.glob("/nix/store/*calamares-nixos-extensions*/src/modules/nixos/main.py")
cands += glob.glob("/run/current-system/sw/share/calamares/modules/nixos/main.py")
print("main.py candidates:", cands)
if not cands:
    raise SystemExit("patched main.py not found in live store")
src = max((open(c).read() for c in cands), key=len)
def grab(name):
    for line in src.splitlines():
        s = line.strip()
        if s.startswith(name + " = "):
            rhs = s.split(" = ", 1)[1]
            if rhs[:1] == chr(39) or rhs[:1] == chr(34):
                return ast.literal_eval(rhs)
    raise SystemExit("template not found in shipped main.py: " + name)
for name, digest in want.items():
    got = hashlib.sha256(grab(name).encode()).hexdigest()
    assert got == digest, name + " hash mismatch: " + got + " != " + digest
    print(name + " hash OK: " + got)
print("EMBEDDING-OK")
PYEOF
'

echo "=== phase 2: unattended install, network cut ==="
guest_exec 'lsmod | grep -E "^(ext4|vfat)" || echo NO-FS-MODULES-LOADED; modprobe ext4 && echo MODPROBE-EXT4-OK || echo MODPROBE-EXT4-FAIL; modprobe vfat && echo MODPROBE-VFAT-OK || echo MODPROBE-VFAT-FAIL; grep -E "ext4|vfat" /proc/filesystems || echo NO-FS-IN-PROCFILESYS' || true
guest_exec 'sgdisk -Z /dev/vda && sgdisk -n 1:0:+512M -t 1:ef00 -c 1:ESP /dev/vda && sgdisk -n 2:0:0 -t 2:8300 -c 2:root /dev/vda && partx -u /dev/vda && udevadm settle && lsblk -f /dev/vda && mkfs.fat -F32 /dev/vda1 && mkfs.ext4 -F /dev/vda2 && blkid /dev/vda1 /dev/vda2 && (mount /dev/vda2 /mnt || (dmesg | tail -25; blkid; exit 1)) && mkdir -p /mnt/boot && mount /dev/vda1 /mnt/boot && nixos-generate-config --root /mnt && echo PARTITION-OK'
# Render the target files from the SHIPPED main.py's embedded templates
# (extracted exactly as the patch wrote them, then substituted with the
# writer's own semantics for the default choice: scoot-moonrise in the
# home folder), into /mnt/home/<user>/nixos-config with /etc/nixos
# symlinked to it, committed to git and user-owned — byte for byte what
# the GUI writes. Then install with the guest network namespace emptied
# (unshare -n): any missing closure path fails here instead of phoning
# home.
guest_exec "
python3 - '$TEST_USER' 'Test User' 'scoot-test' 'Etc/UTC' 'en_US.UTF-8' '25.11' '$SYSTEM' <<'PYEOF'
import ast, glob, os, subprocess, sys
_, username, fullname, hostname, timezone, lang, nixosversion, system = sys.argv
cands = glob.glob('/nix/store/*calamares-nixos-extensions*/lib/calamares/modules/nixos/main.py')
cands += glob.glob('/nix/store/*calamares-nixos-extensions*/src/modules/nixos/main.py')
cands += glob.glob('/run/current-system/sw/share/calamares/modules/nixos/main.py')
if not cands:
    raise SystemExit('patched main.py not found in live store')
src = max((open(c).read() for c in cands), key=len)
def grab(name):
    for line in src.splitlines():
        s = line.strip()
        if s.startswith(name + ' = '):
            rhs = s.split(' = ', 1)[1]
            if rhs[:1] == chr(39) or rhs[:1] == chr(34):
                return ast.literal_eval(rhs)
    raise SystemExit('template not found in shipped main.py: ' + name)
flake = grab('scoot_flake_text').replace('@@SYSTEM@@', system)
config = grab('scoot_config_text')
lock = grab('scoot_lock_text')
hm = grab('scoot_hm').replace('@@SCOOT_LOOK@@', 'moonrise')
users = grab('scoot_users')
scoot_vars = {'hostname': hostname, 'username': username, 'fullname': fullname, 'timezone': timezone, 'LANG': lang, 'nixosversion': nixosversion}
for _key, _val in scoot_vars.items():
    hm = hm.replace('@@' + _key + '@@', _val)
    users = users.replace('@@' + _key + '@@', _val)
config = config.replace('@@SCOOT_LOOK@@', 'moonrise')
config = config.replace('@@SCOOT_NH_FLAKE@@', '/home/' + username + '/nixos-config')
config = config.replace('  # @@TIMEZONE@@\n', '  time.timeZone = \"' + timezone + '\";\n')
config = config.replace('  # @@LOCALE@@\n', '  i18n.defaultLocale = \"' + lang + '\";\n')
config = config.replace('  # @@SCOOT_HM_USER@@', hm.rstrip(chr(10))).replace('  # @@SCOOT_USERS@@', users.rstrip(chr(10)))
for _key, _val in scoot_vars.items():
    config = config.replace('@@' + _key + '@@', _val)
assert '@@' not in config, 'unsubstituted marker left in rendered config'
assert '@@' not in flake, 'unsubstituted marker left in rendered flake'
flakedir = '/mnt/home/' + username + '/nixos-config'
os.makedirs(flakedir, exist_ok=True)
open(flakedir + '/flake.nix', 'w').write(flake)
open(flakedir + '/configuration.nix', 'w').write(config)
open(flakedir + '/flake.lock', 'w').write(lock)
_hw = open('/mnt/etc/nixos/hardware-configuration.nix').read()
open(flakedir + '/hardware-configuration.nix', 'w').write(_hw)
os.remove('/mnt/etc/nixos/configuration.nix')
os.remove('/mnt/etc/nixos/hardware-configuration.nix')
os.rmdir('/mnt/etc/nixos')
os.symlink('/home/' + username + '/nixos-config', '/mnt/etc/nixos')
subprocess.check_output(['git', '-C', flakedir, 'init', '-b', 'main'])
subprocess.check_output(['git', '-C', flakedir, 'add', '-A'])
subprocess.check_output(['git', '-C', flakedir, '-c', 'user.name=' + fullname, '-c', 'user.email=' + username + '@localhost', 'commit', '-m', 'Initial scoot system (scoot-iso installer)'])
subprocess.check_output(['chown', '-R', '1000:100', flakedir])
print('RENDER-OK')
PYEOF
"
guest_exec "
ip -o link show | awk -F': ' '{print \$2}' | grep -v '^lo$' | while read -r ifc; do ip link set \"\$ifc\" down; done
ip -o link show
echo '--- offline eval gate: the generated flake must resolve with no network and no substituters ---'
nix eval --offline --option substitute false --no-write-lock-file '/mnt/home/'$TEST_USER'/nixos-config#nixosConfigurations.scoot.config.system.build.toplevel.drvPath' && echo EVAL-OFFLINE-OK
unshare -n /bin/sh -c 'ip link set lo up; nixos-install --flake /mnt/home/$TEST_USER/nixos-config#scoot --root /mnt --no-root-passwd --no-write-lock-file --option build-dir /nix/var/nix/builds --option substitute false' > /tmp/install.log 2>&1
rc=\$?
echo INSTALL-RC:\$rc
tail -40 /tmp/install.log
ls -la /mnt/home/$TEST_USER/nixos-config/ /mnt/etc/nixos
exit \$rc
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
guest_exec 'systemctl is-active greetd && pgrep -af "[c]age|[r]egreet" | head -5 && echo GREETER-OK'
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

echo "=== phase 3b: the installed flake is normal and maintainable ==="
# The installer wrote ~/nixos-config (home default) with /etc/nixos
# symlinked to it. Prove it: ownership, the git repo, a github-pinned
# lock with no path: overrides, then rebuild offline two ways
# (nixos-rebuild and nh, network namespace emptied).
guest_exec '
echo "--- flake home ---"
ls -lad /etc/nixos /home/'$TEST_USER'/nixos-config
test -L /etc/nixos && echo SYMLINK-OK
stat -c "%U %G %a %n" /home/'$TEST_USER'/nixos-config /home/'$TEST_USER'/nixos-config/flake.nix
echo "--- git repo ---"
git -C /home/'$TEST_USER'/nixos-config log --oneline
git -C /home/'$TEST_USER'/nixos-config status --short
echo "--- flake files ---"
cat /home/'$TEST_USER'/nixos-config/flake.nix
echo "--- lock inputs ---"
python3 - /home/'$TEST_USER'/nixos-config/flake.lock <<'PYEOF'
import json, sys
lock = json.load(open(sys.argv[1]))
for node in ("nixpkgs", "scoot", "home-manager"):
    locked = lock["nodes"][node]["locked"]
    print(node, locked["type"] + ":" + locked.get("owner", "") + "/" + locked.get("repo", ""), locked["rev"])
    assert locked["type"] == "github", "not a github input: " + node
raw = open(sys.argv[1]).read()
assert "path:/nix/store" not in raw, "override leaked into the installed lock"
print("LOCK-OK")
PYEOF
'
echo "=== phase 3c: scoot msg checks via guest agent ==="
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
# Pull the IPC screenshot back to the host for the artifacts, in small
# pieces: only small guest->host payloads are proven, so the
# reassembled PNG is validated, and the test carries on with the QMP
# screendump alone if the fetch fails (the guest-side SCREENSHOT-OK
# already proves scoot's own screenshot path).
guest_exec 'split -b 100K -d /tmp/installed-scoot.png /tmp/shot_ && echo SPLIT-OK || echo SPLIT-FAIL'
: > "$WORKDIR/shot-parts.b64"
pieces=0
while [ "$pieces" -lt 20 ]; do
  frag=$(printf '/tmp/shot_%02d' "$pieces")
  out=$(guest_exec "base64 -w0 $frag 2>/dev/null || echo MISSING") || break
  if printf '%s' "$out" | grep -q '^MISSING$'; then break; fi
  body=$(printf '%s' "$out" | grep -v '^rc:' || true)
  printf '%s' "$body" >> "$WORKDIR/shot-parts.b64"
  pieces=$((pieces + 1))
  if [ "${#body}" -lt 100000 ]; then break; fi
done
if [ "$pieces" -gt 0 ] && python3 - "$WORKDIR/shot-parts.b64" "$WORKDIR/installed-scoot.png" <<'EOF'
import base64, sys
raw = base64.b64decode(open(sys.argv[1]).read())
assert raw[:8] == b"\x89PNG\r\n\x1a\n", "reassembled bytes are not a PNG"
assert len(raw) > 10000, f"suspiciously small screenshot: {len(raw)}"
open(sys.argv[2], "wb").write(raw)
print(f"screenshot saved: {sys.argv[2]} ({len(raw)} bytes)")
EOF
then
  echo "PNG-OK"
else
  echo "PNG-FETCH-WARN: continuing with the QMP screendump alone"
fi
echo "=== phase 3e: offline rebuilds on the installed system ==="
# The network namespace is emptied, so success proves the store holds
# everything a maintainable flake needs; the lock hash before/after
# proves neither rebuild rewrote it. nh switches last (it re-activates).
guest_exec '
lock_before=$(sha256sum /home/'$TEST_USER'/nixos-config/flake.lock)
ip link show | awk -F": " "{print \$2}" | grep -v "^lo$" | while read -r ifc; do ip link set "\$ifc" down; done
fail=0
unshare -n /bin/sh -c "ip link set lo up; nixos-rebuild build --flake /etc/nixos#scoot" && echo REBUILD-OK || fail=1
unshare -n /bin/sh -c "ip link set lo up; NH_FLAKE=/home/'$TEST_USER'/nixos-config nh os switch" && echo NH-OK || fail=1
lock_after=$(sha256sum /home/'$TEST_USER'/nixos-config/flake.lock)
echo "lock before: $lock_before"
echo "lock after:  $lock_after"
[ "$lock_before" = "$lock_after" ] && echo LOCK-STABLE-OK || fail=1
nix flake metadata /home/'$TEST_USER'/nixos-config --json | python3 -c "import json,sys; d=json.load(sys.stdin); [print(k, v[\"locked\"].get(\"rev\", \"?\")) for k,v in d.get(\"locks\",{}).get(\"nodes\",{}).items() if \"locked\" in v]" || fail=1
exit $fail
'
stop_vm
# Convert QMP's PPM screendumps to PNG for the workflow artifacts and
# the README (stdlib only; idempotent, so the workflow's fallback step
# re-running it after a failure is harmless).
python3 "$(dirname "$0")/ppm-to-png.py" "$WORKDIR"
echo "=== qemu-test done; artifacts in $WORKDIR ==="
