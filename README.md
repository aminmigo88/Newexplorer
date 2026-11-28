# Newexplorer

A two-pane file explorer for iPhone. Browse two places at once and copy or move files between them: Newexplorer's own folder, On My iPhone, iCloud Drive, folders from the Files app, the Photos library and shared folders on Windows PCs. Archives open like folders, files open in a built-in viewer, DXF drawings open in a drawing viewer, STL, OBJ, 3MF, STEP and IGES models open in a 3D view, and a storage review finds duplicate files and empty folders.

**Version 0.12.0 (build 17)** · iPhone with iOS 17 or later · SwiftUI

> [!IMPORTANT]
> The app's bundle ID must be exactly the App ID in your signing profile. If it isn't, the app installs but can't use the files and folders you pick in Files. See [Signing and the bundle ID](#signing-and-the-bundle-id).

## Features

### Two panes or tabs

- Two independent panes, each with its own location, folder, search, sort order and selection. They stack in portrait and sit side by side in landscape.
- **Tab mode**: the button next to the ⚙︎ gear shows one pane over the whole screen, with a Chrome-style tab for each pane at the bottom, labelled with its address. Both panes stay loaded, so each tab keeps its folder and scroll position. Tap the button again to see both panes. The app remembers the mode.
- On first launch both panes show **App files**. While it's empty, a pane lists the places it can open.

### Address bar and location menu

