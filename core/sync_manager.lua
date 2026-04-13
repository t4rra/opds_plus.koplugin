-- Sync Manager for OPDS Browser
-- Handles catalog synchronization, sync settings, and batch downloads
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Constants = require("models.constants")
local DownloadManager = require("core.download_manager")
local StateManager = require("core.state_manager")

local SyncManager = {}

local function isOneWayMirrorSync(server)
    if not server or not server.sync then return false end
    return server.sync_mode == nil or server.sync_mode ==
               Constants.SYNC.MODE_ONE_WAY_MIRROR
end

local function startDownloadsOrNotify(browser)
    if #browser.pending_syncs > 0 then
        Trapper:wrap(function() SyncManager.downloadPendingSyncs(browser) end)
    else
        if browser.sync_requires_refresh then
            UIManager:broadcastEvent(Event:new("RefreshContent"))
            UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
            browser.sync_requires_refresh = nil
        end
        UIManager:show(InfoMessage:new{text = _("Up to date!")})
    end
end

--- Show dialog to set maximum number of files to sync
-- @param browser table OPDSBrowser instance
function SyncManager.showMaxSyncDialog(browser)
    local current_max_dl = browser.settings.sync_max_dl or
                               Constants.SYNC.DEFAULT_MAX_DOWNLOADS
    local spin = SpinWidget:new{
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
        end
    }
    UIManager:show(spin)
end

--- Show directory chooser for sync folder
-- @param browser table OPDSBrowser instance
function SyncManager.showSyncDirChooser(browser)
    local force_chooser_dir
    if Device:isAndroid() then force_chooser_dir = Device.home_dir end

    require("ui/downloadmgr"):new{
        onConfirm = function(inbox)
            logger.info("set opds sync folder", inbox)
            browser.settings.sync_dir = inbox
            StateManager.getInstance():markDirty()
        end
    }:chooseDir(force_chooser_dir)
end

