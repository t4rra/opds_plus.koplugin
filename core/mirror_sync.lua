-- Mirror Sync: mirror a catalog's feed into the sync folder
-- manifest: entry identity -> file; deletes only our own tracked files, only on a fully-read feed

local util = require("util")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local MirrorSync = {}

MirrorSync.MANIFEST_NAME = ".opds_plus_mirror.lua"
MirrorSync.MANIFEST_VERSION = 1
MirrorSync.MAX_PAGES = 500 -- feed page cap
MirrorSync.MAX_SUBFEED_DEPTH = 2 -- sub-feed recursion cap

--- strip trailing slashes; "/" stays "/"
-- @param sync_dir string|nil
-- @return string
function MirrorSync.normalizeDir(sync_dir)
	if type(sync_dir) ~= "string" or sync_dir == "" then
		return "/"
	end
	local stripped = sync_dir:gsub("/+$", "")
	if stripped == "" then
		return "/"
	end
	return stripped
end

-- @param sync_dir string
-- @return string
function MirrorSync.manifestPath(sync_dir)
	local dir = MirrorSync.normalizeDir(sync_dir)
	if dir == "/" then
		return "/" .. MirrorSync.MANIFEST_NAME
	end
	return dir .. "/" .. MirrorSync.MANIFEST_NAME
end

local function freshManifest()
	return { version = MirrorSync.MANIFEST_VERSION, catalogs = {} }
end

--- load manifest; never raises, fresh manifest on any error
-- stored paths relative to sync_dir when under it
-- @param sync_dir string
-- @return table manifest (fresh on any error)
function MirrorSync.load(sync_dir)
	local dir = MirrorSync.normalizeDir(sync_dir)
	local path = MirrorSync.manifestPath(dir)
	local default = freshManifest()
	local file_exists = lfs.symlinkattributes and lfs.symlinkattributes(path, "mode") == "file"

	local ok, data = pcall(function()
		local luasettings = require("luasettings")
		local doc = luasettings:open(path)
		return doc:readSetting("data", default)
	end)
	if not ok then
		logger.warn("mirror sync: could not read manifest", path, data)
		return freshManifest()
	end
	if data == default and file_exists then
		logger.warn("mirror sync: ignoring corrupt manifest", path)
		return freshManifest()
	end
	if type(data) ~= "table" or type(data.catalogs) ~= "table" then
		logger.warn("mirror sync: manifest has the wrong shape, starting over", path)
		return freshManifest()
	end
	data.version = MirrorSync.MANIFEST_VERSION
	return data
end

--- persist manifest via luasettings; never raises
-- @param sync_dir string
-- @param manifest table
-- @return boolean success
function MirrorSync.save(sync_dir, manifest)
	local path = MirrorSync.manifestPath(sync_dir)
	local ok, err = pcall(function()
		local luasettings = require("luasettings")
		local doc = luasettings:open(path)
		doc:saveSetting("data", manifest)
		doc:flush()
	end)
	if not ok then
		logger.warn("mirror sync: could not save manifest", path, err)
		return false
	end
	return true
end

--- entry identity: entry.id, else link href
-- @param entry table
-- @param link table
-- @return string|nil
function MirrorSync.identity(entry, link)
	if type(entry) == "table" and type(entry.id) == "string" and entry.id ~= "" then
		return entry.id
	end
	if type(link) == "table" and type(link.href) == "string" and link.href ~= "" then
		return link.href
	end
	return nil
end

local function firstAcquisition(entry)
	local acquisitions = entry.acquisitions
	if type(acquisitions) ~= "table" then
		return nil
	end
	for _, link in ipairs(acquisitions) do
		if type(link) == "table" and type(link.href) == "string" and link.href ~= "" then
			return link
		end
	end
	return nil
end

local function joinPath(dir, rel)
	if dir == "/" then
		return "/" .. rel
	end
	return dir .. "/" .. rel
end

