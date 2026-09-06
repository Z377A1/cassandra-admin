local cjson = require("cjson")
local cassandra = require("cassandra")
local config = require("config")
local formatting = require("formatting")
local utils = require("utils")

local _M = {}

local system_keyspaces = {
    "system", "system_auth", "system_distributed", "system_schema", "system_traces",
    "system_views", "system_virtual_schema"
}

local function handle_error(err)
    local error_msg = string.format("Database error: %s", tostring(err))
    ngx.log(ngx.ERR, error_msg)
    
    ngx.header.content_type = "application/json"
    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.say(cjson.encode({
        error = true,
        message = error_msg
    }))
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    error(error_msg)
end

local function quote_ident(ident)
    if not ident then return '""' end
    return '"' .. tostring(ident):gsub('"', '""') .. '"'
end

local function connect()
    local peer, err = cassandra.new({
        host = config.connection.host,
        port = utils.coerce_positive_integer(config.connection.port, 9042),
        auth = cassandra.auth_providers[config.connection.auth_provider](config.connection.username, config.connection.password),
    })
    if not peer then
        handle_error(err or "Failed to initialize Cassandra client")
        return nil
    end
    peer:settimeout(config.connection.timeout)
    local ok, conn_err = peer:connect()
    if not ok then
        handle_error(conn_err)
        return nil
    end
    return peer
end

local function execute(query, params, options)
    local peer = connect()
    if not peer then
        handle_error("No database connection")
        return nil
    end
    local result, err = peer:execute(query, params, options)
    if not result then
        handle_error(err)
        return nil
    end
    return result
end

---@class CassandraKeyspaceRow
---@field keyspace_name string

---@class CassandraTableRow
---@field keyspace_name string
---@field table_name string
---@field comment? string

---@class CassandraViewRow
---@field keyspace_name string
---@field view_name string
---@field comment? string

---@class CassandraColumnMetadata
---@field column_name string
---@field type string
---@field kind string
---@field clustering_order string
---@field position number
---@field is_vector? boolean
---@field dimension? number
---@field is_masked? boolean
---@field mask_function? string
---@field mask_args? any
---@field has_index? boolean
---@field index_name? string
---@field is_sai? boolean
---@field is_vector_index? boolean
---@field similarity_function? string

---@class CassandraColumnMaskRow
---@field column_name string
---@field function_name string
---@field function_argument_values any[]

---@class CassandraIndexOptions
---@field target? string
---@field class_name? string
---@field similarity_function? string
---@field [string] any

---@class CassandraIndexRow
---@field index_name string
---@field kind string
---@field target? string
---@field is_sai? boolean
---@field similarity_function? string
---@field options? CassandraIndexOptions|table

function _M.getSchema()
    local peer = connect()
    if not peer then
        handle_error("No database connection")
        return nil
    end
    
    local keyspaces_query = "SELECT keyspace_name FROM system_schema.keyspaces;"
    local keyspaces = peer:execute(keyspaces_query)
    if not keyspaces then
        handle_error("Failed to fetch keyspaces")
        return nil
    end
    ---@cast keyspaces CassandraKeyspaceRow[]

    local tables_query = "SELECT * FROM system_schema.tables;"
    local tables = peer:execute(tables_query) or {}
    ---@cast tables CassandraTableRow[]

    local views_query = "SELECT * FROM system_schema.views;"
    local views = peer:execute(views_query) or {}
    ---@cast views CassandraViewRow[]

    local keyspace_entities = {}
    for _, tbl in ipairs(tables) do
        if not keyspace_entities[tbl.keyspace_name] then
            keyspace_entities[tbl.keyspace_name] = {}
        end
        table.insert(keyspace_entities[tbl.keyspace_name], { name = tbl.table_name, type = "table", comment = tbl.comment })
    end
    for _, view in ipairs(views) do
        if not keyspace_entities[view.keyspace_name] then
            keyspace_entities[view.keyspace_name] = {}
        end
        table.insert(keyspace_entities[view.keyspace_name], { name = view.view_name, type = "view", comment = view.comment })
    end

    -- Query virtual keyspaces and tables (Cassandra 4.x / 5.0)
    pcall(function()
        local vks_res = peer:execute("SELECT keyspace_name FROM system_virtual_schema.keyspaces;")
        if vks_res and #vks_res > 0 then
            ---@cast vks_res CassandraKeyspaceRow[]
            for _, vks in ipairs(vks_res) do
                table.insert(keyspaces, vks)
            end
        end
        local vtbl_res = peer:execute("SELECT * FROM system_virtual_schema.tables;")
        if vtbl_res and #vtbl_res > 0 then
            ---@cast vtbl_res CassandraTableRow[]
            for _, vtbl in ipairs(vtbl_res) do
                if not keyspace_entities[vtbl.keyspace_name] then
                    keyspace_entities[vtbl.keyspace_name] = {}
                end
                table.insert(keyspace_entities[vtbl.keyspace_name], {
                    name = vtbl.table_name,
                    type = "table",
                    is_virtual = true,
                    comment = vtbl.comment
                })
            end
        end
    end)

    local schema = {}
    local seen_keyspaces = {}
    for _, ks in ipairs(keyspaces) do
        if not seen_keyspaces[ks.keyspace_name] then
            seen_keyspaces[ks.keyspace_name] = true
            local entities = keyspace_entities[ks.keyspace_name] or {}
            table.sort(entities, function(a, b)
                return a.name < b.name
            end)
            local is_virtual = (ks.keyspace_name == "system_views" or ks.keyspace_name == "system_virtual_schema")
            local is_system = utils.table_contains(system_keyspaces, ks.keyspace_name)
            table.insert(schema, {
                keyspace = ks.keyspace_name,
                entities = entities,
                is_virtual = is_virtual,
                is_system = is_system
            })
        end
    end

    table.sort(schema, function(a, b)
        return a.keyspace < b.keyspace
    end)

    return schema