--- Show dialog to set file types to sync
-- @param browser table OPDSBrowser instance
function SyncManager.showFiletypesDialog(browser)
    local input = browser.settings.filetypes
    local dialog
    dialog = InputDialog:new{
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
                    end
                }, {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local str = dialog:getInputText()
                        browser.settings.filetypes = str ~= "" and str or nil
                        StateManager.getInstance():markDirty()
                        UIManager:close(dialog)
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Parse filetypes string into a lookup table
-- @param filetypes_str string Comma-separated list of filetypes
-- @return table|nil Lookup table of filetypes, or nil if no filter
function SyncManager.parseFiletypes(filetypes_str)
    if not filetypes_str then return nil end

    local file_list = {}
    for filetype in util.gsplit(filetypes_str, ",") do
        file_list[util.trim(filetype)] = true
    end
    return file_list
end

--- Pick the first matching acquisition for sync based on filetype filters
-- @param item table Parsed OPDS item with acquisitions
-- @param file_list table|nil Allowed filetypes map
-- @return table|nil Acquisition metadata {link, filetype}
function SyncManager.pickSyncAcquisition(item, file_list)
    for _, link in ipairs(item.acquisitions or {}) do
        local filetype = DownloadManager.getFiletype(link)
        if filetype and (not file_list or file_list[filetype]) then
            return {link = link, filetype = filetype}
        end
    end
    return nil
end

--- Build a full remote manifest for a server to safely detect stale local files
-- @param browser table OPDSBrowser instance
-- @param server table Server configuration
-- @param file_list table|nil Allowed filetypes map
-- @return table, table, boolean Set of expected local paths, item metadata map, and manifest completeness
function SyncManager.getServerManifest(browser, server, file_list)
    local remote_files = {}
    local file_metadata = {}
    local fetch_url = server.url
    local total_items = 0
    local saw_page = false
    local manifest_limit = Constants.SYNC.MANIFEST_MAX_ITEMS

    while fetch_url and total_items < manifest_limit do
        local page_items = browser:genItemTableFromURL(fetch_url)
        if #page_items == 0 then
            if not saw_page then
                return remote_files, file_metadata, false
            end
            break
        end
        saw_page = true

        for _, entry in ipairs(page_items) do
            local item = entry
            if entry.url then
                local sub_table = browser:genItemTableFromURL(entry.url) or {}
                if #sub_table > 1 then
                    item = sub_table[2]
                elseif #sub_table > 0 then
                    item = sub_table[1]
                end
            end

            local acquisition = SyncManager.pickSyncAcquisition(item, file_list)
            if acquisition then
                local filename = browser:getFileName(entry)
                local download_path = browser:getLocalDownloadPath(filename,
                                                                   acquisition.filetype,
                                                                   acquisition.link
                                                                       .href)
                remote_files[download_path] = true
                file_metadata[download_path] = {
                    entry = entry,
                    item = item,
                    acquisition = acquisition,
                    filename = filename
                }
                total_items = total_items + 1
                if total_items >= manifest_limit then break end
            end
        end

        if total_items >= manifest_limit then break end

        fetch_url = page_items.hrefs and page_items.hrefs.next or nil
    end

    local is_complete = saw_page and fetch_url == nil and total_items <
                            manifest_limit
    return remote_files, file_metadata, is_complete
end

--- Build stale file list from previous synced manifest and current remote manifest
-- @param server table Server configuration
-- @param remote_files table Set of expected local paths from remote server
-- @return table List of stale local file paths
function SyncManager.getStaleLocalFiles(server, remote_files)
    local stale_files = {}
    if type(server.synced_files) ~= "table" then return stale_files end

    for _, path in ipairs(server.synced_files) do
        if not remote_files[path] and lfs.attributes(path) then
            table.insert(stale_files, path)
        end
    end

    return stale_files
end

--- Convert remote file set to stable sorted list for persistence
-- @param remote_files table Set of file paths
-- @return table Sorted list of paths
function SyncManager.toSortedFileList(remote_files)
    local files = {}
    for path in pairs(remote_files) do table.insert(files, path) end
    table.sort(files)
    return files
end

--- Delete stale local files that are no longer present on server
-- @param stale_files table List of local file paths
function SyncManager.deleteStaleFiles(stale_files)
    local deleted_count = 0
    for _, path in ipairs(stale_files) do
        if lfs.attributes(path) then
            local ok = os.remove(path)
            if ok then deleted_count = deleted_count + 1 end
        end
    end

    return deleted_count
end

--- Check if sync is properly configured and start sync process
-- @param browser table OPDSBrowser instance
-- @param server_idx number|nil Index of specific server to sync (nil for all)
function SyncManager.checkAndStartSync(browser, server_idx)
    if not browser.settings.sync_dir then
        UIManager:show(InfoMessage:new{
            text = _("Please choose a folder for sync downloads first")
        })
        return
    end

    browser.sync = true
    browser.pending_syncs = {}
    browser.sync_stale_files = {}
    local info = InfoMessage:new{text = _("Synchronizing lists…")}
    UIManager:show(info)
    UIManager:forceRePaint()

    if server_idx then
        -- Sync specific server (first item is "Downloads", so subtract 1)
        SyncManager.fillPendingSyncs(browser, browser.servers[server_idx - 1])
    else
        -- Sync all servers with sync enabled
        for _, server in ipairs(browser.servers) do
            if server.sync then
                SyncManager.fillPendingSyncs(browser, server)
            end
        end
    end

    UIManager:close(info)

    local deleted_count = 0
    if #browser.sync_stale_files > 0 then
        deleted_count = SyncManager.deleteStaleFiles(browser.sync_stale_files)
    end

    local added_count = #browser.pending_syncs
    browser.sync_requires_refresh = (added_count > 0 or deleted_count > 0) and
                                        true or nil
    if added_count > 0 or deleted_count > 0 then
        browser.sync_change_summary = {
            added = added_count,
            deleted = deleted_count
        }
        if added_count == 0 and deleted_count > 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("Mirror sync changes: %1 added, %2 deleted"),
                         added_count, deleted_count),
                timeout = Constants.UI_TIMING.DUPLICATE_NOTIFICATION_TIMEOUT
            })
            browser.sync_change_summary = nil
        end
    end

    startDownloadsOrNotify(browser)

    browser.sync = false
end

