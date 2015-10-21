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

local shard_name = module:get_option("shard_name", nil);
if not shard_name then
    error("shard_name not configured", 0);
end


module:log("info", "%s added to shard %s", module.host, shard_name);


local function handle_event (event)
    local to = event.stanza.attr.to;
    local node, host = jid_split(to);

    if not node or not host then
        return nil
    end
    if host ~= module.host then
        return nil
    end

    module:log("debug", "looking up target shard for "..to);

    local rhosts = redis_sessions.get_hosts(to);
    for shard,_ in pairs(rhosts) do
        if shard and shard ~= shard_name then
            module:log("debug", "target shard for "..to.." is "..shard);
            fire_event("shard/send", { shard = shard, stanza = event.stanza });
        end
    end

    return true;
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
