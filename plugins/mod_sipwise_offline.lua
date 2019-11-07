-- store offline stanzas to DB
-- Copyright (C) 2016 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--
local sql = require "util.sql";
local default_params = { driver = "MySQL" };
local engine;

local sipwise_offline = module:shared("sipwise_offline");

local serialize = require "util.serialization".serialize;
local deserialize = require "util.serialization".deserialize;
local st = require "util.stanza";
local datetime = require "util.datetime";
local ipairs = ipairs;
local jid_split = require "util.jid".split;

local count_query=[[
SELECT id
FROM sipwise_offline
WHERE domain = ? AND username = ?;
]]
local load_query =[[
SELECT stanza
FROM prosody.sipwise_offline
WHERE domain = ? AND username = ?;
]]
local store_query=[[
INSERT INTO prosody.sipwise_offline (domain, username, stanza)
VALUES (?,?,?);
]]
local delete_query=[[
DELETE FROM prosody.sipwise_offline
WHERE domain = ? AND username = ?;
]]

-- Reconnect to DB if necessary
local function reconect_check()
	if not engine.conn:ping() then
		engine.conn = nil;
		engine:connect();
	end
end

function sipwise_offline.get_num(node, host)
	reconect_check();
	local res = 0;
	for _ in engine:select(count_query, host, node) do
		res = res + 1;
	end
	return res;
end

local function load_db(node, host)
	local res;
	reconect_check();
	res = engine:select(load_query, host, node);
	local out = {};
	for row in res do
		table.insert(out, row[1]);
	end
	return out;
end

local function store_db(node, host, stanza)
	reconect_check();
	local res = engine:insert(store_query, host, node, serialize(stanza));
	engine.conn:commit();
	return res;
end

local function delete_db(node, host)
	reconect_check();
	engine:delete(delete_query, host, node);
	engine.conn:commit();
end

--- http://xmpp.org/extensions/xep-0160.html#types
local function should_store(stanza)
	local body = stanza:get_child("body");
	local stanza_type = stanza.attr.type or "normal";
	if (stanza_type == 'normal') then
		return true;
	elseif (stanza_type == 'chat' and body) then
		return true;
	end
	return false;
end

-- save stanza
local function handle_offline(event)
	local origin, stanza = event.origin, event.stanza;
	local to = stanza.attr.to;
	local node, host;
	local stanza_info = stanza:top_tag();
	if to then
		node, host = jid_split(to)
	else
		node, host = origin.username, origin.host;
	end

	if should_store(stanza) then
		stanza.attr.stamp = datetime.datetime();
		stanza.attr.stamp_legacy = datetime.legacy();
		local res = store_db(node, host, st.preserialize(stanza));
		if not res or res.__affected ~= 1 then
			module:log("error", "store_db failed for %s", stanza_info);
		else
			module:log("debug", "stored: %s", stanza_info);
		end
		stanza.attr.stamp, stanza.attr.stamp_legacy = nil, nil;
	else
		module:log("debug", "stanza[%s] not for offline, not stored",
			stanza_info);
	end
	-- we should be the last
	return true;
end

-- load stanzas and send
local function broadcast_offline(event)
	local origin = event.origin;
	local node, host = origin.username, origin.host;

	local data = load_db(node, host);
	for _, stanza in ipairs(data) do
		stanza = st.deserialize(deserialize(stanza));
		stanza:tag("delay", {
			xmlns = "urn:xmpp:delay",
			from = host,
			stamp = stanza.attr.stamp
		}):up(); -- XEP-0203
		stanza:tag("x", {
			xmlns = "jabber:x:delay",
			from = host,
			stamp = stanza.attr.stamp_legacy
		}):up(); -- XEP-0091 (deprecated)
		stanza.attr.stamp, stanza.attr.stamp_legacy = nil, nil;
		module:log("debug", "send: %s", stanza:top_tag());
		origin.send(stanza);
	end
	if #data > 0 then
		delete_db(node, host);
		module:log("debug", "delete all stanzas for %s@%s", node, host);
	end
	-- we should be the last
	return true;
end

local function normalize_params(params)
	assert(params.driver and params.database,
		"Configuration error: Both the SQL driver and the database need to be specified");
	return params;
end

function module.load()
	if prosody.prosodyctl then return; end
	local engines = module:shared("/*/sql/connections");
	local params = normalize_params(module:get_option("sql", default_params));
	engine = engines[sql.db2uri(params)];
	if not engine then
		module:log("debug", "Creating new engine");
		engine = sql:create_engine(params);
		engines[sql.db2uri(params)] = engine;
	end
	engine:connect();
	module:hook("message/offline/handle", handle_offline, 1);
	module:hook("message/offline/broadcast", broadcast_offline, 1);
end
