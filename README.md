# OPDS Plus - Enhanced OPDS Browser for KOReader

**Version:** 1.2.1 (t4rra fork)

**What's New:** I added an option to "mirror sync" a catalog and added metadata writing for downloaded books. Developed with LLMs so it's not production ready, this was made for personal use. 

**OPDS Plus** is a feature-rich enhancement of KOReader's built-in OPDS catalog browser, providing visual book cover displays, multiple viewing modes, and extensive customization options for browsing online book catalogs.

## Installation
1. **Download the latest release**:
   - Go to the releases page and download the `opds_plus.koplugin.zip` file from the latest release

2. **Extract to KOReader plugins directory**:
   - **Kindle/Kobo/Android**: Extract to `/koreader/plugins/`
   - **Linux**: Extract to `~/.config/koreader/plugins/`
   - **Windows**: Extract to `%APPDATA%/koreader/plugins/`
   - **macOS**: Extract to `~/Library/Application Support/koreader/plugins/`

	For complete platform-specific install/upgrade paths, see the KOReader wiki: [KOReader Installation/Upgrading](https://github.com/koreader/koreader/wiki#installationupgrading)

	The archive should extract to create an `opds_plus.koplugin` directory containing all plugin files.

3. Restart KOReader to load the plugin.

## Usage

### Access OPDS Plus:
1. Open KOReader's Top Menu (while browsing a catalog or on the home screen)
2. Tap the file browser icon
3. You should see "OPDS Plus Catalog" in the menu (if not, the plugin may not be installed correctly)
4. Tap "OPDS Plus Catalog" to open the plugin

### Add Catalogs:
1. In OPDS Plus, select "Add Catalog"
2. Enter the catalog URL and a name
   - Optionally enable "Sync Catalog" to automatically sync this catalog's contents to local storage
   - Optionally enable "Mirror Sync" to mirror changes from the server
3. Save to add to your catalog list

### Add Collection:
1. To sync a collection under a catalog, navigate to the collection you want to sync and tap the menu icon (⋮ or ≡) 
2. Select the "Add catalog" option
3. Return to the main catalog list and long-press the catalog you just added
4. Choose "Edit" to configure sync options for this catalog
   - Optionally enable sync/mirror sync options
5. Save to apply settings

### Syncing:
- To sync a catalog, long-press it in the catalog list and select "Sync"
- A shortcut to sync will also be available in OPDS Plus's top menu, which syncs all catalogs with sync enabled
- Gesture actions for syncing can be configured in KOReader's gesture settings under the "File Browser" category, where you will find:
  - `OPDS Plus: Sync all catalogs`
  - `OPDS Plus: Force sync all catalogs`

## Settings and Customization

<details>
<summary>Display Mode</summary>

- **List View**: Traditional list with covers on the left
- **Grid View**: Visual grid layout with larger covers

</details>

<details>
<summary>List View Settings</summary>

- **Cover Size**: Choose from presets or set custom size
  - Compact (8%): More books per page
  - Regular (10%): Default balanced view
  - Large (15%): Easier to see cover details
  - Extra Large (20%): Maximum cover visibility
  - Custom: Fine-tune between 5-25%

</details>

<details>
<summary>Cover Settings (New in 1.2.0)</summary>

- **Prefer Large Covers**:
  - Enabled: prioritizes higher-quality cover sources when available.
  - Disabled: prefers faster thumbnail sources.
- **Enable Cover Cache**:
  - Enabled: reuses previously downloaded covers.
  - Disabled: fetches covers from the server each time.
- **Advanced Cache Controls**:
  - Cache Size (MB)
  - Cache TTL (minutes)
  - Clear Cover Cache

</details>

<details>
<summary>Grid View Settings</summary>

- **Grid Layout**:
  - Compact: 4 columns, more books visible
  - Balanced: 3 columns, good middle ground (default)
  - Spacious: 2 columns, larger covers
  - Custom: Manual column selection (2-4)

- **Grid Borders**:
  - Style: None, Hash Grid, or Individual Tiles
  - Thickness: 1-5 pixels
  - Color: Light Gray, Dark Gray, or Black

</details>

<details>
<summary>Font & Text Settings</summary>

- **Use Same Font for All**: Match title and detail fonts
- **Title Settings**:
  - Font family
  - Font size (12-24pt)
  - Bold/regular weight
- **Information Settings**:
  - Font family (independent if same font disabled)
  - Font size (10-20pt)
  - Bold/regular weight
  - Color: Dark Gray or Black

</details>

<details>
<summary>Syncing & Gestures</summary>

- **Direct Sync Actions**:
  - Sync all catalogs
  - Force sync all catalogs (overwrite existing files)
- **Gesture Integration**:
  - Actions are registered in KOReader's dispatcher as:
    - `OPDS Plus: Sync all catalogs (one-way mirror)`
    - `OPDS Plus: Force sync all catalogs (overwrite existing)`
  - These can be assigned in KOReader's gesture/action configuration.
- **Catalog Sync Controls**:
  - Per-catalog sync and force-sync via catalog long-press actions.
  - One-way (mirror) mode (1.2.1 t4rra fork) can remove stale local files that no longer exist on server.
  - Sync folder selection.
  - Maximum sync download count.
  - Filetype filtering for sync downloads.

</details>