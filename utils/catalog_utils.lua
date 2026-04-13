-- Catalog utility functions for OPDS operations
-- Handles catalog entry construction and formatting
local CatalogUtils = {}

--- Build a catalog entry for the root menu
-- @param server table Server configuration object
-- @return table Formatted catalog entry
function CatalogUtils.buildRootEntry(server)
    local icons = ""
    if server.username then
        icons = "\u{f2c0}" -- Lock icon for authenticated catalogs
    end
    if server.sync then
        icons = "\u{f46a} " .. icons -- Sync icon
    end
    return {
        text = server.title,
        mandatory = icons,
        url = server.url,
        username = server.username,
        password = server.password,
        raw_names = server.raw_names,
        searchable = server.url and server.url:match("%%s") and true or false,
        sync = server.sync,
        sync_mode = server.sync_mode
    }
end

--- Parse title from entry (handles both string and table formats)
-- @param entry_title string|table Title from OPDS entry
-- @param default string Default value if parsing fails
-- @return string Parsed title
function CatalogUtils.parseEntryTitle(entry_title, default)
    default = default or "Unknown"

    if type(entry_title) == "string" then
        return entry_title
    elseif type(entry_title) == "table" then
        if type(entry_title.text) == "string" and entry_title.text ~= "" then
            return entry_title.text
        end
        if type(entry_title.type) == "string" and entry_title.div ~= "" then
            return entry_title.div
        end
    end

    return default
end

--- Parse author from entry (handles various formats)
-- @param entry_author table Author information from OPDS entry
-- @param default string Default value if parsing fails
-- @return string|nil Parsed author name or nil
function CatalogUtils.parseEntryAuthor(entry_author, default)
    default = default or "Unknown Author"

    if type(entry_author) ~= "table" or not entry_author.name then return nil end

    local author = entry_author.name

    if type(author) == "table" then
        if #author > 0 then
            author = table.concat(author, ", ")
            return author
        else
            return nil
        end
    elseif type(author) == "string" then
        return author
    end

    return default
end

--- Parse author list from entry author object
-- @param entry_author table Author information from OPDS entry
-- @return table|nil Array of author names, or nil
function CatalogUtils.parseEntryAuthors(entry_author)
    if type(entry_author) ~= "table" or not entry_author.name then return nil end

    if type(entry_author.name) == "string" and entry_author.name ~= "" then
        return {entry_author.name}
    end

    if type(entry_author.name) == "table" then
        local authors = {}
        for _, name in ipairs(entry_author.name) do
            if type(name) == "string" and name ~= "" then
                table.insert(authors, name)
            end
        end
        if #authors > 0 then return authors end
    end

    return nil
end

--- Best-effort extraction of series metadata from OPDS entry
-- @param entry table Raw OPDS entry table
-- @return string|nil, number|nil Series name and series index
function CatalogUtils.parseEntrySeries(entry)
    if type(entry) ~= "table" then return nil, nil end

    local function fromSeriesObject(series_obj)
        if type(series_obj) ~= "table" then return nil, nil end
        local series_name = series_obj.title or series_obj.name or
                                series_obj.label
        local series_index = tonumber(series_obj.position or series_obj.index)
        return series_name, series_index
    end

    local belongs_to = entry["belongs-to"]
    if type(belongs_to) == "table" then
        if #belongs_to > 0 then
            for _, relation in ipairs(belongs_to) do
                local rel = relation.rel or relation.type
                if type(rel) == "string" and rel:find("series") then
                    local series_name, series_index = fromSeriesObject(relation)
                    if series_name then
                        return series_name, series_index
                    end
                end
            end

            local fallback_name, fallback_index =
                fromSeriesObject(belongs_to[1])
            if fallback_name then
                return fallback_name, fallback_index
            end
        else
            local series_name, series_index = fromSeriesObject(belongs_to)
            if series_name then return series_name, series_index end
        end
    end

    if type(entry["calibre:series"]) == "string" and entry["calibre:series"] ~=
        "" then
        return entry["calibre:series"], tonumber(entry["calibre:series_index"])
    end

    if type(entry.series) == "string" and entry.series ~= "" then
        return entry.series, tonumber(entry.series_index)
    end

    local metas = entry.meta
    if type(metas) == "table" then
        local meta_list = metas
        if metas.property or metas[1] == nil then meta_list = {metas} end

        local series_name
        local series_id
        local series_index

        for _, meta in ipairs(meta_list) do
            if type(meta) == "table" then
                local property = meta.property
                local value = meta.text or meta.value
                if property == "belongs-to-collection" and type(value) ==
                    "string" and value ~= "" then
                    series_name = value
                    if type(meta.id) == "string" and meta.id ~= "" then
                        series_id = "#" .. meta.id
                    end
                end
            end
        end

        if series_name then
            for _, meta in ipairs(meta_list) do
                if type(meta) == "table" and meta.property == "group-position" then
                    local refines = meta.refines
                    if not series_id or refines == series_id or refines ==
                        "series" or refines == "#series" or refines == nil then
                        series_index = tonumber(meta.text or meta.value)
                        if series_index then break end
                    end
                end
            end
            return series_name, series_index
        end
    end

    return nil, nil
