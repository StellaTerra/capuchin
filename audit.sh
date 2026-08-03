#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RPM_OSTREE_PACKAGES="$ROOT/packages/rpm-ostree.txt"
BORGMATIC_RPM_OSTREE_PACKAGES="$ROOT/packages/borg-rpm-ostree.txt"
RPM_OSTREE_ALLOWED="$ROOT/packages/rpm-ostree-allowed.txt"
VSCODE_EXTENSIONS="$ROOT/packages/vscode-extensions.txt"
BREWFILE="$ROOT/Brewfile"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

read_list() {
  local file="$1"
  [[ -f "$file" ]] || die "missing list: $file"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$file"
}

print_diff() {
  local title="$1"
  local expected_file="$2"
  local actual_file="$3"
  local expected_sorted actual_sorted missing_file extra_file

  expected_sorted="$(mktemp)"
  actual_sorted="$(mktemp)"
  missing_file="$(mktemp)"
  extra_file="$(mktemp)"

  LC_ALL=C sort -u "$expected_file" >"$expected_sorted"
  LC_ALL=C sort -u "$actual_file" >"$actual_sorted"

  LC_ALL=C comm -23 "$expected_sorted" "$actual_sorted" >"$missing_file"
  LC_ALL=C comm -13 "$expected_sorted" "$actual_sorted" >"$extra_file"

  printf '%s\n' "$title"
  if [[ ! -s "$missing_file" && ! -s "$extra_file" ]]; then
    printf '  ok: matches repo\n'
    rm -f "$expected_sorted" "$actual_sorted" "$missing_file" "$extra_file"
    return
  fi

  if [[ -s "$missing_file" ]]; then
    printf '  missing from system:\n'
    sed 's/^/    /' "$missing_file"
  fi

  if [[ -s "$extra_file" ]]; then
    printf '  extra on system:\n'
    sed 's/^/    /' "$extra_file"
  fi

  rm -f "$expected_sorted" "$actual_sorted" "$missing_file" "$extra_file"
}

rpm_ostree_target_json() {
  local status_json
  status_json="$(rpm-ostree status --json)"

  python3 -c '
import json
import sys

status = json.load(sys.stdin)
deployments = status.get("deployments", [])
target = next((deployment for deployment in deployments if deployment.get("staged")), None)
if target is None:
    target = next((deployment for deployment in deployments if deployment.get("booted")), None)

if target is not None:
    json.dump(target, sys.stdout)
' <<<"$status_json"
}

actual_rpm_ostree_layered_packages() {
  rpm_ostree_target_json | python3 -c '
import json
import sys

target = json.load(sys.stdin)
for package in sorted(set(target.get("requested-packages", []))):
    print(package)
'
}

