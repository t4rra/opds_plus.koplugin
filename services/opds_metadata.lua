-- OPDS metadata writer
-- Persists metadata using KOReader custom metadata overrides only
local logger = require("logger")
local DocSettings = require("docsettings")

local OPDSMetadata = {}

-- Remove any custom sidecar/metadata associated with a book path.
-- Attempts to clear custom_props for the given book and flush.
-- Returns true on success or false, err on failure.
function OPDSMetadata.removeSidecar(book_path)
    if type(book_path) ~= "string" or book_path == "" then
        return false, "invalid book path"
    end

    local ok, err = pcall(function()
        local custom_doc_settings = DocSettings.openSettingsFile()
        if not custom_doc_settings then
            error("could not open custom DocSettings")
        end

        -- Try to clear any custom props for this book and flush the change.
        -- Some DocSettings implementations may provide a direct removal API;
        -- saving nil for the key is a best-effort fallback.
        custom_doc_settings:saveSetting("custom_props", nil)
        custom_doc_settings:flushCustomMetadata(book_path)
    end)

    if not ok then return false, err end
    logger.dbg("OPDS custom sidecar removed", book_path)
    return true
end

local function isArray(value)
    if type(value) ~= "table" then return false end
    local max = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        if key > max then max = key end
    end
    for i = 1, max do if value[i] == nil then return false end end
    return true
end

local function normalizeValue(value)
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type ==
        "boolean" then return value end
    if value_type == "table" then
        if isArray(value) then
            local out = {}
            for i = 1, #value do
                local item = value[i]
                if type(item) == "string" or type(item) == "number" then
                    table.insert(out, tostring(item))
                end
            end
            return table.concat(out, "\n")
        end
        return nil
    end
    return nil
end

local function buildCustomMetadata(metadata)
    local custom = {}
    for key, value in pairs(metadata or {}) do
        local normalized = normalizeValue(value)
        if normalized ~= nil then custom[key] = normalized end
    end

    if custom.summary and not custom.description then
        custom.description = custom.summary
    end

    -- KOReader surfaces description in book info; keep a single canonical field.
    custom.summary = nil

    return custom
end

local function buildDisplayTitle(metadata, book_path)
    if type(metadata.title) == "string" and metadata.title ~= "" then
        return metadata.title
    end
    return (book_path:gsub(".*[/\\]", "")):gsub("%.[^.]+$", "")
end

local function cloneTable(value)
    local clone = {}
    for key, item in pairs(value or {}) do clone[key] = item end
    return clone
end

function OPDSMetadata.writeMetadata(book_path, metadata)
    if type(book_path) ~= "string" or book_path == "" then
        return false, "invalid book path"
    end
    if type(metadata) ~= "table" then return false, "invalid metadata" end

    local normalized_metadata = buildCustomMetadata(metadata)
    normalized_metadata.display_title = buildDisplayTitle(normalized_metadata,
                                                          book_path)

    local doc_settings = DocSettings:open(book_path)
    local original_doc_props = cloneTable(
                                   doc_settings:readSetting("doc_props") or {})

    local custom_doc_settings = DocSettings.openSettingsFile()
    if not custom_doc_settings then
        return false, "could not open custom DocSettings"
    end

    custom_doc_settings:saveSetting("doc_props", original_doc_props)
    custom_doc_settings:saveSetting("custom_props", normalized_metadata)

    local ok, err = pcall(function()
        custom_doc_settings:flushCustomMetadata(book_path)
    end)

    if not ok then return false, err end

    logger.dbg("OPDS custom metadata written", book_path)
    return true
end

-- Backward-compatible name for existing call sites
function OPDSMetadata.writeSidecar(book_path, metadata)
    return OPDSMetadata.writeMetadata(book_path, metadata)
end

return OPDSMetadata
