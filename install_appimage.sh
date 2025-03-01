#!/bin/bash
set -euo pipefail

# Global Variables
DEFAULT_INSTALL_DIR="$HOME/bin"
DESKTOP_ENTRY_DIR="$HOME/.local/share/applications"
ICON_INSTALL_DIR="$HOME/.local/share/icons"
APPIMAGE=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
TMPDIR=""
DRY_RUN=false
DEBUG=false

# Usage message
usage() {
    echo "Usage: $0 -i <AppImage> [-d <installation_directory>] [-n] [-v]"
    echo "  -i   AppImage file to install"
    echo "  -d   Installation directory for the AppImage (default: $DEFAULT_INSTALL_DIR)"
    echo "  -n   Dry-run mode (simulate operations without making changes)"
    echo "  -v   Verbose debug output"
    exit 1
}

# Check that required commands are available
check_dependency() {
    command -v "$1" >/dev/null 2>&1 || { echo "Error: Required dependency '$1' is not installed."; exit 1; }
}

# Debug logging
debug_log() {
    if $DEBUG; then
        echo "[DEBUG] $*"
    fi
}

# Execute a command with dry-run support
execute() {
    if $DRY_RUN; then
        echo "[DRY RUN] $*"
    else
        debug_log "Executing: $*"
        eval "$*"
    fi
}

# Validate that the input file exists, is executable, and of an acceptable MIME type
validate_input() {
    if [[ ! -f "$APPIMAGE" ]]; then
        echo "Error: File '$APPIMAGE' not found or is not a regular file."
        exit 1
    fi

    # Ensure the file is executable; if not, attempt to make it executable
    if [[ ! -x "$APPIMAGE" ]]; then
        echo "Setting execute permission for $APPIMAGE"
        chmod +x "$APPIMAGE"
    fi

    local mime
    mime=$(file --mime-type -b "$APPIMAGE")
    if [[ "$mime" != "application/octet-stream" && "$mime" != "application/x-executable" ]]; then
        echo "Warning: '$APPIMAGE' does not appear to be a typical binary AppImage. Detected MIME type: $mime"
    fi
}

# Parse command-line arguments
parse_args() {
    while getopts "i:d:nv" opt; do
        case "$opt" in
            i) APPIMAGE="$OPTARG" ;;
            d) INSTALL_DIR="$OPTARG" ;;
            n) DRY_RUN=true ;;
            v) DEBUG=true ;;
            *) usage ;;
        esac
    done

    if [[ -z "${APPIMAGE:-}" ]]; then
        usage
    fi
}

# Clean up temporary extraction directory on exit
cleanup() {
    if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
        execute "rm -rf \"$TMPDIR\""
    fi
}
trap cleanup EXIT

# Extract the AppImage into a temporary directory
extract_appimage() {
    TMPDIR=$(mktemp -d) || { echo "Error: Unable to create temporary directory"; exit 1; }
    echo "Extracting AppImage to temporary directory: $TMPDIR"
    pushd "$TMPDIR" > /dev/null
    if $DRY_RUN; then
        echo "[DRY RUN] Would run: $APPIMAGE --appimage-extract"
        # Simulate successful extraction by creating a dummy directory structure.
        mkdir -p "$TMPDIR/squashfs-root"
    else
        "$APPIMAGE" --appimage-extract > /dev/null 2>&1
    fi
    popd > /dev/null
    if $DRY_RUN; then
        echo "[DRY RUN] Skipping extraction directory existence check."
    else
        if [[ ! -d "$TMPDIR/squashfs-root" ]]; then
            echo "Error: Extraction failed."
            exit 1
        fi
    fi
}

# Find the .desktop file and icon inside the extracted content
find_desktop_and_icon() {
    DESKTOP_FILE=$(find "$TMPDIR/squashfs-root" -maxdepth 2 -type f -name "*.desktop" | head -n 1)
    if [[ -z "$DESKTOP_FILE" ]]; then
        echo "Error: No .desktop file found in the AppImage."
        exit 1
    fi
    echo "Found desktop file: $DESKTOP_FILE"
    APP_NAME=$(basename "$DESKTOP_FILE" .desktop)

    ICON_NAME=$(grep -i '^Icon=' "$DESKTOP_FILE" | head -n 1 | cut -d '=' -f2)
    if [[ -z "$ICON_NAME" ]]; then
        echo "Error: No Icon entry found in the .desktop file."
        exit 1
    fi

    ICON_PATH=$(find "$TMPDIR/squashfs-root" -type f \( -iname "${ICON_NAME}.png" -o -iname "${ICON_NAME}.svg" \) | head -n 1)
    if [[ -z "$ICON_PATH" ]]; then
        echo "Error: Icon file not found."
        exit 1
    fi
    echo "Found icon file: $ICON_PATH"
}

# Copy the AppImage and icon to the appropriate directories
copy_files() {
    # Create installation directory for AppImage if needed
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo "Creating installation directory: $INSTALL_DIR"
        execute "mkdir -p \"$INSTALL_DIR\""
    fi

    DEST_APPIMAGE="$INSTALL_DIR/${APP_NAME}.AppImage"
    echo "Copying AppImage to $DEST_APPIMAGE"
    if $DRY_RUN; then
        echo "[DRY RUN] cp \"$APPIMAGE\" \"$DEST_APPIMAGE\""
        echo "[DRY RUN] chmod +x \"$DEST_APPIMAGE\""
    else
        cp "$APPIMAGE" "$DEST_APPIMAGE"
        chmod +x "$DEST_APPIMAGE"
    fi

    # Create icon installation directory if needed
    if [[ ! -d "$ICON_INSTALL_DIR" ]]; then
        echo "Creating icon directory: $ICON_INSTALL_DIR"
        execute "mkdir -p \"$ICON_INSTALL_DIR\""
    fi

    EXT="${ICON_PATH##*.}"
    DEST_ICON="$ICON_INSTALL_DIR/${APP_NAME}.${EXT}"
    echo "Copying icon to $DEST_ICON"
    execute "cp \"$ICON_PATH\" \"$DEST_ICON\""
}

# Create a desktop entry in the user's local applications directory
create_desktop_entry() {
    execute "mkdir -p \"$DESKTOP_ENTRY_DIR\""
    DEST_DESKTOP="$DESKTOP_ENTRY_DIR/${APP_NAME}.desktop"
    echo "Creating desktop entry at $DEST_DESKTOP"
    if $DRY_RUN; then
        echo "[DRY RUN] Would create desktop entry with the following content:"
        cat <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$DEST_APPIMAGE
Icon=$DEST_ICON
Type=Application
Categories=Utility;
EOF
    else
        cat > "$DEST_DESKTOP" <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$DEST_APPIMAGE
Icon=$DEST_ICON
Type=Application
Categories=Utility;
EOF
    fi
}

### Main Execution Flow ###

# Check required dependencies
for dep in mktemp find grep file; do
    check_dependency "$dep"
done

parse_args "$@"
validate_input
extract_appimage
find_desktop_and_icon
copy_files
create_desktop_entry

echo "Installation of '$APP_NAME' completed successfully."