end

---@return CassandraColumnMetadata[]|nil, string|nil
local function getTableColumns(keyspace, table_name)
    local query = string.format([[
        SELECT column_name, type, kind, clustering_order, position
        FROM system_schema.columns 
        WHERE keyspace_name = '%s' AND table_name = '%s'
    ]], keyspace, table_name)

    local result = execute(query)
    if not result or #result == 0 then
        -- Fallback to virtual schema columns (Cassandra 4/5)
        local vquery = string.format([[
            SELECT column_name, type, kind, clustering_order, position
            FROM system_virtual_schema.columns 
            WHERE keyspace_name = '%s' AND table_name = '%s'
        ]], keyspace, table_name)
        result = execute(vquery)
    end
    if not result then
        return nil, "Failed to fetch columns"
    end

    -- Check for Dynamic Data Masking (DDM in Cassandra 5.0)
    local masks_by_col = {}
    pcall(function()
        local mask_query = string.format([[
            SELECT column_name, function_name, function_argument_values 
            FROM system_schema.column_masks 
            WHERE keyspace_name = '%s' AND table_name = '%s'
        ]], keyspace, table_name)
        local mask_res = execute(mask_query)
        if mask_res and #mask_res > 0 then
            ---@cast mask_res CassandraColumnMaskRow[]
            for _, m in ipairs(mask_res) do
                masks_by_col[m.column_name] = {
                    function_name = m.function_name,
                    argument_values = m.function_argument_values
                }
            end
        end
    end)

    ---@cast result CassandraColumnMetadata[]
    -- Detect vector columns and masks
    for _, col in ipairs(result) do
        if col.type then
            local dim = col.type:match("^vector<[^,]+,%s*(%d+)>")
            if dim then
                col.is_vector = true
                col.dimension = tonumber(dim)
            end
        end
        if masks_by_col[col.column_name] then
            col.is_masked = true
            col.mask_function = masks_by_col[col.column_name].function_name
            col.mask_args = masks_by_col[col.column_name].argument_values
        end
    end

    local columns = formatting.get_sorted_columns(result)
    return columns
end

---@return CassandraIndexRow[]
local function getTableIndexes(keyspace, table_name)
    local indexes = {}
    pcall(function()
        local query = string.format([[
            SELECT index_name, kind, options 
            FROM system_schema.indexes 
            WHERE keyspace_name = '%s' AND table_name = '%s'
        ]], keyspace, table_name)
        local result = execute(query)
        if result and #result > 0 then
            ---@cast result CassandraIndexRow[]
            for _, idx in ipairs(result) do
                local is_sai = false
                local target = nil
                local sim_func = nil
                if idx.options and type(idx.options) == "table" then
                    target = idx.options.target
                    if idx.options.class_name and idx.options.class_name:find("StorageAttachedIndex") then
                        is_sai = true
                    end
                    sim_func = idx.options.similarity_function
                end
                table.insert(indexes, {
                    index_name = idx.index_name,
                    kind = idx.kind,
                    target = target,
                    is_sai = is_sai,
                    similarity_function = sim_func,
                    options = idx.options
                })
            end
        end
    end)
    return indexes
