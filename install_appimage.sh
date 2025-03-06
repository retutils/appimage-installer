#!/usr/bin/env bash
set -euo pipefail

#######################################
# Global Constants / Default Values
#######################################
DEFAULT_INSTALL_DIR="$HOME/bin"
DESKTOP_ENTRY_DIR="$HOME/.local/share/applications"
ICON_INSTALL_DIR="$HOME/.local/share/icons"

# Exit codes for more specific error reporting
ERR_DEPENDENCY=2
ERR_INPUT=3
ERR_EXTRACTION=4
ERR_CHECKSUM=5
ERR_INSTALL=6
ERR_UNKNOWN=99

#######################################
# Script variables (can be overridden by CLI args)
#######################################
APPIMAGE=""
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
TMPDIR=""
DRY_RUN=false
DEBUG=false
CHECKSUM=""
CHECKSUM_FILE=""
FORCE=false
UPDATE=false
REINSTALL=false
CREATE_FALLBACK_DESKTOP=true

#######################################
# Usage / Help
#######################################
usage() {
    cat <<EOF
Usage: $0 -i <AppImage> [options]
  -i <AppImage>          Path to the AppImage file to install
  -d <directory>         Installation directory (default: $DEFAULT_INSTALL_DIR)
  -c <checksum>          Expected SHA256 checksum of the AppImage (string)
  -C <checksum_file>     Path to a file containing the expected SHA256 hash
  -u                     Update an existing installation (if found)
  -r                     Reinstall (overwrite) if an existing installation is found
  -n                     Dry-run mode (simulate actions without making changes)
  -v                     Verbose debug output
  -f                     Force certain actions (e.g., skip warnings)
  --no-fallback-desktop  Do not create a fallback .desktop file if none is found
  -h                     Show this help message
EOF
    exit 1
}

#######################################
# Check whether a command is available
# You can add version checks here if needed.
#######################################
check_dependency() {
    local dep="$1"
    if ! command -v "$dep" &>/dev/null; then
        echo "Error: Required dependency '$dep' is not installed."
        exit $ERR_DEPENDENCY
    fi

    # Example of minimal version check (commented out):
    # if [[ "$dep" == "sha256sum" ]]; then
    #     local ver
    #     ver=$(sha256sum --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+' || true)
    #     # If you require version >= 8.30 for example, parse and compare
    # fi
}

#######################################
# Debug logging
#######################################
debug_log() {
    if $DEBUG; then
        echo "[DEBUG] $*"
    fi
}

#######################################
# Safe command execution (no eval)
#######################################
execute() {
    if $DRY_RUN; then
        echo "[DRY RUN]" "$@"
    else
        debug_log "Executing: $*"
        "$@"
    fi
}

#######################################
# Parse command-line arguments
#######################################
parse_args() {
    # We need long-option handling for --no-fallback-desktop.
    # One approach is to check each argument manually in a loop.
    # Then we exit that loop and parse short options via getopts. 
    # Alternatively, you can parse everything manually. 
    # For simplicity, we do a quick loop for the long option:
    for arg in "$@"; do
        case "$arg" in
            --no-fallback-desktop)
                CREATE_FALLBACK_DESKTOP=false
                # Remove this argument from $@
                shift # or shift once to skip it
                ;;
        esac
    done

    while getopts "i:d:c:C:nvfruh" opt; do
        case "$opt" in
            i) APPIMAGE="$OPTARG" ;;
            d) INSTALL_DIR="$OPTARG" ;;
            c) CHECKSUM="$OPTARG" ;;
            C) CHECKSUM_FILE="$OPTARG" ;;
            n) DRY_RUN=true ;;
            v) DEBUG=true ;;
            f) FORCE=true ;;
            r) REINSTALL=true ;;
            u) UPDATE=true ;;
            h|?) usage ;;
        esac
    done

    # Ensure we have at least an AppImage
    if [[ -z "${APPIMAGE:-}" ]]; then
        echo "Error: Missing required -i <AppImage> argument."
        usage
        exit $ERR_INPUT
    fi
}

#######################################
# Validate input file, set executable permission
#######################################
validate_input() {
    if [[ ! -f "$APPIMAGE" ]]; then
        echo "Error: File '$APPIMAGE' not found or is not a regular file."
        exit $ERR_INPUT
    fi

    if [[ ! -x "$APPIMAGE" ]]; then
        echo "Setting execute permission on $APPIMAGE"
        chmod +x "$APPIMAGE"
    fi

    local mime
    mime=$(file --mime-type -b "$APPIMAGE")
    if [[ "$mime" != "application/octet-stream" && "$mime" != "application/x-executable" ]]; then
        echo "Warning: '$APPIMAGE' doesn't seem like a typical binary AppImage. (MIME: $mime)"
        if ! $FORCE; then
            echo "Use -f to force the installation despite this warning."
            exit $ERR_INPUT
        fi
    fi
}

