-- Load vhosts from DB on startup of Prosody XMPP server.
-- Copyright (C) 2013-2015 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

module:set_global();

local DBI = require "DBI"
local hostmanager = require "core.hostmanager";
local configmanager = require "core.configmanager";
local ut = require "util.table";

local connection;
local params = module:get_option("auth_sql", module:get_option("auth_sql"));
local prosody = _G.prosody;

local function test_connection()
	module:log("debug", "test_connection");
	if not connection then return nil; end
	if connection:ping() then
		module:log("debug", "test_connection ok");
		return true;
	else
		module:log("debug", "Database connection closed");
		connection = nil;
	end
end
local function connect()
	module:log("debug", "connect");
	if not test_connection() then
		prosody.unlock_globals();
		local dbh, err = DBI.Connect(
			params.driver, params.database,
			params.username, params.password,
			params.host, params.port
		);
		prosody.lock_globals();
		if not dbh then
			module:log("debug",
				"Database connection failed: %s", tostring(err));
			return nil, err;
		end
		module:log("debug", "Successfully connected to database");
		dbh:autocommit(true); -- don't run in transaction
		connection = dbh;
		return connection;
	end
end

do -- process options to get a db connection
	params = params or { driver = "SQLite3" };

	if params.driver == "SQLite3" then
		params.database = configmanager.resolve_relative_path(
			prosody.paths.data or ".",
			params.database or "prosody.sqlite");
	end

	assert(params.driver and params.database,
		"Both the SQL driver and the database need to be specified");
	assert(connect());
end

local function getsql(sql, ...)
	if params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	if not test_connection() then connect(); end
	-- do prepared statement stuff
	local stmt, err = connection:prepare(sql);
	if not stmt and not test_connection() then error("connection failed"); end
	if not stmt then
		module:log("error", "QUERY FAILED: %s %s", err, debug.traceback());
		return nil, err;
	end
	-- run query
	local ok
	ok, err = stmt:execute(...);
	if not ok and not test_connection() then error("connection failed"); end
	if not ok then return nil, err; end

	return stmt;
end

local function load_vhosts_from_db()
	local stmt, _ = getsql("SELECT `domain` FROM `domain`");
	local host_config = { enable = true };
	if stmt then
		for row in stmt:rows(true) do
			module:log("debug", "load_vhosts_from_db: activate host %s",
				row.domain);
			hostmanager.activate(row.domain, host_config);
			local host_modules = configmanager.get(row.domain, "modules_enabled");
			module:log("debug", "modules_enabled[%s]: %s", row.domain,
				ut.table.tostring(host_modules));

			module:log("debug",
				"load_vhosts_from_db: activate implicit search.%s",
				row.domain);
			configmanager.set("search."..row.domain, "component_module",
				"sipwise_vjud");
			local search_config = configmanager.getconfig()["search."..row.domain];
			hostmanager.activate("search."..row.domain, search_config);


			configmanager.set("conference."..row.domain, "component_module",
				"muc");
			local conference_modules = {};
			if ut.table.contains(host_modules, "shard") then
				ut.table.add(conference_modules, "sipwise_redis_mucs");
				ut.table.add(conference_modules, "shard");
			end
			if ut.table.contains(host_modules, "sipwise_pushd") then
				ut.table.add(conference_modules, "sipwise_pushd");
			end
			module:log("debug", "conference_modules[%s]: %s",
				"conference."..row.domain, ut.table.tostring(host_modules));
			configmanager.set("conference."..row.domain, "modules_enabled",
				conference_modules);
			local conference_config = configmanager.getconfig()["conference."..row.domain];
			conference_config['restrict_room_creation'] = 'local';
			hostmanager.activate("conference."..row.domain, conference_config);
			module:log("debug", "modules_enabled[%s]: %s", "conference."..row.domain,
				ut.table.tostring(conference_config['modules_enabled']));
		end
	end
end

module:hook("server-started", load_vhosts_from_db);
