-- Sync Manager for OPDS Browser
-- Handles catalog synchronization, sync settings, and batch downloads

local Device = require("device")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Constants = require("models.constants")
local DownloadManager = require("core.download_manager")
local MirrorSync = require("core.mirror_sync")
local StateManager = require("core.state_manager")
local CatalogUtils = require("utils.catalog_utils")
local N_ = _.ngettext

local SyncManager = {}

--- Show dialog to set maximum number of files to sync
-- @param browser table OPDSBrowser instance
function SyncManager.showMaxSyncDialog(browser)
	local current_max_dl = browser.settings.sync_max_dl or Constants.SYNC.DEFAULT_MAX_DOWNLOADS
	local spin = SpinWidget:new {
		title_text = _("Set maximum sync size"),
		info_text = _("Set the max number of books to download at a time"),
		value = current_max_dl,
		value_min = 0,
		value_max = Constants.SYNC.MAX_DOWNLOADS_LIMIT,
		value_step = Constants.SYNC.STEP,
		value_hold_step = Constants.SYNC.HOLD_STEP,
		default_value = Constants.SYNC.DEFAULT_MAX_DOWNLOADS,
		wrap = true,
		ok_text = _("Save"),
		callback = function(spin)
			browser.settings.sync_max_dl = spin.value
			StateManager.getInstance():markDirty()
		end,
	}
	UIManager:show(spin)
end

--- Show directory chooser for sync folder
-- @param browser table OPDSBrowser instance
function SyncManager.showSyncDirChooser(browser)
	local force_chooser_dir
	if Device:isAndroid() then
		force_chooser_dir = Device.home_dir
	end

	require("ui/downloadmgr"):new {
		onConfirm = function(inbox)
			logger.info("set opds sync folder", inbox)
			browser.settings.sync_dir = inbox
			StateManager.getInstance():markDirty()
		end,
	}:chooseDir(force_chooser_dir)
end

--- Show dialog to set file types to sync
-- @param browser table OPDSBrowser instance
function SyncManager.showFiletypesDialog(browser)
	local input = browser.settings.filetypes
	local dialog
	dialog = InputDialog:new {
		title = _("File types to sync"),
		description = _("A comma separated list of desired filetypes"),
		input_hint = _("epub, mobi"),
		input = input,
		buttons = {
			{
				{
					text = _("Cancel"),
					id = "close",
					callback = function()
						UIManager:close(dialog)
					end,
				},
				{
					text = _("Save"),
					is_enter_default = true,
					callback = function()
						local str = dialog:getInputText()
						browser.settings.filetypes = str ~= "" and str or nil
						StateManager.getInstance():markDirty()
						UIManager:close(dialog)
					end,
				},
			},
		},
	}
	UIManager:show(dialog)
	dialog:onShowKeyboard()
end

--- Parse filetypes string into a lookup table
-- Types are lowercase in the table: KOReader matches extensions without regard to case, and a server can
-- send `.EPUB` as well as `.epub`.
-- @param filetypes_str string Comma-separated list of filetypes
-- @return table|nil Lookup table of filetypes, or nil if no filter
function SyncManager.parseFiletypes(filetypes_str)
	if not filetypes_str then
		return nil
	end

	local file_list = {}
	for filetype in util.gsplit(filetypes_str, ",") do
		filetype = util.trim(filetype):lower()
		if filetype ~= "" then
			file_list[filetype] = true
		end
	end
	-- A field with nothing but spaces and commas filters nothing
	if next(file_list) == nil then
		return nil
	end
	return file_list
end