#######################################
# Optional checksum verification
#######################################
verify_checksum() {
    if [[ -z "$CHECKSUM" && -z "$CHECKSUM_FILE" ]]; then
        debug_log "No checksum provided, skipping verification."
        return
    fi

    debug_log "Verifying SHA256 checksum..."

    local expected=""
    if [[ -n "$CHECKSUM_FILE" ]]; then
        if [[ ! -f "$CHECKSUM_FILE" ]]; then
            echo "Error: checksum file '$CHECKSUM_FILE' not found."
            exit $ERR_CHECKSUM
        fi
        expected=$(<"$CHECKSUM_FILE")
    else
        expected="$CHECKSUM"
    fi

    local actual
    actual=$(sha256sum "$APPIMAGE" | awk '{print $1}')

    if [[ "$actual" != "$expected" ]]; then
        echo "Error: Checksum verification failed!"
        echo "Expected: $expected"
        echo "Actual:   $actual"
        exit $ERR_CHECKSUM
    fi

    echo "Checksum verified successfully."
}

#######################################
# Clean up temporary directory on exit
#######################################
cleanup() {
    if [[ -n "${TMPDIR:-}" && -d "$TMPDIR" ]]; then
        execute rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

#######################################
# Extract the AppImage
#######################################
extract_appimage() {
    TMPDIR=$(mktemp -d) || {
        echo "Error: Unable to create temporary directory."
        exit $ERR_EXTRACTION
    }
    echo "Extracting AppImage to $TMPDIR"

    pushd "$TMPDIR" > /dev/null
    if $DRY_RUN; then
        echo "[DRY RUN] Would run: $APPIMAGE --appimage-extract"
        # Create a minimal simulation
        mkdir -p "$TMPDIR/squashfs-root"
        # Also simulate a fake desktop file if you want the script to proceed
        # with the "find .desktop" logic in dry-run mode:
        cat <<EOF > "$TMPDIR/squashfs-root/fake.desktop"
[Desktop Entry]
Name=FakeApp
Exec=fakeExec
Icon=fakeIcon
Type=Application
Categories=Utility;
EOF
    else
        if ! "$APPIMAGE" --appimage-extract > /dev/null 2>&1; then
            echo "Error: Extraction failed."
            popd > /dev/null
            exit $ERR_EXTRACTION
        fi
    fi
    popd > /dev/null

    if [[ ! -d "$TMPDIR/squashfs-root" ]]; then
        echo "Error: Extraction failed. 'squashfs-root' not found."
        exit $ERR_EXTRACTION
    fi
}

#######################################
# Check if installation already exists for update/reinstall logic
#######################################
check_existing_installation() {
    # We'll consider an existing installation if there's a matching AppImage
    # in the target INSTALL_DIR. Adjust if you prefer other heuristics.
    local base="$(basename "$APPIMAGE")"
    local existing_appimage="$INSTALL_DIR/$base"

    if [[ -f "$existing_appimage" ]]; then
        echo "Found existing AppImage at $existing_appimage."

        if $UPDATE; then
            echo "Proceeding with update."
        elif $REINSTALL; then
            echo "Reinstall requested, will overwrite."
        else
            # If user didn't specify -u or -r, prompt:
            read -r -p "Reinstall/overwrite existing installation? [y/N] " ans
            case "$ans" in
                [Yy]* ) echo "Overwriting existing install." ;;
                * ) echo "Installation canceled." ; exit 0 ;;
            esac
        fi
    fi
}