audit_rpm_ostree_packages() {
  need_cmd rpm-ostree
  need_cmd python3

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  {
    read_list "$RPM_OSTREE_PACKAGES"
    read_list "$BORGMATIC_RPM_OSTREE_PACKAGES"
  } | sort -u >"$expected"
  comm -23 \
    <(actual_rpm_ostree_layered_packages | sort -u) \
    <(read_list "$RPM_OSTREE_ALLOWED" | sort -u) >"$actual"

  print_diff 'rpm-ostree managed packages (Toshy-owned layering allowed)' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_system_flathub() {
  need_cmd flatpak

  printf 'Flatpak system Flathub remote\n'
  if flatpak remotes --system --columns=name |
    sed '/^[[:space:]]*$/d' |
    grep -Fxq flathub; then
    printf '  ok: available from Aurora\n'
  else
    printf '  missing from system: flathub\n'
  fi
}

audit_managed_system_flatpaks() {
  need_cmd flatpak

  local expected actual missing
  expected="$(mktemp)"
  actual="$(mktemp)"
  missing="$(mktemp)"

  sed -n 's/^[[:space:]]*flatpak[[:space:]]*"\([^"]*\)".*$/\1/p' "$BREWFILE" |
    sort -u >"$expected"
  flatpak list --system --app --columns=application |
    sed '/^[[:space:]]*$/d' |
    sort -u >"$actual"
  comm -23 "$expected" "$actual" >"$missing"

  printf 'managed system Flatpaks\n'
  if [[ ! -s "$missing" ]]; then
    printf '  ok: all personal additions are installed\n'
  else
    printf '  missing from system:\n'
    sed 's/^/    /' "$missing"
  fi

  rm -f "$expected" "$actual" "$missing"
}

audit_vscode_extensions() {
  need_cmd code

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  read_list "$VSCODE_EXTENSIONS" | sort -u >"$expected"
  code --list-extensions | sort -u >"$actual"

  print_diff 'VS Code extensions' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_brew_formulae() {
  need_cmd brew

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  sed -n 's/^[[:space:]]*brew[[:space:]]*"\([^"]*\)".*$/\1/p' "$BREWFILE" |
    sort -u >"$expected"
  brew leaves | sort -u >"$actual"

  print_diff 'Homebrew requested formulae' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_home_directory() {
  need_cmd getent

  local expected actual
  expected="$(mktemp)"
  actual="$(mktemp)"

  printf '/var/home/stella\n' >"$expected"
  getent passwd stella | cut -d: -f6 >"$actual"

  print_diff 'stella passwd home' "$expected" "$actual"
  rm -f "$expected" "$actual"
}

audit_host_memory() {
  need_cmd awk
  need_cmd findmnt
  need_cmd getconf
  need_cmd swapon
  need_cmd systemctl

  local swap_status swap_usable_bytes var_fstype var_source managed_oom_swap
  swap_status="$(swapon --show=NAME,SIZE,PRIO --bytes --noheadings --raw | awk '$1 == "/var/swap/swapfile" { print $2, $3 }')"
  swap_usable_bytes="$((17179869184 - $(getconf PAGESIZE)))"
  var_fstype="$(findmnt --noheadings --output FSTYPE --target /var)"
  var_source="$(findmnt --noheadings --output SOURCE --target /var)"

  printf 'host memory defenses\n'
  if [[ "$swap_status" == "$swap_usable_bytes 10" ]]; then
    printf '  ok: 16 GiB disk swap is active at priority 10\n'
  else
    printf '  mismatch: expected active 16 GiB /var/swap/swapfile at priority 10; got %s\n' "${swap_status:-inactive}"
  fi

  if [[ "$var_fstype" == btrfs && "$var_source" == /dev/mapper/luks-* ]]; then
    printf '  ok: swap path is on LUKS-backed Btrfs /var\n'
  else
    printf '  mismatch: expected LUKS-backed Btrfs /var; got %s on %s\n' "$var_fstype" "$var_source"
  fi

  if systemctl is-enabled --quiet var-swap-swapfile.swap; then
    printf '  ok: disk swap unit is enabled\n'
  else
    printf '  mismatch: var-swap-swapfile.swap is not enabled\n'
  fi

  if [[ -e /etc/systemd/system/-.slice.d/50-managed-oom.conf ]]; then
    printf '  mismatch: legacy root-slice ManagedOOMSwap override is present\n'
  else
    printf '  ok: legacy root-slice ManagedOOMSwap override is absent\n'
  fi

  managed_oom_swap="$(systemctl show --property=ManagedOOMSwap --value -- -.slice)"
  if [[ "$managed_oom_swap" == auto ]]; then
    printf '  ok: root slice uses the default ManagedOOMSwap=auto policy\n'
  else
    printf '  mismatch: root slice ManagedOOMSwap is %s, expected auto\n' "$managed_oom_swap"
  fi
}

main() {
  audit_host_memory
  audit_rpm_ostree_packages
  audit_brew_formulae
  audit_system_flathub
  audit_managed_system_flatpaks
  audit_vscode_extensions
  audit_home_directory
}

main "$@"
