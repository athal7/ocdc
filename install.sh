#!/usr/bin/env bash
#
# Install devcontainer-multi scripts
#

set -euo pipefail

INSTALL_DIR="${1:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing devcontainer-multi to $INSTALL_DIR"

# Create install directory if needed
mkdir -p "$INSTALL_DIR"

# Copy scripts
for script in dcup dcdown dclist dcexec dcgo dctui; do
  if [[ -f "$SCRIPT_DIR/bin/$script" ]]; then
    cp "$SCRIPT_DIR/bin/$script" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
    echo "  Installed: $script"
  fi
done

# Check if install dir is in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  echo ""
  echo "Note: $INSTALL_DIR is not in your PATH."
  echo "Add this to your shell profile:"
  echo ""
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

# Check dependencies
echo ""
echo "Checking dependencies..."

if ! command -v jq >/dev/null 2>&1; then
  echo "  WARNING: jq not found. Install with: brew install jq"
fi

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "  WARNING: devcontainer CLI not found. Install with: npm install -g @devcontainers/cli"
fi

echo ""
echo "Installation complete!"
echo ""
echo "Commands:"
echo "  dcup [branch]   - Start devcontainer"
echo "  dcdown          - Stop devcontainer"
echo "  dclist          - List instances"
echo "  dcgo [branch]   - Navigate to clone"
echo "  dcexec <cmd>    - Execute in container"
echo "  dctui           - Interactive TUI"