#######################################
# Locate the .desktop file and icon in the extracted content
#######################################
find_desktop_and_icon() {
    DESKTOP_FILE=$(find "$TMPDIR/squashfs-root" -maxdepth 2 -type f -name "*.desktop" | head -n 1)
    if [[ -z "$DESKTOP_FILE" ]]; then
        echo "Warning: No .desktop file found in the AppImage."

        if $CREATE_FALLBACK_DESKTOP; then
            echo "Creating a fallback .desktop file."
            DESKTOP_FILE="$TMPDIR/squashfs-root/fallback.desktop"
            local fallback_name
            fallback_name="$(basename "$APPIMAGE" .AppImage)"

            cat <<EOF > "$DESKTOP_FILE"
[Desktop Entry]
Name=$fallback_name
Exec=$fallback_name
Icon=$fallback_name
Type=Application
Categories=Utility;
EOF
        else
            echo "No fallback .desktop creation requested. Exiting."
            exit $ERR_INSTALL
        fi
    fi

    echo "Using desktop file: $DESKTOP_FILE"
    APP_NAME=$(basename "$DESKTOP_FILE" .desktop)

    ICON_NAME=$(grep -i '^Icon=' "$DESKTOP_FILE" | head -n 1 | cut -d '=' -f2 | xargs)
    if [[ -z "$ICON_NAME" ]]; then
        echo "Warning: No Icon entry found in .desktop file, setting an empty icon."
        ICON_NAME="$APP_NAME"
    fi

    # Search for possible icon files in the extracted root
    ICON_PATH=$(find "$TMPDIR/squashfs-root" -type f \( -iname "${ICON_NAME}.png" -o -iname "${ICON_NAME}.svg" -o -iname "${ICON_NAME}.ico" \) | head -n 1)
    if [[ -z "$ICON_PATH" ]]; then
        echo "Warning: Could not find an icon matching '${ICON_NAME}' in the AppImage."
        # If no icon is found, we could create a placeholder or skip the icon.
        # For now, let's skip it and let the .desktop reference a missing icon.
        ICON_PATH=""
    else
        echo "Found icon: $ICON_PATH"
    fi
}

#######################################
# Copy the AppImage and icon to the install directories
#######################################
copy_files() {
    # Ensure the install directory exists
    if [[ ! -d "$INSTALL_DIR" ]]; then
        echo "Creating install directory: $INSTALL_DIR"
        execute mkdir -p "$INSTALL_DIR"
    fi

    # Name the installed file after the .desktop's base name
    local dest_appimage="$INSTALL_DIR/${APP_NAME}.AppImage"
    echo "Copying AppImage to $dest_appimage"
    if $DRY_RUN; then
        echo "[DRY RUN] cp \"$APPIMAGE\" \"$dest_appimage\""
    else
        cp "$APPIMAGE" "$dest_appimage"
        chmod +x "$dest_appimage"
    fi

    # Copy icon (if we found one)
    if [[ -n "$ICON_PATH" ]]; then
        if [[ ! -d "$ICON_INSTALL_DIR" ]]; then
            echo "Creating icon directory: $ICON_INSTALL_DIR"
            execute mkdir -p "$ICON_INSTALL_DIR"
        fi
        local ext="${ICON_PATH##*.}"
        local dest_icon="$ICON_INSTALL_DIR/${APP_NAME}.${ext}"
        echo "Copying icon to $dest_icon"
        execute cp "$ICON_PATH" "$dest_icon"
    fi
}

#######################################
# Create a .desktop file in the user applications directory
#######################################
create_desktop_entry() {
    execute mkdir -p "$DESKTOP_ENTRY_DIR"
    local dest_desktop="$DESKTOP_ENTRY_DIR/${APP_NAME}.desktop"
    echo "Creating desktop entry at $dest_desktop"

    local desktop_icon_ref=""
    # If we successfully placed an icon, reference it
    # (the extension might be png, svg, or something else)
    if [[ -n "$ICON_PATH" ]]; then
        local icon_ext="${ICON_PATH##*.}"
        desktop_icon_ref="$ICON_INSTALL_DIR/${APP_NAME}.${icon_ext}"
    fi

    if $DRY_RUN; then
        echo "[DRY RUN] Would create .desktop with content:"
        cat <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$INSTALL_DIR/${APP_NAME}.AppImage
Icon=$desktop_icon_ref
Type=Application
Categories=Utility;
EOF
    else
        cat > "$dest_desktop" <<EOF
[Desktop Entry]
Name=$APP_NAME
Exec=$INSTALL_DIR/${APP_NAME}.AppImage
Icon=$desktop_icon_ref
Type=Application
Categories=Utility;
EOF
    fi
}

#######################################
# Main
#######################################
main() {
    # 1) Check dependencies
    for dep in mktemp find grep file sha256sum; do
        check_dependency "$dep"
    done

    # 2) Parse arguments
    parse_args "$@"

    # 3) Validate input
    validate_input

    # 4) Verify optional checksum
    verify_checksum

    # 5) Check existing installation for update/reinstall logic
    check_existing_installation

    # 6) Extract AppImage
    extract_appimage

    # 7) Find .desktop & icon
    find_desktop_and_icon

    # 8) Copy files
    copy_files

    # 9) Create .desktop file
    create_desktop_entry

    # 10) Done
    echo "Installation of '${APP_NAME}' completed successfully."
    exit 0
}

main "$@"
