local helper = require("helper")
local ui_stub = require("support.ui")
local registry_stub = require("support.documentregistry")
local luasettings = require("support.luasettings")
local fs = helper.fs

describe("Mirror sync", function()
	local SyncManager, DownloadManager, MirrorSync
	local ui, state, device, registry, dir, downloads, should_fail

	local SERVER_URL = "https://library.example.org/opds"
	local BOOKS = "https://library.example.org/dl/"

	-- fake download manager: removes items that download fine, keeps failures and duplicates
	local function load_sync()
		local stubs = {
			device = device,
			["document/documentregistry"] = registry,
			docsettings = {},
			["socket.http"] = {},
			socketutil = {},
			luasettings = luasettings,
			["ui/downloadmgr"] = {
				new = function(self, options)
					self.options = options
					return self
				end,
				chooseDir = function() end,
			},
			["core.state_manager"] = {
				getInstance = function()
					return state
				end,
			},
		}
		for name, stand_in in pairs(ui.stubs) do
			stubs[name] = stand_in
		end
		SyncManager = helper.load("core.sync_manager", stubs)
		DownloadManager = require("core.download_manager")
		MirrorSync = require("core.mirror_sync")
		---@diagnostic disable-next-line: duplicate-set-field
		DownloadManager.downloadPendingSyncs = function(browser, dl_list)
			local snapshot = {}
			for index, item in ipairs(dl_list) do
				snapshot[index] = item
			end
			downloads[#downloads + 1] = { list = snapshot, forced = browser.sync_force }
			for index = #dl_list, 1, -1 do
				local item = dl_list[index]
				if not should_fail[item.file] and not fs.exists(item.file) then
					fs.write(item.file, "downloaded: " .. item.url)
					table.remove(dl_list, index)
				end
			end
			return nil
		end
	end

	-- book entry: one acquisition link per href, plus an id
	local function book(title, hrefs, fields)
		local item = { title = title, acquisitions = {} }
		for _, href in ipairs(type(hrefs) == "table" and hrefs or { hrefs }) do
			item.acquisitions[#item.acquisitions + 1] = { href = href, type = "application/octet-stream" }
		end
		for key, value in pairs(fields or {}) do
			item[key] = value
		end
		return item
	end

	-- genItemTableFromURL stub: entries plus feed links in `hrefs`
	local function page(entries, next_href)
		local items = { hrefs = { next = next_href } }
		for index, item in ipairs(entries) do
			items[index] = item
		end
		return items
	end

	-- the parts of OPDSBrowser that sync uses; pages maps feed address -> what fetching gives
	local function new_browser(pages, fields)
		local browser = {
			settings = { sync_dir = dir },
			servers = {},
			pending_syncs = {},
			fetched = {},
			updated = {},
			genItemTableFromURL = function(self, url)
				self.fetched[#self.fetched + 1] = url
				local result = pages[url]
				if type(result) == "function" then
					return result(self)
				end
				return result or {}
			end,
			getFileName = function(_, item)
				return item.title
			end,
			getLocalDownloadPath = function(_, filename, filetype)
				return dir .. "/" .. filename .. "." .. filetype
			end,
			updateFieldInCatalog = function(self, server, name, value)
				self.updated[#self.updated + 1] = { server = server, name = name, value = value }
			end,
		}
		for key, value in pairs(fields or {}) do
			browser[key] = value
		end
		return browser
	end

	local function new_server(fields)
		local server = { url = SERVER_URL, title = "Library", sync = false, mirror = true }
		for key, value in pairs(fields or {}) do
			server[key] = value
		end
		return server
	end

	-- two-book feed
	local function two_books()
		return page({
			book("Book One", BOOKS .. "1.epub", { id = "b1" }),
			book("Book Two", BOOKS .. "2.epub", { id = "b2" }),
		})
	end

	before_each(function()
		helper.reset()
		ui = ui_stub.new()
		registry = registry_stub.new()
		state = {
			dirty = 0,
			markDirty = function(self)
				self.dirty = self.dirty + 1
			end,
		}
		device = { home_dir = "/sdcard", isAndroid = function() return false end }
		downloads = {}
		should_fail = {}
		dir = helper.tmpdir()
		load_sync()
	end)

	after_each(helper.reset)

	it("downloads the missing books and tracks them in the manifest", function()
		local browser = new_browser({ [SERVER_URL] = two_books() })
		browser.servers = { new_server() }

		SyncManager.checkAndStartSync(browser)

		assert.equals(1, #downloads)
		local list = downloads[1].list
		assert.equals(2, #list)
		assert.is_true(list[1].mirror)
		assert.equals("b1", list[1].mirror_identity)
		assert.equals(SERVER_URL, list[1].catalog)
		assert.is_true(list[2].mirror)
		assert.equals("b2", list[2].mirror_identity)

		assert.same({}, browser.pending_syncs)
		assert.is_true(fs.exists(dir .. "/Book One.epub"))
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))

		local manifest = MirrorSync.load(dir)
		assert.is_table(manifest.catalogs[SERVER_URL])
		assert.equals("Book One.epub", manifest.catalogs[SERVER_URL]["b1"].file)
		assert.equals("Book Two.epub", manifest.catalogs[SERVER_URL]["b2"].file)
	end)

	it("downloads nothing when nothing changed", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)
		downloads = {}

		local browser = new_browser({ [SERVER_URL] = two_books() })
		browser.servers = { new_server() }
		SyncManager.checkAndStartSync(browser)

		assert.same({}, downloads)
		assert.same({}, browser.pending_syncs)
		assert.equals("Up to date!", ui:last().text)
		assert.is_true(fs.exists(dir .. "/Book One.epub"))
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))
		assert.is_nil(ui:last().text:find("Mirror sync", 1, true))
	end)

	it("deletes the tracked file of a book that left the feed, and nothing else", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)
		fs.write(dir .. "/loose.epub", "not the plugin's file")

		local browser = new_browser({ [SERVER_URL] = page({ book("Book One", BOOKS .. "1.epub", { id = "b1" }) }) })
		browser.servers = { new_server() }
		SyncManager.checkAndStartSync(browser)

		assert.is_false(fs.exists(dir .. "/Book Two.epub"))
		assert.is_true(fs.exists(dir .. "/Book One.epub"))
		assert.is_true(fs.exists(dir .. "/loose.epub"))

		local manifest = MirrorSync.load(dir)
		assert.is_nil(manifest.catalogs[SERVER_URL]["b2"])
		assert.is_table(manifest.catalogs[SERVER_URL]["b1"])

		local joined = table.concat(ui:texts(), "\n")
		assert.truthy(joined:find("Mirror sync", 1, true))
		assert.truthy(joined:find("removed 1 book", 1, true))
	end)

	it("deletes nothing when a later feed page cannot be read", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)

		local pages = {
			[SERVER_URL] = page({ book("Book One", BOOKS .. "1.epub", { id = "b1" }) }, SERVER_URL .. "?page=2"),
			[SERVER_URL .. "?page=2"] = {},
		}
		local browser = new_browser(pages)
		browser.mirror_results = {}
		browser.servers = { new_server() }
		SyncManager.fillPendingSyncs(browser, browser.servers[1])

		assert.equals("incomplete", browser.mirror_results[SERVER_URL].skipped)
		assert.is_true(fs.exists(dir .. "/Book One.epub"))
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))

		-- end-to-end run also reports nothing was deleted
		local browser2 = new_browser(pages)
		browser2.servers = { new_server() }
		SyncManager.checkAndStartSync(browser2)
		local joined = table.concat(ui:texts(), "\n")
		assert.truthy(joined:find("could not be fully read", 1, true))
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))
	end)

	it("downloads the readable subset of an unreadable feed, but deletes nothing", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)
		fs.remove_tree(dir .. "/Book One.epub")

		local pages = {
			[SERVER_URL] = page({ book("Book One", BOOKS .. "1.epub", { id = "b1" }) }, SERVER_URL .. "?page=2"),
			[SERVER_URL .. "?page=2"] = {},
		}
		local browser = new_browser(pages)
		browser.mirror_results = {}
		browser.servers = { new_server() }
		SyncManager.fillPendingSyncs(browser, browser.servers[1])

		-- what the feed sent is still downloaded when the target file is missing
		assert.equals(1, #browser.pending_syncs)
		assert.equals("b1", browser.pending_syncs[1].mirror_identity)
		-- nothing deleted: feed not fully read
		assert.equals("incomplete", browser.mirror_results[SERVER_URL].skipped)
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))
	end)

	it("deletes nothing when the feed's first page is empty", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)

		local browser = new_browser({ [SERVER_URL] = {} })
		browser.mirror_results = {}
		browser.servers = { new_server() }
		SyncManager.fillPendingSyncs(browser, browser.servers[1])

		assert.equals("incomplete", browser.mirror_results[SERVER_URL].skipped)
		assert.same({}, browser.pending_syncs)
		assert.is_true(fs.exists(dir .. "/Book One.epub"))
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))
	end)

	it("re-downloads a tracked book whose file was deleted on the device", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)
		fs.remove_tree(dir .. "/Book Two.epub")
		assert.is_false(fs.exists(dir .. "/Book Two.epub"))

		downloads = {}
		local browser = new_browser({ [SERVER_URL] = two_books() })
		browser.servers = { new_server() }
		SyncManager.checkAndStartSync(browser)

		assert.equals(1, #downloads)
		local list = downloads[1].list
		assert.equals(1, #list)
		assert.is_true(list[1].mirror)
		assert.equals("b2", list[1].mirror_identity)
		assert.equals(BOOKS .. "2.epub", list[1].url)
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))
		assert.is_true(fs.exists(dir .. "/Book One.epub"))
	end)

	it("respects the filetypes filter and tracks only the allowed types", function()
		local browser = new_browser({
			[SERVER_URL] = page({
				book("Pdf Book", BOOKS .. "1.pdf", { id = "p1" }),
				book("Epub Book", BOOKS .. "2.epub", { id = "e1" }),
			}),
		}, { settings = { sync_dir = dir, filetypes = "epub" } })
		browser.servers = { new_server() }

		SyncManager.checkAndStartSync(browser)

		assert.equals(1, #downloads[1].list)
		assert.equals("e1", downloads[1].list[1].mirror_identity)
		assert.is_true(fs.exists(dir .. "/Epub Book.epub"))
		assert.is_false(fs.exists(dir .. "/Pdf Book.pdf"))

		local manifest = MirrorSync.load(dir)
		assert.is_table(manifest.catalogs[SERVER_URL]["e1"])
		assert.is_nil(manifest.catalogs[SERVER_URL]["p1"])
	end)

	it("syncs a mirror catalog next to a regular one, touching only the regular one with last_download", function()
		local regular = { url = "https://regular.example.org/opds", title = "Regular", sync = true }
		local mirror = new_server({ url = "https://mirror.example.org/opds", title = "Mirror" })
		local browser = new_browser({
			[regular.url] = page({ book("Reg Book", "https://regular.example.org/dl/reg.epub", { id = "r1" }) }),
			[mirror.url] = page({ book("Mirror Book", "https://mirror.example.org/dl/mir.epub", { id = "m1" }) }),
		})
		browser.servers = { regular, mirror }

		SyncManager.checkAndStartSync(browser)

		assert.same({ regular.url, mirror.url }, browser.fetched)
		local by_catalog = {}
		for _, item in ipairs(downloads[1].list) do
			by_catalog[item.catalog] = item
		end
		assert.is_nil(by_catalog[regular.url].mirror)
		assert.is_true(by_catalog[mirror.url].mirror)

		local regular_updated, mirror_updated
		for _, update in ipairs(browser.updated) do
			if update.server == regular then regular_updated = update end
			if update.server == mirror then mirror_updated = update end
		end
		assert.is_table(regular_updated)
		assert.equals("last_download", regular_updated.name)
		assert.is_nil(mirror_updated)
	end)

	it("never deletes a tracked file whose book is still in the feed", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)

		local browser = new_browser({
			[SERVER_URL] = page({
				book("Book Three", BOOKS .. "3.epub", { id = "b3" }),
				book("Book One", BOOKS .. "1.epub", { id = "b1" }),
				book("Book Two", BOOKS .. "2.epub", { id = "b2" }),
			}),
		})
		browser.servers = { new_server() }
		SyncManager.checkAndStartSync(browser)

		assert.is_true(fs.exists(dir .. "/Book One.epub"))
		assert.is_true(fs.exists(dir .. "/Book Two.epub"))
		assert.is_true(fs.exists(dir .. "/Book Three.epub"))

		local manifest = MirrorSync.load(dir)
		assert.is_table(manifest.catalogs[SERVER_URL]["b1"])
		assert.is_table(manifest.catalogs[SERVER_URL]["b2"])
		assert.is_table(manifest.catalogs[SERVER_URL]["b3"])
	end)

	it("caps the downloads per run at sync_max_dl, in feed order", function()
		local entries = {}
		for index = 1, 4 do
			entries[index] = book("Cap Book " .. index, BOOKS .. index .. ".epub", { id = "cap" .. index })
		end
		local browser = new_browser(
			{ [SERVER_URL] = page(entries) },
			{ settings = { sync_dir = dir, sync_max_dl = 2 } }
		)
		browser.servers = { new_server() }

		SyncManager.checkAndStartSync(browser)

		assert.equals(1, #downloads)
		local list = downloads[1].list
		assert.equals(2, #list)
		assert.equals("cap1", list[1].mirror_identity)
		assert.equals("cap2", list[2].mirror_identity)

		local manifest = MirrorSync.load(dir)
		assert.is_table(manifest.catalogs[SERVER_URL]["cap1"])
		assert.is_table(manifest.catalogs[SERVER_URL]["cap2"])
		assert.is_nil(manifest.catalogs[SERVER_URL]["cap3"])

		-- rest download on the next run
		downloads = {}
		local second = new_browser(
			{ [SERVER_URL] = page(entries) },
			{ settings = { sync_dir = dir, sync_max_dl = 2 } }
		)
		second.servers = { new_server() }
		SyncManager.checkAndStartSync(second)
		assert.equals(2, #downloads[1].list)
		assert.equals("cap3", downloads[1].list[1].mirror_identity)
	end)

	it("keeps tracked books that failed to download, so the next run tries again", function()
		local first = new_browser({ [SERVER_URL] = two_books() })
		first.servers = { new_server() }
		SyncManager.checkAndStartSync(first)
		fs.remove_tree(dir .. "/Book Two.epub")

		should_fail[dir .. "/Book Two.epub"] = true
		downloads = {}
		local browser = new_browser({ [SERVER_URL] = two_books() })
		browser.servers = { new_server() }
		SyncManager.checkAndStartSync(browser)

		-- failed item stays tracked, not re-adopted
		assert.is_true(fs.exists(dir .. "/Book One.epub"))
		local manifest = MirrorSync.load(dir)
		assert.is_table(manifest.catalogs[SERVER_URL]["b1"])
		assert.is_table(manifest.catalogs[SERVER_URL]["b2"])
	end)
end)
