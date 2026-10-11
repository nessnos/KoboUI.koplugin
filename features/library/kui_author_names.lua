-- kui_author_names.lua — KoboUI
-- Author names for the library: sort by last name, show as "First Last".
--
--   "Sarah J. Maas"      → sorted under M  (key "maas sarah j.")
--   "Ursula K. Le Guin"  → sorted under L  (particles stay with the surname)
--   "Martin Luther King Jr." → sorted under K (suffixes are ignored)
--   "Maas, Sarah J."     → shown as "Sarah J. Maas", sorted under M
--
-- Setting: kindleui_author_lastname_sort (default on).

local SUISettings = require("infra/sui_store")

local M = {}

local KEY = "kindleui_author_lastname_sort"

function M.isEnabled() return SUISettings:nilOrTrue(KEY) end
function M.setEnabled(on) SUISettings:saveSetting(KEY, on and true or false) end

-- Words that belong to the surname when they come right before it.
local PARTICLES = {
    ["van"] = true, ["von"] = true, ["der"] = true, ["den"] = true,
    ["de"] = true, ["del"] = true, ["della"] = true, ["di"] = true,
    ["da"] = true, ["du"] = true, ["des"] = true, ["la"] = true,
    ["le"] = true, ["st."] = true, ["st"] = true, ["ten"] = true,
    ["ter"] = true, ["bin"] = true, ["ibn"] = true, ["al"] = true,
}
-- Words after the surname that aren't part of it.
local SUFFIXES = {
    ["jr."] = true, ["jr"] = true, ["sr."] = true, ["sr"] = true,
    ["ii"] = true, ["iii"] = true, ["iv"] = true, ["phd"] = true,
    ["ph.d."] = true, ["md"] = true,
}

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- "Last, First" → "First Last". Leaves "First Last, Jr." alone.
function M.displayName(name)
    if type(name) ~= "string" then return name end
    local last, first = name:match("^([^,]+),%s*([^,]+)$")
    if last and first and not SUFFIXES[trim(first):lower()] then
        return trim(first) .. " " .. trim(last)
    end
    return name
end

-- Lower-case "surname given-names" key used for sorting.
function M.sortKey(name)
    if type(name) ~= "string" or name == "" then return "" end
    local shown = M.displayName(name):gsub(",", " ")
    local words = {}
    for w in shown:gmatch("%S+") do words[#words + 1] = w end
    if #words <= 1 then return shown:lower() end
    local suffix = {}
    while #words > 1 and SUFFIXES[words[#words]:lower()] do
        table.insert(suffix, 1, table.remove(words))
    end
    local first_surname = #words
    while first_surname > 2 and PARTICLES[words[first_surname - 1]:lower()] do
        first_surname = first_surname - 1
    end
    local surname, given = {}, {}
    for i = 1, #words do
        if i >= first_surname then surname[#surname + 1] = words[i]
        else given[#given + 1] = words[i] end
    end
    local key = table.concat(surname, " ") .. " " .. table.concat(given, " ")
    if #suffix > 0 then key = key .. " " .. table.concat(suffix, " ") end
    return key:lower()
end

-- Comparator for author name strings (strcoll on the sort keys).
function M.less(a, b, strcoll)
    local ka, kb = M.sortKey(a), M.sortKey(b)
    if ka ~= kb then
        if strcoll then return strcoll(ka, kb) end
        return ka < kb
    end
    if strcoll then return strcoll(a, b) end
    return a < b
end

return M
