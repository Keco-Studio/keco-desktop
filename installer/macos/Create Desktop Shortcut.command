#!/bin/zsh
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_app="$script_dir/Keco Studio.app"
system_app="/Applications/Keco Studio.app"
user_app_dir="$HOME/Applications"
user_app="$user_app_dir/Keco Studio.app"
desktop_link="$HOME/Desktop/Keco Studio.app"

if [[ ! -d "$source_app" ]]; then
  osascript -e 'display dialog "Open this file from the Keco Studio disk image." buttons {"OK"} with icon caution' >/dev/null 2>&1 || true
  exit 1
fi

if [[ -d "$system_app" ]]; then
  target_app="$system_app"
else
  mkdir -p "$user_app_dir"
  if [[ ! -d "$user_app" ]]; then
    ditto "$source_app" "$user_app"
  fi
  target_app="$user_app"
fi

ln -sfn "$target_app" "$desktop_link"
osascript -e 'tell application "Finder" to update desktop' >/dev/null 2>&1 || true
osascript -e 'display dialog "Keco Studio desktop shortcut created." buttons {"OK"} with icon note' >/dev/null 2>&1 || true
