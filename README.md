# appimage-installer
A Bash script that automates AppImage installation by extracting embedded icons and desktop files, installing the AppImage to a user-specified directory, and creating a corresponding desktop entry.


## Usage
Run the script with the required -i flag to specify the AppImage file. Optionally, use the -d flag to set a custom installation directory for the AppImage executable (default is ~/bin), -n for dry-run mode, or -v for debug mode.
```bash
./install_appimage.sh -i <AppImage> [-d <installation_directory>] [-n] [-v]
```
### Examples

- Standard Installation:
```bash
./install_appimage.sh -i ~/Downloads/MyApp.AppImage
```

- Custom Installation Directory with Debug Output:
```bash
./install_appimage.sh -i ~/Downloads/MyApp.AppImage -d ~/custom_bin -v
```
- Dry-Run Mode (Simulation Only):
```bash
    ./install_appimage.sh -i ~/Downloads/MyApp.AppImage -n
```
## Dependencies

Ensure that the following utilities are available on your system:
```bash
    mktemp
    find
    grep
    file
```

These are typically pre-installed on most Unix-like systems.
Contributing
Contributions are welcome! If you encounter any issues or have suggestions for improvements, please open an issue or submit a pull request.
MIT License


