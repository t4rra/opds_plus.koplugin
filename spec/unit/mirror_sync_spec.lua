local helper = require("helper")
local lfs = require("lfs")
local luasettings = require("support.luasettings")

describe("MirrorSync", function()
	local MirrorSync, dir
	local CATALOG = "https://library.example.org/opds"

	local function load()
		return helper.load("core.mirror_sync", { luasettings = luasettings })
	end

	-- entry as genItemTableFromCatalog builds it
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

	-- notice entry that only opens a sub-feed
	local function subfeed(url, fields)
		local item = { acquisitions = {}, url = url }
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

	-- pages maps feed address -> page (a table, or function(browser) -> table)
	local function new_browser(pages, fields)
		local browser = {
			fetched = {},
			genItemTableFromURL = function(self, url)
				self.fetched[#self.fetched + 1] = url
				local result = pages[url]
				if type(result) == "function" then
					return result(self)
				end
				return result or {}
			end,
		}
		for key, value in pairs(fields or {}) do
			browser[key] = value
		end
		return browser
	end

	-- track `files` (relative to the sync dir) by identity; return the manifest
	local function tracked(identities, files)
		local manifest = { version = 1, catalogs = { [CATALOG] = {} } }
		for index, identity in ipairs(identities) do
			manifest.catalogs[CATALOG][identity] = { file = files[index], url = "https://x/" .. identity }
		end
		return manifest
	end

	before_each(function()
		helper.reset()
		dir = helper.tmpdir()
		MirrorSync = load()
	end)

	after_each(function()
		helper.reset()
	end)

	describe("normalizeDir", function()
		it("normalizes plain, trailing-slashed, root and invalid input", function()
			assert.equals("/sync", MirrorSync.normalizeDir("/sync"))
			assert.equals("/sync", MirrorSync.normalizeDir("/sync/"))
			assert.equals("/sync", MirrorSync.normalizeDir("/sync///"))
			assert.equals("/", MirrorSync.normalizeDir("/"))
			assert.equals("/", MirrorSync.normalizeDir("////"))
			assert.equals("/", MirrorSync.normalizeDir(""))
			assert.equals("/", MirrorSync.normalizeDir(nil))
			assert.equals("/", MirrorSync.normalizeDir(42))
		end)
	end)

	describe("manifest roundtrip", function()
		it("returns a fresh manifest on an empty directory", function()
			local manifest = MirrorSync.load(dir)

			assert.equals(1, manifest.version)
			assert.same({}, manifest.catalogs)
		end)

		it("stores downloads and reads them back", function()
			local manifest = MirrorSync.load(dir)
			MirrorSync.trackDownloads(manifest, dir, CATALOG, {
				{ mirror_identity = "one", file = dir .. "/one.epub" },
				{ mirror_identity = "two", file = dir .. "/sub/two.epub" },
			})

			assert.is_true(MirrorSync.save(dir, manifest))
			assert.equals("file", lfs.attributes(dir .. "/" .. MirrorSync.MANIFEST_NAME, "mode"))

			local reloaded = MirrorSync.load(dir)

			assert.equals(1, reloaded.version)
			assert.equals("one.epub", reloaded.catalogs[CATALOG]["one"].file)
			assert.equals("sub/two.epub", reloaded.catalogs[CATALOG]["two"].file)
		end)

		it("loads a fresh manifest from a corrupt file instead of raising", function()
			helper.fs.write(dir .. "/" .. MirrorSync.MANIFEST_NAME, "not lua{{{")

			local manifest = MirrorSync.load(dir)

			assert.equals(1, manifest.version)
			assert.same({}, manifest.catalogs)
		end)

		it("logs a warning for a corrupt manifest", function()
			helper.fs.write(dir .. "/" .. MirrorSync.MANIFEST_NAME, "not lua{{{")

			MirrorSync.load(dir)

			local logger = require("logger")
			assert.is_true(logger.logged("warn", "corrupt manifest"))
		end)

		it("returns false instead of raising when the manifest cannot be written", function()
			-- a directory sits where the manifest file goes
			assert.is_true(lfs.mkdir(dir .. "/" .. MirrorSync.MANIFEST_NAME))

			assert.is_false(MirrorSync.save(dir, { version = 1, catalogs = {} }))
		end)
	end)

	describe("reconcile", function()
		it("deletes a tracked file whose entry left the feed and keeps one that stayed", function()
			helper.fs.write(dir .. "/gone.epub", "gone")
			helper.fs.write(dir .. "/kept.epub", "kept")
			local manifest = tracked({ "gone-id", "kept-id" }, { "gone.epub", "kept.epub" })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, { ["kept-id"] = true })

			assert.same({ dir .. "/gone.epub" }, result.deleted)
			assert.equals(0, result.missing)
			assert.same({}, result.failed)
			assert.is_false(helper.fs.exists(dir .. "/gone.epub"))
			assert.is_true(helper.fs.exists(dir .. "/kept.epub"))
			assert.is_nil(manifest.catalogs[CATALOG]["gone-id"])
			assert.is_table(manifest.catalogs[CATALOG]["kept-id"])
		end)

		it("never touches a file it did not download", function()
			helper.fs.write(dir .. "/mine.epub", "not tracked")
			local manifest = tracked({ "gone-id" }, { "gone.epub" })
			helper.fs.write(dir .. "/gone.epub", "tracked")

			MirrorSync.reconcile(dir, manifest, CATALOG, { ["other-id"] = true })

			assert.is_true(helper.fs.exists(dir .. "/mine.epub"))
			assert.equals("not tracked", helper.fs.read(dir .. "/mine.epub"))
		end)

		it("deletes nothing and reports skipped=empty when the desired set is empty", function()
			helper.fs.write(dir .. "/gone.epub", "gone")
			local manifest = tracked({ "gone-id" }, { "gone.epub" })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, {})

			assert.equals("empty", result.skipped)
			assert.same({}, result.deleted)
			assert.is_true(helper.fs.exists(dir .. "/gone.epub"))
			assert.is_table(manifest.catalogs[CATALOG]["gone-id"])
		end)

		it("refuses a manifest path that escapes the sync dir", function()
			local outside_dir = helper.tmpdir()
			helper.fs.write(outside_dir .. "/outside.epub", "outside")
			local rel = "../" .. outside_dir:match("[^/]+$") .. "/outside.epub"
			local manifest = tracked({ "escape-id" }, { rel })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, { ["other-id"] = true })

			assert.equals(1, result.refused)
			assert.same({}, result.deleted)
			assert.is_true(helper.fs.exists(outside_dir .. "/outside.epub"))
			assert.is_table(manifest.catalogs[CATALOG]["escape-id"])
		end)

		it("refuses an absolute manifest path outside the sync dir", function()
			local outside_dir = helper.tmpdir()
			local decoy = outside_dir .. "/decoy.epub"
			helper.fs.write(decoy, "decoy")
			local manifest = tracked({ "abs-id" }, { decoy })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, { ["other-id"] = true })

			assert.equals(1, result.refused)
			assert.same({}, result.deleted)
			assert.equals("decoy", helper.fs.read(decoy))
			assert.is_table(manifest.catalogs[CATALOG]["abs-id"])
		end)

		it("refuses a manifest path whose .. components stay inside the sync dir", function()
			helper.fs.write(dir .. "/kept.epub", "kept")
			local manifest = tracked({ "dot-id" }, { "sub/./../kept.epub" })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, { ["other-id"] = true })

			assert.equals(1, result.refused)
			assert.same({}, result.deleted)
			assert.is_true(helper.fs.exists(dir .. "/kept.epub"))
			assert.is_table(manifest.catalogs[CATALOG]["dot-id"])
		end)

		it("does not delete a directory sitting at the tracked path", function()
			assert.is_true(lfs.mkdir(dir .. "/folder.epub"))
			local manifest = tracked({ "dir-id" }, { "folder.epub" })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, { ["other-id"] = true })

			assert.equals(1, result.missing)
			assert.same({}, result.deleted)
			assert.same({}, result.failed)
			assert.equals("directory", lfs.attributes(dir .. "/folder.epub", "mode"))
			assert.is_nil(manifest.catalogs[CATALOG]["dir-id"])
		end)

		it("drops a tracked path whose file is already gone, without raising", function()
			local manifest = tracked({ "ghost-id" }, { "ghost.epub" })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, { ["other-id"] = true })

			assert.equals(1, result.missing)
			assert.same({}, result.deleted)
			assert.same({}, result.failed)
			assert.is_nil(manifest.catalogs[CATALOG]["ghost-id"])
		end)

		it("removes a symlink at the tracked path without touching its target", function()
			helper.fs.write(dir .. "/target.epub", "target")
			os.execute(("ln -sf %q %q"):format(dir .. "/target.epub", dir .. "/link.epub"))
			assert.equals("link", lfs.symlinkattributes(dir .. "/link.epub", "mode"))
			local manifest = tracked({ "link-id" }, { "link.epub" })

			local result = MirrorSync.reconcile(dir, manifest, CATALOG, { ["other-id"] = true })

			assert.same({ dir .. "/link.epub" }, result.deleted)
			assert.is_true(helper.fs.exists(dir .. "/target.epub"))
			assert.is_nil(manifest.catalogs[CATALOG]["link-id"])
		end)

		it("keeps entries that are still in the desired set", function()
			helper.fs.write(dir .. "/kept.epub", "kept")
			local manifest = tracked({ "kept-id" }, { "kept.epub" })

			MirrorSync.reconcile(dir, manifest, CATALOG, { ["kept-id"] = true })

			assert.is_true(helper.fs.exists(dir .. "/kept.epub"))
			assert.is_table(manifest.catalogs[CATALOG]["kept-id"])
		end)
	end)

	describe("enumerate", function()
		it("collects identities in feed order across rel=next pages", function()
			local browser = new_browser({
				[CATALOG] = page({ book("One", "https://x/1", { id = "id-1" }) }, "https://x/page2"),
				["https://x/page2"] = page({
					book("Two", "https://x/2", { id = "id-2" }),
					book("Three", "https://x/3", { id = "id-3" }),
				}, nil),
			})

			local desired, order, complete = MirrorSync.enumerate(browser, CATALOG)

			assert.is_true(complete)
			assert.same({ "id-1", "id-2", "id-3" }, order)
			assert.is_table(desired["id-1"])
			assert.equals("https://x/2", desired["id-2"].link.href)
			assert.same({ CATALOG, "https://x/page2" }, browser.fetched)
		end)

		it("does not re-collect an identity that appears twice", function()
			local browser = new_browser({
				[CATALOG] = page({
					book("First", "https://x/a", { id = "dup" }),
					book("Second", "https://x/b", { id = "dup" }),
				}, nil),
			})

			local desired, order, complete = MirrorSync.enumerate(browser, CATALOG)

			assert.is_true(complete)
			assert.same({ "dup" }, order)
			assert.equals("https://x/a", desired["dup"].link.href)
		end)

		it("marks the walk incomplete when a page mid-pagination returns nothing, keeping earlier pages", function()
			local browser = new_browser({
				[CATALOG] = page({ book("One", "https://x/1", { id = "id-1" }) }, "https://x/page2"),
				["https://x/page2"] = page({}, "https://x/page3"),
			})

			local desired, order, complete = MirrorSync.enumerate(browser, CATALOG)

			assert.is_false(complete)
			assert.same({ "id-1" }, order)
			assert.is_table(desired["id-1"])
		end)

		it("marks the walk incomplete and collects nothing when the first page is empty", function()
			local browser = new_browser({
				[CATALOG] = page({}, nil),
			})

			local desired, order, complete = MirrorSync.enumerate(browser, CATALOG)

			assert.is_false(complete)
			assert.same({}, order)
			assert.same({}, desired)
		end)

		it("recurses into a sub-feed entry with no acquisitions and a .opds url", function()
			local browser = new_browser({
				[CATALOG] = page({
					subfeed("https://x/books.opds"),
					book("Top", "https://x/top", { id = "top-id" }),
				}, nil),
				["https://x/books.opds"] = page({ book("Sub", "https://x/sub", { id = "sub-id" }) }, nil),
			})

			local _, order, complete = MirrorSync.enumerate(browser, CATALOG)

			assert.is_true(complete)
			assert.same({ "sub-id", "top-id" }, order)
		end)

		it("skips a revisited sub-feed url", function()
			local browser = new_browser({
				[CATALOG] = page({
					subfeed("https://x/books.opds"),
					subfeed("https://x/books.opds"),
				}, nil),
				["https://x/books.opds"] = page({ book("Sub", "https://x/sub", { id = "sub-id" }) }, nil),
			})

			local _, order, complete = MirrorSync.enumerate(browser, CATALOG)

			assert.is_true(complete)
			assert.same({ "sub-id" }, order)
		end)

		it("does not recurse past MAX_SUBFEED_DEPTH", function()
			local browser = new_browser({
				[CATALOG] = page({ subfeed("https://x/l1.opds") }, nil),
				["https://x/l1.opds"] = page({ subfeed("https://x/l2.opds") }, nil),
				-- at the cap: entries read, deeper sub-feed not followed
				["https://x/l2.opds"] = page({
					subfeed("https://x/l3.opds"),
					book("Deep", "https://x/deep", { id = "deep-id" }),
				}, nil),
				["https://x/l3.opds"] = page({ book("TooDeep", "https://x/too", { id = "too-deep-id" }) }, nil),
			})

			local _, order, complete = MirrorSync.enumerate(browser, CATALOG)

			assert.is_true(complete)
			assert.same({ "deep-id" }, order)
		end)

		it("stops at MAX_PAGES pages and marks the walk incomplete", function()
			local original = MirrorSync.MAX_PAGES
			MirrorSync.MAX_PAGES = 3
			local counter = 0
			local browser = new_browser({
				[CATALOG] = function()
					counter = counter + 1
					return page({
						book("Book " .. counter, "https://x/" .. counter, { id = "id-" .. counter }),
					}, CATALOG)
				end,
			})

			local _, order, complete = MirrorSync.enumerate(browser, CATALOG)
			MirrorSync.MAX_PAGES = original

			assert.is_false(complete)
			assert.same({ "id-1", "id-2", "id-3" }, order)
		end)

		it("prefers entry.id over the link href", function()
			local browser = new_browser({
				[CATALOG] = page({ book("One", "https://x/a", { id = "x" }) }, nil),
			})

			local desired = MirrorSync.enumerate(browser, CATALOG)

			assert.is_table(desired["x"])
			assert.is_nil(desired["https://x/a"])
		end)

		it("falls back to the href when there is no id", function()
			local browser = new_browser({
				[CATALOG] = page({ book("One", "https://x/a") }, nil),
			})

			local desired = MirrorSync.enumerate(browser, CATALOG)

			assert.is_table(desired["https://x/a"])
		end)

		it("falls back to the href when the id is an empty string", function()
			local browser = new_browser({
				[CATALOG] = page({ book("One", "https://x/a", { id = "" }) }, nil),
			})

			local desired = MirrorSync.enumerate(browser, CATALOG)

			assert.is_table(desired["https://x/a"])
		end)

		it("takes the first acquisition link with a non-empty href", function()
			local entry = book("One", { "", "https://x/first", "https://x/second" }, { id = "pick-id" })
			local browser = new_browser({
				[CATALOG] = page({ entry }, nil),
			})

			local desired, order = MirrorSync.enumerate(browser, CATALOG)

			assert.same({ "pick-id" }, order)
			assert.equals("https://x/first", desired["pick-id"].link.href)
		end)
	end)

	describe("trackDownloads", function()
		it("ignores items without a mirror_identity or without a file", function()
			local manifest = { version = 1, catalogs = {} }

			MirrorSync.trackDownloads(manifest, dir, CATALOG, {
				{ file = dir .. "/a.epub" }, -- no identity
				{ mirror_identity = "b" }, -- no file
				{ mirror_identity = 7, file = dir .. "/c.epub" }, -- identity not a string
				{ mirror_identity = "d", file = 9 }, -- file not a string
				"not a table",
			})

			assert.same({}, manifest.catalogs)
		end)

		it("records the downloaded file under the identity", function()
			local manifest = { version = 1, catalogs = {} }

			MirrorSync.trackDownloads(manifest, dir, CATALOG, {
				{ mirror_identity = "one", file = dir .. "/one.epub" },
			})

			assert.equals("one.epub", manifest.catalogs[CATALOG]["one"].file)
		end)

		it("stores an absolute path when the file lives outside the sync dir", function()
			local outside_dir = helper.tmpdir()
			local manifest = { version = 1, catalogs = {} }

			MirrorSync.trackDownloads(manifest, dir, CATALOG, {
				{ mirror_identity = "abs", file = outside_dir .. "/abs.epub" },
			})

			assert.equals(outside_dir .. "/abs.epub", manifest.catalogs[CATALOG]["abs"].file)
		end)

		it("does not mistake a sibling directory with a shared prefix for the sync dir", function()
			local manifest = { version = 1, catalogs = {} }
			local prefix = dir:match("[^/]+$")

			MirrorSync.trackDownloads(manifest, dir, CATALOG, {
				{ mirror_identity = "sib", file = dir .. "-" .. prefix .. "/x.epub" },
			})

			assert.equals(dir .. "-" .. prefix .. "/x.epub", manifest.catalogs[CATALOG]["sib"].file)
		end)
	end)
end)