end

function _M.getTableData(keyspace, table_name, page_size, paging_state_encoded)
    page_size = utils.coerce_positive_integer(page_size, config.default_page_size)
    
    local query_options = {
        page_size = page_size
    }
    
    if paging_state_encoded and paging_state_encoded ~= "" then
        local paging_state = ngx.decode_base64(paging_state_encoded)
        if paging_state then
            query_options.paging_state = paging_state
        end
    end
    
    local columns = getTableColumns(keyspace, table_name)
    local indexes = getTableIndexes(keyspace, table_name)

    -- Attach index info to columns
    local vector_columns = {}
    local has_vector = false
    local has_sai = false
    if columns then
        for _, col in ipairs(columns) do
            if indexes then
                for _, idx in ipairs(indexes) do
                    if idx.target == col.column_name then
                        col.has_index = true
                        col.index_name = idx.index_name
                        col.is_sai = idx.is_sai
                        col.similarity_function = idx.similarity_function
                        if col.is_vector then
                            col.is_vector_index = true
                        end
                    end
                end
            end
            if col.is_vector then
                has_vector = true
                table.insert(vector_columns, {
                    name = col.column_name,
                    column_name = col.column_name,
                    type = col.type,
                    dimension = col.dimension,
                    has_index = col.has_index or false,
                    is_sai = col.is_sai or false,
                    similarity_function = col.similarity_function or "cosine"
                })
            end
            if col.is_sai then
                has_sai = true
            end
        end
    end

    local query = string.format("SELECT * FROM %s.%s", quote_ident(keyspace), quote_ident(table_name))
    local result = execute(query, nil, query_options)
    
    local has_more_pages = false
    local next_paging_state = nil
    
    if result then
        if result.meta then
            has_more_pages = result.meta.has_more_pages or false
            if has_more_pages and result.meta.paging_state then
                next_paging_state = ngx.encode_base64(result.meta.paging_state)
            end
        end
    end
    
    local formatted_rows = formatting.format_rows(result)

    return {
        keyspace = keyspace,
        table = table_name,
        rows = formatted_rows,
        columns = columns,
        indexes = indexes,
        has_vector = has_vector,
        has_sai = has_sai,
        vector_columns = vector_columns,
        is_virtual = (keyspace == "system_views" or keyspace == "system_virtual_schema"),
        has_more_pages = has_more_pages,
        paging_state = next_paging_state,
        page_size = page_size
    }
end

function _M.vectorSearch(keyspace, table_name, vector_column, query_vector, limit, metric)
    limit = utils.coerce_positive_integer(limit, 10)
    if limit > 200 then limit = 200 end

    metric = metric or "cosine"
    local allowed_metrics = {
        cosine = "similarity_cosine",
        euclidean = "similarity_euclidean",
        dot_product = "similarity_dot_product"
    }
    local sim_fn = allowed_metrics[metric] or "similarity_cosine"

    -- Ensure query_vector is formatted as a CQL vector literal "[v1, v2, ...]"
    local vec_str
    if type(query_vector) == "table" then
        local parts = {}
        for _, v in ipairs(query_vector) do
            table.insert(parts, tostring(v))
        end
        vec_str = "[" .. table.concat(parts, ", ") .. "]"
    elseif type(query_vector) == "string" then
        vec_str = query_vector:gsub("^%s+", ""):gsub("%s+$", "")
        if not vec_str:find("^%[") then
            vec_str = "[" .. vec_str .. "]"
        end
    else
        return nil, "Invalid query vector"
    end

    local columns, col_err = getTableColumns(keyspace, table_name)
    if not columns then
        return nil, col_err or "Failed to fetch columns"
    end

    local col_names = {}
    for _, c in ipairs(columns) do
        table.insert(col_names, quote_ident(c.column_name))
    end
    local select_cols = table.concat(col_names, ", ")
    local query = string.format(
        "SELECT %s, %s(%s, %s) AS similarity_score FROM %s.%s ORDER BY %s ANN OF %s LIMIT %d",
        select_cols,
        sim_fn,
        quote_ident(vector_column),
        vec_str,
        quote_ident(keyspace),
        quote_ident(table_name),
        quote_ident(vector_column),
        vec_str,
        limit
    )

    local result = execute(query)
    if not result then
        return nil, "Vector search query failed"
    end

    local formatted_rows = formatting.format_rows(result)

    -- Return search columns including similarity_score
    local search_columns = {}
    for _, c in ipairs(columns) do
        table.insert(search_columns, c)
    end
    table.insert(search_columns, {
        column_name = "similarity_score",
        kind = "regular",
        type = "float",
        clustering_order = "none",
        position = -1,
        is_score = true
    })

    return {
        keyspace = keyspace,
        table = table_name,
        rows = formatted_rows,
        columns = search_columns,
        vector_column = vector_column,
        query_vector = vec_str,
        metric = metric,
        limit = limit,
        is_vector_search = true
    }