--- Fill pending syncs list for a specific server
-- @param browser table OPDSBrowser instance
-- @param server table Server configuration
function SyncManager.fillPendingSyncs(browser, server)
    -- Set browser context for this server
    browser.root_catalog_password = server.password
    browser.root_catalog_raw_names = server.raw_names
    browser.root_catalog_username = server.username
    browser.root_catalog_title = server.title
    browser.sync_server = server
    browser.sync_server_list = browser.sync_server_list or {}
    browser.sync_max_dl = browser.settings.sync_max_dl or
                              Constants.SYNC.DEFAULT_MAX_DOWNLOADS

    local file_list = SyncManager.parseFiletypes(browser.settings.filetypes)
    local remote_files, file_metadata, manifest_complete =
        SyncManager.getServerManifest(browser, server, file_list)

    if isOneWayMirrorSync(server) then
        if manifest_complete then
            local stale_files = SyncManager.getStaleLocalFiles(server,
                                                               remote_files)
            for _, stale_path in ipairs(stale_files) do
                table.insert(browser.sync_stale_files, stale_path)
            end
            browser:updateFieldInCatalog(server, "synced_files",
                                         SyncManager.toSortedFileList(
                                             remote_files))
        else
            logger.warn("Skipping stale cleanup due to incomplete manifest for",
                        server.title)
        end
    else
        -- For regular sync, also check for missing files
        if manifest_complete then
            browser:updateFieldInCatalog(server, "synced_files",
                                         SyncManager.toSortedFileList(
                                             remote_files))
        end
    end

    local new_last_download = nil
    local dl_count = 1

    -- Check for missing synced files and add them back to pending syncs
    local missing_entries = {}
    if manifest_complete and type(server.synced_files) == "table" then
        for _, path in ipairs(server.synced_files) do
            if not lfs.attributes(path) and remote_files[path] then
                table.insert(missing_entries, path)
            end
        end
    end

    -- Add missing files back to pending syncs (highest priority, before new items)
    local missing_count = 0
    for _, missing_path in ipairs(missing_entries) do
        if dl_count <= browser.sync_max_dl then
            local metadata = file_metadata[missing_path]
            if metadata then
                local item = metadata.item
                local acquisition = metadata.acquisition

                local download_metadata =
                    DownloadManager.buildDownloadMetadata(browser, item,
                                                          acquisition.link,
                                                          acquisition.filetype,
                                                          {
                        source_catalog = server.title,
                        source_catalog_url = server.url,
                        sync = true
                    })
                table.insert(browser.pending_syncs, {
                    file = missing_path,
                    url = acquisition.link.href,
                    username = browser.root_catalog_username,
                    password = browser.root_catalog_password,
                    catalog = server.url,
                    metadata = download_metadata
                })
                missing_count = missing_count + 1
                dl_count = dl_count + 1
            end
        end
    end

    if missing_count > 0 then
        logger.info("Sync found", missing_count,
                    "missing files that were previously synced")
    end

    local sync_list = SyncManager.getSyncDownloadList(browser)
    if sync_list then
        for i, entry in ipairs(sync_list) do
            -- Handle Project Gutenberg style entries
            local sub_table = {}
            local item
            if entry.url then
                sub_table =
                    SyncManager.getSyncDownloadList(browser, entry.url) or {}
            end
            if #sub_table > 0 then
                -- The first element seems to be most compatible. Second element has most options
                item = sub_table[2]
            else
                item = entry
            end

            for j, link in ipairs(item.acquisitions) do
                -- Only save first link in case of several file types
                if i == 1 and j == 1 then
                    new_last_download = link.href
                end
                local filetype = DownloadManager.getFiletype(link)
                if filetype and (not file_list or file_list[filetype]) then
                    local filename = browser:getFileName(entry)
                    local download_path =
                        browser:getLocalDownloadPath(filename, filetype,
                                                     link.href)
                    if dl_count <= browser.sync_max_dl then
                        local metadata =
                            DownloadManager.buildDownloadMetadata(browser, item,
                                                                  link,
                                                                  filetype, {
                                source_catalog = server.title,
                                source_catalog_url = server.url,
                                sync = true
                            })
                        table.insert(browser.pending_syncs, {
                            file = download_path,
                            url = link.href,
                            username = browser.root_catalog_username,
                            password = browser.root_catalog_password,
                            catalog = server.url,
                            metadata = metadata
                        })
                        dl_count = dl_count + 1
                    end
                    break
                end
            end
        end
    end

    browser.sync_server_list[server.url] = true
    if new_last_download then
        logger.dbg("Updating opds last download for server", server.title, "to",
                   new_last_download)
        browser:updateFieldInCatalog(server, "last_download", new_last_download)
    end
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
        if #sub_table == 0 then return sync_table end

        local count = 1
        local acquisitions_empty = false

        -- Handle Project Gutenberg style entries
        while #sub_table[count].acquisitions == 0 do
            if util.stringEndsWith(sub_table[count].url, ".opds") then
                acquisitions_empty = true
                break
            end
            if count == #sub_table then return sync_table end
            count = count + 1
        end

        -- First entry in table is the newest
        -- If already downloaded, return
        local first_href
        if acquisitions_empty then
            first_href = sub_table[count].url
        else
            first_href = sub_table[1].acquisitions[1].href
        end

        if first_href == browser.sync_server.last_download and
            not browser.sync_force then return nil end

        local href
        for i, entry in ipairs(sub_table) do
            if acquisitions_empty then
                if i >= count then
                    href = entry.url
                else
                    href = nil
                end
            else
                href = entry.acquisitions[1].href
            end

            if href then
                if href == browser.sync_server.last_download and
                    not browser.sync_force then
                    up_to_date = true
                    break
                else
                    table.insert(sync_table, entry)
                end
            end
        end

        if not sub_table.hrefs.next then break end
        fetch_url = sub_table.hrefs.next
    end

    return sync_table