--- Check if sync is properly configured and start sync process
-- @param browser table OPDSBrowser instance
-- @param server_idx number|nil Index of specific server to sync (nil for all)
function SyncManager.checkAndStartSync(browser, server_idx)
	if not browser.settings.sync_dir then
		UIManager:show(InfoMessage:new {
			text = _("Please choose a folder for sync downloads first.\n\nOpen the menu at the top left of the list of catalogs and tap \"Set sync folder\"."),
		})
		return
	end

	local servers_to_sync = {}
	if server_idx then
		-- A specific server is synced even when its sync option is off (first item is "Downloads", so subtract 1)
		servers_to_sync[1] = browser.servers[server_idx - 1]
	else
		for _, server in ipairs(browser.servers) do
			if server.sync or server.mirror then
				table.insert(servers_to_sync, server)
			end
		end
	end

	if #servers_to_sync == 0 then
		UIManager:show(InfoMessage:new {
			text = _("No catalogs are set to sync.\n\nLong-press a catalog, tap Edit and tick “Sync catalog”."),
		})
		return
	end

	browser.sync = true
	browser.mirror_results = {}
	browser.sync_report = nil
	local info = InfoMessage:new {
		text = _("Synchronizing lists…"),
	}
	UIManager:show(info)
	UIManager:forceRePaint()

	-- A failing feed must not leave the progress message on screen or the browser stuck in sync mode.
	local ok, err = pcall(function()
		for _, server in ipairs(servers_to_sync) do
			SyncManager.fillPendingSyncs(browser, server)
		end
	end)

	-- Drop anything that can never be downloaded (stale queue entries of catalogs no longer
	-- flagged for sync, duplicate entries for the same file) before downloading
	SyncManager.prunePendingSyncs(browser)
	SyncManager.pruneMirrorManifests(browser)

	UIManager:close(info)
	browser.sync = false

	if not ok then
		logger.err("OPDS Plus: sync failed:", err)
		-- failed sync may still have deleted files first; the summary lists them under one dialog
		SyncManager.showSyncSummary(browser, err)
		return
	end

	if #browser.pending_syncs > 0 then
		Trapper:wrap(function()
			-- shows the summary dialog itself when the download ends
			SyncManager.downloadPendingSyncs(browser)
		end)
	else
		SyncManager.showSyncSummary(browser)
	end
end

--- Fill pending syncs list for a specific server
-- @param browser table OPDSBrowser instance
-- @param server table Server configuration
function SyncManager.fillPendingSyncs(browser, server)
	-- Set browser context for this server
	browser.root_catalog_password  = server.password
	browser.root_catalog_raw_names = server.raw_names
	browser.root_catalog_username  = server.username
	browser.root_catalog_title     = server.title
	browser.root_catalog_url       = server.url
	browser.sync_server            = server
	browser.sync_server_list       = browser.sync_server_list or {}
	browser.sync_max_dl            = browser.settings.sync_max_dl or Constants.SYNC.DEFAULT_MAX_DOWNLOADS

	local file_list                = SyncManager.parseFiletypes(browser.settings.filetypes)
	if server.mirror then
		SyncManager.fillMirrorPendingSyncs(browser, server, file_list)
		browser.sync_server_list[server.url] = true
		return
	end
	local new_last_download        = nil
	local dl_count                 = 1

	local sync_list                = SyncManager.getSyncDownloadList(browser)
	if sync_list then
		for i, entry in ipairs(sync_list) do
			-- Handle Project Gutenberg style entries
			local sub_table = {}
			local item
			if entry.url then
				sub_table = SyncManager.getSyncDownloadList(browser, entry.url) or {}
			end
			if #sub_table > 0 then
				-- Second element has most options, but a sub-feed may only have one entry
				item = sub_table[2] or sub_table[1]
			else
				item = entry
			end

			for j, link in ipairs(item.acquisitions) do
				-- Only save first link in case of several file types
				if i == 1 and j == 1 then
					new_last_download = link.href
				end
				local filetype = DownloadManager.getFiletype(link)
				if filetype then
					if not file_list or file_list[filetype:lower()] then
						local filename = browser:getFileName(entry)
						local download_path = browser:getLocalDownloadPath(filename, filetype, link.href)
						if dl_count <= browser.sync_max_dl then
							table.insert(browser.pending_syncs, {
								file = download_path,
								url = link.href,
								username = browser.root_catalog_username,
								password = browser.root_catalog_password,
								catalog = server.url,
								info = CatalogUtils.getDescription(item),
								metadata = CatalogUtils.getMetadata(item),
							})
							dl_count = dl_count + 1
						end
						break
					end
				end
			end
		end
	end

	browser.sync_server_list[server.url] = true
	if new_last_download then
		logger.dbg("Updating opds last download for server", server.title, "to", new_last_download)
		browser:updateFieldInCatalog(server, "last_download", new_last_download)
	end
