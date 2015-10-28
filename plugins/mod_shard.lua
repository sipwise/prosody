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
local jid_split = require "util.jid".split;
local fire_event = prosody.events.fire_event;
local st = require "util.stanza";
local ut = require "util.table";
local shard_name = module:get_option("shard_name", nil);
if not shard_name then
    error("shard_name not configured", 0);
end

module:log("info", "%s added to shard %s", module.host, shard_name);

local function build_query_result(host, rooms, stanza)
    local xmlns = 'http://jabber.org/protocol/disco#items';
    local s = stanza:query(xmlns);
    for _,v in ipairs(rooms) do
        s:tag("item", {jid=v.."@"..host}):up();
    end
    return stanza;
end

local function handle_room_event(event)
    local to = event.stanza.attr.to;
    local node, host, _ = jid_split(to);
    local rhost;

    if node then
        module:log("debug", "looking up target room shard for %s", to);
        rhost = redis_mucs.get_room_host(to);
    else
        local l = redis_mucs.get_rooms(host);
        module:log("debug", "rooms: %s", ut.table.tostring(l));
        local stanza = build_query_result(host, l, st.reply(event.stanza));
        module:log("debug", "reply[%s]", tostring(stanza));
        event.origin.send(stanza);
        return true;
    end

    if not rhost then
        module:log("debug", "room not found. Nothing to do");
        return nil;
    end

    if rhost == shard_name then
        module:log("debug", "room is hosted here. Nothing to do");
        return nil
    end

    module:log("debug", "target shard for %s is %s", to, rhost);
    fire_event("shard/send", { shard = rhost, stanza = event.stanza });
    return true;
end

local function handle_event (event)
    local to = event.stanza.attr.to;
    local node, host, resource = jid_split(to);
    local stop_process_local;

    if not host then
        module:log("debug", "no host. Nothing to do here");
        return nil
    end

    local muc_hosts = redis_mucs.get_hosts();
    if muc_hosts:contains(host) then
        module:log("debug", "to MUC %s detected", host);
        return handle_room_event(event);
    end

    if resource and prosody.full_sessions[to] then
        module:log("debug", "%s has a session here, nothing to do", to);
        return nil
    end

    if not node then
        module:log("debug", "no node. Nothing to do here");
        return nil
    end

    if prosody.bare_sessions[to] then
        module:log("debug", "%s has a bare session here."..
            " stanza will be processed here too", to);
    else
        stop_process_local = true
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
            end
        end
    end

    return stop_process_local;
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
module:log("debug", "hooked at %s", module:get_host());