end

--- Best-effort extraction of language metadata from OPDS entry
-- @param entry table Raw OPDS entry table
-- @return string|nil Language code/name
function CatalogUtils.parseEntryLanguage(entry)
    if type(entry) ~= "table" then return nil end

    local function normalizeLanguage(value)
        if type(value) == "string" and value ~= "" then return value end
        if type(value) == "table" then
            local candidate = value[1] or value.code or value.term or
                                  value.value
            if type(candidate) == "string" and candidate ~= "" then
                return candidate
            end
        end
        return nil
    end

    return normalizeLanguage(entry.language) or
               normalizeLanguage(entry["dc:language"]) or
               normalizeLanguage(entry["dcterms:language"])
end

--- Best-effort extraction of keywords metadata from OPDS entry
-- @param entry table Raw OPDS entry table
-- @return string|nil Newline-separated keywords string
function CatalogUtils.parseEntryKeywords(entry)
    if type(entry) ~= "table" then return nil end

    local out = {}
    local seen = {}

    local function pushKeyword(value)
        if type(value) ~= "string" or value == "" then return end
        if not seen[value] then
            seen[value] = true
            table.insert(out, value)
        end
    end

    local function parseCategory(category)
        if type(category) ~= "table" then return end
        if #category > 0 then
            for _, cat in ipairs(category) do
                if type(cat) == "table" then
                    pushKeyword(cat.label or cat.term or cat.name)
                end
            end
        else
            pushKeyword(category.label or category.term or category.name)
        end
    end

    parseCategory(entry.category)

    local subjects = entry["dc:subject"] or entry["dcterms:subject"]
    if type(subjects) == "string" then
        pushKeyword(subjects)
    elseif type(subjects) == "table" then
        if #subjects > 0 then
            for _, subject in ipairs(subjects) do
                if type(subject) == "string" then
                    pushKeyword(subject)
                elseif type(subject) == "table" then
                    pushKeyword(subject.value or subject.label or subject.term)
                end
            end
        else
            pushKeyword(subjects.value or subjects.label or subjects.term)
        end
    end

    if #out == 0 then return nil end
    return table.concat(out, "\n")
end

--- Extract count and last_read from PSE stream link attributes
-- @param link table Link object with PSE attributes
-- @return number|nil, number|nil count, last_read values
function CatalogUtils.extractPSEStreamInfo(link)
    local count, last_read

    for k, v in pairs(link) do
        if k:sub(-6) == ":count" then
            count = tonumber(v)
        elseif k:sub(-9) == ":lastRead" then
            last_read = tonumber(v)
        end
    end

    return count, (last_read and last_read > 0 and last_read or nil)
end

return CatalogUtils
