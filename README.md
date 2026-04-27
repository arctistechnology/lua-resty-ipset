# lua-resty-ipset

LuaJIT FFI bindings for `libipset`, exposing the Linux kernel's ipset
machinery to OpenResty and nginx as a regular Lua API.

The library opens a netlink session against `nfnetlink_ipset` and issues
commands directly, with no `popen` / `os.execute` / fork-exec round trip
per call. Set operations are submitted as netlink messages, results are
parsed in-process, and output for `list` / `save` is captured through a
custom `ipset_print_outfn` callback rather than a temporary file. Each
ban, unban, or membership test resolves in tens of microseconds and
never yields the worker.

## Synopsis

```lua
local ipset = require "resty.ipset"

local bl, err = ipset.new("banlist", { default_timeout = 3600 })
if not bl then
    ngx.log(ngx.ERR, "ipset init failed: ", err)
    return
end

bl:ban("203.0.113.42")
bl:is_banned("203.0.113.42")    -- true
bl:unban("203.0.113.42")
```

OpenResty integration:

```nginx
http {
    init_worker_by_lua_block {
        local banlist = require "resty.ipset.banlist"
        local ok, err = banlist.init()
        if not ok then
            ngx.log(ngx.ERR, "banlist init failed: ", err)
        end
    }

    server {
        access_by_lua_block {
            local bl = require("resty.ipset.banlist").get()
            if bl and bl:is_banned(ngx.var.remote_addr) then
                return ngx.exit(403)
            end
        }
    }
}
```

## Installation

Install the Lua module:

```bash
luarocks install lua-resty-ipset
```

Install the system dependencies (Ubuntu / Debian):

```bash
sudo apt install ipset libipset-dev iptables-persistent
```

Create the kernel set:

```bash
sudo ipset create banlist hash:ip family inet \
    timeout 3600 maxelem 1000000 hashsize 4096 -exist
```

Wire it into iptables so banned packets are dropped before reaching nginx:

```bash
sudo iptables -I INPUT -m set --match-set banlist src -j DROP
sudo netfilter-persistent save
```

Persist ipset across reboots:

```bash
sudo ipset save > /etc/ipset.conf
sudo systemctl enable ipset.service
echo "*/15 * * * * root /usr/sbin/ipset save > /etc/ipset.conf" | \
    sudo tee /etc/cron.d/ipset-save
```

The nginx worker process needs `CAP_NET_ADMIN` to talk to the kernel via
netlink. If nginx runs as root this is satisfied automatically. If it
runs as a non-root user, grant the capability through systemd:

```bash
sudo systemctl edit nginx.service
```

Add the following lines in the editor, then save:

```ini
[Service]
AmbientCapabilities=CAP_NET_ADMIN
```

Reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart nginx
```

Or apply the capability directly to the binary:

```bash
sudo setcap cap_net_admin+ep /usr/sbin/nginx
```

## Methods

### ipset.new(setname, opts?)

`syntax: bl, err = ipset.new(setname, opts?)`

Creates a new ipset session bound to `setname`.

`opts` is an optional table:

| Field             | Type    | Default | Description                                  |
|-------------------|---------|---------|----------------------------------------------|
| `ipv6`            | boolean | `false` | Use `inet6` family instead of `inet`.        |
| `default_timeout` | number  | `0`     | Default TTL in seconds for `ban()`.          |
| `auto_create`     | boolean | `false` | Create the set if it does not exist.         |
| `maxelem`         | number  | 1048576 | Max entries (only with `auto_create`).       |
| `hashsize`        | number  | 4096    | Initial hash size (only with `auto_create`). |

Returns the instance on success, or `nil` and an error string.

> Do not call `new()` inside `init_by_lua`. Netlink sockets do not survive
> the master → worker fork. Use `init_worker_by_lua` or any later phase.

### bl:ban(ip, timeout?)

`syntax: ok, err = bl:ban(ip, timeout?)`

Adds `ip` to the set. If `timeout` is omitted, `default_timeout` is used.
Returns `true` on success.

### bl:unban(ip)

`syntax: ok, err = bl:unban(ip)`

Removes `ip` from the set. Returns `true` on success.

### bl:is_banned(ip)

`syntax: banned, err = bl:is_banned(ip)`

Returns `true` if `ip` is in the set, `false` if not, or `nil` and an
error string on failure.

### bl:ban_many(ips, timeout?)

`syntax: results = bl:ban_many(ips, timeout?)`

Bans an array of IPs. Returns a table
`{ ok = N, failed = N, errors = {...} }`.

### bl:unban_many(ips)

`syntax: results = bl:unban_many(ips)`

Unbans an array of IPs. Same return shape as `ban_many`.

### bl:list()

`syntax: entries, err = bl:list()`

Returns an array of `{ ip, timeout?, packets?, bytes? }` entries.

### bl:count()

`syntax: n, err = bl:count()`

Returns the number of entries in the set.

### bl:create(opts?)

`syntax: ok, err = bl:create(opts?)`

Creates the set. Accepts `timeout`, `maxelem`, `hashsize`. Idempotent
(uses `-exist`).

### bl:flush()

`syntax: ok, err = bl:flush()`

Removes all entries from the set.

### bl:destroy()

`syntax: ok, err = bl:destroy()`

Destroys the set. Fails if the set is referenced by iptables/nftables.

### bl:close()

`syntax: bl:close()`

Releases the netlink socket. Idempotent. The instance becomes unusable
afterwards.

## Submodules

### resty.ipset.banlist

A singleton wrapper around a default `banlist` set. Designed for
OpenResty worker initialization — creates one ipset instance per worker
on startup, then reused by every request.

```lua
-- nginx.conf
init_worker_by_lua_block {
    local banlist = require "resty.ipset.banlist"
    banlist.init()
}

-- in any request handler
local bl = require("resty.ipset.banlist").get()
bl:ban("203.0.113.42")
```

`banlist.init()` creates the instance once per worker. `banlist.get()`
returns the cached instance, or `nil` plus an error if init failed.

## Performance

Measured on a single OpenResty worker, 10,000 sequential operations
against a fresh `hash:ip` set:

| Operation  | Throughput      | Latency      |
|------------|-----------------|--------------|
| `ban`      | ~60,000 ops/sec | ~16 µs/op    |
| `is_banned`| ~80,000 ops/sec | ~12 µs/op    |
| `unban`    | ~83,000 ops/sec | ~12 µs/op    |
| `list`     | 10,000 entries  | ~13 ms total |

All operations are non-blocking from nginx's point of view. No subprocess,
no temporary files, no disk I/O.

## License

MIT. See [LICENSE](LICENSE).

## Author

Zephrise &lt;[github.com/zephrise](https://github.com/zephrise)&gt; — Arctis Technology