--- normalize path; refuses ".."
-- @return string|nil nil when a ".." component is present
local function normalizePath(path)
	local absolute = path:sub(1, 1) == "/"
	local parts = {}
	for component in path:gmatch("[^/]+") do
		if component == ".." then
			return nil
		end
		if component ~= "." then
			parts[#parts + 1] = component
		end
	end
	local joined = table.concat(parts, "/")
	if absolute then
		return "/" .. joined
	end
	return joined
end

local function isInside(sync_dir, path)
	if sync_dir == "/" then
		return path:sub(1, 1) == "/" and path ~= "/"
	end
	return path:sub(1, #sync_dir + 1) == sync_dir .. "/"
end

--- walk the whole feed in order
-- @param browser table OPDSBrowser instance
-- @param url string
-- @return table desired identity -> { entry = entry, link = link }
-- @return table order identity strings, feed order, deduped
-- @return boolean complete false if any page failed/was empty or the cap was hit
function MirrorSync.enumerate(browser, url)
	local desired, order = {}, {}
	local complete = true
	local seen_urls = {}

	if type(url) ~= "string" or url == "" then
		return desired, order, false
	end
	seen_urls[url] = true

	local function walk(fetch_url, depth)
		local page = 0
		local current = fetch_url
		while type(current) == "string" and current ~= "" do
			page = page + 1
			if page > MirrorSync.MAX_PAGES then
				logger.warn("mirror sync: page cap of", MirrorSync.MAX_PAGES, "reached at", current)
				complete = false
				return
			end
			local ok, items = pcall(browser.genItemTableFromURL, browser, current)
			if not ok or type(items) ~= "table" then
				-- failed page = incomplete walk; deleting would be wrong
				logger.warn("mirror sync: could not fetch feed page", current, ok and "not a table" or items)
				complete = false
				return
			end
			if #items == 0 then
				complete = false
				return
			end
			for index = 1, #items do
				local entry = items[index]
				if type(entry) == "table" then
					local link = firstAcquisition(entry)
					if link then
						local identity = MirrorSync.identity(entry, link)
						if identity and not desired[identity] then
							desired[identity] = { entry = entry, link = link }
							order[#order + 1] = identity
						end
					elseif type(entry.url) == "string"
						and util.stringEndsWith(entry.url, ".opds")
						and depth < MirrorSync.MAX_SUBFEED_DEPTH
						and not seen_urls[entry.url] then
						-- Gutenberg-style sub-feed notice
						seen_urls[entry.url] = true
						walk(entry.url, depth + 1)
					end
				end
			end
			local hrefs = items.hrefs
			local next_href = type(hrefs) == "table" and hrefs.next or nil
			if type(next_href) == "string" and next_href ~= "" then
				current = next_href
			else
				current = nil
			end
		end
	end

	walk(url, 0)
	return desired, order, complete
end

--- reconcile manifest against identities in the feed now; mutates, never raises
-- deletes only plugin-tracked files under sync_dir; empty desired set deletes nothing
-- @param sync_dir string
-- @param manifest table
-- @param catalog_url string
-- @param desired table identity -> true
-- @return table result { deleted = {paths}, missing = n, failed = { { file = path }... }, refused = n, skipped = string|nil }
function MirrorSync.reconcile(sync_dir, manifest, catalog_url, desired)
	local result = { deleted = {}, missing = 0, failed = {}, refused = 0, skipped = nil }

	local ok, err = pcall(function()
		local dir = MirrorSync.normalizeDir(sync_dir)
		if type(manifest) ~= "table" or type(manifest.catalogs) ~= "table" then
			result.skipped = "invalid"
			return
		end
		local catalog = manifest.catalogs[catalog_url]
		if type(catalog) ~= "table" then
			return -- nothing tracked for this catalog
		end
		if next(desired) == nil and next(catalog) ~= nil then
			-- empty feed set: no wholesale deletion
			result.skipped = "empty"
			return
		end
		for identity, entry in pairs(catalog) do
			if not desired[identity] then
				if type(entry) ~= "table" or type(entry.file) ~= "string" or entry.file == "" then
					-- unusable entry: drop it
					result.missing = result.missing + 1
					catalog[identity] = nil
				else
					local stored = entry.file
					local resolved = stored:sub(1, 1) == "/" and stored or joinPath(dir, stored)
					local normalized = normalizePath(resolved)
					if not normalized or not isInside(dir, normalized) then
						-- path escapes sync_dir; keep entry
						result.refused = result.refused + 1
					else
						local attr_ok, mode = pcall(lfs.symlinkattributes, normalized, "mode")
						if attr_ok and (mode == "file" or mode == "link") then
							local remove_ok, removed = pcall(os.remove, normalized)
							if remove_ok and removed == true then
								result.deleted[#result.deleted + 1] = normalized
								catalog[identity] = nil
							else
								logger.warn("mirror sync: could not delete", normalized)
								result.failed[#result.failed + 1] = { file = normalized }
							end
						else
							-- missing or not a file: drop manifest entry
							result.missing = result.missing + 1
							catalog[identity] = nil
						end
					end
				end
			end
		end
	end)
	if not ok then
		logger.warn("mirror sync: reconcile failed", err)
		result.skipped = "error"
	end
	return result
end

--- record downloaded items in the manifest; mutates, does not save
-- stored path relative to sync_dir when under it
-- @param manifest table
-- @param sync_dir string
-- @param catalog_url string
-- @param items table[] pending sync items
function MirrorSync.trackDownloads(manifest, sync_dir, catalog_url, items)
	local dir = MirrorSync.normalizeDir(sync_dir)
	local prefix = dir == "/" and "/" or dir .. "/"
	if type(manifest.catalogs) ~= "table" then
		manifest.catalogs = {}
	end
	local catalog = type(manifest.catalogs[catalog_url]) == "table" and manifest.catalogs[catalog_url] or nil
	for _, item in ipairs(items) do
		if type(item) == "table"
			and type(item.mirror_identity) == "string"
			and item.mirror_identity ~= ""
			and type(item.file) == "string"
			and item.file ~= "" then
			if not catalog then
				catalog = {}
				manifest.catalogs[catalog_url] = catalog
			end
			local file = item.file
			local stored = file
			if file:sub(1, #prefix) == prefix then
				stored = file:sub(#prefix + 1)
			end
			catalog[item.mirror_identity] = { file = stored }
		end
	end
end

return MirrorSync
