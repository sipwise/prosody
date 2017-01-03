-- luacheck: ignore 212/self
local uuid = require "util.uuid".generate;
local archive_store = { _provided_by = "mam"; name = "fallback"; };

local serialize = require "util.serialization".serialize;
local deserialize = require "util.serialization".deserialize;
local st = require "util.stanza";

local mod_sql = module:require("sql");
local params = module:get_option("sql", {});
local engine = mod_sql:create_engine(params);
engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");
local log = require "util.logger".init("sipwise_archive");
local ut_tostring = require "util.table".table.tostring;

local store_query=[[
INSERT INTO `sipwise_mam` (`username`, `key`, `stanza`, `epoch`, `with`)
VALUES (?,UuidToBin(?),?,?,?);
]]

local delete_query=[[
DELETE FROM `sipwise_mam`
WHERE `username` = ?;
]]

local delete_query_extra=[[
DELETE FROM `sipwise_mam`
WHERE `username` = ? AND `epoch` <= ?;
]]

local select_key_query=[[
SELECT id FROM `sipwise_mam`
WHERE `key` = UuidToBin(?)
]]

local select_query_base=[[
SELECT UuidFromBin(`key`),`stanza`,`epoch`,`with` FROM `sipwise_mam`
WHERE `username` = ?
]]

-- Reconnect to DB if necessary
local function reconect_check()
	if not engine.conn:ping() then
		engine.conn = nil;
		log("debug", "DDBB reconecting");
		engine:connect();
	end
end

local function load_db(query, _params)
	local res;
	reconect_check();
	log("debug", "query[%s]", query);
	log("debug", "_params[%s]", ut_tostring(_params));
	res = engine:select(query, unpack(_params));
	local out = {};
	for row in res do
		table.insert(out, {row[1], row[2], row[3], row[4]});
	end
	return out;
end

local function key_get_id(key)
	local res;
	reconect_check();
	res = engine:select(select_key_query, key);
	local out = {};
	for row in res do
		table.insert(out, row[1]);
	end
	return out[1];
end

local function key_in_db(key)
	local res = key_get_id(key);
	if res then
		return true;
	else
		return false;
	end
end

function archive_store:append(username, key, value, when, with)
	reconect_check();
	if not key or key_in_db(key) then
		key = uuid();
	end
	engine:insert(store_query, username, key, serialize(st.preserialize(value)),
		when, with);
	engine.conn:commit();
end

function archive_store:find(username, query)
	local qstart, qend, qwith = -math.huge, math.huge;
	local qlimit, qid;
	local db_query = select_query_base;
	local _params = { username, };
	local i, values = 0;

	if query then
		if query.reverse then
			if query.before then
				qid = key_get_id(query.before);
			end
		elseif query.after then
			qid = key_get_id(query.after);
		end
		qwith = query.with;
		qlimit = query.limit;
		qstart = query.start or qstart;
		qend = query["end"] or qend;
	end

	if qwith then
		db_query = db_query.." AND `with` = ?";
		table.insert(_params, qwith);
	end
	if qid then
		if query.reverse then
			db_query = db_query.." AND `id` < ?";
		else
			db_query = db_query.." AND `id` > ?";
		end
		table.insert(_params, qid);
	end
	db_query = db_query.." AND (`epoch` >= ? AND `epoch` <= ?)";
	table.insert(_params, qstart);
	table.insert(_params, qend);
	db_query = db_query.." ORDER BY `epoch`";
	if query.reverse then
		db_query = db_query.." DESC";
	end
	if qlimit then
		db_query = db_query.." LIMIT ?";
		table.insert(_params, qlimit);
	end
	db_query = db_query..";"
	values = load_db(db_query, _params);

	return function ()
		i = i + 1;
		if values[i] then
			return values[i][1], deserialize(values[i][2]), values[i][3], values[i][4];
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