end

function _M.truncateTable(keyspace, table_name)
    if utils.table_contains(system_keyspaces, keyspace) then
        return nil, "System keyspaces are not user-modifiable."
    end

    local query = string.format("TRUNCATE %s.%s", quote_ident(keyspace), quote_ident(table_name))
    local result = execute(query)
    
    return true
end

function _M.dropEntity(entity_type, keyspace, table_name)
    if utils.table_contains(system_keyspaces, keyspace) then
        return nil, "System keyspaces are not user-modifiable."
    end

    local entity_types = {
        table = "TABLE",
        view = "MATERIALIZED VIEW"
    }
    
    local result = execute(string.format("DROP %s %s.%s", entity_types[entity_type], quote_ident(keyspace), quote_ident(table_name)))

    return true
end

function _M.dropKeyspace(keyspace)
    if utils.table_contains(system_keyspaces, keyspace) then
        return nil, "System keyspaces are not user-modifiable."
    end

    local result = execute(string.format("DROP KEYSPACE %s", quote_ident(keyspace)))

    return true
end

function _M.getTableDDL(keyspace, table_name)
    local table_info_query = string.format([[
        SELECT * FROM system_schema.tables 
        WHERE keyspace_name = '%s' AND table_name = '%s' LIMIT 1
    ]], keyspace, table_name)

    local table_info = execute(table_info_query)
    if not table_info or #table_info == 0 then
        return nil, "Table does not exist"
    end
    
    local tbl = table_info[1]
    
    local columns = getTableColumns(keyspace, table_name)
    if not columns then
        return nil, "Failed to fetch columns"
    end
    
    local cql = {}
    table.insert(cql, string.format("CREATE TABLE IF NOT EXISTS %s.%s (", quote_ident(keyspace), quote_ident(table_name)))
    
    local col_defs = {}
    local partition_keys = {}
    local clustering_keys = {}
    
    for _, col in ipairs(columns) do
        local col_def = string.format("    %s %s", quote_ident(col.column_name), col.type)
        if col.is_masked and col.mask_function then
            local args_str = ""
            if col.mask_args and #col.mask_args > 0 then
                args_str = table.concat(col.mask_args, ", ")
            end
            col_def = col_def .. string.format(" MASKED WITH %s(%s)", col.mask_function, args_str)
        end
        table.insert(col_defs, col_def)
        if col.kind == "partition_key" then
            table.insert(partition_keys, quote_ident(col.column_name))
        elseif col.kind == "clustering" then
            table.insert(clustering_keys, quote_ident(col.column_name))
        end
    end
    
    table.insert(cql, table.concat(col_defs, ",\n") .. ",")
    
    local pk = "    PRIMARY KEY ("
    if #partition_keys > 1 then
        pk = pk .. "(" .. table.concat(partition_keys, ", ") .. ")"
    else
        pk = pk .. partition_keys[1]
    end
    if #clustering_keys > 0 then
        pk = pk .. ", " .. table.concat(clustering_keys, ", ")
    end
    pk = pk .. ")"
    
    table.insert(cql, pk)
    table.insert(cql, ")")

    local column_type_map = {}
    if table_info and table_info.columns and type(table_info.columns) == "table" then
        for _, col_meta in ipairs(table_info.columns) do
            if col_meta and col_meta.name then
                column_type_map[col_meta.name] = col_meta.type
            end
        end
    end
    
    local with_clauses = {}
    
    if #clustering_keys > 0 then
        local orders = {}
        for _, col in ipairs(columns) do
            if col.kind == "clustering" then
                table.insert(orders, string.format("%s %s", quote_ident(col.column_name), col.clustering_order:upper()))
            end
        end
        if #orders > 0 then
            table.insert(cql, "WITH CLUSTERING ORDER BY (" .. table.concat(orders, ", ") .. ")")
        end
    end
    
    local skip_columns = {
        keyspace_name = true,
        table_name = true,
        id = true,
        flags = true
    }
    
    local properties = {}
    for column_name, value in pairs(tbl) do
        if not skip_columns[column_name] and value ~= nil and value ~= "" then
            local type_info = column_type_map[column_name]
            local formatted_value = formatting.format_cql_value(value, type_info)
            table.insert(properties, {
                name = column_name,
                value = formatted_value
            })
        end
    end
    
    table.sort(properties, function(a, b)
        return a.name < b.name
    end)
    
    for _, prop in ipairs(properties) do
        table.insert(with_clauses, "AND " .. prop.name .. " = " .. prop.value)
    end
    
    if #with_clauses > 0 then
        table.insert(cql, table.concat(with_clauses, "\n"))
    end
    
    table.insert(cql, ";")

    local indexes = getTableIndexes(keyspace, table_name)
    if indexes and #indexes > 0 then
        for _, idx in ipairs(indexes) do
            table.insert(cql, "")
            if idx.is_sai then
                local opt_parts = {}
                if idx.similarity_function then
                    table.insert(opt_parts, string.format("'similarity_function': '%s'", idx.similarity_function))
                end
                local opts_clause = ""
                if #opt_parts > 0 then
                    opts_clause = " WITH OPTIONS = {" .. table.concat(opt_parts, ", ") .. "}"
                end
                table.insert(cql, string.format(
                    "CREATE CUSTOM INDEX IF NOT EXISTS %s ON %s.%s (%s) USING 'StorageAttachedIndex'%s;",
                    quote_ident(idx.index_name), quote_ident(keyspace), quote_ident(table_name), quote_ident(idx.target or ""), opts_clause
                ))
            else
                table.insert(cql, string.format(
                    "CREATE INDEX IF NOT EXISTS %s ON %s.%s (%s);",
                    quote_ident(idx.index_name), quote_ident(keyspace), quote_ident(table_name), quote_ident(idx.target or "")
                ))
            end
        end
    end

    return table.concat(cql, "\n")
