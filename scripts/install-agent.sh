#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then echo "run as root" >&2; exit 1; fi
: "${REMOTE_CONTROL_MCP_AGENT_CENTER_URL:?required}"
: "${REMOTE_CONTROL_MCP_AGENT_NAME:?required}"

script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
service_file="${REMOTE_CONTROL_MCP_AGENT_SERVICE_FILE:-$script_dir/remote-control-mcp-agent.service}"
[[ -f "$service_file" ]] || { echo "systemd service template is missing: $service_file (set REMOTE_CONTROL_MCP_AGENT_SERVICE_FILE)" >&2; exit 1; }

binary_source="${REMOTE_CONTROL_MCP_AGENT_BINARY:-}"
[[ -n "$binary_source" && -f "$binary_source" ]] || { echo "REMOTE_CONTROL_MCP_AGENT_BINARY must point to the current Java Agent ZIP" >&2; exit 1; }
[[ "${binary_source,,}" == *.zip ]] || { echo "REMOTE_CONTROL_MCP_AGENT_BINARY must be a Native Image ZIP" >&2; exit 1; }
desktop_source="${REMOTE_CONTROL_MCP_AGENT_DESKTOP_BINARY:-}"
browser_source="${REMOTE_CONTROL_MCP_AGENT_BROWSER_BINARY:-}"
updater_source="${REMOTE_CONTROL_MCP_AGENT_UPDATER_BINARY:-}"
[[ -z "$desktop_source" || "${desktop_source,,}" == *.zip ]] || { echo "REMOTE_CONTROL_MCP_AGENT_DESKTOP_BINARY must be a Native Image ZIP" >&2; exit 1; }
[[ -z "$browser_source" || "${browser_source,,}" == *.zip ]] || { echo "REMOTE_CONTROL_MCP_AGENT_BROWSER_BINARY must be a Native Image ZIP" >&2; exit 1; }
[[ -z "$updater_source" || "${updater_source,,}" == *.zip ]] || { echo "REMOTE_CONTROL_MCP_AGENT_UPDATER_BINARY must be a Native Image ZIP" >&2; exit 1; }
desktop_enabled="${REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED:-false}"
desktop_enabled="${desktop_enabled,,}"
desktop_user="${REMOTE_CONTROL_MCP_AGENT_DESKTOP_USER:-${SUDO_USER:-}}"
browser_profile_dir="${REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR:-}"
browser_engine="${REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE:-camoufox}"
browser_name="${REMOTE_CONTROL_MCP_AGENT_BROWSER:-firefox}"
browser_headless="${REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS:-1}"
browser_browsers_path="${REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH:-}"
camoufox_install_dir="${REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR:-}"

verify_archive_checksum() {
  local artifact="$1" sidecar="${1}.sha256" expected listed actual
  [[ -f "$sidecar" ]] || return 0
  read -r expected listed _ < "$sidecar" || { echo "invalid SHA-256 sidecar: $sidecar" >&2; exit 1; }
  listed="${listed#\*}"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ && "$listed" == "$(basename "$artifact")" ]] || {
    echo "invalid SHA-256 sidecar: $sidecar" >&2
    exit 1
  }
  actual="$(sha256sum "$artifact" | awk '{print tolower($1)}')"
  [[ "$actual" == "${expected,,}" ]] || { echo "SHA-256 mismatch: $artifact" >&2; exit 1; }
}

