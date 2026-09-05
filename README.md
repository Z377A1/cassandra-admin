# Cassandra Admin

A lightweight, web-based admin interface for Apache Cassandra, powered by [Alpine.js](https://alpinejs.dev/). Built with OpenResty and Lua, using the [lua-cassandra](https://github.com/thibaultcha/lua-cassandra) library, a Cassandra driver written in pure Lua.

![screenshot](/docs/screenshot.jpeg)

## Features

- **Schema Management** — Sidebar displaying all keyspaces, tables, and materialized views with search-friendly tree navigation.
- **Data Viewer** — Browse table and view data with customizable page sizes (50, 100, 200 rows).
- **Cursor-Based Pagination** — Fast and efficient cursor pagination using Cassandra's native paging states, eliminating offset overhead.
- **Column Metadata & Key Badges** — Visual indicators showing data types for each column, with distinct badges distinguishing partition keys and clustering keys.
- **Formatted CQL Output** — `cqlsh`-like formatting for complex data types including collections (lists, sets, maps), tuples, User-Defined Types (UDTs), blobs, timestamps, decimals, inet, and UUIDs/TimeUUIDs.
- **Data Export** — Export table data as **CQL** (`INSERT INTO` statements), **CSV**, or **JSON** with configurable row limits and optional DDL (`CREATE TABLE`) statements.
- **Quick Operations** — Truncate or drop tables and views, and drop keyspaces directly from the UI with modal confirmation.
- **Safeguards** — Built-in protection prevents accidental modification or deletion of system keyspaces (`system`, `system_auth`, `system_distributed`, `system_schema`, `system_traces`).
- **Deep Linking** — Direct URL routing (`/table/{keyspace}/{table}` and `/view/{keyspace}/{view}`) with browser history support (back/forward navigation).
- **Flexible Configuration** — Configure via environment variables or a `settings.cfg` configuration file.
- **Dark Mode** — Built-in dark and light theme toggle with automatic system preference detection and `localStorage` persistence.
- **Lightweight Architecture** — Powered by OpenResty (Nginx + LuaJIT) for minimal memory (< 512MB RAM) and CPU usage.

## Quick Setup

### Using Docker Compose

The included `docker-compose.yml` spins up an Apache Cassandra 5 container alongside `cassandra-admin`:

```bash
git clone https://github.com/IBM/cassandra-admin.git
cd cassandra-admin

docker-compose up -d

# Follow Cassandra startup logs until healthy (30-60 seconds)
docker-compose logs -f cassandra
```

Access the admin interface at `http://localhost:8000`.

### Connecting to an Existing Cassandra Instance

You can run `cassandra-admin` as a standalone container connected to an existing Cassandra cluster:

```bash
docker build -t cassandra-admin .

docker run -d \
  --name cassandra-admin \
  -p 8000:80 \
  -e CA_CONNECTION_HOST=your-cassandra-host \
  -e CA_CONNECTION_PORT=9042 \
  -e CA_CONNECTION_USERNAME=cassandra \
  -e CA_CONNECTION_PASSWORD=cassandra \
  cassandra-admin
```

## Configuration

### Environment Variables

The application can be configured using the following environment variables:

| Variable | Description | Default |
|---|---|---|
| `CA_CONNECTION_HOST` | Hostname or IP address of the Cassandra node | `127.0.0.1` |
| `CA_CONNECTION_PORT` | Native CQL protocol port | `9042` |
| `CA_CONNECTION_USERNAME` | Username for authentication | `cassandra` |
| `CA_CONNECTION_PASSWORD` | Password for authentication | `cassandra` |
| `CA_CONNECTION_TIMEOUT` | Connection and socket timeout in milliseconds | `5000` |
| `CA_DEBUG_MODE` | Set to `true` to disable template caching and show debug banner | `false` |

### Configuration File

Alternatively, you can provide configuration via a `settings.cfg` Lua file. When running in Docker, this file is mounted to `/etc/cassandra-admin/settings.cfg`:

```lua
{
  app_name = "Cassandra Admin",
  connection = {
    host = "cassandra_db",
    port = 9042,
    username = "cassandra",
    password = "cassandra",
    auth_provider = "plain_text",
    timeout = 5000, -- milliseconds
  },
  page_sizes = {50, 100, 200},
  default_page_size = 50,
}
```

> **Note:** Environment variables take precedence over settings defined in `settings.cfg`.

## REST API Reference

`cassandra-admin` provides a clean REST API used by the frontend:

| Endpoint | Method | Description |
|---|---|---|
| `/api/schema` | `GET` | Returns all keyspaces, tables, views, columns, and key definitions |
| `/api/table/:keyspace/:table` | `GET` | Fetches paginated rows and columns (`?page_size=50&paging_state=...`) |
| `/api/view/:keyspace/:view` | `GET` | Fetches paginated rows and columns for a materialized view |
| `/api/table/:keyspace/:table/truncate` | `POST` | Truncates all data from the specified table |
| `/api/:entity/:keyspace/:table/drop` | `POST` | Drops a table or view (`:entity` must be `table` or `view`) |
| `/api/keyspace/:keyspace/drop` | `POST` | Drops the specified keyspace |
| `/api/table/:keyspace/:table/export` | `POST` | Exports table data (`format`, `limit`, `include_ddl`) |
| `/api/view/:keyspace/:table/export` | `POST` | Exports materialized view data (`format`, `limit`) |

## Tech Stack

- **Server & Runtime**: [OpenResty](https://openresty.org/) (Nginx + LuaJIT)
- **Cassandra Driver**: [lua-cassandra](https://github.com/thibaultcha/lua-cassandra)
- **Frontend Framework**: [Alpine.js](https://alpinejs.dev/) v3
- **Styling**: [Bootstrap 5](https://getbootstrap.com/) & [Bootstrap Icons](https://icons.getbootstrap.com/)
- **Templating**: [lua-resty-template](https://github.com/bungle/lua-resty-template)
- **Request Parsing**: [lua-resty-reqargs](https://github.com/bungle/lua-resty-reqargs)

## Limitations

This list is not exhaustive, but outlines current architectural limitations:

- **Single contact point** — Connects to one contact point only; full cluster topology routing is planned for a future release.
- **No user authentication** — The app does not implement internal user authentication or role-based access control (RBAC). It is recommended to deploy behind an authenticating reverse proxy (e.g. Authelia, Keycloak, or HTTP Basic Auth) when exposed outside a private network.
- **No user/role management** — Database user, role, and permission management is planned for a future release.
- **No search/filter** — Freeform CQL queries or arbitrary row filtering are planned for a future release.
- **Read-only data manipulation** — Editing, inserting, or modifying individual rows in the UI is not yet supported.
- **No data import** — Importing data from CQL, CSV, or JSON files is planned for a future release.

## Roadmap

- [ ] Datatable with client-side sorting and search
- [ ] Testbed against Cassandra-compatible databases (e.g., ScyllaDB) and various Cassandra versions (3.x, 4.x, 5.x)
- [ ] UI for creating keyspaces, tables, and indexes
- [ ] Direct CQL query editor/console
- [ ] Multi-node cluster topology awareness

## Credits

This project makes use of the following open-source libraries:

- [thibaultcha/lua-cassandra](https://github.com/thibaultcha/lua-cassandra)
- [bungle/lua-resty-template](https://github.com/bungle/lua-resty-template)
- [bungle/lua-resty-reqargs](https://github.com/bungle/lua-resty-reqargs)

## Disclaimer

This project is an independent, open-source tool created to help administer Apache Cassandra databases. **This software is not affiliated with, endorsed by, or sponsored by the Apache Software Foundation or the Apache Cassandra project.**

"Apache Cassandra" and "Cassandra" are trademarks of the Apache Software Foundation. This project uses these terms solely to indicate compatibility and functionality with the Apache Cassandra database system.

The Apache Software Foundation has not reviewed, approved, or been involved in the development of this tool. For official Apache Cassandra resources, documentation, and support, please visit the [official Apache Cassandra website](https://cassandra.apache.org/).

This project is provided "as is" without warranty of any kind. Use at your own risk.

## License

`cassandra-admin` is licensed under the [MIT License](LICENSE).

```text
MIT License

Copyright (c) 2025 International Business Machines

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
