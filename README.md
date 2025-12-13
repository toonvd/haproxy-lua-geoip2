# HAProxy Lua GeoIP2

![Tests](https://img.shields.io/github/actions/workflow/status/toonvd/haproxy-lua-geoip2/tests.yml?branch=main&style=for-the-badge&label=Tests) ![Lint](https://img.shields.io/github/actions/workflow/status/toonvd/haproxy-lua-geoip2/lint.yml?branch=main&style=for-the-badge&label=Linter) ![Format](https://img.shields.io/github/actions/workflow/status/toonvd/haproxy-lua-geoip2/format.yml?branch=main&style=for-the-badge&label=Format) ![Tested On](https://img.shields.io/badge/Tested%20on-Haproxy%202%209%2015-004B59?style=for-the-badge)

This project provides a Lua module for HAProxy to perform GeoIP lookups using MaxMind GeoLite2 databases. It allows you to enrich HTTP requests with geographic and ASN information based on client IP addresses.

## Features

- Fast MMDB lookups using Lua in HAProxy
- Support for GeoLite2-Country and GeoLite2-ASN databases
- Flexible property traversal for any nested data
- Automatic ASN number formatting

## Installation

1. Download the GeoLite2 databases from [MaxMind](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data):
   - GeoLite2-Country.mmdb
   - GeoLite2-ASN.mmdb

2. Place the databases in `/var/lib/GeoIP/` (or update paths in `haproxy_mmdb.lua`).

3. Copy `haproxy_mmdb.lua` and `mmdb.lua` to your HAProxy Lua path (e.g., `/etc/haproxy/geoip/`).

4. Load the module in your HAProxy config:
   ```
   global
    lua-prepend-path /etc/haproxy/geoip/?.lua
    lua-load /etc/haproxy/geoip/haproxy_mmdb.lua
   ```

## Usage

Use the `lua.mmdb_lookup` converter in HAProxy expressions:

```
http-request set-header X-Country %[src,lua.mmdb_lookup("country","country","iso_code")]
http-request set-header X-Continent %[src,lua.mmdb_lookup("country","continent","code")]
http-request set-header X-ASN %[src,lua.mmdb_lookup("asn","autonomous_system_number")]
```

### Traversing Databases

The converter accepts:
- First argument: Database type (`"country"` or `"asn"`)
- Subsequent arguments: Property path from the MMDB record root

#### Country Database Examples
- ISO Code: `lua.mmdb_lookup("country","country","iso_code")`
- Continent Code: `lua.mmdb_lookup("country","continent","code")`
- City Name: `lua.mmdb_lookup("country","city","names","en")` (if using GeoLite2-City)

#### ASN Database Examples
- ASN Number: `lua.mmdb_lookup("asn","autonomous_system_number")`
- Organization: `lua.mmdb_lookup("asn","autonomous_system_organization")`

For full database schemas and available properties, see the [MaxMind GeoLite2 Documentation](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data).

## Testing

Run the validation script to compare Lua lookups against the `mmdblookup` CLI tool:

```bash
./tests/validate_mmdb_whois.sh <IP>
```

Or test individual lookups:

```bash
lua tests/mmdb_validate.lua <IP> country country iso_code
```

## Disclaimer

This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages or other liability, whether in an action of contract, tort or otherwise, arising from, out of or in connection with the software or the use or other dealings in the software.

## License

This project is licensed under the GPL-2.0 license. See LICENSE.md for details.

## Contributing

Contributions welcome! Please open issues or pull requests on GitHub.
