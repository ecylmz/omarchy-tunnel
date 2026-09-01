#!/usr/bin/env bash

# Lint the plugin against the Omarchy/Quickshell import layout.
#
# Omarchy's runtime exposes its shell tree under the `qs` QML namespace.
# qmllint does not receive that alias automatically, so a direct
#   qmllint -I "$OMARCHY_PATH/shell" ...
# is insufficient on a stock Quattro installation. Build a temporary import
# root containing qs -> <omarchy>/shell, matching the runtime namespace.
#
# Two qmllint warning classes are known tooling limitations rather than plugin
# defects in this environment:
#   - missing-property for nested Style.* / Color.* singleton groups
#   - signal-handler-parameters for Quickshell Process.exited's
#     QProcess::ExitStatus parameter
# Everything else, especially [unqualified], is treated as a failure.

set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
PLUGIN_DIR="$(dirname -- "$TEST_DIR")"
readonly PLUGIN_DIR

# Omarchy 4 package installs to /usr/share/omarchy. Respect a development
# checkout when OMARCHY_PATH is set, but tolerate terminals with a missing or
# stale pre-Quattro value.
omarchy_root="${OMARCHY_PATH:-/usr/share/omarchy}"
if [[ ! -d "$omarchy_root/shell" && -d /usr/share/omarchy/shell ]]; then
  omarchy_root=/usr/share/omarchy
fi
readonly SHELL_ROOT="$omarchy_root/shell"
readonly QML_ROOT="${OMARCHY_QML_ROOT:-/usr/lib/qt6/qml}"

QMLLINT="$(command -v qmllint 2>/dev/null || true)"
[[ -x "$QMLLINT" ]] || QMLLINT=/usr/lib/qt6/bin/qmllint

if [[ ! -x "$QMLLINT" ]]; then
  echo "lint: qmllint not found" >&2
  echo "lint: install it with: omarchy pkg add qt6-declarative" >&2
  exit 127
fi

if [[ ! -d "$SHELL_ROOT" ]]; then
  echo "lint: Omarchy shell modules not found at $SHELL_ROOT" >&2
  echo "lint: current OMARCHY_PATH=${OMARCHY_PATH:-<unset>}" >&2
  exit 1
fi

if [[ ! -d "$QML_ROOT" ]]; then
  echo "lint: Qt QML import root not found at $QML_ROOT" >&2
  exit 1
fi

import_root="$(mktemp -d)" || exit 1
trap 'rm -rf "$import_root"' EXIT
ln -s "$SHELL_ROOT" "$import_root/qs"

status=0
shopt -s nullglob
qml_files=("$PLUGIN_DIR"/*.qml "$PLUGIN_DIR"/components/*.qml)

if (( ${#qml_files[@]} == 0 )); then
  echo "lint: no QML files found" >&2
  exit 1
fi

for qml in "${qml_files[@]}"; do
  echo "qmllint ${qml#"$PLUGIN_DIR"/}"

  output=$("$QMLLINT" -I "$QML_ROOT" -I "$import_root" "$qml" 2>&1)
  lint_exit=$?

  remaining=$(grep -E '^(Warning|Error)' <<<"$output" \
    | grep -vE 'missing-property|signal-handler-parameters' || true)

  if [[ -n "$remaining" ]]; then
    printf '%s\n' "$remaining"
    status=1
  elif (( lint_exit != 0 )); then
    # Keep a non-zero qmllint exit visible even when its diagnostics did not
    # match the normal Warning/Error prefix.
    printf '%s\n' "$output"
    status=1
  else
    expected=$(grep -cE 'missing-property|signal-handler-parameters' <<<"$output" || true)
    printf '  clean (%s expected tooling warning(s) suppressed)\n' "$expected"
  fi
done

exit "$status"
