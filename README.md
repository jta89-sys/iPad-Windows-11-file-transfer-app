# File Bridge for iPad

A small iPadOS 17+ app for copying individual files between an iPad and Windows 11.

## Build in GitHub — no Mac required

The included Actions workflow uses a GitHub-hosted Mac. Push to `main`, or open **Actions → Build iPad IPA (unsigned) → Run workflow**. After a successful run, download **FileBridge-unsigned** under Artifacts and extract the ZIP to find `FileBridge-unsigned.ipa`.

**This is an unsigned IPA, not an installable app yet.** GitHub supplies Xcode and a Mac but does not supply Apple signing credentials. This workflow requires no secrets and never asks for an Apple password. A separate signing/install process is required before an iPad will run the app. For Apple's registered-device distribution route, a developer will need an appropriate signing certificate and provisioning profile covering your iPad. Do not commit credentials to this repository. No App Store or TestFlight submission is included.

The workflow runs file-copy tests, builds a device executable, verifies the package, and uploads the IPA and a SHA-256 checksum. Artifacts expire after 14 days. Actual USB and SMB transfers require testing with a physical iPad and Windows PC; the automated tests do not establish that those transfers work end to end.

## Install from Windows with a free Apple account

One third-party option is [Sideloadly](https://sideloadly.io/), which supports Windows and free Apple accounts. Download the IPA artifact, extract it, then follow Sideloadly's current setup instructions to sign and install it on your USB-connected iPad. Enter account credentials in the signing tool yourself, not in GitHub or chat. Enable Developer Mode and trust the developer profile if prompted. Free-account installations expire after seven days and need refreshing. This installation route has not been tested with this app on your iPad. See the [Sideloadly FAQ](https://sideloadly.io/faq.html) for requirements and limits.

## Wi-Fi transfers

1. Connect both devices to the same trusted local network.
2. On Windows 11, use a Private network profile. Enable network discovery and file and printer sharing for Private networks under advanced sharing settings. Share a dedicated folder with a named Windows account; give that account write permission in both share and file-system permissions. Keep password-protected sharing enabled.
3. On iPad, open **Files → Browse → … → Connect to Server**. Enter `smb://PC-NAME` or `smb://192.168.x.x` using your PC's actual local address. Choose **Registered User**, and enter the Windows account username and password (not the Windows Hello PIN).
4. In File Bridge, tap **Add files** to copy items into the local inbox. Select files, tap **Copy to folder**, and choose the connected Windows share in the system picker. iPadOS performs the network copy and presents errors or overwrite choices.
5. To receive files from Windows, choose **Add files** and browse to the connected share.

The app uses the iPadOS file provider; it does not implement its own SMB client or store Windows credentials. Connect the share in Files first. A disconnected share must be reconnected in Files.

**Available today without installing this app:** use Files to connect to the Windows share using steps 1–3, then copy/paste files directly to or from the share.

## USB transfers

1. After the signed app is installed, install **Apple Devices** from the Microsoft Store on Windows.
2. Connect your iPad using a data-capable USB cable, unlock it, and trust the computer.
3. Open Apple Devices, select your iPad, then **Files → File Bridge**. Save inbox files to the PC or add files from the PC to File Bridge.
4. Tap **Refresh** in File Bridge to see files added over USB.

The app's Documents directory is exposed through `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. Only individual files appear in the app; ZIP folders before importing. You can manage or delete inbox files in **Files → On My iPad → File Bridge**. Avoid modifying the same file in Apple Devices while a copy is running.

## Behavior and limitations

- Copies preserve source files. Duplicate imports receive numbered names.
- Multiple file selection, file sizes, refresh, and setup instructions are included.
- Imports use security-scoped access and coordinated reading. Copies run off the main UI thread and are staged before appearing in the inbox.
- Keep the app open during import. There is no background transfer service, resume, progress-by-byte display, or transfer cancellation.
- The app stores local copies, so sufficient iPad storage is required. Network export errors are handled by the system picker.
- No analytics, custom network server, or third-party Swift dependencies.
- This initial version has no custom app icon and is intended for personal testing, not App Store submission.

## Local build on a Mac

Open `FileBridge.xcodeproj` in Xcode. Choose a signing team and a unique bundle identifier under Signing & Capabilities. Select your iPad and run. For an unsigned command-line build, use the command in `.github/workflows/build.yml`.

## Physical-device acceptance checks

- Import several files, including a large video, an empty file, a Unicode filename, and duplicates; verify originals remain intact.
- Export to a writable Windows share and compare SHA-256 hashes on Windows with the source files.
- Cancel each picker; disconnect Wi-Fi; try a read-only share; confirm no false success after an error.
- Receive a Windows file from the share and verify its contents.
- Copy both directions over USB in Apple Devices, refresh, and verify hashes.
- Relaunch the app; confirm the inbox persists. Check portrait, landscape, and large text.

## References

- [Apple: transfers to a server using Files](https://support.apple.com/guide/ipad/transfer-files-ipad-a-storage-device-server-ipad8139864c/ipados)
- [Apple: file sharing with Apple Devices for Windows](https://support.apple.com/en-gb/120402)
- [Microsoft: file sharing over a network](https://support.microsoft.com/en-us/windows/experience/connectivity-networking/file-sharing-over-a-network-in-windows)
- [Apple: distributing to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)
- [GitHub: hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)