end

--- fill mirror pending syncs: sync folder ends up holding the feed's books
-- never updates last_download; deletes only our own files whose entries left the feed
-- @param browser table OPDSBrowser instance
-- @param server table Server configuration
-- @param file_list table|nil allowed filetypes lookup, or nil for every type
function SyncManager.fillMirrorPendingSyncs(browser, server, file_list)
	local sync_dir = browser.settings.sync_dir
	local max_dl = browser.sync_max_dl or Constants.SYNC.DEFAULT_MAX_DOWNLOADS
	local manifest = MirrorSync.load(sync_dir)
	browser.mirror_results = browser.mirror_results or {}
	local desired_map, order, complete = MirrorSync.enumerate(browser, server.url)

	-- filetype filter; remember target paths in feed order
	local full = {}        -- identity -> { entry =, link =, file = }
	local desired = {}     -- identity -> true (filetype filter included)
	for _, identity in ipairs(order) do
		local d = desired_map[identity]
		local filetype = DownloadManager.getFiletype(d.link)
		if filetype and (not file_list or file_list[filetype:lower()]) then
			local filename = browser:getFileName(d.entry)
			local target = browser:getLocalDownloadPath(filename, filetype, d.link.href)
			full[identity] = { entry = d.entry, link = d.link, file = target }
			desired[identity] = true
		end
	end

	-- delete only when the whole feed enumerated
	local result
	if complete then
		result = MirrorSync.reconcile(sync_dir, manifest, server.url, desired)
		MirrorSync.save(sync_dir, manifest)
	else
		result = { deleted = {}, failed = {}, skipped = "incomplete" }
	end

	-- download in feed order, capped by max_dl, skip existing files
	local dl_count = 1
	for _, identity in ipairs(order) do
		local d = full[identity]
		if d and not lfs.attributes(d.file, "mode") and dl_count <= max_dl then
			table.insert(browser.pending_syncs, {
				file = d.file,
				url = d.link.href,
				username = browser.root_catalog_username,
				password = browser.root_catalog_password,
				catalog = server.url,
				info = CatalogUtils.getDescription(d.entry),
				metadata = CatalogUtils.getMetadata(d.entry),
				mirror = true,
				mirror_identity = identity,
			})
			dl_count = dl_count + 1
		end
	end

	browser.mirror_results[server.url] = {
		deleted = result.deleted or {},
		failed = result.failed or {},
		skipped = result.skipped,
	}
end

--- Get list of books to download for sync
-- @param browser table OPDSBrowser instance
-- @param url_arg string|nil URL to fetch (nil uses sync_server.url)
-- @return table|nil List of entries to sync, or nil if up to date
function SyncManager.getSyncDownloadList(browser, url_arg)
	local sync_table = {}
	local fetch_url = url_arg or browser.sync_server.url
	local sub_table
	local up_to_date = false

	while #sync_table < browser.sync_max_dl and not up_to_date do
		sub_table = browser:genItemTableFromURL(fetch_url)

		-- Handle timeout
		if #sub_table == 0 then
			return sync_table
		end

		local count = 1
		local acquisitions_empty = false

		-- Handle Project Gutenberg style entries
		-- Entries without links (e.g. a notice at the top of the feed) have no url and no acquisitions
		while #sub_table[count].acquisitions == 0 do
			local entry_url = sub_table[count].url
			if entry_url and util.stringEndsWith(entry_url, ".opds") then
				acquisitions_empty = true
				break
			end
			if count == #sub_table then
				return sync_table
			end
			count = count + 1
		end

		-- First entry in table is the newest
		-- If already downloaded, return
		local first_href
		if acquisitions_empty then
			first_href = sub_table[count].url
		else
			first_href = sub_table[count].acquisitions[1].href
		end

		if first_href == browser.sync_server.last_download and not browser.sync_force then
			return nil
		end

		local href
		for i, entry in ipairs(sub_table) do
			if acquisitions_empty then
				if i >= count then
					href = entry.url
				else
					href = nil
				end
			else
				href = entry.acquisitions[1] and entry.acquisitions[1].href
			end

			if href then
				if href == browser.sync_server.last_download and not browser.sync_force then
					up_to_date = true
					break
				else
					table.insert(sync_table, entry)
				end
			end
		end

		if not sub_table.hrefs.next then
			break
		end
		fetch_url = sub_table.hrefs.next
	end

	return sync_table
