--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local get_routes = require("apisix.router").http_routes
local utils = require("apisix.admin.utils")
local schema_plugin = require("apisix.admin.plugins").check_schema
local v3_adapter = require("apisix.admin.v3_adapter")
local type = type
local tostring = tostring
local ipairs = ipairs


local _M = {
}


local function check_conf(id, conf, need_id)
    if not conf then
        return nil, {error_msg = "missing configurations"}
    end

    id = id or conf.id
    if need_id and not id then
        return nil, {error_msg = "missing id"}
    end

    if not need_id and id then
        return nil, {error_msg = "wrong id, do not need it"}
    end

    if need_id and conf.id and tostring(conf.id) ~= tostring(id) then
        return nil, {error_msg = "wrong id"}
    end

    conf.id = id

    core.log.info("conf: ", core.json.delay_encode(conf))
    local ok, err = core.schema.check(core.schema.plugin_config, conf)
    if not ok then
        return nil, {error_msg = "invalid configuration: " .. err}
    end

    local ok, err = schema_plugin(conf.plugins)
    if not ok then
        return nil, {error_msg = err}
    end

    return true
end


function _M.put(id, conf)
    local ok, err = check_conf(id, conf, true)
    if not ok then
        return 400, err
    end

    local key = "/plugin_configs/" .. id

    local ok, err = utils.inject_conf_with_prev_conf("plugin_config", key, conf)
    if not ok then
        return 503, {error_msg = err}
    end

    local res, err = core.etcd.set(key, conf)
    if not res then
        core.log.error("failed to put plugin config[", key, "]: ", err)
        return 503, {error_msg = err}
    end

    return res.status, res.body
end


function _M.get(id)
    local key = "/plugin_configs"
    if id then
        key = key .. "/" .. id
    end
    local res, err = core.etcd.get(key, not id)
    if not res then
        core.log.error("failed to get plugin config[", key, "]: ", err)
        return 503, {error_msg = err}
    end

    utils.fix_count(res.body, id)
    v3_adapter.filter(res.body)
    return res.status, res.body
end


function _M.delete(id)
    if not id then
        return 400, {error_msg = "missing plugin config id"}
    end

    local routes, routes_ver = get_routes()
    if routes_ver and routes then
        for _, route in ipairs(routes) do
            if type(route) == "table" and route.value
               and route.value.plugin_config_id
               and tostring(route.value.plugin_config_id) == id then
                return 400, {error_msg = "can not delete this plugin config,"
                                         .. " route [" .. route.value.id
                                         .. "] is still using it now"}
            end
        end
    end

    local key = "/plugin_configs/" .. id
    local res, err = core.etcd.delete(key)
    if not res then
        core.log.error("failed to delete plugin config[", key, "]: ", err)
        return 503, {error_msg = err}
    end


    return res.status, res.body
end


function _M.patch(id, conf, sub_path)
    if not id then
        return 400, {error_msg = "missing plugin config id"}
    end

    if not conf then
        return 400, {error_msg = "missing new configuration"}
    end

    if not sub_path or sub_path == "" then
        if type(conf) ~= "table"  then
            return 400, {error_msg = "invalid configuration"}
        end
    end

    local key = "/plugin_configs/" .. id
    local res_old, err = core.etcd.get(key)
    if not res_old then
        core.log.error("failed to get plugin config [", key, "]: ", err)
        return 503, {error_msg = err}
    end

    if res_old.status ~= 200 then
        return res_old.status, res_old.body
    end
    core.log.info("key: ", key, " old value: ",
                  core.json.delay_encode(res_old, true))

    local node_value = res_old.body.node.value
    local modified_index = res_old.body.node.modifiedIndex

    if sub_path and sub_path ~= "" then
        local code, err, node_val = core.table.patch(node_value, sub_path, conf)
        node_value = node_val
        if code then
            return code, err
        end
        utils.inject_timestamp(node_value, nil, true)
    else
        node_value = core.table.merge(node_value, conf)
        utils.inject_timestamp(node_value, nil, conf)
    end

    core.log.info("new conf: ", core.json.delay_encode(node_value, true))

    local ok, err = check_conf(id, node_value, true)
    if not ok then
        return 400, err
    end

    local res, err = core.etcd.atomic_set(key, node_value, nil, modified_index)
    if not res then
        core.log.error("failed to set new plugin config[", key, "]: ", err)
        return 503, {error_msg = err}
    end

    return res.status, res.body
end


return _M