# Install an optional companion into its own directory so Native Image
# libraries with common names (for example libjava.so) can never overwrite the
# command-agent runtime.  ZIPs are checked before extraction and must contain
# exactly one flat canonical executable plus optional .so sidecars.
install_companion_bundle() (
  set -euo pipefail
  local source_path="$1" expected="$2" destination="$3"
  [[ -n "$source_path" ]] || exit 0
  [[ -f "$source_path" ]] || { echo "companion bundle is missing: $source_path" >&2; exit 1; }
  local staging='' source_file='' source_root=''
  trap '[[ -z "${staging:-}" ]] || rm -rf -- "$staging"' EXIT
  if [[ "${source_path,,}" == *.zip ]]; then
    command -v unzip >/dev/null 2>&1 || { echo 'unzip is required for companion ZIPs' >&2; exit 1; }
    verify_archive_checksum "$source_path"
    while IFS= read -r entry; do
      [[ -n "$entry" && "$entry" != */* && "$entry" != /* && "$entry" != *..* ]] || {
        echo "companion ZIP must contain flat safe file names: $entry" >&2; exit 1;
      }
      case "$entry" in
        "$expected"|*.so|*.so.*) ;;
        *) echo "unexpected file in companion ZIP: $entry" >&2; exit 1 ;;
      esac
    done < <(unzip -Z1 "$source_path")
    staging="$(mktemp -d -t rcm-companion-install.XXXXXX)"
    unzip -q "$source_path" -d "$staging"
    mapfile -t executables < <(find "$staging" -mindepth 1 -maxdepth 1 -type f -name "$expected" -print)
    (( ${#executables[@]} == 1 )) || { echo "companion ZIP must contain exactly one $expected" >&2; exit 1; }
    source_file="${executables[0]}"
    source_root="$staging"
  else
    echo "companion input must be a Native Image ZIP containing $expected" >&2
    exit 1
  fi
  [[ -x "$source_file" ]] || { echo "companion executable is not executable: $source_file" >&2; exit 1; }
  install -d -m 0755 "$destination"
  for old in "$destination"/*.so "$destination"/*.so.*; do
    [[ -e "$old" ]] || continue
    rm -f -- "$old"
  done
  install -m 0755 "$source_file" "$destination/$expected"
  while IFS= read -r -d '' sidecar; do
    install -m 0755 "$sidecar" "$destination/$(basename "$sidecar")"
  done < <(find "$source_root" -mindepth 1 -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) -print0)
)
center_url="${REMOTE_CONTROL_MCP_AGENT_CENTER_URL%/}"
[[ "$center_url" == https://* ]] || { echo "REMOTE_CONTROL_MCP_AGENT_CENTER_URL must use HTTPS" >&2; exit 1; }
state_dir="${REMOTE_CONTROL_MCP_AGENT_STATE_DIR:-/var/lib/remote-control-mcp-agent}"
install_root="${REMOTE_CONTROL_MCP_AGENT_INSTALL_ROOT:-/opt/remote-control-mcp-agent}"
re_enroll="${REMOTE_CONTROL_MCP_AGENT_REENROLL:-false}"
max_concurrency="${REMOTE_CONTROL_MCP_AGENT_MAX_CONCURRENCY:-1}"
  max_browser_workers="${REMOTE_CONTROL_MCP_AGENT_MAX_BROWSER_WORKERS:-1}"
  desktop_max_launched="${REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES:-16}"
  max_total_child_processes="${REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES:-}"
  max_output="${REMOTE_CONTROL_MCP_AGENT_MAX_OUTPUT_BYTES:-67108864}"
max_aggregate="${REMOTE_CONTROL_MCP_AGENT_MAX_AGGREGATE_OUTPUT_BYTES:-}"
max_task_duration="${REMOTE_CONTROL_MCP_AGENT_MAX_TASK_DURATION_SECONDS:-0}"
max_child_processes="${REMOTE_CONTROL_MCP_AGENT_MAX_CHILD_PROCESSES:-32}"
max_rss_bytes="${REMOTE_CONTROL_MCP_AGENT_MAX_RSS_BYTES:-0}"
max_cpu_seconds="${REMOTE_CONTROL_MCP_AGENT_MAX_CPU_SECONDS:-0}"
resource_sample_interval="${REMOTE_CONTROL_MCP_AGENT_RESOURCE_SAMPLE_INTERVAL_MS:-1000}"
transfer_stall_timeout="${REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS:-120}"
registration_timeout="${REMOTE_CONTROL_MCP_AGENT_REGISTRATION_TIMEOUT_SECONDS:-90}"
cgroup_path="${REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH:-}"
[[ "$browser_profile_dir" != *$'\r'* && "$browser_profile_dir" != *$'\n'* && ${#browser_profile_dir} -le 4096 ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR must be a single path up to 4096 characters" >&2; exit 1;
}
[[ "$browser_engine" == camoufox || "$browser_engine" == playwright || "$browser_engine" == patchright ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE is invalid" >&2; exit 1;
}
[[ "$browser_name" == chromium || "$browser_name" == firefox || "$browser_name" == webkit ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_BROWSER must be chromium, firefox, or webkit" >&2; exit 1;
}
[[ "$browser_headless" == 0 || "$browser_headless" == 1 ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS must be 0 or 1" >&2; exit 1;
}
[[ "$browser_browsers_path" != *$'\r'* && "$browser_browsers_path" != *$'\n'* && "$browser_browsers_path" != *'"'* && ${#browser_browsers_path} -le 4096 ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH must be a single path up to 4096 characters" >&2; exit 1;
}
[[ "$camoufox_install_dir" != *$'\r'* && "$camoufox_install_dir" != *$'\n'* && "$camoufox_install_dir" != *'"'* && ${#camoufox_install_dir} -le 4096 ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR must be a single path up to 4096 characters" >&2; exit 1;
}
[[ "$desktop_enabled" == true || "$desktop_enabled" == false ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED must be true or false" >&2; exit 1;
}
[[ "$state_dir" != *$'\r'* && "$state_dir" != *$'\n'* && "$state_dir" != *'"'* \
  && "$install_root" != *$'\r'* && "$install_root" != *$'\n'* && "$install_root" != *'"'* ]] || {
  echo "state/install paths must not contain quotes or newlines" >&2; exit 1;
}
if [[ -n "$desktop_user" ]]; then
  [[ "$desktop_user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,63}$ ]] || {
    echo "REMOTE_CONTROL_MCP_AGENT_DESKTOP_USER is invalid" >&2; exit 1;
  }
  id "$desktop_user" >/dev/null 2>&1 || {
    echo "desktop user does not exist: $desktop_user" >&2; exit 1;
  }
fi
[[ "$cgroup_path" != *$'\r'* && "$cgroup_path" != *$'\n'* && ${#cgroup_path} -le 4096 ]] || {
  echo "REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH must be a single path up to 4096 characters" >&2; exit 1;
}
[[ "$max_concurrency" =~ ^[0-9]+$ ]] && (( max_concurrency >= 1 && max_concurrency <= 32 )) || {
  echo "REMOTE_CONTROL_MCP_AGENT_MAX_CONCURRENCY must be between 1 and 32" >&2; exit 1;
}
[[ "$max_output" =~ ^[0-9]+$ ]] && (( max_output >= 1048576 && max_output <= 1073741824 )) || {
  echo "REMOTE_CONTROL_MCP_AGENT_MAX_OUTPUT_BYTES must be between 1 MiB and 1 GiB" >&2; exit 1;
}
if [[ -n "$max_aggregate" ]]; then
  [[ "$max_aggregate" =~ ^[0-9]+$ ]] || { echo "REMOTE_CONTROL_MCP_AGENT_MAX_AGGREGATE_OUTPUT_BYTES must be an integer" >&2; exit 1; }
fi
if [[ -z "$max_aggregate" ]]; then
  max_aggregate=$((max_output * max_concurrency))
  (( max_aggregate > 268435456 )) && max_aggregate=268435456
  (( max_aggregate < max_output )) && max_aggregate=$max_output
fi
(( max_aggregate >= max_output && max_aggregate <= 4294967296 )) || { echo "aggregate output limit is invalid" >&2; exit 1; }
[[ "$max_browser_workers" =~ ^[0-9]+$ ]] || { echo "REMOTE_CONTROL_MCP_AGENT_MAX_BROWSER_WORKERS must be an integer" >&2; exit 1; }
(( max_browser_workers >= 1 && max_browser_workers <= 8 && max_browser_workers <= max_concurrency )) || {
  echo "REMOTE_CONTROL_MCP_AGENT_MAX_BROWSER_WORKERS must be between 1 and MAX_CONCURRENCY (maximum 8)" >&2; exit 1;
}
[[ "$desktop_max_launched" =~ ^[0-9]+$ ]] || { echo "REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES must be an integer" >&2; exit 1; }
  (( desktop_max_launched >= 1 && desktop_max_launched <= 64 )) || {
    echo "REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES must be between 1 and 64" >&2; exit 1;
  }
  if [[ -z "$max_total_child_processes" ]]; then
    max_total_child_processes=$((max_concurrency * 32))
    (( max_total_child_processes < 32 )) && max_total_child_processes=32
    (( max_total_child_processes > 256 )) && max_total_child_processes=256
  fi
  [[ "$max_total_child_processes" =~ ^[0-9]+$ ]] || {
    echo "REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES must be an integer" >&2; exit 1;
  }
  (( max_total_child_processes >= 1 && max_total_child_processes <= 4096 )) || {
    echo "REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES must be between 1 and 4096" >&2; exit 1;
  }
for value in "$max_task_duration" "$max_child_processes" "$max_rss_bytes" "$max_cpu_seconds" "$resource_sample_interval" "$transfer_stall_timeout"; do
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "resource budget values must be non-negative integers" >&2; exit 1; }
done
(( max_task_duration <= 2592000 )) || { echo "REMOTE_CONTROL_MCP_AGENT_MAX_TASK_DURATION_SECONDS must be between 0 and 2592000" >&2; exit 1; }
(( max_child_processes >= 1 && max_child_processes <= 256 )) || { echo "REMOTE_CONTROL_MCP_AGENT_MAX_CHILD_PROCESSES must be between 1 and 256" >&2; exit 1; }
(( max_rss_bytes <= 17179869184 )) || { echo "REMOTE_CONTROL_MCP_AGENT_MAX_RSS_BYTES must be at most 16 GiB" >&2; exit 1; }
(( max_cpu_seconds <= 2592000 )) || { echo "REMOTE_CONTROL_MCP_AGENT_MAX_CPU_SECONDS must be between 0 and 2592000" >&2; exit 1; }
(( resource_sample_interval >= 250 && resource_sample_interval <= 10000 )) || { echo "REMOTE_CONTROL_MCP_AGENT_RESOURCE_SAMPLE_INTERVAL_MS must be between 250 and 10000" >&2; exit 1; }
(( transfer_stall_timeout >= 5 && transfer_stall_timeout <= 3600 )) || { echo "REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS must be between 5 and 3600" >&2; exit 1; }
[[ "$registration_timeout" =~ ^[0-9]+$ ]] && (( registration_timeout >= 15 && registration_timeout <= 600 )) || {
  echo "REMOTE_CONTROL_MCP_AGENT_REGISTRATION_TIMEOUT_SECONDS must be between 15 and 600" >&2; exit 1;
}
if [[ "$re_enroll" == true || ! -f "$state_dir/identity.json" ]]; then
  : "${REMOTE_CONTROL_MCP_AGENT_ENROLLMENT_TOKEN:?required for first registration or re-enroll}"
  command -v timeout >/dev/null 2>&1 || { echo 'timeout is required to bound Agent registration' >&2; exit 1; }
fi

install -d -m 0755 "$install_root"
install -d -m 0700 "$state_dir"
install_companion_bundle "$desktop_source" rcm-desktop-companion "$install_root/desktop"
install_companion_bundle "$browser_source" rcm-browser-agent "$install_root/browser"
install_companion_bundle "$updater_source" rcm-updater "$install_root/updater"

# On Linux the command Agent is a root system service, while AWT/Wayland/X11
# must run in the logged-in user's session.  Install an optional systemd-user
# unit for that same user.  It is deliberately not enabled when no user was
# supplied: a headless host can still install the desktop binary without
# creating a broken background process.  The companion only gets ACL access
# to state_dir/desktop; identity.json and the Center token remain root-only.
configure_linux_desktop_companion() {
  [[ "$desktop_enabled" == true ]] || return 0
  [[ "$(uname -s)" == Linux ]] || return 0
  local desktop_binary="$install_root/desktop/rcm-desktop-companion"
  if [[ -n "$desktop_source" ]]; then
    # A supplied bundle has already been installed above.  Reusing the
    # resolved destination keeps rerunning the installer idempotent.
    [[ -x "$desktop_binary" ]] || { echo "Desktop companion binary was not installed: $desktop_binary" >&2; exit 1; }
  elif [[ ! -x "$desktop_binary" ]]; then
    echo "Desktop is enabled but no companion binary was supplied" >&2
    exit 1
  fi
  if [[ -z "$desktop_user" ]]; then
    echo "desktop companion installed; set REMOTE_CONTROL_MCP_AGENT_DESKTOP_USER to enable Linux session auto-start" >&2
    return 0
  fi
  local uid home unit_dir unit_file escaped_binary escaped_state
  uid="$(id -u "$desktop_user")"
  home="$(getent passwd "$desktop_user" | cut -d: -f6)"
  [[ -n "$home" && -d "$home" ]] || { echo "could not resolve home for desktop user: $desktop_user" >&2; exit 1; }
  unit_dir="$home/.config/systemd/user"
  unit_file="$unit_dir/remote-control-mcp-desktop.service"
  desktop_binary="$install_root/desktop/rcm-desktop-companion"
  [[ -x "$desktop_binary" ]] || { echo "desktop companion binary was not installed: $desktop_binary" >&2; exit 1; }
  install -d -m 0700 "$unit_dir" "$state_dir/desktop"
  chown "$desktop_user:$desktop_user" "$unit_dir" "$state_dir/desktop" 2>/dev/null || chown "$desktop_user" "$unit_dir" "$state_dir/desktop"
  # Do not relax the root-owned identity/configuration directory.  If ACLs are
  # unavailable, leave the binary installed but skip auto-start rather than
  # exposing the Agent token to the interactive user.
  if ! command -v setfacl >/dev/null 2>&1; then
    echo "setfacl is unavailable; desktop companion will not be auto-started (install acl and rerun)" >&2
    return 0
  fi
  setfacl -m "u:$desktop_user:--x" "$state_dir"
  setfacl -m "u:$desktop_user:rwx" "$state_dir/desktop"
  setfacl -m "d:u:$desktop_user:rwx" "$state_dir/desktop"
  escaped_binary="\"${desktop_binary//\\/\\\\}\""
  escaped_state="\"${state_dir//\\/\\\\}\""
  {
    printf '[Unit]\n'
    printf 'Description=Remote Control MCP desktop companion\n'
    printf 'After=graphical-session.target\n'
    printf 'PartOf=graphical-session.target\n\n'
    printf '[Service]\nType=simple\n'
    printf 'ExecStart=%s --desktop-companion %s\n' "$escaped_binary" "$escaped_state"
    printf 'Restart=on-failure\nRestartSec=3\n'
    printf 'PassEnvironment=DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XAUTHORITY XDG_SESSION_TYPE\n'
    printf 'Environment=REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_CONNECTIONS=4\n'
    printf 'Environment=REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES=%s\n' "$desktop_max_launched"
    printf 'NoNewPrivileges=true\nUMask=0077\n\n'
    printf '[Install]\nWantedBy=graphical-session.target\n'
  } > "$unit_file"
  chown "$desktop_user:$desktop_user" "$unit_file" 2>/dev/null || chown "$desktop_user" "$unit_file"
  chmod 0600 "$unit_file"
  if [[ -d "/run/user/$uid" ]] && command -v systemctl >/dev/null 2>&1; then
    if runuser -u "$desktop_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1 \
      && runuser -u "$desktop_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user enable --now remote-control-mcp-desktop.service >/dev/null 2>&1; then
      echo "Linux desktop companion enabled for user $desktop_user"
    else
      echo "desktop unit installed but current graphical session is not ready; it will start on the next login" >&2
    fi
  else
    echo "desktop unit installed for user $desktop_user; it will start on the next graphical login" >&2
  fi
}

disable_linux_desktop_companion() {
  [[ "$(uname -s)" == Linux ]] || return 0
  [[ -n "$desktop_user" ]] || return 0
  local uid home unit_file
  uid="$(id -u "$desktop_user" 2>/dev/null || true)"
  home="$(getent passwd "$desktop_user" 2>/dev/null | cut -d: -f6 || true)"
  unit_file="${home:-}/.config/systemd/user/remote-control-mcp-desktop.service"
  if [[ -n "$uid" && -d "/run/user/$uid" ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$desktop_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user disable --now remote-control-mcp-desktop.service >/dev/null 2>&1 || true
    runuser -u "$desktop_user" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  [[ -z "$home" ]] || rm -f -- "$unit_file"
}

# EnvironmentFile uses a shell-like tokenizer.  A browser adapter is a
# command line and therefore normally contains a space between the runtime
# executable and its worker script (and may contain spaces in either path).
# Writing that value verbatim makes systemd concatenate separately quoted
# fragments, for example `"node" "worker.mjs"` becomes `nodeworker.mjs`.
# Keep the whole value in one quoted assignment and escape its embedded
# quotes/backslashes so the Agent receives the exact command string.
systemd_env_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  printf '"%s"' "$value"
}

# Native Image may emit shared libraries beside the ELF.  Accept only the flat
# Agent ZIP produced by GitHub Actions so the executable and every sidecar are
# installed as one immutable bundle.
staging=""
source_dir=""
source_binary=""
if [[ "${binary_source,,}" == *.zip ]]; then
  command -v unzip >/dev/null 2>&1 || { echo "unzip is required to install a Java Agent ZIP (apt install unzip)" >&2; exit 1; }
  command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required to verify the Agent bundle" >&2; exit 1; }
  verify_archive_checksum "$binary_source"
  staging="$(mktemp -d -t rcm-agent-install.XXXXXX)"
  trap 'rm -rf "$staging"' EXIT
  unzip -q "$binary_source" -d "$staging"
  mapfile -t executables < <(find "$staging" -type f -name 'rcm-agent' -print)
  (( ${#executables[@]} == 1 )) || { echo "Agent ZIP must contain exactly one flat rcm-agent executable" >&2; exit 1; }
  source_dir="$(dirname "${executables[0]}")"
  [[ "$source_dir" == "$staging" ]] || { echo "Agent ZIP must be flat (no nested executable path)" >&2; exit 1; }
  source_binary="${executables[0]}"
else
  echo "Java native Agent input must be a Native Image ZIP" >&2
  exit 1
fi

[[ -x "$source_binary" ]] || { echo "selected Java Agent executable is not executable" >&2; exit 1; }
declare -A bundle_files=()
bundle_files[rcm-agent]=1
while IFS= read -r -d '' sidecar; do
  name="$(basename "$sidecar")"
  bundle_files["$name"]=1
done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) -print0)

for old in "$install_root"/*.so "$install_root"/*.so.*; do
  [[ -e "$old" ]] || continue
  [[ -n "${bundle_files[$(basename "$old")]+x}" ]] || rm -f -- "$old"
done
install -m 0755 "$source_binary" "$install_root/rcm-agent"
while IFS= read -r -d '' sidecar; do
  install -m 0755 "$sidecar" "$install_root/$(basename "$sidecar")"
done < <(find "$source_dir" -mindepth 1 -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) -print0)
identity="$state_dir/identity.json"
if [[ "$re_enroll" == true || ! -f "$identity" ]]; then
  : "${REMOTE_CONTROL_MCP_AGENT_ENROLLMENT_TOKEN:?required for first registration or re-enroll}"
  tmp_log="$(mktemp)"
  chmod 600 "$tmp_log"
  set +e
  REMOTE_CONTROL_MCP_AGENT_CENTER_URL="$center_url" \
  REMOTE_CONTROL_MCP_AGENT_ENROLLMENT_TOKEN="$REMOTE_CONTROL_MCP_AGENT_ENROLLMENT_TOKEN" \
  REMOTE_CONTROL_MCP_AGENT_NAME="$REMOTE_CONTROL_MCP_AGENT_NAME" \
  REMOTE_CONTROL_MCP_AGENT_HOST_ID="${REMOTE_CONTROL_MCP_AGENT_HOST_ID:-$REMOTE_CONTROL_MCP_AGENT_NAME}" \
  REMOTE_CONTROL_MCP_AGENT_DEFAULT_CWD="${REMOTE_CONTROL_MCP_AGENT_DEFAULT_CWD:-/}" \
  REMOTE_CONTROL_MCP_AGENT_CAPABILITIES="${REMOTE_CONTROL_MCP_AGENT_CAPABILITIES:-command,durable_tasks,file_transfer}" \
  REMOTE_CONTROL_MCP_AGENT_VERSION="${REMOTE_CONTROL_MCP_AGENT_VERSION:-dev}" \
  REMOTE_CONTROL_MCP_AGENT_BROWSER_ADAPTER="${REMOTE_CONTROL_MCP_AGENT_BROWSER_ADAPTER:-}" \
  REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR="$browser_profile_dir" \
  REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE="$browser_engine" \
  REMOTE_CONTROL_MCP_AGENT_BROWSER="$browser_name" \
  REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS="$browser_headless" \
  REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH="$browser_browsers_path" \
  REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR="$camoufox_install_dir" \
  REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED="${REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED:-false}" \
  REMOTE_CONTROL_MCP_AGENT_STATE_DIR="$state_dir" \
  REMOTE_CONTROL_MCP_AGENT_MAX_CONCURRENCY="$max_concurrency" \
  REMOTE_CONTROL_MCP_AGENT_MAX_BROWSER_WORKERS="$max_browser_workers" \
  REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES="$desktop_max_launched" \
  REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES="$max_total_child_processes" \
  REMOTE_CONTROL_MCP_AGENT_MAX_OUTPUT_BYTES="$max_output" \
  REMOTE_CONTROL_MCP_AGENT_MAX_AGGREGATE_OUTPUT_BYTES="$max_aggregate" \
  REMOTE_CONTROL_MCP_AGENT_MAX_TASK_DURATION_SECONDS="$max_task_duration" \
  REMOTE_CONTROL_MCP_AGENT_MAX_CHILD_PROCESSES="$max_child_processes" \
  REMOTE_CONTROL_MCP_AGENT_MAX_RSS_BYTES="$max_rss_bytes" \
  REMOTE_CONTROL_MCP_AGENT_MAX_CPU_SECONDS="$max_cpu_seconds" \
  REMOTE_CONTROL_MCP_AGENT_RESOURCE_SAMPLE_INTERVAL_MS="$resource_sample_interval" \
  REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS="$transfer_stall_timeout" \
  REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH="$cgroup_path" \
  timeout --kill-after=5s "$registration_timeout" "$install_root/rcm-agent" --register-once >"$tmp_log" 2>&1
  rc=$?
  set -e
  if (( rc != 0 )) || [[ ! -f "$identity" ]]; then
    if (( rc == 124 || rc == 137 )); then echo "Agent registration timed out after $registration_timeout seconds" >&2; fi
    echo "Java Agent registration failed:" >&2
    sed -n '1,80p' "$tmp_log" >&2
    rm -f "$tmp_log"
    exit 1
  fi
  rm -f "$tmp_log"
fi

umask 077
install -d -m 0700 /etc/remote-control-mcp-agent
{
  printf 'REMOTE_CONTROL_MCP_AGENT_CENTER_URL=%s\n' "$center_url"
  printf 'REMOTE_CONTROL_MCP_AGENT_NAME=%s\n' "$REMOTE_CONTROL_MCP_AGENT_NAME"
  printf 'REMOTE_CONTROL_MCP_AGENT_HOST_ID=%s\n' "${REMOTE_CONTROL_MCP_AGENT_HOST_ID:-$REMOTE_CONTROL_MCP_AGENT_NAME}"
  printf 'REMOTE_CONTROL_MCP_AGENT_DEFAULT_CWD=%s\n' "${REMOTE_CONTROL_MCP_AGENT_DEFAULT_CWD:-/}"
  printf 'REMOTE_CONTROL_MCP_AGENT_CAPABILITIES=%s\n' "${REMOTE_CONTROL_MCP_AGENT_CAPABILITIES:-command,durable_tasks,file_transfer}"
  printf 'REMOTE_CONTROL_MCP_AGENT_VERSION=%s\n' "${REMOTE_CONTROL_MCP_AGENT_VERSION:-dev}"
  printf 'REMOTE_CONTROL_MCP_AGENT_BROWSER_ADAPTER=%s\n' "$(systemd_env_quote "${REMOTE_CONTROL_MCP_AGENT_BROWSER_ADAPTER:-}")"
  printf 'REMOTE_CONTROL_MCP_AGENT_BROWSER_PROFILE_DIR=%s\n' "$browser_profile_dir"
  printf 'REMOTE_CONTROL_MCP_AGENT_BROWSER_ENGINE=%s\n' "$browser_engine"
  printf 'REMOTE_CONTROL_MCP_AGENT_BROWSER=%s\n' "$browser_name"
  printf 'REMOTE_CONTROL_MCP_AGENT_BROWSER_HEADLESS=%s\n' "$browser_headless"
  printf 'REMOTE_CONTROL_MCP_AGENT_PLAYWRIGHT_BROWSERS_PATH=%s\n' "$browser_browsers_path"
  printf 'REMOTE_CONTROL_MCP_AGENT_CAMOUFOX_INSTALL_DIR=%s\n' "$camoufox_install_dir"
  printf 'REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED=%s\n' "${REMOTE_CONTROL_MCP_AGENT_DESKTOP_ENABLED:-false}"
  printf 'REMOTE_CONTROL_MCP_AGENT_STATE_DIR=%s\n' "$state_dir"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_CONCURRENCY=%s\n' "$max_concurrency"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_BROWSER_WORKERS=%s\n' "$max_browser_workers"
  printf 'REMOTE_CONTROL_MCP_AGENT_DESKTOP_MAX_LAUNCHED_PROCESSES=%s\n' "$desktop_max_launched"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_TOTAL_CHILD_PROCESSES=%s\n' "$max_total_child_processes"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_OUTPUT_BYTES=%s\n' "$max_output"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_AGGREGATE_OUTPUT_BYTES=%s\n' "$max_aggregate"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_TASK_DURATION_SECONDS=%s\n' "$max_task_duration"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_CHILD_PROCESSES=%s\n' "$max_child_processes"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_RSS_BYTES=%s\n' "$max_rss_bytes"
  printf 'REMOTE_CONTROL_MCP_AGENT_MAX_CPU_SECONDS=%s\n' "$max_cpu_seconds"
  printf 'REMOTE_CONTROL_MCP_AGENT_RESOURCE_SAMPLE_INTERVAL_MS=%s\n' "$resource_sample_interval"
  printf 'REMOTE_CONTROL_MCP_AGENT_TRANSFER_STALL_TIMEOUT_SECONDS=%s\n' "$transfer_stall_timeout"
  printf 'REMOTE_CONTROL_MCP_AGENT_CGROUP_PATH=%s\n' "$cgroup_path"
  printf 'REMOTE_CONTROL_MCP_AGENT_BINARY_PATH=%s\n' "$install_root/rcm-agent"
  printf 'REMOTE_CONTROL_MCP_AGENT_SERVICE_NAME=remote-control-mcp-agent\n'
  if [[ -x "$install_root/updater/rcm-updater" ]]; then
    printf 'REMOTE_CONTROL_MCP_AGENT_UPDATER_BINARY_PATH=%s\n' "$install_root/updater/rcm-updater"
  fi
  if [[ -x "$install_root/desktop/rcm-desktop-companion" ]]; then
    printf 'REMOTE_CONTROL_MCP_DESKTOP_BINARY_PATH=%s\n' "$install_root/desktop/rcm-desktop-companion"
  fi
  if [[ -x "$install_root/browser/rcm-browser-agent" ]]; then
    printf 'REMOTE_CONTROL_MCP_AGENT_BROWSER_BINARY=%s\n' "$install_root/browser/rcm-browser-agent"
    printf 'REMOTE_CONTROL_MCP_BROWSER_BINARY_PATH=%s\n' "$install_root/browser/rcm-browser-agent"
  fi
  if [[ -n "$browser_browsers_path" ]]; then
    printf 'PLAYWRIGHT_BROWSERS_PATH=%s\n' "$browser_browsers_path"
  fi
  if [[ -n "$camoufox_install_dir" ]]; then
    printf 'CAMOUFOX_INSTALL_DIR=%s\n' "$camoufox_install_dir"
  fi
 } > /etc/remote-control-mcp-agent/agent.env

# The runtime prefers the immutable marker written by the detached upgrade
# helper.  Refresh it during a package installation too; otherwise reinstalling
# a newer binary can keep advertising the previous upgrade version forever.
printf '%s\n' "${REMOTE_CONTROL_MCP_AGENT_VERSION:-dev}" > "$state_dir/agent-version"
chmod 0600 "$state_dir/agent-version"

install -m 0644 "$service_file" /etc/systemd/system/remote-control-mcp-agent.service
configure_linux_desktop_companion
systemctl daemon-reload
systemctl enable --now remote-control-mcp-agent.service
systemctl is-active --quiet remote-control-mcp-agent.service
echo "remote-control-mcp Java Agent is active; Enrollment Token is not stored in agent.env"