end

--- Download all pending sync items; ends with the summary dialog
-- The download manager stashes the outcome on browser.sync_report; the summary reads and resets it.
-- @param browser table OPDSBrowser instance
function SyncManager.downloadPendingSyncs(browser)
	local dl_list = browser.pending_syncs
	local before = {}
	for _, item in ipairs(dl_list) do before[item] = true end
	DownloadManager.downloadPendingSyncs(browser, dl_list)
	-- duplicates left the queue undownloaded; keep Mirror Sync from adopting them (matched by path: the fork re-encodes the tables)
	local skipped_duplicates = {}
	for _, item in ipairs(browser.sync_report and browser.sync_report.duplicates or {}) do
		skipped_duplicates[item.file] = true
	end
	local ok, err = pcall(SyncManager.trackMirrorDownloads, browser, dl_list, before, skipped_duplicates)
	if not ok then
		logger.err("OPDS Plus: could not update the mirror manifest:", err)
	end
	SyncManager.showSyncSummary(browser)
end

--- Drop queue items that can never download: unflagged catalogs and duplicate entries for the same file
function SyncManager.prunePendingSyncs(browser)
	local pending = browser.pending_syncs
	if type(pending) ~= "table" then return end
	local sync_catalogs = {}
	for _, server in ipairs(browser.servers or {}) do
		if server.sync or server.mirror then
			sync_catalogs[server.url] = true
		end
	end
	-- scan from the end so the newest copy of a book (queued by this run) wins
	local seen = {}
	local pruned = 0
	for index = #pending, 1, -1 do
		local item = pending[index]
		local file = item and item.file
		if not file or not (item.catalog and sync_catalogs[item.catalog]) or seen[file] then
			table.remove(pending, index)
			pruned = pruned + 1
		else
			seen[file] = true
		end
	end
	if pruned > 0 then
		logger.info("OPDS Plus: dropped", pruned, "stale item(s) from the sync queue")
	end
end

