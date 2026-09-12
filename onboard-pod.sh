#!/usr/bin/env bash
set -euo pipefail

# The pod release workflow publishes these bytes to the public artifact repository.
# Mintlify preserves the docs.sentientx.io/onboard-pod.sh contract with an external redirect.

readonly ONBOARD_URL="https://docs.sentientx.io/onboard-pod.sh"
readonly MANIFEST_URL="https://raw.githubusercontent.com/Sentient-X/sx-pod-releases/releases/latest.json"
readonly FACTORY_URL="https://app.sentientx.io/d/factory/"
readonly AUTH_URL="https://app.sentientx.io/d/auth/"
readonly TARGET="x86_64-unknown-linux-gnu"

die() { echo "SX Pod onboarding: $*" >&2; exit 2; }
prompt_secret() {
  local label=$1 value
  test -r /dev/tty || die "$label requires an interactive terminal"
  read -r -s -p "$label: " value </dev/tty
  echo >/dev/tty
  test -n "$value" || die "$label must not be empty"
  printf '%s' "$value"
}
safe_id() { [[ "$1" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ && ${#1} -le 54 ]]; }
# Publish complete configuration/credential bytes atomically, including on reruns.
put_file() {  # put_file MODE OWNER:GROUP DEST
  local staged
  staged=$(mktemp "$3.XXXXXXXX")
  if ! (umask 077 && cat >"$staged" && chown "$2" "$staged" && chmod "$1" "$staged"); then
    rm -f -- "$staged"
    return 1
  fi
  mv -f -- "$staged" "$3"
}

test $# -eq 0 || die "this installer takes no arguments"
if test "$(id -u)" -ne 0; then
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  bootstrap=$(mktemp)
  trap 'rm -f -- "$bootstrap"' EXIT
  curl --proto '=https' --tlsv1.2 -fsSL "$ONBOARD_URL" -o "$bootstrap"
  sudo bash "$bootstrap"
  exit
fi

desktop_user=${SUDO_USER:-}
if test -z "$desktop_user" || test "$desktop_user" = root; then
  desktop_user=$(logname 2>/dev/null || true)
fi
test -n "$desktop_user" && test "$desktop_user" != root \
  || die "run the curl command from the laptop's desktop user"
id "$desktop_user" >/dev/null 2>&1 || die "desktop user does not exist: $desktop_user"

. /etc/os-release
test "${ID:-}" = ubuntu || die "only Ubuntu x86-64 is currently qualified"
test "$(uname -m)" = x86_64 || die "this release channel is for x86-64 pods"

echo "Installing the SX Pod media and device runtime…"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  adb ca-certificates chrony curl ffmpeg jq tar zstd util-linux usbutils v4l-utils xdg-utils \
  libgstreamer1.0-0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  libegl1 libgl1 libgl1-mesa-dri libudev1 libwayland-client0 libx11-6 \
  libx11-xcb1 libxcb1 libxcursor1 libxi6 libxkbcommon0 libxkbcommon-x11-0 libxrandr2
# SX Pod sounds its cues through ALSA's default device, the session's PulseAudio or
# PipeWire. Every desktop Ubuntu carries the library with its sound server; without it the
# binary cannot load, so refuse here rather than leave the service crash-looping.
ldconfig -p | grep 'libasound\.so\.2' >/dev/null ||
  die "libasound.so.2 is missing: this laptop has no desktop sound server (pulseaudio or pipewire)"

install -d -m 0755 /etc/chrony/conf.d
put_file 0644 root:root /etc/chrony/conf.d/sx-station.conf <<'EOF'
# SX camera timestamps use CLOCK_MONOTONIC. Never let UTC discipline slew it fast
# enough to violate the Quest-to-host mapping proved at episode arm and stop.
maxslewrate 100
# Boot recovery only; chrony will step during its first three updates, never mid-run.
makestep 1.0 3
EOF
systemctl disable --now systemd-timesyncd.service 2>/dev/null || true
systemctl mask systemd-timesyncd.service 2>/dev/null || true
systemctl enable --now chrony.service
systemctl restart chrony.service

install -d -m 0755 /etc/modprobe.d
printf '%s\n' 'options uvcvideo hwtimestamps=1' \
  | put_file 0644 root:root /etc/modprobe.d/sx-yubi-uvc.conf
if test -w /sys/module/uvcvideo/parameters/hwtimestamps; then
  printf '1\n' >/sys/module/uvcvideo/parameters/hwtimestamps
fi

download=$(mktemp -d)
trap 'rm -rf -- "$download"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 5 --retry-all-errors \
  "$MANIFEST_URL" -o "$download/release.json"
jq -e --arg target "$TARGET" '
  .schema == "sx.pod-release/v2" and
  .target == $target and
  (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
  (.runtime_url | startswith("https://raw.githubusercontent.com/Sentient-X/sx-pod-releases/releases/")) and
  (.runtime_sha256 | test("^[0-9a-f]{64}$")) and
  (.runtime_parts | type == "number") and .runtime_parts >= 1 and .runtime_parts <= 64 and (.runtime_parts | floor == .)
' "$download/release.json" >/dev/null || die "release manifest is invalid"
version=$(jq -er .version "$download/release.json")
runtime_url=$(jq -er .runtime_url "$download/release.json")
runtime_sha256=$(jq -er .runtime_sha256 "$download/release.json")
runtime_parts=$(jq -er .runtime_parts "$download/release.json")
for ((index=0; index<runtime_parts; index++)); do
  printf -v suffix '%04d' "$index"
  curl --proto '=https' --tlsv1.2 -fL --retry 8 --retry-all-errors \
    "$runtime_url.part$suffix" -o "$download/part"
  test "$(stat -c %s "$download/part")" -le 67108864 || die "release part is too large"
  cat "$download/part" >> "$download/runtime.tar.zst"
done
printf '%s  %s\n' "$runtime_sha256" "$download/runtime.tar.zst" \
  | sha256sum --check --status || die "release digest mismatch"

release="/opt/sx-pod/releases/$version"
if test ! -d "$release"; then
  install -d -m 0755 "$release"
  tar --zstd -xf "$download/runtime.tar.zst" -C "$release" --strip-components=1
fi
test -x "$release/bin/sx-pod" || die "release contains no sx-pod binary"
test -f "$release/assets/yubi_hands.urdf" \
  || die "release contains no governed YUBI URDF"

getent group sx-pod >/dev/null || groupadd --system sx-pod
for group in video dialout plugdev sx-pod; do
  getent group "$group" >/dev/null || groupadd --system "$group"
  usermod -aG "$group" "$desktop_user"
done
install -d -o "$desktop_user" -g sx-pod -m 0770 \
  /var/lib/sx-pod /var/lib/sx-pod/android /var/lib/sx-pod/captures /opt/sx-pod/bin
install -d -o root -g sx-pod -m 2770 /etc/sx-pod
install -d -o root -g sx-pod -m 2770 /etc/sx-yubi /etc/sx-yubi/calibration
install -o "$desktop_user" -g sx-pod -m 0750 "$release/bin/sx-pod" /opt/sx-pod/bin/sx-pod
ln -sfn /opt/sx-pod/bin/sx-pod /usr/local/bin/sx-pod
ln -sfn "$release" /opt/sx-pod/current

# A pending join response survives an interrupted install. It is removed only
# after the new identity's configuration and Factory registration are durable.
pending_enrollment=/etc/sx-pod/pending-enrollment.json
reuse_identity=false
reenrolling=false
if test ! -s "$pending_enrollment" && test -s /etc/sx-pod/machine-key && test -s /etc/sx-pod/config.toml; then
  pod_id=$(sed -n 's/^pod_id = "\([A-Za-z0-9._-]*\)"$/\1/p' /etc/sx-pod/config.toml)
  safe_id "$pod_id" || die "existing pod identity is invalid"
  curl --proto '=https' --tlsv1.2 -fsS "${FACTORY_URL}api/pods/$pod_id" \
    -o "$download/existing-pod.json" || die "cannot verify this station's current service life; try again"
  lifecycle=$(jq -er .lifecycle "$download/existing-pod.json")
  case "$lifecycle" in
    active)
      reuse_identity=true
      ;;
    retiring|revoking)
      die "finish retiring and decommissioning $pod_id in Capture before connecting it again"
      ;;
    decommissioned)
      test "$(jq -er .teardown_state "$download/existing-pod.json")" = done \
        || die "finish $pod_id's network removal in Capture before re-enrolling this laptop"
      echo "Station $pod_id is decommissioned. Enter a new installation code to connect this laptop again."
      desktop_uid=$(id -u "$desktop_user")
      if test -S "/run/user/$desktop_uid/bus"; then
        runuser -u "$desktop_user" -- env XDG_RUNTIME_DIR="/run/user/$desktop_uid" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$desktop_uid/bus" \
          systemctl --user stop sx-pod.service
      fi
      archive=$(mktemp -d /etc/sx-pod/retired-XXXXXXXX)
      chmod 0700 "$archive"
      cp /etc/sx-pod/config.toml /etc/sx-pod/machine-key "$archive/"
      reenrolling=true
      ;;
    *) die "Factory returned an unknown service life for $pod_id" ;;
  esac
fi

if test "$reuse_identity" = true; then
  journal_path=$(sed -n 's/^local_journal = "\([^"]*\)"$/\1/p' /etc/sx-pod/config.toml)
  test -n "$journal_path" || die "existing station configuration has no journal"
else
  if test ! -s "$pending_enrollment"; then
    join_code=$(prompt_secret "Single-use SX pod join code")
    curl --proto '=https' --tlsv1.2 -fsS \
      -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg code "$join_code" '{code:$code}')" \
      "${AUTH_URL}api/nodes/join" -o "$download/join.json" || die "pod join failed; retry with the same code"
    subject=$(jq -er .subject "$download/join.json")
    safe_id "${subject#pod:}" && test "$subject" = "pod:${subject#pod:}" \
      || die "join code is not for a valid pod"
    jq -e '.key | type == "string" and length > 0' "$download/join.json" >/dev/null \
      || die "join response has no machine credential"
    put_file 0600 root:root "$pending_enrollment" <"$download/join.json"
  fi
  subject=$(jq -er .subject "$pending_enrollment")
  pod_id=${subject#pod:}
  safe_id "$pod_id" && test "$subject" = "pod:$pod_id" || die "pending enrollment is invalid"
  jq -er .key "$pending_enrollment" | tr -d '\n' \
    | put_file 0640 root:sx-pod /etc/sx-pod/machine-key
  install -d -o "$desktop_user" -g sx-pod -m 0770 /var/lib/sx-pod/journals
  journal_path="/var/lib/sx-pod/journals/$pod_id.sqlite3"
fi

if test ! -s /etc/sx-pod/agent-token; then
  agent_token=$(prompt_secret "Factory YUBI agent token")
  printf '%s' "$agent_token" \
    | put_file 0640 root:sx-pod /etc/sx-pod/agent-token
  unset agent_token
fi
install -o root -g sx-pod -m 0640 \
  "$release/assets/yubi_hands.urdf" \
  /etc/sx-pod/yubi_hands.urdf

if ! command -v tailscale >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -fsSL https://tailscale.com/install.sh \
    -o "$download/tailscale-install.sh"
  sh "$download/tailscale-install.sh"
fi
systemctl enable --now tailscaled
if test "$reenrolling" = true; then
  tailscale logout
fi
if ! tailscale status >/dev/null 2>&1; then
  tailscale_auth_key=$(prompt_secret "Single-use tagged Tailscale auth key")
  tailscale up --auth-key "$tailscale_auth_key" --hostname "$pod_id" \
    --advertise-tags=tag:pod --accept-routes=false
  unset tailscale_auth_key
else
  tailscale set --hostname "$pod_id"
fi
tailscale_ip=$(tailscale ip -4 | head -n1)
[[ "$tailscale_ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
  || die "Tailscale did not assign an IPv4 address from 100.64.0.0/10"

nas_root=$(sed -n 's/^nas_root = "\(.*\)"$/\1/p' /etc/sx-pod/config.toml 2>/dev/null || true)
if test -r /dev/tty; then
  nas_answer=""
  if test -n "$nas_root"; then
    read -r -p "NAS capture path [$nas_root]: " nas_answer </dev/tty
  else
    read -r -p "NAS capture path (leave blank to configure later): " nas_answer </dev/tty
  fi
  test -z "$nas_answer" || nas_root=$nas_answer
fi
nas_toml=""
if test -n "$nas_root"; then
  [[ "$nas_root" = /* && "$nas_root" != / && "$nas_root" != /home && "$nas_root" != /media \
    && "$nas_root" != /mnt && "$nas_root" != /srv && "$nas_root" != /var ]] \
    || die "NAS path must be a dedicated absolute directory"
  [[ "$nas_root" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "NAS path may contain only letters, numbers, dot, underscore, slash, and hyphen"
  test -d "$nas_root" && mountpoint --quiet -- "$nas_root" \
    || die "NAS path must already be a mounted directory"
  nas_toml="nas_root = \"$nas_root\""
fi

put_file 0660 root:sx-pod /etc/sx-pod/config.toml <<EOF
pod_id = "$pod_id"
factory_url = "$FACTORY_URL"
auth_url = "$AUTH_URL"
rig_family = "yubi"
agent_host = "$tailscale_ip"
agent_port = 8220
agent_token_file = "/etc/sx-pod/agent-token"
yubi_urdf = "/etc/sx-pod/yubi_hands.urdf"
left_camera = "/dev/yubi_left_camera"
right_camera = "/dev/yubi_right_camera"
left_encoder = "/dev/yubi_left_esp32c6"
right_encoder = "/dev/yubi_right_esp32c6"
calibration_root = "/etc/sx-yubi/calibration"
capture_root = "/var/lib/sx-pod/captures"
$nas_toml
machine_key_file = "/etc/sx-pod/machine-key"
local_journal = "$journal_path"
poll_interval_ms = 1000
reserve_gib = 10
minimum_write_mib_s = 32.0
upload_limit_mib_s = 20
simulation = false
EOF

commission=$(jq -nc \
  --arg name "SX Pod $pod_id" --arg laptop "$(hostname)" --arg ip "$tailscale_ip" \
  '{name:$name,laptop_hostname:$laptop,tailscale_ip:$ip,rig_type_id:"rig_yubi_managed"}')
curl --proto '=https' --tlsv1.2 -fsS -X PUT \
  -H "X-API-Key: $(</etc/sx-pod/machine-key)" -H 'Content-Type: application/json' \
  -d "$commission" "${FACTORY_URL}api/pods/$pod_id/commission" >/dev/null \
  || die "Factory pod commissioning failed; rerun the installer to resume"
rm -f -- "$pending_enrollment"

# The hosted backend reaches this pod through a platform route the Factory now
# provisions from its own pod table; enrollment is complete before that route is.
# Wait a little for it, then report what the Factory observed rather than claim it.
route_state=unknown
route_detail="not yet observed"
for _ in $(seq 1 24); do
  if pod_json=$(curl --proto '=https' --tlsv1.2 -fsS "${FACTORY_URL}api/pods/$pod_id"); then
    route_state=$(jq -er .egress_state <<<"$pod_json") || die "Factory answered without a route state"
    route_detail=$(jq -er .egress_detail <<<"$pod_json") || die "Factory answered without a route state"
    case $route_state in ready|direct|rejected|withdrawn) break ;; esac
  fi
  sleep 5
done

install -m 0644 "$release/systemd/sx-pod.service" \
  /etc/systemd/user/sx-pod.service
if test -n "$nas_root"; then
  install -d -m 0755 /etc/systemd/user/sx-pod.service.d
  put_file 0644 root:root /etc/systemd/user/sx-pod.service.d/storage.conf <<EOF
[Service]
ReadWritePaths=$nas_root
EOF
fi
put_file 0644 root:root /etc/security/limits.d/60-sx-pod.conf <<'EOF'
@sx-pod - nice -5
@sx-pod - memlock 262144
@sx-pod - rtprio 20
EOF

systemctl daemon-reload
systemctl --global enable sx-pod.service

qualified=true
if ! runuser -u "$desktop_user" -- /opt/sx-pod/bin/sx-pod \
  --qualify --config /etc/sx-pod/config.toml \
  >/var/lib/sx-pod/qualification.json; then
  qualified=false
fi
chown "$desktop_user":sx-pod /var/lib/sx-pod/qualification.json

desktop_uid=$(id -u "$desktop_user")
if test -S "/run/user/$desktop_uid/bus"; then
  runuser -u "$desktop_user" -- env \
    XDG_RUNTIME_DIR="/run/user/$desktop_uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$desktop_uid/bus" \
    systemctl --user daemon-reload
  runuser -u "$desktop_user" -- env \
    XDG_RUNTIME_DIR="/run/user/$desktop_uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$desktop_uid/bus" \
    systemctl --user enable sx-pod.service
fi

echo
if test "$qualified" = true; then
  echo "SX Pod $pod_id is installed, enrolled, and host-qualified at $tailscale_ip."
else
  echo "SX Pod $pod_id is installed and enrolled at $tailscale_ip."
  echo "Open Settings to finish the host checklist; no reinstall is needed."
fi
echo "Connect the registered rig and start a shift to download its calibration and check devices."
echo "Platform route: $route_state — $route_detail"
case $route_state in
  ready|direct) ;;
  *) echo "The platform provisions the route on its own; Capture › Pods shows its state, and managed recording waits for it." ;;
esac
echo "Log out and back in once to activate device/priority groups and start SX Pod."
