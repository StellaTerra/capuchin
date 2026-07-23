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

main() {
  audit_rpm_ostree_packages
  audit_brew_formulae
  audit_system_flathub
  audit_managed_system_flatpaks
  audit_vscode_extensions
  audit_home_directory
}

main "$@"