--- Forget mirror manifests of catalogs no longer set to mirror; the books stay on disk
function SyncManager.pruneMirrorManifests(browser)
	local sync_dir = browser.settings and browser.settings.sync_dir
	if not sync_dir then return end
	local mirror_catalogs = {}
	for _, server in ipairs(browser.servers or {}) do
		if server.mirror then
			mirror_catalogs[server.url] = true
		end
	end
	local manifest = MirrorSync.load(sync_dir)
	if type(manifest) ~= "table" or type(manifest.catalogs) ~= "table" then return end
	local pruned = {}
	for catalog_url in pairs(manifest.catalogs) do
		if not mirror_catalogs[catalog_url] then
			pruned[#pruned + 1] = catalog_url
		end
	end
	if #pruned == 0 then return end
	logger.info("OPDS Plus: forgetting mirror manifest for", table.concat(pruned, ", "))
	for _, catalog_url in ipairs(pruned) do
		manifest.catalogs[catalog_url] = nil
	end
	MirrorSync.save(sync_dir, manifest)
end

--- adopt mirror items that left the queue (i.e. downloaded) into the manifest
-- @param browser table OPDSBrowser instance
-- @param dl_list table items after the download (mutated in place)
-- @param before table set (item -> true) of items pending before the download
-- @param skipped_duplicates table|nil set (file -> true) of items left because they were already on the device
function SyncManager.trackMirrorDownloads(browser, dl_list, before, skipped_duplicates)
	local sync_dir = browser.settings and browser.settings.sync_dir
	if not sync_dir then return end
	local still = {}
	for _, item in ipairs(dl_list) do still[item] = true end
	local succeeded = {}
	for item in pairs(before) do
		if item.mirror and not still[item] and not (skipped_duplicates and skipped_duplicates[item.file]) then
			succeeded[#succeeded + 1] = item
		end
	end
	if #succeeded == 0 then return end
	local by_catalog = {}
	for _, item in ipairs(succeeded) do
		by_catalog[item.catalog] = by_catalog[item.catalog] or {}
		table.insert(by_catalog[item.catalog], item)
	end
	local manifest = MirrorSync.load(sync_dir)
	for catalog_url, items in pairs(by_catalog) do
		MirrorSync.trackDownloads(manifest, sync_dir, catalog_url, items)
	end
	MirrorSync.save(sync_dir, manifest)
end

--- One dialog for the end of a sync: counts of added/removed/not downloaded/already-on-device books.
-- With duplicates it also offers Do nothing / Overwrite / Download copies.
-- Reads and resets browser.sync_report and browser.mirror_results.
-- @param browser table OPDSBrowser instance
-- @param sync_error string|nil Why the sync aborted, if it did
function SyncManager.showSyncSummary(browser, sync_error)
	local report = browser.sync_report
	browser.sync_report = nil
	local results = browser.mirror_results
	browser.mirror_results = {}

	local lines = {}
	local function section(title, count)
		if count == 0 then return end
		if #lines > 0 and lines[#lines] ~= "" then
			table.insert(lines, "")
		end
		table.insert(lines, T(N_("%1: %2 book", "%1: %2 books", count), title, count))
	end

	if sync_error then
		table.insert(lines, T(_("Sync failed:\n%1"), tostring(sync_error)))
		table.insert(lines, "")
	end

	section(_("Added"), report and report.downloaded and #report.downloaded or 0)

	-- Everything the mirror catalogs deleted from the sync folder
	local removed, undeletable, incomplete, empty = 0, 0, false, false
	if type(results) == "table" then
		for _, result in pairs(results) do
			if type(result) == "table" then
				removed = removed + (result.deleted and #result.deleted or 0)
				undeletable = undeletable + (result.failed and #result.failed or 0)
				if result.skipped == "incomplete" then incomplete = true end
				if result.skipped == "empty" then empty = true end
			end
		end
	end
	section(_("Removed"), removed)

	section(_("Not downloaded"), report and report.failed and #report.failed or 0)

	local duplicates = report and report.duplicates or {}
	section(_("Already on the device"), #duplicates)

	if incomplete then
		table.insert(lines, _("Mirror sync: the catalog feed could not be fully read."))
	end
	if empty then
		table.insert(lines, _("Mirror sync: the catalog feed is empty."))
	end
	if undeletable > 0 then
		table.insert(lines, T(_("Mirror sync: %1 file(s) could not be deleted."), undeletable))
	end
	if report and report.interrupted then
		table.insert(lines, _("Sync was cancelled; some books may be missing."))
	end
	if #lines == 0 then
		table.insert(lines, _("Up to date."))
	end

	local viewer
	local buttons_table
	if #duplicates > 0 then
		local function redownload(transform)
			browser.sync_force = true
			for _, entry in ipairs(duplicates) do
				if transform then
					transform(entry)
				end
				table.insert(browser.pending_syncs, entry)
			end
			Trapper:wrap(function()
				SyncManager.downloadPendingSyncs(browser)
			end)
			-- sync_force is for this re-download only; don't leak it to later syncs
			browser.sync_force = nil
		end
		buttons_table = {
			{
				{
					text = _("Do nothing"),
					callback = function()
						UIManager:close(viewer)
					end,
				},
				{
					text = _("Overwrite"),
					callback = function()
						UIManager:close(viewer)
						redownload()
					end,
				},
				{
					text = _("Download copies"),
					callback = function()
						UIManager:close(viewer)
						local original_dir = util.splitFilePathName(duplicates[1].file)
						local copy_download_dir = original_dir .. "copies" .. "/"
						util.makePath(copy_download_dir)
						redownload(function(entry)
							local _, file_name = util.splitFilePathName(entry.file)
							entry.file = copy_download_dir .. file_name
						end)
					end,
				},
			},
		}
	end
	local content = table.concat(lines, "\n")
	if buttons_table then
		viewer = ButtonDialog:new {
			title = content,
			buttons = buttons_table,
		}
	else
		viewer = InfoMessage:new {
			text = content,
		}
	end
	UIManager:show(viewer)
	return viewer
end

return SyncManager