- Each pane shows its full address, for example `On My iPhone/Downloads/Documents`, `MSI/shared` or `Photos/Others`. Tap any part to go back to it. ↑ opens the parent folder.
- The bordered icon before the address opens the location menu:
  - At the top: **On My iPhone**, **iCloud Drive**, **Open Photos** and **Connect to Windows**.
  - Below a divider: **App files**, **Reopen** *(the pane's last Files folder)*, **Open a folder in this pane** and **Browse Files locations**.
  - Then your saved Windows shares.

### Locations

| Location | What it shows |
|---|---|
| App files | Newexplorer's own Documents folder. It also appears in the Files app under On My iPhone › Newexplorer. |
| On My iPhone, iCloud Drive | One list: the items at the top level plus the app folders you added. |
| Files folder | Any folder opened with **Open a folder in this pane**, from any provider the Files app shows. |
| Selected files | Single files chosen with **Browse Files locations**, for this session. |
| Photos | The photo library in folders: All, Pictures, Videos, Screenshots, Others and your albums. |
| Windows share | A shared folder on a PC, Mac or NAS drive, over SMB. |
| Archive | A ZIP, RAR, TAR, TGZ or ISO file, opened read-only. |

What you can do in each:

| Location | Copy from | Paste into | Cut (move) | Delete | New folder, Rename | Search subfolders | Thumbnails |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| App files, Files folder | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| On My iPhone, iCloud Drive | ✅ | ✅ ¹ | ✅ | ✅ ² | ✅ ¹ | ✅ | ✅ |
| Selected files | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Photos | ✅ | ✅ ³ | ❌ | ✅ ⁴ | ❌ | ❌ | ✅ |
| Windows share | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Archive | ✅ ⁵ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ |

1. Paste and New folder act on the top level. Inside an added app folder, the pane works like a Files folder.
2. Deletes the items stored at the top level. Added app folders are only removed from the list.
3. Images and videos only. Pasting into an album folder also adds them to that album.
4. iOS asks you to confirm. With iCloud Photos on, they're deleted on your other devices too.
5. Copy then Paste unpacks only the selected items.

### On My iPhone and iCloud Drive

- Choose **On My iPhone** or **iCloud Drive** in a pane's location menu. The first time, tap **Open the top of On My iPhone** (or iCloud Drive) and press **Open** at the top level in Files.
- iOS gives an app only the items stored directly at that top level. Each app's folder (in iCloud Drive, for example Pages) is a separate grant, so tap **Add app folders** and tick the ones you want, several at a time when the picker allows.
- Both panes share the list, and it stays after a relaunch. Long-press an added folder for **Rename in list** or **Remove from list**. Neither changes the folder itself.
- iCloud files that aren't downloaded show a cloud icon and download when you open or copy them.

### Files folders and single files

- **Open a folder in this pane**: pick any folder in Files and confirm it with Open or Done. The pane browses it and can paste, rename and delete there. **Reopen** *(name)* in the location menu brings it back later.
- **Browse Files locations** shows the Files app's own listing, which helps when a provider returns an empty folder, and lets you choose single files to preview or copy. They appear as **Selected files**.
- Each provider decides what it returns. For example, picking the On My iPhone root as a folder doesn't include other apps' folders, which is why On My iPhone and iCloud Drive have their own combined lists.

### Photos

- Allow full or selected access the first time you open Photos. To change a selected-access choice later, use **Open Settings** in the empty Photos pane, or the Settings app.
- Photos opens to folders: **All**, **Pictures**, **Videos**, **Screenshots**, **Others**, then one folder per album with its Photos name.
  - **Pictures** holds camera shots: photos with a location, Live, HDR, Portrait, Panorama or burst photos, or photos in the camera's HEIC or RAW format.
  - **Others** holds every other image, such as saved or downloaded ones.
  - iOS doesn't tell apps which app saved an image, so Pictures and Others are a best guess. Neither includes screenshots.
- A folder loads 150 items at a time. **Show more photos** at the bottom adds the next 150 and keeps your place.
- The date order comes from Photos, so it's right for the whole folder. Sorting by Name or Kind, and searching, load the whole folder first.
- Copy and Send give one file as Photos shows it: the edited version when there is one, and the still image of a Live Photo. iCloud may need to download the original first.

### Windows shares

- **Connect to Windows** asks for the computer name or IP address, the shared folder name, a Windows username and its password. **Show shared folders** lists the computer's shares so you can pick one.
- If the computer doesn't answer within 5 seconds, you get an error instead of a long wait. **Cancel** works at any time, even while connecting.
- **Find devices** looks on the same Wi-Fi for computers that accept file sharing on port 445, and for Macs and NAS drives that announce it (Bonjour). It shows the PC's name when the PC gives it. A PC whose firewall blocks file sharing doesn't appear.
- Use the password of the Windows account that has access to the share. A Windows Hello PIN only signs you in on the PC and doesn't work here.
- Addresses show the PC's name, from Find devices or asked from a PC you connect to by IP address. The IP address appears only in Find devices.
- **Remember this share** adds the share to the location menus and the Windows sheet, and keeps its password in this iPhone's Keychain (this device only). Swipe left on a saved share to forget it and its password.
- Files on a share open in the viewer after downloading, and you can swipe through them.

### Viewer and Info

- Tap a file, photo or video to open it. Photos fit the screen and zoom with two fingers or a double tap. Videos play in the system player, and other files open in Quick Look.
- Swipe left or right for the next or previous file in the list, in the order shown. In the 3D view, use the ‹ › buttons instead.
- **Send to** *(the other pane's address)* copies the item there in one tap, the same as Copy and Paste. **Share** opens the share sheet.
- **ⓘ Info** shows the name, kind, size, dates and where the item is.
  - Photos add dimensions, camera, lens, focal length, aperture, shutter speed, ISO, date taken and location.
  - Videos add duration, resolution and frame rate.
  - For a folder (long-press, then **Info**), it shows the total size and how many files and folders it holds.

### DXF drawings

- Tap a `.dxf` file anywhere: on the iPhone, in a Files folder, on a Windows share or inside an archive. It opens in Newexplorer's drawing viewer, fitted to the screen.
- Pinch or double-tap to zoom, and drag to move around. Lines stay thin at every zoom, while dashes, text and pictures grow with the drawing. When it isn't zoomed, swipe to the next file as usual.
- The main drawing shows its size underneath, such as "120 × 80 mm", in the units the file names ("units" when it names none).
- The **2D | 3D** switch at the top right turns the main drawing around in 3D, with the same moves as [3D models](#3d-models). Layouts show in 2D.
- The sheet button at the top left switches between the main drawing (**Model**) and each layout. A layout's windows show the main drawing at their own scale, without the layers frozen in that window.
- Colors are the file's. The background is white in light mode and black in dark mode, and white lines in the drawing (color 7) show black on white.
- Pictures in a drawing are looked for by file name in the drawing's folder. When one isn't there, a frame with its name shows instead.
- DXF files in the lists show a small picture of the drawing, up to 20 MB per file.

| In the DXF | Shown |
|---|---|
| Lines, polylines (including curved segments and widths), circles, arcs, ellipses, splines, points, leaders | ✅ |
| Blocks, including arrays, attributes, dimensions and tables | ✅ |
| Text and multi-line text: plain text in the system font, with symbols such as Ø, ° and ± | ✅ |
| Hatches | ✅ solid and gradient ones filled, patterned ones as outlines |
| Layer and object colors, line types (dashes and dots) and line weights | ✅ hidden and frozen layers left out |
| Layouts with rectangular windows | ✅ |
| Meshes, polyface meshes and 3D faces | ✅ as outlines in 2D, as surfaces in 3D |
| Pictures | ⚠️ only when the picture file is in the same folder |
| Binary DXF files | ✅ |
| Line types with text or symbols inside them (like "GAS" lines) | ⚠️ drawn as solid lines |
| 3D drawings | ✅ turned around with the 2D \| 3D switch; in 3D, lines are thin and solid, and only the first 2,000 fills and 1,000 texts show |
| 3D solids, multileaders, DWG files | ❌ |

### 3D models

- Tap a `.stl`, `.obj`, `.3mf`, `.step`/`.stp` or `.iges`/`.igs` file anywhere: on the iPhone, in a Files folder, on a Windows share or inside an archive. It opens in Newexplorer's 3D view, fitted to the screen and seen from the front, a little from above.
- One finger turns the model, two fingers move it, pinch zooms, and double-tap fits it back.
- One finger turns the model, so swiping to the next file is off in the 3D view. The ‹ and › buttons at the sides go to the previous and next file.
- Files up to 500 MB (STEP and IGES up to 200 MB) and 6 million triangles open. A STEP or IGES model that needs more triangles is shown coarser.
- STEP and IGES files are read with [Open CASCADE Technology](https://github.com/Open-Cascade-SAS/OCCT) 7.9.3. A big one takes a while to open.

| File | Shown |
|---|---|
| STL, binary and text | ✅ in light gray-blue |
| 3MF, including objects made of parts in other files (as slicers save them) | ✅ |
| 3MF colors | ⚠️ the colors stored in the model; filament colors a slicer keeps in its own settings aren't used, so those parts show in light gray-blue |
| OBJ | ✅ with its materials and textures when their files are in the same folder |
| STEP/STP and IGES/IGS solids and surfaces | ✅ in light gray-blue; curved faces are made of small flat triangles |
| IGES wireframes and loose curves | ✅ as lines |
| STEP and IGES colors | ⚠️ not used, so everything shows in light gray-blue |

### Copy, Cut, Paste and Send

- Tap ✓ at the top of a pane to show the selection circles, tick items, then tap **Copy** or **Cut**. In the other pane, tap **Paste here**. Tap ✓ again to hide the circles and clear the ticks. The ⋯ menu also has **Select visible items** and **Clear selection**.
- **Cut** moves the items. Inside one storage area, it only renames: for example inside On My iPhone, or inside one shared folder on a PC, even when the two panes opened that share separately. Elsewhere it copies and then deletes the original. Photos, archives and selected files can only be copied.
- A folder can't be moved into itself or one of its own folders, and can't be replaced by an item that's inside it.
- Copies go straight into the destination under a hidden `.NX-` name and get their real name when complete. On the same drive, files are cloned instantly; elsewhere they're copied in 4 MB chunks.
- When a name is taken, choose **Replace**, **Keep both** (adds a number) or **Skip**, the same for all remaining items, or **Stop**. Replace keeps the old item as a hidden backup until the new one has its name, so a dropped connection doesn't lose it.
- If a paste fails, or you cancel or stop it, the clipboard keeps only the items that weren't finished, and **Paste here** carries on from there.
- The bar under the panes shows MB and percent and has **Cancel**. You can keep browsing while it runs. Only panes that show a changed folder reload, and they keep their scroll position.
- Long-press an item for **Send to** *(the other pane's address)*, **Share**, **Info**, **Rename**, **Delete…**, **Extract here** and **Create ZIP**. Send isn't offered when the other pane shows Photos, iCloud Drive, Selected files, an archive or the item's own folder.

### Archives

- Tap a ZIP, RAR, TAR, TGZ (.tar.gz) or ISO file to browse it like a folder without extracting it. Files inside open in the viewer, and Copy then Paste unpacks only the selected items. Archives are read-only.
- In App files, a Files folder or at the top of On My iPhone or iCloud Drive, long-press an archive for **Extract here**, or a file or folder for **Create ZIP**. If the name is taken, a number is added.
- **Compress selected items…** in the ⋯ menu puts all ticked items into one ZIP that you name.
- Not supported: 7z, password-protected archives, encrypted or multipart RAR, archives on a Windows share, archives inside archives, and making RAR files.

### Search

- **Search this location** filters the loaded list as you type.
- Tick **Subfolders** to also search every folder below. This works in App files, Files folders, On My iPhone and iCloud Drive (with their added app folders), Windows shares and archives, and shows the first 500 matches.
- Results show the folder they're in. Tap one to open it, long-press for Send, Share, Info or **Show in folder**, or tick results for Copy and Cut.

### Saving files from other apps

- In another app's share sheet, choose Newexplorer (Open in or Copy to). A sheet asks where to save: **App files**, or the location shown in pane A or B when it can take the files. Photos takes only images and videos.
- iOS's temporary Inbox copy is removed afterwards.

### Reopening where you were

- After a relaunch, each pane reopens in the exact folder it showed. This covers App files, its Files folder, On My iPhone and iCloud Drive with their app folders, Photos folders (when access was already given) and remembered Windows shares.
- Selected files last only until the app closes.
- Each pane also remembers its sort order, and the app remembers Tab mode and the open tab.

### Lists, sorting and tools

- Each row shows a thumbnail or a type icon, the name, and below it the date and time and the size. Photos show the date and time taken.
- Photos, videos and PDFs on this iPhone get a Quick Look thumbnail, DXF drawings a small picture of the drawing, and Photos items show their own picture. Other files show an icon for their type.
- The ⋯ pane menu has:
  - **Refresh** and **Show hidden files**
  - **Sort by** Name, Date, Size or Kind. Pick the current order again to reverse it.
  - **Select visible items** and **Clear selection**
  - **Compress selected items…**, **New folder** and **Delete selected…** (asks first)
  - **Find duplicates and empty folders**
- Folders stay on top, and each pane keeps its own order. Photos keeps its own order: newest first by default, and no Size.
- Long-press an item to rename or delete it.
- The ⚙︎ menu shows the version and has **Clear temporary transfer files**.

### Storage review

- **Find duplicates and empty folders** (in App files and Files folders) lists files with identical contents (same size and SHA-256), the space their extra copies take, and empty folders.
- It only reports. Delete the copies you don't want in the browser. Identical contents alone don't tell you which copy is safe to delete, and a scan can download cloud files.

## Permissions

| Permission | Used for |
|---|---|
| Photos | Browsing and copying photos and videos, with full or selected access |
| Add to Photos | Saving pasted images and videos into Photos |
| Local Network | Finding computers and drives on your Wi-Fi, and connecting to a share |
| Files | Each folder or file you open in the Files picker is its own grant |

## Signing and the bundle ID

The IPA built here is unsigned. Sign it with your own certificate and provisioning profile, for example with a signing service such as KravaSigner, an on-device signer or Xcode. The signer must also sign the embedded `AMSMB2.framework`.

### The bundle ID must match your profile's App ID

The source code uses the placeholder bundle ID `com.example.newexplorer`. A provisioning profile is made for one App ID, for example `com.yourname.newexplorer`. If the IPA's bundle ID differs from that App ID, the signed app still installs and opens, but iOS doesn't hand it the files and folders you pick in Files:

- In the Files picker, **Open** does nothing. iOS can't resolve the picked item for the app (error 257, no permission) and drops the pick.
- Folders you opened in Files don't reopen after a relaunch.

This is the problem we hit while building Newexplorer. Picks from Files failed on the iPhone until the bundle ID was set to exactly the App ID of the signing profile (version 0.3.0).

To find your App ID: it's the App ID (bundle ID) of your provisioning profile. Signing services usually show it with the certificate. In a `.mobileprovision` file, it's the `application-identifier` value after the team ID and the first dot.

### How to get a working app

| Way | What to do | When it works |
|---|---|---|
| 1. Build with your App ID (recommended) | GitHub: add the repository secret `BUNDLE_ID` (steps below). Xcode: generate the project with your App ID, see [Xcode](#xcode). | Always |
| 2. Let the signer change it | When signing, set the app's bundle ID to exactly the profile's App ID: same spelling, no extra suffix. | If your signer can change the bundle ID |
| 3. Use a wildcard profile | A profile whose App ID ends in `*`, such as `com.yourname.*`, accepts any bundle ID that fits the pattern. | If you have a wildcard profile |

To add the `BUNDLE_ID` secret on GitHub:

1. Open your repository on github.com, then **Settings** › **Secrets and variables** › **Actions**.
2. Tap **New repository secret**.
3. Name: `BUNDLE_ID`. Secret: your App ID, such as `com.yourname.newexplorer`.
4. Tap **Add secret**. The next build on `main` uses it.

Without the secret, the build shows the warning "The BUNDLE_ID secret is not set" and the IPA keeps the placeholder. The secret doesn't appear in the code or in the build logs. The IPA itself always contains its bundle ID.

Keep the same bundle ID for every update. iOS treats a different bundle ID as a different app: it installs next to the old one, and the old one keeps its App files, added folders and saved shares.

## Building

### GitHub Actions

The workflow in `.github/workflows/simulator.yml` runs on every push and pull request:

1. It builds Open CASCADE 7.9.3 for iPhone and simulator with `Scripts/build_occt.sh`, or takes it from the Actions cache. The first build takes about an hour; the cache is used until that script changes.
2. It builds the app for an iPhone simulator and runs 53 unit tests and 3 UI tests.
3. On `main` only, it builds an unsigned arm64 Release app with your `BUNDLE_ID`. It checks the version, bundle ID, arm64 code, the embedded AMSMB2 framework and the permission texts, then packages the IPA.
4. It uploads the artifact **Newexplorer-v0.12.0-unsigned**, with the IPA and `SHA256.txt`. Open the run under **Actions** and download it from **Artifacts** while signed in to GitHub.

In a fork, add the `BUNDLE_ID` secret first. GitHub also keeps workflows off in a new fork until you turn them on in its **Actions** tab.

### Xcode

You need a Mac with Xcode 16 or later and an iPhone with iOS 17 or later. The workflow runs on GitHub's macOS 15 runner, which currently has Xcode 16.4.

1. Clone the repository.
2. Install CMake (`brew install cmake`). In Terminal, in the repository folder, run `bash Scripts/build_occt.sh` once. It downloads Open CASCADE 7.9.3 and builds it for iPhone and simulator into `Vendor/occt`, which takes about an hour.
3. In the same folder, run this with your App ID:

   ```sh
   BUNDLE_ID=com.yourname.newexplorer python3 Scripts/generate_project.py
   ```

   It rewrites `Newexplorer.xcodeproj` with that bundle ID. Without `BUNDLE_ID`, it uses the placeholder.
4. Open `Newexplorer.xcodeproj`, choose the **Newexplorer** scheme and your iPhone, pick your team under **Signing & Capabilities**, and run.

Notes:

- `Scripts/generate_project.py` generates the Xcode project, so make lasting project changes there. Running it again overwrites `project.pbxproj`.
- The version and build numbers are set in `Scripts/generate_project.py` and checked by `Scripts/package_ipa.py`.
- Xcode resolves three Swift packages:
  - AMSMB2 4.0.3 for Windows shares (LGPL-2.1)
  - ZIPFoundation 0.9.20 for making ZIPs (MIT)
  - LibArchive 0.1.6 for reading archives (BSD)
- Open CASCADE Technology 7.9.3 reads STEP and IGES files (LGPL-2.1 with the Open CASCADE exception). `Scripts/build_occt.sh` builds it and the app links it in.

  Their licenses are in `App/ThirdPartyNotices.txt`, which ships inside the app.

## Tests

- **Unit tests (53)** cover:
  - copying, streaming and cancelling, name conflicts, moves and unique names
  - folder Info, ZIPs, archive browsing and extraction
  - the On My iPhone and iCloud Drive lists and their deletes, and picked files
  - sorting, the Send rule, Photos folders and export names, and Info formatting
  - saved shares, NetBIOS names and the Wi-Fi scan
  - share paths, and two connections to the same share
  - DXF drawings: text and binary files, blocks, layers, line types, curves, hatches, text codes, pictures, layouts and the size
  - 3D models: binary and text STL, 3MF parts, moves and colors, OBJ files, and DXF drawings in 3D
  - STEP and IGES: a box from each, an IGES wireframe, and files that aren't CAD
  - subfolder search, reopening the exact folder, receiving files, file icons and the storage scan
- **UI tests (3)** cover:
  - empty panes, the Windows connection form and the Photos permission request
  - picking folders and files in Files, and relaunching
  - Photos folders, the viewer (swipe, Info, Send), Cut, long-press Info and archives
- The Files picker and Photos UI tests run and are reported, but they don't block the build. In the current simulator, the Files picker drops picks and the Photos library hangs, and the 0.6.0 code fails both the same way. Check those on an iPhone.

## Limits and known issues

- Keep the app open during large transfers, because iOS can pause it in the background.
- A transfer stopped by closing the app or losing Wi-Fi can leave a hidden `.NX-` item in the destination. Turn on **Show hidden files** to see and delete it. **Clear temporary transfer files** removes only the app's own temporary transfer files.
- Deleting is permanent outside Photos, so check the location and the ticked items first.
- iOS gives each app folder in On My iPhone and iCloud Drive as its own grant, so add each one once.
- Find devices doesn't find a PC whose firewall blocks file sharing. Type its name or IP address instead.
- Drag and drop between panes isn't included. With it, taps, long presses and the Files picker failed in every simulator test run.
- In 3D, lines are thin and solid: dashes and line widths show only in 2D, and a DXF drawing shows only its first 2,000 fills and 1,000 texts. DXF 3D solids, multileaders and DWG files can't be shown, and STEP and IGES colors aren't used.

## Version history

### 0.12.0 (build 17)

- STEP and IGES coordinates share storage with the renderer. Closing an unfinished model cancels native transfer, meshing and coordinate extraction. The file-read phase checks cancellation when Open CASCADE returns.
- Interrupted Windows uploads and replacements write a local recovery record. Reopen the same shared folder using the same host and account. If the destination is missing, the original regains its name. If publication was unacknowledged and both versions exist, the original is preserved alongside the destination as `Recovered-<UUID>`. Unfinished uploads restart through Paste. The clipboard lasts for the current app session.
- Folder selection and reopening now have their own blocking UI test. Simulator results are available as an Actions artifact. Shared roadmap, verification and device checks are in HANDOVER.md.

### 0.11.0 (build 16)

- **STEP and IGES**: `.step`, `.stp`, `.iges` and `.igs` files open in the 3D view, read with Open CASCADE Technology 7.9.3.
- IGES wireframes and loose curves show as lines.
- The README notes that a DXF drawing in 3D shows only its first 2,000 fills and 1,000 texts.

### 0.10.0 (build 15)

- **3D view**: STL, OBJ and 3MF models open in a 3D view. One finger turns the model, two fingers move it, pinch zooms, and double-tap fits it back.
- In the 3D view, swiping is off; the ‹ › buttons go to the previous and next file.
- DXF drawings get a **2D | 3D** switch for the main drawing. 3D faces and meshes show as surfaces.
- 3MF objects made of parts in other files, as slicers save them, with their moves and colors.

### 0.9.0 (build 14)

- **DXF viewer**: DXF drawings open in Newexplorer's own viewer, from every location. It handles text and binary files of every AutoCAD version, with lines, polylines, circles, arcs, ellipses, splines, blocks, dimensions, text, hatches, meshes and pictures.
- Layer and object colors, dashed and dotted line types, and line weights. Hidden and frozen layers are left out.
- A sheet button switches between the main drawing and its layouts, with their windows at scale.
- The drawing's size under it, in the file's units.
- DXF thumbnails in the file lists.

### 0.8.2 (build 13)

- Fixed: with the same Windows share open in both panes, cutting a file, pasting it into its own folder and choosing Replace deleted it. Moving a folder into one of its own subfolders on a share deleted the folder. Two connections to the same PC and share now count as one place.
- A move within one Windows share is a rename on the PC: instant, with no download and upload.
- Replace on a Windows share keeps the old item as a hidden backup until the new one has its name.
- After a failed, cancelled or stopped paste, the clipboard keeps only the unfinished items.

### 0.8.1 (build 12)

- Fixed: the Windows sheet stayed locked after tapping a saved share whose PC was offline. **Cancel** and swipe-down now work even while connecting.
- A computer that doesn't answer gives an error within 5 seconds instead of a 1-minute wait. This covers Connect, Show shared folders, saved shares opened from a pane's location menu, and reopening a share at launch.
- The location icon is a little bigger and has a border.
- The location menu lists On My iPhone, iCloud Drive, Open Photos and Connect to Windows first, above a divider.

### 0.8.0 (build 11)

- **Tab mode**: one pane over the whole screen, with a Chrome-style tab for each pane at the bottom. Switch with the button next to the gear.
- **Address bar** with the full path, such as `On My iPhone/Downloads/Documents`, `MSI/shared` or `Photos/Others`. Tap a part to go back to it, and the icon before it opens the location menu. It replaces the A and B pane letters.
- Rows show the date and time for files and photos, plus the size for files.
- **Send to** names the destination's address instead of the pane letter.
- Windows shares show the PC's name. The IP address appears only in Find devices.
- Build: the Files picker and Photos UI tests are reported but no longer block the build.
- Source: the bundle ID is a placeholder, and builds take yours from the `BUNDLE_ID` secret.

### 0.7.0 (build 10)

- Thumbnails for photos, videos and PDFs on this iPhone, and type icons for every other file.
- **Remember this share**: saved shares appear in the location menus and the Windows sheet, with the password in the Keychain. Swipe to forget one.
- Files on a Windows share open in the viewer after downloading and can be swiped.
- Search can include subfolders (first 500 matches). Results keep their folder for opening, Copy, Cut, Send, Share, Info and Show in folder.
- Files from other apps (Open in, Copy to) can be saved where you choose.
- Each pane reopens in the exact folder after a relaunch.
- **Find devices** (Bonjour, plus a port 445 scan of the Wi-Fi with NetBIOS names) and **Show shared folders**.
- Drag and drop between panes was tried and left out.

### 0.6.0 (build 9)

- Copies go straight into the destination: cloned on the same drive, streamed in 4 MB chunks elsewhere. Extract here and Create ZIP write next to the item without a temporary copy.
- **Cut** and Paste move items.
- Name conflicts ask Replace, Keep both or Skip, with "for all" choices, or Stop.
- A transfer bar shows MB and percent and has Cancel, and the panes stay usable.
- Only panes that show a changed location reload, in place.
- Long-press: Send to the other pane, Share and Info (folders show total size and item counts). Extract here works for every browsable archive type, also at the top of On My iPhone and iCloud Drive. **Compress selected items** makes one ZIP.
- Photos: the date order comes from Photos for the whole folder. Name and Kind sorting and search load the whole folder.
- Deleting a mixed selection at the top of On My iPhone or iCloud Drive deletes the top-level items and reports the skipped app folders.
- Selected files show their size and date. Lists are sorted once per change.

### 0.5.1 (build 8)

- **Pictures** holds camera shots, and the new **Others** folder holds every other image. Neither includes screenshots.
- **Show more photos** adds the next 150 and keeps your place.

### 0.5.0 (build 7)

- Photos opens to folders: All, Pictures, Videos, Screenshots and one per album. Pasting into an album folder adds the item to that album.
- The viewer swipes through the list and shows **Info**, with camera data for photos and details for videos.
- ZIP, RAR, TAR, TGZ and ISO archives open like read-only folders.

### 0.4.0 (build 6)

- Photos, videos and files open in Newexplorer's viewer, with Close, Share and **Send to** the other pane.
- Photos copy as Photos shows them: the edited version, and the still image of a Live Photo.
- **Sort by** Name, Date, Size or Kind, remembered per pane.
- The ✓ button shows or hides the selection circles.

### 0.3.0 (build 5)

- **On My iPhone** and **iCloud Drive** as combined lists: the top-level items plus app folders you add once. The lists are kept across relaunches and show real names. iCloud files that aren't downloaded still show and download when needed.
- Files picks work on the iPhone: the bundle ID was set to the signing profile's App ID (see [Signing and the bundle ID](#signing-and-the-bundle-id)). **Browse Files locations** opens the original files again instead of copies.

### 0.2.0 to 0.2.2 (builds 2 to 4)

- 0.2.2: **Open a folder in this pane** and **Browse Files locations**. Each pane remembers its confirmed folder (**Reopen**). Later fixes on 0.2.2:
  - The Files app's own listing opens when a provider returns an empty folder.
  - Picked files come back as copies so Open always delivers them. 0.3.0 replaced this.
- 0.2.1: empty panes offer the folder, Photos and Windows choices. Adds **Show hidden files**, and **Open Settings** when Photos access is limited.
- 0.2.0: New folder, Rename, Delete, Delete selected, selection controls and **Clear temporary transfer files**. Adds the app icon and the first unsigned IPA built by GitHub Actions.

### First builds

- Two panes with the app's own folder, a chosen folder, Photos and Windows shares.
- Copy and Paste between the panes, search, Create ZIP, and the review of duplicate files and empty folders.
- ZIP and RAR extraction.