end

function _M.exportTableData(keyspace, table_name, format, limit, include_ddl)
    if utils.table_contains({"cql", "csv", "json"}, format) == false then
        return nil, "Unsupported export format: " .. tostring(format)
    end

    local limit = utils.coerce_positive_integer(limit, 100)
    local columns, col_err = getTableColumns(keyspace, table_name)
    if not columns then
        return nil, col_err or "Failed to fetch columns"
    end

    local result = execute(string.format("SELECT * FROM %s.%s LIMIT %d", quote_ident(keyspace), quote_ident(table_name), limit))
    if not result then
        return nil, "Failed to fetch table data"
    end

    local formatted_rows = formatting.format_rows(result)

    if format == "json" then
        return cjson.encode(formatted_rows)
    end
    
    local output = {}
    
    if format == "cql" then
        if include_ddl then
            local ddl, ddl_err = _M.getTableDDL(keyspace, table_name)
            if ddl then
                table.insert(output, ddl)
                table.insert(output, "")
            end
        end
        
        local column_type_map = {}
        if result and result.columns and type(result.columns) == "table" then
            for _, col_meta in ipairs(result.columns) do
                if col_meta and col_meta.name then
                    column_type_map[col_meta.name] = col_meta.type
                end
            end
        end
        
        for _, row in ipairs(result) do
            if type(row) == "table" then
                local insert_stmt = formatting.format_cql_insert(
                    keyspace, 
                    table_name, 
                    row, 
                    columns, 
                    column_type_map
                )
                if insert_stmt then
                    table.insert(output, insert_stmt)
                end
            end
        end
    end
    
    if format == "csv" then
        local headers = {}
        for _, col in ipairs(columns) do
            table.insert(headers, col.column_name)
        end
        table.insert(output, table.concat(headers, ","))
        
        for _, formatted_row in ipairs(formatted_rows) do
            local values = {}
            for _, col in ipairs(columns) do
                local val = formatted_row[col.column_name]
                if val == nil or val == "" then
                    table.insert(values, "")
                elseif type(val) == "string" then
                    table.insert(values, '"' .. val:gsub('"', '""') .. '"')
                else
                    table.insert(values, tostring(val))
                end
            end
            table.insert(output, table.concat(values, ","))
        end
    end
    return table.concat(output, "\n")
end


return _M