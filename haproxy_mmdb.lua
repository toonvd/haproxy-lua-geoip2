-- luacheck: globals core
local mmdb = require("mmdb")
local db_country, db_asn

local function init()
	local ok, r = pcall(mmdb.open, "/var/lib/GeoIP/GeoLite2-Country.mmdb")
	if ok then
		db_country = r
	end
	ok, r = pcall(mmdb.open, "/var/lib/GeoIP/GeoLite2-ASN.mmdb")
	if ok then
		db_asn = r
	end
end

local function search(db, ip)
	if not db or not ip or ip == "" then
		return nil
	end
	local method = ip:match(":") and "search_ipv6" or "search_ipv4"
	local ok, r = pcall(db[method], db, ip)
	return ok and r or nil
end

local function mmdb_lookup(ip, db_type, ...)
	local db
	if db_type == "country" then
		db = db_country
	elseif db_type == "asn" then
		db = db_asn
	else
		return nil
	end
	local result = search(db, ip)
	if not result then
		return nil
	end
	local props = { ... }
	local obj = result
	if #props == 0 then
		if db_type == "asn" and result.autonomous_system_number then
			return "AS" .. result.autonomous_system_number
		end
		return nil
	else
		for _, key in ipairs(props) do
			if type(obj) == "table" and obj[key] then
				obj = obj[key]
			else
				return nil
			end
		end
		if db_type == "asn" and type(obj) == "number" then
			return "AS" .. obj
		else
			return tostring(obj)
		end
	end
end

core.register_converters("mmdb_lookup", function(ip, db_type, ...)
	return mmdb_lookup(ip, db_type, ...)
end)

init()
