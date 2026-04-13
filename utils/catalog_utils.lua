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

    return nil, nil
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
