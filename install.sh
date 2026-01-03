#!/usr/bin/env bash
#
# Install ocdc
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/athal7/ocdc/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/athal7/ocdc/main/install.sh | bash -s -- ~/.local/bin
#

set -euo pipefail

INSTALL_DIR="${1:-$HOME/.local/bin}"
LIB_DIR="$INSTALL_DIR/../lib"
REPO="athal7/ocdc"
LIB_SCRIPTS="ocdc-up ocdc-down ocdc-list ocdc-exec ocdc-go ocdc-tui ocdc-clean ocdc-poll ocdc-paths.bash ocdc-sessions.bash ocdc-poll-config.bash ocdc-poll-defaults.bash ocdc-poll-fetch.bash ocdc-poll-filter.bash ocdc-file-lock.bash ocdc-yaml.bash"

echo "Installing ocdc to $INSTALL_DIR"

# Create install directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$LIB_DIR"

# Check if we're running from a local clone or need to download
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null)" && pwd 2>/dev/null)" || SCRIPT_DIR=""

if [[ -n "$SCRIPT_DIR" ]] && [[ -f "$SCRIPT_DIR/bin/ocdc" ]]; then
  # Local install from clone
  echo "Installing from local directory..."
  
  # Install main executable
  cp "$SCRIPT_DIR/bin/ocdc" "$INSTALL_DIR/ocdc"
  chmod +x "$INSTALL_DIR/ocdc"
  echo "  Installed: bin/ocdc"
  
  # Install lib scripts
  for script in $LIB_SCRIPTS; do
    if [[ -f "$SCRIPT_DIR/lib/$script" ]]; then
      cp "$SCRIPT_DIR/lib/$script" "$LIB_DIR/$script"
      chmod +x "$LIB_DIR/$script"
      echo "  Installed: lib/$script"
    fi
  done
else
  # Remote install - download from GitHub
  echo "Downloading from GitHub..."
  
  # Download main executable
  echo "  Downloading: bin/ocdc"
  if curl -fsSL "https://raw.githubusercontent.com/$REPO/main/bin/ocdc" -o "$INSTALL_DIR/ocdc"; then
    chmod +x "$INSTALL_DIR/ocdc"
    echo "  Installed: bin/ocdc"
  else
    echo "  ERROR: Failed to download ocdc"
    exit 1
  fi
  
  # Download lib scripts
  for script in $LIB_SCRIPTS; do
    echo "  Downloading: lib/$script"
    if curl -fsSL "https://raw.githubusercontent.com/$REPO/main/lib/$script" -o "$LIB_DIR/$script"; then
      chmod +x "$LIB_DIR/$script"
      echo "  Installed: lib/$script"
    else
      echo "  ERROR: Failed to download $script"
      exit 1
    fi
  done
fi

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

missing_deps=false
if ! command -v jq >/dev/null 2>&1; then
  echo "  WARNING: jq not found. Install with: brew install jq"
  missing_deps=true
fi

if ! command -v devcontainer >/dev/null 2>&1; then
  echo "  WARNING: devcontainer CLI not found. Install with: npm install -g @devcontainers/cli"
  missing_deps=true
fi

if [[ "$missing_deps" == "false" ]]; then
  echo "  All dependencies found!"
fi

echo ""
echo "Installation complete!"
echo ""
echo "Commands:"
echo "  ocdc                # Launch TUI or show help"
echo "  ocdc up [branch]    # Start devcontainer"
echo "  ocdc down           # Stop devcontainer"
echo "  ocdc list           # List instances"
echo "  ocdc go [branch]    # Navigate to clone"
echo "  ocdc exec <cmd>     # Execute in container"
echo "  ocdc poll           # Run poll manually (once)"
echo ""
echo "Optional: Set up automatic polling"
echo "  See: https://github.com/athal7/ocdc#automatic-polling-optional"
echo "  Or install via Homebrew for automatic setup: brew install athal7/tap/ocdc"
