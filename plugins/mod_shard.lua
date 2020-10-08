-- Prosody IM
-- Copyright (C) 2015 Robert Norris <robn@robn.io>
-- Copyright (C) 2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:depends("sipwise_redis_sessions");
module:depends("sipwise_redis_mucs");

local redis_sessions = module:shared("/*/sipwise_redis_sessions/redis_sessions");
local redis_mucs = module:shared("/*/sipwise_redis_mucs/redis_mucs");
local hosts = prosody.hosts;
local jid_split = require "util.jid".split;
local jid_bare = require "util.jid".bare;
local fire_event = prosody.events.fire_event;
local st = require "util.stanza";
local set = require "util.set";

local shard_name = module:get_option("shard_name", nil);
if not shard_name then
    error("shard_name not configured", 0);
end
local persistent_rooms = module:open_store("persistent", "map");
module:log("info", "%s added to shard %s", module.host, shard_name);

local function build_query_result(rooms, stanza)
    local xmlns = 'http://jabber.org/protocol/disco#items';
    local s = stanza:query(xmlns);
    for room in rooms do
        s:tag("item", {jid=room}):up();
    end
    return stanza;
end

local function get_local_rooms(host)
    local rooms = set.new();
    for room in hosts[host].modules.muc.live_rooms() do
        rooms:add(room.jid);
    end
    return rooms;
end

local function is_local_room(room_jid)
    local node, host, _ = jid_split(room_jid);
    if not node then return false; end

    if not hosts[host] or not hosts[host].modules.muc then
        return false;
    end
    for room in hosts[host].modules.muc.live_rooms() do
        if room.jid == room_jid then return true; end
    end
    return false;
end

local function is_persistent_room(jid)
    local room_jid = jid_bare(jid);
    local res = persistent_rooms:get(nil, room_jid);
    module:log("debug", "[%s] is_persistent:%s", room_jid, tostring(res));
    if res then return true else return false end;
end

local function check_redis_info(room_jid)
    local rhost = redis_mucs.get_room_host(room_jid);

    if not rhost then return; end
    if rhost ~= shard_name then
        module:log("info", "clean wrong shard info for room[%s]", room_jid);
        redis_mucs.clean_room_host(room_jid, rhost);
        redis_mucs.set_room_host(room_jid, shard_name);
    end
end

local function handle_room_event(event)
    local to = event.stanza.attr.to;
    local node, host, _ = jid_split(to);
    local rhost, room_jid;

    if node then
        room_jid = jid_bare(to);
        if is_local_room(room_jid) then
            module:log("debug", "room[%s] is hosted here. Nothing to do", room_jid);
            check_redis_info(room_jid);
            return nil;
        end
        module:log("debug", "looking up target room shard for %s", to);
        rhost = redis_mucs.get_room_host(to);
    else
        -- TODO: remove me this is just for check if there are missing rooms
        local rooms = set.union(get_local_rooms(host),
            redis_mucs.get_rooms(host));
        module:log("debug", "rooms: %s", tostring(rooms));
        local stanza = build_query_result(rooms, st.reply(event.stanza));
        module:log("debug", "reply[%s]", tostring(stanza));
        event.origin.send(stanza);
        return true;
    end

    if not rhost then
        assert(room_jid);
        if is_persistent_room(room_jid) then
            module:log("info",
                "restore missing info for persistent room[%s]", room_jid);
            redis_mucs.set_room_host(room_jid, shard_name);
        else
            module:log("debug", "room[%s] not found, nothing to do", room_jid);
        end
        return nil;
    end

    if rhost == shard_name then
        module:log("debug", "room[%s] is hosted here, nothing to do", room_jid);
        return nil
    end

    fire_event("shard/send", { shard = rhost, stanza = event.stanza });
    return true;
end

local function handle_event (event)
    local to = event.stanza.attr.to;
    local node, host, resource = jid_split(to);
    local stop_process_local;

    if not host then
        module:log("debug", "no host, nothing to do here");
        return nil
    end

    if hosts[host].modules.muc then
        module:log("debug", "to MUC %s detected", host);
        return handle_room_event(event);
    end

    if resource and prosody.full_sessions[to] then
        module:log("debug", "%s has a session here, nothing to do", to);
        return nil
    end

    if not node then
        module:log("debug", "no node, nothing to do here");
        return nil
    end

    module:log("debug", "looking up target shard for %s", to);

    local rhosts = redis_sessions.get_hosts(to);
    for shard,resources in pairs(rhosts) do
        if shard and shard ~= shard_name then
            for _,r in pairs(resources) do
                local stanza_c = st.clone(event.stanza);
                stanza_c.attr.to = node..'@'..host..'/'..r;
                module:log("debug", "target shard for %s is %s",
                    stanza_c.attr.to ,shard);
                fire_event("shard/send", { shard = shard, stanza = stanza_c });
                stop_process_local = true;
            end
        end
    end

    if prosody.bare_sessions[jid_bare(to)] then
        module:log("debug", "%s has a bare session here."..
            " stanza will be processed here too", to);
        return nil;
    end

    return stop_process_local;
end

local function handle_shard_error(event)
    local server_id = event.shard
    local stanza = event.stanza
    local jid = stanza.attr.to;
    local _, host, _ = jid_split(jid);

    if hosts[host].modules.muc then
        module:log("debug",
            "to MUC %s detected, clean conference %s", host, jid);
        redis_mucs.clean_room_host(jid, server_id)
    else
        redis_sessions.clean_host(jid, server_id)
    end
end

module:hook("iq/bare", handle_event, 1000);
module:hook("iq/full", handle_event, 1000);
module:hook("iq/host", handle_event, 1000);
module:hook("message/bare", handle_event, 1000);
module:hook("message/full", handle_event, 1000);
module:hook("message/host", handle_event, 1000);
module:hook("presence/bare", handle_event, 1000);
module:hook("presence/full", handle_event, 1000);
module:hook("presence/host", handle_event, 1000);
module:hook_global("shard/error", handle_shard_error);
module:log("debug", "hooked at %s", module:get_host());
