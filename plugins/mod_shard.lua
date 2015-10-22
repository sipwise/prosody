-- Prosody IM
-- Copyright (C) 2015 Robert Norris <robn@robn.io>
-- Copyright (C) 2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
module:depends("sipwise_redis_sessions");
local redis_sessions = module:shared("/*/sipwise_redis_sessions/redis_sessions");
local jid_split = require "util.jid".split;
local fire_event = prosody.events.fire_event;
local st = require "util.stanza";
local uts = require "util.table".string;
local shard_name = module:get_option("shard_name", nil);
if not shard_name then
    error("shard_name not configured", 0);
end


module:log("info", "%s added to shard %s", module.host, shard_name);


local function handle_room_event(event)
    local to = event.stanza.attr.to;

    module:log("debug", "looking up target room shard for %s", to);
    local rhost = redis_sessions.get_room_host(to);

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

    if not node or not host then
        return nil
    end
    if host ~= module.host then
        return nil
    end
    if uts.starts(host, 'conference.') then
        module:log("debug", "MUC %s detected", host);
        return handle_room_event(event);
    end

    if resource and prosody.full_sessions[to] then
        module:log("debug", "%s has a session here, nothing to do", to);
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
