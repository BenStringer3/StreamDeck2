#!/bin/bash
# Script to copy all repository content to clipboard
# Uses wl-copy (wl-clipboard) for Wayland/Hyprland

set -euo pipefail

# Check for required commands
command -v wl-copy >/dev/null 2>&1 || { echo "Error: wl-clipboard is not installed" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT=""

# Add repository structure
OUTPUT+="=== Repository Structure ===\n\n"
OUTPUT+="$(cd "$REPO_DIR" && find . -type f -not -path './.git/*' -not -name 'copy-repo.sh' | sort)\n\n"

# Add file contents
OUTPUT+="=== File Contents ===\n\n"

while IFS= read -r file; do
    # Skip the script itself
    [[ "$file" == "./copy-repo.sh" ]] && continue
    
    OUTPUT+="--- $file ---\n"
    OUTPUT+="$(cat "$REPO_DIR/$file")\n\n"
done < <(cd "$REPO_DIR" && find . -type f -not -path './.git/*' -not -name 'copy-repo.sh' | sort)

# Copy to clipboard
echo -e "$OUTPUT" | wl-copy

echo "Repository content copied to clipboard!"
