local has_bit, bit = pcall(require, "bit")
local has_ffi, ffi = pcall(require, "ffi")

local function my_unpack(fmt, str, pos)
	pos = pos or 1
	local len
	if fmt == ">d" then
		len = 8
		return pos + len, 0
	elseif fmt == ">f" then
		len = 4
		return pos + len, 0
	elseif fmt:sub(1, 2) == ">I" then
		len = tonumber(fmt:sub(3))
		local x = 0
		for i = 0, len - 1 do
			x = x * 256 + str:byte(pos + i)
		end
		return pos + len, x
	elseif fmt:sub(1, 2) == ">i" then
		len = tonumber(fmt:sub(3))
		local x = 0
		for i = 0, len - 1 do
			x = x * 256 + str:byte(pos + i)
		end
		if len == 4 and x >= 2 ^ 31 then
			x = x - 2 ^ 32
		end
		if len == 8 and x >= 2 ^ 63 then
			x = x - 2 ^ 64
		end
		return pos + len, x
	end
end

local sunpack = string.unpack or my_unpack
local mmdb_separator = "\171\205\239MaxMind.com"
local geodb_methods = {}
local geodb_mt = {
	__name = "mmdblua-database",
	__index = geodb_methods,
}
local data_types = {}
local getters = {}

local function open_db(filename)
	local fd = assert(io.open(filename, "rb"))
	local contents = assert(fd:read("*a"))

	local start_metadata
	do
		local init = math.max(1, #contents - (128 * 1024))
		while true do
			local s, e = contents:find(mmdb_separator, start_metadata or init, true)
			if s == nil then
				break
			end
			start_metadata = e + 1
		end
		if start_metadata == nil then
			error("Invalid MaxMind Database")
		end
	end

	local self = setmetatable({
		contents = contents,
		start_metadata = start_metadata,
		data = nil,
		left = nil,
		right = nil,
		ipv4_start = 0,
	}, geodb_mt)

	local _, data = self:read_data(start_metadata, 0)
	self.data = data

	local getter = getters[data.record_size]
	if getter == nil then
		error("Unsupported record size: " .. data.record_size)
	end
	self.left, self.right, self.record_length = getter.left, getter.right, getter.record_length

	self.start_data = self.record_length * self.data.node_count + 16 + 1

	if self.data.ip_version == 6 then
		self.ipv4_start = self:ipv6_find_ipv4_start()
	end

	return self
end

function geodb_methods:read_data(base, offset)
	local control_byte = self.contents:byte(base + offset)
	offset = offset + 1

	local data_type = math.floor(control_byte / 32)
	if data_type == 0 then
		data_type = self.contents:byte(base + offset) + 7
		offset = offset + 1
	end

	local func = data_types[data_type]
	if func == nil then
		error("Unknown data section: " .. data_type)
	end

	local data_size = control_byte % 32
	if data_type ~= 1 then
		if data_size == 29 then
			data_size = 29 + self.contents:byte(base + offset)
			offset = offset + 1
		elseif data_size == 30 then
			local hi, lo = self.contents:byte(base + offset, base + offset + 1)
			offset = offset + 2
			data_size = 285 + hi * 256 + lo
		elseif data_size == 31 then
			local o1, o2, o3, o4 = self.contents:byte(base + offset, base + offset + 3)
			offset = offset + 4
			data_size = 65821 + o1 * 16777216 + o2 * 65536 + o3 * 256 + o4
		end
	end

	return func(self, base, offset, data_size)
end

function geodb_methods:read_pointer(base, offset, magic)
	local size = math.floor(magic / 8)
	local pointer
	if size == 0 then
		local o1 = self.contents:byte(base + offset)
		offset = offset + 1
		pointer = (magic % 8) * 256 + o1
	elseif size == 1 then
		local o1, o2 = self.contents:byte(base + offset, base + offset + 1)
		offset = offset + 2
		pointer = (magic % 8) * 65536 + o1 * 256 + o2 + 2048
	elseif size == 2 then
		local o1, o2, o3 = self.contents:byte(base + offset, base + offset + 2)
		offset = offset + 3
		pointer = (magic % 8) * 16777216 + o1 * 65536 + o2 * 256 + o3 + 526336
	elseif size == 3 then
		local o1, o2, o3, o4 = self.contents:byte(base + offset, base + offset + 3)
		offset = offset + 4
		pointer = o1 * 16777216 + o2 * 65536 + o3 * 256 + o4
	end
	local _, val = self:read_data(base, pointer)
	return offset, val
end

function geodb_methods:read_string(base, offset, length)
	return offset + length, self.contents:sub(base + offset, base + offset + length - 1)
end

function geodb_methods:read_double(base, offset, length)
	assert(length == 8, "double of non-8 length")
	return offset + 8, sunpack(">d", self.contents, base + offset)
end

function geodb_methods:read_float(base, offset, length)
	assert(length == 4, "float of non-4 length")
	return offset + 4, sunpack(">f", self.contents, base + offset)
end

function geodb_methods:read_unsigned(base, offset, length)
	if length == 0 then
		return offset, 0
	end
	return offset + length, sunpack(">I" .. length, self.contents, base + offset)
end

function geodb_methods:read_signed(base, offset, length)
	if length == 0 then
		return offset, 0
	end
	return offset + length, sunpack(">i" .. length, self.contents, base + offset)
end

function geodb_methods:read_map(base, offset, n_pairs)
	local map = {}
	for _ = 1, n_pairs do
		local key, val
		offset, key = self:read_data(base, offset)
		assert(type(key) == "string")
		offset, val = self:read_data(base, offset)
		map[key] = val
	end
	return offset, map
end

function geodb_methods:read_array(base, offset, n_items)
	local array = {}
	for i = 1, n_items do
		local val
		offset, val = self:read_data(base, offset)
		array[i] = val
	end
	return offset, array
end

data_types[1] = geodb_methods.read_pointer
data_types[2] = geodb_methods.read_string
data_types[3] = geodb_methods.read_double
data_types[4] = geodb_methods.read_string
data_types[5] = geodb_methods.read_unsigned
data_types[6] = geodb_methods.read_unsigned
data_types[7] = geodb_methods.read_map
data_types[8] = geodb_methods.read_signed
data_types[9] = geodb_methods.read_unsigned
data_types[10] = geodb_methods.read_unsigned
data_types[11] = geodb_methods.read_array
data_types[13] = function(_self, _base, _offset, _zero)
	return nil
end
data_types[14] = function(_self, _base, offset, length)
	return offset, length == 1
end
data_types[15] = geodb_methods.read_float

if has_ffi and has_bit then
	local const_char_a = ffi.typeof("const char*")
	local buff = ffi.new("char[8]")
	local uint16_p = ffi.typeof("uint16_t*")
	local uint32_p = ffi.typeof("uint32_t*")
	local int32_p = ffi.typeof("int32_t*")
	local uint64_p = ffi.typeof("uint64_t*")
	if ffi.abi("le") then
		function geodb_methods:read_uint16(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 4 - length, src, length)
			local x = ffi.cast(uint32_p, buff)[0]
			ffi.fill(buff + 4 - length, length)
			x = bit.bswap(x)
			return offset + length, x
		end
		function geodb_methods:read_uint32(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 4 - length, src, length)
			local x = ffi.cast(uint32_p, buff)[0]
			ffi.fill(buff + 4 - length, length)
			x = bit.bswap(x)
			return offset + length, x
		end
		function geodb_methods:read_int32(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 4 - length, src, length)
			local x = ffi.cast(int32_p, buff)[0]
			ffi.fill(buff + 4 - length, length)
			x = bit.bswap(x)
			return offset + length, x
		end
		function geodb_methods:read_uint64(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 8 - length, src, length)
			local as_u32 = ffi.cast(uint32_p, buff)
			as_u32[0], as_u32[1] = bit.bswap(as_u32[1]), bit.bswap(as_u32[0])
			local x = ffi.cast(uint64_p, buff)[0]
			ffi.fill(buff, length)
			return offset + length, x
		end
	else
		function geodb_methods:read_uint16(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 2 - length, src, length)
			local x = ffi.cast(uint16_p, buff)[0]
			ffi.fill(buff + 2 - length, length)
			return offset + length, x
		end
		function geodb_methods:read_uint32(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 4 - length, src, length)
			local x = ffi.cast(uint32_p, buff)[0]
			ffi.fill(buff + 4 - length, length)
			return offset + length, x
		end
		function geodb_methods:read_int32(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 4 - length, src, length)
			local x = ffi.cast(int32_p, buff)[0]
			ffi.fill(buff + 4 - length, length)
			return offset + length, x
		end
		function geodb_methods:read_uint64(base, offset, length)
			local src = ffi.cast(const_char_a, self.contents) + base + offset - 1
			ffi.copy(buff + 8 - length, src, length)
			local x = ffi.cast(uint64_p, buff)[0]
			ffi.fill(buff + 8 - length, length)
			return offset + length, x
		end
	end
	data_types[5] = geodb_methods.read_uint16
	data_types[6] = geodb_methods.read_uint32
	data_types[8] = geodb_methods.read_int32
	data_types[9] = geodb_methods.read_uint64
end

getters[24] = {
	left = function(self, offset)
		local o1, o2, o3 = self.contents:byte(offset, offset + 2)
		return (o1 << 16) | (o2 << 8) | o3
	end,
	right = function(self, offset)
		local o1, o2, o3 = self.contents:byte(offset + 3, offset + 5)
		return (o1 << 16) | (o2 << 8) | o3
	end,
	record_length = 6,
}
getters[28] = {
	left = function(self, offset)
		local o1, o2, o3, o4 = self.contents:byte(offset, offset + 3)
		return ((o4 >> 4) << 24) | (o1 << 16) | (o2 << 8) | o3
	end,
	right = function(self, offset)
		local o1, o2, o3, o4 = self.contents:byte(offset + 3, offset + 6)
		return ((o1 & 15) << 24) | (o2 << 16) | (o3 << 8) | o4
	end,
	record_length = 7,
}
getters[32] = {
	left = function(self, offset)
		local o1, o2, o3, o4 = self.contents:byte(offset, offset + 3)
		return (o1 << 24) | (o2 << 16) | (o3 << 8) | o4
	end,
	right = function(self, offset)
		local o1, o2, o3, o4 = self.contents:byte(offset + 4, offset + 7)
		return (o1 << 24) | (o2 << 16) | (o3 << 8) | o4
	end,
	record_length = 8,
}

function geodb_methods:search(bits, node)
	node = node or 0
	local seen = { [node] = true }
	for _, direction in ipairs(bits) do
		local offset = node * self.record_length + 1
		local record_value
		if direction then
			record_value = self:right(offset)
		else
			record_value = self:left(offset)
		end

		if seen[record_value] then
			error("Cyclical tree")
		end
		seen[record_value] = true

		if record_value == self.data.node_count then
			return nil
		elseif record_value > self.data.node_count then
			local data_offset = record_value - self.data.node_count - 16
			local _, res = self:read_data(self.start_data, data_offset)
			return node, res
		else
			node = record_value
		end
	end
	return node
end

do
	local bits = {}
	for i = 1, 80 do
		bits[i] = false
	end
	for i = 81, 96 do
		bits[i] = true
	end
	function geodb_methods:ipv6_find_ipv4_start()
		return self:search(bits, 0)
	end
end

local function ipv4_to_bit_array(str)
	local o1, o2, o3, o4 = str:match("(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)")
	assert(o1, "invalid IPv4 address")
	o1 = tonumber(o1, 10)
	o2 = tonumber(o2, 10)
	o3 = tonumber(o3, 10)
	o4 = tonumber(o4, 10)
	assert(o1 <= 255 and o2 <= 255 and o3 <= 255 and o4 <= 255, "invalid IPv4 address")
	return {
		(o1 >> 7) & 1 == 1,
		(o1 >> 6) & 1 == 1,
		(o1 >> 5) & 1 == 1,
		(o1 >> 4) & 1 == 1,
		(o1 >> 3) & 1 == 1,
		(o1 >> 2) & 1 == 1,
		(o1 >> 1) & 1 == 1,
		o1 & 1 == 1,
		(o2 >> 7) & 1 == 1,
		(o2 >> 6) & 1 == 1,
		(o2 >> 5) & 1 == 1,
		(o2 >> 4) & 1 == 1,
		(o2 >> 3) & 1 == 1,
		(o2 >> 2) & 1 == 1,
		(o2 >> 1) & 1 == 1,
		o2 & 1 == 1,
		(o3 >> 7) & 1 == 1,
		(o3 >> 6) & 1 == 1,
		(o3 >> 5) & 1 == 1,
		(o3 >> 4) & 1 == 1,
		(o3 >> 3) & 1 == 1,
		(o3 >> 2) & 1 == 1,
		(o3 >> 1) & 1 == 1,
		o3 & 1 == 1,
		(o4 >> 7) & 1 == 1,
		(o4 >> 6) & 1 == 1,
		(o4 >> 5) & 1 == 1,
		(o4 >> 4) & 1 == 1,
		(o4 >> 3) & 1 == 1,
		(o4 >> 2) & 1 == 1,
		(o4 >> 1) & 1 == 1,
		o4 & 1 == 1,
	}
end

function geodb_methods:search_ipv4(str)
	return select(2, self:search(ipv4_to_bit_array(str), self.ipv4_start))
end

local function ipv6_split(str)
	local components = {}
	local n = 0
	for u16 in str:gmatch("(%x%x?%x?%x?):?") do
		n = n + 1
		u16 = tonumber(u16, 16)
		assert(u16, "invalid IPv6 address")
		components[n] = u16
	end
	return components, n
end

local function ipv6_to_bit_array(str)
	local a, b = str:match("^([%x:]-)::([%x:]*)$")
	local components, n = ipv6_split(a or str)
	if a ~= nil then
		local end_components, m = ipv6_split(b)
		assert(m + n <= 7, "invalid IPv6 address")
		for i = n + 1, 8 - m do
			components[i] = 0
		end
		for i = 8 - m + 1, 8 do
			components[i] = end_components[i - 8 + m]
		end
	else
		assert(n == 8, "invalid IPv6 address")
	end
	local bits = {}
	for i = 1, 8 do
		local u16 = components[i]
		for j = 1, 16 do
			bits[(i - 1) * 16 + j] = ((u16 >> (16 - j)) & 1) == 1
		end
	end
	return bits
end

function geodb_methods:search_ipv6(str)
	return select(2, self:search(ipv6_to_bit_array(str)))
end

return {
	open = open_db,
}