end

--- Download all pending sync items and handle duplicates
-- @param browser table OPDSBrowser instance
function SyncManager.downloadPendingSyncs(browser)
    local dl_list = browser.pending_syncs
    local duplicate_list =
        DownloadManager.downloadPendingSyncs(browser, dl_list)

    if duplicate_list and #duplicate_list > 0 then
        SyncManager.showDuplicateFilesDialog(browser, dl_list, duplicate_list)
    end
end

--- Show dialog for handling duplicate files during sync
-- @param browser table OPDSBrowser instance
-- @param dl_list table Download list
-- @param duplicate_list table List of duplicate files
function SyncManager.showDuplicateFilesDialog(browser, dl_list, duplicate_list)
    local duplicate_files = {_("These files are already on the device:")}
    for _, entry in ipairs(duplicate_list) do
        table.insert(duplicate_files, entry.file)
    end
    local text = table.concat(duplicate_files, "\n")

    local textviewer
    textviewer = TextViewer:new{
        title = _("Duplicate files"),
        text = text,
        buttons_table = {
            {
                {
                    text = _("Do nothing"),
                    callback = function()
                        textviewer:onClose()
                    end
                }, {
                    text = _("Overwrite"),
                    callback = function()
                        browser.sync_force = true
                        textviewer:onClose()
                        for _, entry in ipairs(duplicate_list) do
                            table.insert(dl_list, entry)
                        end
                        Trapper:wrap(function()
                            DownloadManager.downloadPendingSyncs(browser,
                                                                 dl_list)
                        end)
                    end
                }, {
                    text = _("Download copies"),
                    callback = function()
                        browser.sync_force = true
                        textviewer:onClose()
                        local copies_dir = "copies"
                        local original_dir =
                            util.splitFilePathName(duplicate_list[1].file)
                        local copy_download_dir =
                            original_dir .. copies_dir .. "/"
                        util.makePath(copy_download_dir)

                        for _, entry in ipairs(duplicate_list) do
                            local _, file_name =
                                util.splitFilePathName(entry.file)
                            local copy_download_path =
                                copy_download_dir .. file_name
                            entry.file = copy_download_path
                            table.insert(dl_list, entry)
                        end

                        Trapper:wrap(function()
                            DownloadManager.downloadPendingSyncs(browser,
                                                                 dl_list)
                        end)
                    end
                }
            }
        }
    }
    UIManager:show(textviewer)
end

return SyncManager
