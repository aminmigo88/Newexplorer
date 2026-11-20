# Newexplorer 0.2.0

An iPhone file explorer for copying files between two independently navigable panes. The panes stack in portrait and sit side by side in landscape.

## Try the first build

Open Newexplorer.xcodeproj in Xcode, select the Newexplorer scheme and an iPhone running iOS 17 or later, and run the app. The project resolves AMSMB2, LibArchive and ZIPFoundation with Swift Package Manager.

1. Tap the location in pane A to choose a Files folder or Photos. For a Windows destination, tap the location in pane B and choose **Windows share…**. Enter the computer name or IP address, the shared folder name and the credentials for a Windows account with access to that share. Both devices must be able to reach each other on the LAN. Credentials live only in memory.
2. Tap the circles beside files or folders, then **Copy**. In the other pane tap **Paste here**. Each item is staged before it gets its final name. A filename conflict stops the batch and leaves the remaining items on the shelf. The phone needs temporary space for one selected item at a time. Keep the app open for large transfers.
3. In Photos, allow selected or full access. Exporting preserves original media bytes. Related resources such as the still and motion parts of a Live Photo are exported together in a folder. iCloud may need to download an original. Pasting a single supported image or movie into Photos imports it.
4. In a Files folder, long-press an item for **Create ZIP**, choose **Extract here** on a ZIP or RAR file, or use the pane menu to find exact duplicate files and empty folders. Use Search to filter the loaded location. The pane menu also provides New folder, sorting and selection controls. Long-press to rename or delete an item. Delete selected removes the selected files after confirmation. The report groups nonempty files by size and SHA-256. A scan can download cloud-backed files. File contents alone do not indicate whether deleting a copy is safe. Use the review to choose which copies to delete through the file browser. The app menu can clear temporary transfer files.

## Current scope

This first version uses the app’s documents folder, directories granted through the iOS picker, PhotoKit and authenticated SMB shares. Folder grants last for the session. Network copies may leave a temporary .NX- item on a share if the Wi-Fi connection is lost. The scanner is read-only. File deletion is permanent outside Photos, so confirm the selected location and items. Photos deletion also affects iCloud Photos and other synced devices. Encrypted or multipart RAR support, archive browsing, destructive moves and reviewed deletion are future work. Native RAR creation requires a separate encoder.

## Validation

The simulator workflow builds the app and runs the local copy, collision, archive and duplicate-scan tests. First device checks are folder-picker access, limited Photos access, Live Photo export, and copying in both directions against a real Windows share. For the network check, compare the transferred file with its source and repeat a copy with Wi-Fi disconnected partway through. The source should remain intact. After successful simulator tests, the main-branch workflow builds an unsigned arm64 iPhone app, verifies its embedded framework and packages an IPA for signing with KravaSigner. The signing service must sign the embedded AMSMB2 framework as well as the app.
