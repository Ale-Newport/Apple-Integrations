#!/bin/zsh
# Builds the Release app and installs it (default: /Applications).
#
#   scripts/install.sh                 install into /Applications
#   scripts/install.sh ~/Applications  install somewhere else
#
# Quit Jarvis first. The copy keeps the signature, so privacy permissions you already granted to this build identity
# (see Config/Local.xcconfig.example) stay valid.
set -eu
cd "$(dirname "$0")/.."
dest="${1:-/Applications}"
name="Jarvis Apple Integrations.app"

if pgrep -x "Jarvis Apple Integrations" >/dev/null; then
  echo "Jarvis is running — quit it first (menu bar icon ▸ power button, or ⌘Q)." >&2
  exit 1
fi

scripts/build.sh Release build
src="build/DerivedData/Build/Products/Release/$name"
[[ -d "$src" ]] || { echo "Build did not produce $src" >&2; exit 1; }

mkdir -p "$dest"
if [[ -d "$dest/$name" ]]; then
  echo "Replacing the existing $dest/$name"
  rm -rf "$dest/$name"
fi
ditto "$src" "$dest/$name"
codesign --verify --deep --strict "$dest/$name" && echo "Signature OK"
echo "Installed: $dest/$name"
echo "Open it with:  open \"$dest/$name\""
