-- luacheck: ignore 212/self

local archive_store = { _provided_by = "mam"; name = "fallback"; };

local serialize = require "util.serialization".serialize;
local deserialize = require "util.serialization".deserialize;
local st = require "util.stanza";

local mod_sql = module:require("sql");
local params = module:get_option("sql", {});
local engine = mod_sql:create_engine(params);
engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");

local store_query=[[
INSERT INTO prosody.sipwise_mam (username, stanza, when, with)
VALUES (?,?,?);
]]

local delete_query=[[
DELETE FROM prosody.sipwise_mam
WHERE username = ?;
]]

local delete_query_extra=[[
DELETE FROM prosody.sipwise_mam
WHERE username = ? AND when <= ?;
]]

-- Reconnect to DB if necessary
local function reconect_check()
	if not engine.conn:ping() then
		engine.conn = nil;
		module:log("debug", "DDBB reconecting");
		engine:connect();
	end
end

function archive_store:append(username, _, value, when, with)
	reconect_check();
	engine:insert(store_query, username, st.preserialize(value),
		when, with);
	engine.conn:commit();
end

function archive_store:find(username, query)
	local archive = store[username] or {};
	local start, stop, step = 1, archive[0] or #archive, 1;
	local qstart, qend, qwith = -math.huge, math.huge;
	local limit;

	if query then
		if query.reverse then
			start, stop, step = stop, start, -1;
			if query.before and archive[query.before] then
				start = archive[query.before] - 1;
			end
		elseif query.after and archive[query.after] then
			start = archive[query.after] + 1;
		end
		qwith = query.with;
		limit = query.limit;
		qstart = query.start or qstart;
		qend = query["end"] or qend;
	end

	return function ()
		if limit and limit <= 0 then return end
		for i = start, stop, step do
			local item = archive[i];
			if (not qwith or qwith == item.with) and item.when >= qstart and item.when <= qend then
				if limit then limit = limit - 1; end
				start = i + step; -- Start on next item
				return item.key, item.value, item.when, item.with;
			end
		end
	end
end

function archive_store:delete(username, query)
	if not query or next(query) == nil then
		-- no specifics, delete everything
		reconect_check();
		engine:delete(delete_query, username);
		engine.conn:commit();
		return true;
	end

	local qend = query["end"] or math.huge;

	reconect_check();
	engine:delete(delete_query_extra, username, qend);
	engine.conn:commit();
	return true;
end

return archive_store;
