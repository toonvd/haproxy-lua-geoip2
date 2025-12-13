local mmdb = require("mmdb")

local country_path = "/var/lib/GeoIP/GeoLite2-Country.mmdb"
local asn_path = "/var/lib/GeoIP/GeoLite2-ASN.mmdb"

local db_country = mmdb.open(country_path)
local db_asn = mmdb.open(asn_path)

local ip = arg[1]
local db_type = arg[2]
if not ip or not db_type then
	print("Usage: lua mmdb_validate.lua <IP> <db_type> [prop1] [prop2] ...")
	print("db_type: country, asn")
	print("Properties are the full path from the MMDB record root.")
	os.exit(1)
end

local start = os.clock()

local result
if db_type == "country" then
	result = db_country:search_ipv4(ip)
elseif db_type == "asn" then
	result = db_asn:search_ipv4(ip)
else
	print("ERROR: Unknown db_type")
	os.exit(1)
end

local value = "Unknown"
if result then
	local obj = result
	for i = 3, #arg do
		local key = arg[i]
		if type(obj) == "table" and obj[key] then
			obj = obj[key]
		else
			obj = nil
			break
		end
	end
	if obj then
		if db_type == "asn" and type(obj) == "number" then
			value = "AS" .. obj
		else
			value = tostring(obj)
		end
	end
end

local end_time = os.clock()

print(value)
print(string.format("TIME=%.6f", end_time - start))
