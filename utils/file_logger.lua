-- Lightweight file logger for OPDS Plus diagnostics
-- Writes plain text lines to KOReader data dir so users can share traces.

local DataStorage = require("datastorage")

local FileLogger = {}

local LOG_PATH = DataStorage:getDataDir() .. "/opdsplus-debug.log"

local function now()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function stringify(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        parts[#parts + 1] = tostring(value)
    end
    return table.concat(parts, " ")
end

function FileLogger.getPath()
    return LOG_PATH
end

function FileLogger.append(...)
    local fh = io.open(LOG_PATH, "a")
    if not fh then return false end
    fh:write("[", now(), "] ", stringify(...), "\n")
    fh:close()
    return true
end

return FileLogger
