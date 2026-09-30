#!/usr/bin/env bash
# Link the launcher from this clone. Re-run after moving the repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/bin}"

case "$TARGET_DIR" in
  -h|--help)
    echo "Usage: bash install.sh [target_bin_dir]"
    echo "Links telemprompit into target_bin_dir (default: ~/.local/bin)."
    echo "Run bash setup_mac.sh to build the app, or let the launcher build it on first use."
    exit 0
    ;;
  -*)
    echo "Unknown option: $TARGET_DIR (try --help)" >&2
    exit 2
    ;;
esac

if [[ $# -gt 1 ]]; then
  echo "Usage: bash install.sh [target_bin_dir]" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Telemprompit requires macOS." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
DEST="$TARGET_DIR/telemprompit"

# Replace old launcher symlinks, but leave unrelated files alone.
if [[ -e "$DEST" && ! -L "$DEST" ]]; then
  echo "Cannot replace $DEST: it is not a symlink." >&2
  exit 1
fi

chmod +x "$SCRIPT_DIR/telemprompit"
ln -sfn "$SCRIPT_DIR/telemprompit" "$DEST"
echo "Installed $DEST -> $SCRIPT_DIR/telemprompit"

case ":$PATH:" in
  *":$TARGET_DIR:"*)
    echo "$TARGET_DIR is already on PATH."
    ;;
  *)
    echo "Add this to ~/.zshrc or ~/.bashrc:"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
    ;;
esac
