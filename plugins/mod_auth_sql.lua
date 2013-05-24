-- Simple SQL Authentication module for Prosody IM
-- Copyright (C) 2011 Tomasz Sterna <tomek@xiaoka.com>
-- Copyright (C) 2011 Waqas Hussain <waqas20@gmail.com>
--

local log = require "util.logger".init("auth_sql");
local new_sasl = require "util.sasl".new;
local DBI = require "DBI"

local connection;
local params = module:get_option("auth_sql", module:get_option("auth_sql"));

local resolve_relative_path = require "core.configmanager".resolve_relative_path;

local function test_connection()
	if not connection then return nil; end
	if connection:ping() then
		return true;
	else
		module:log("debug", "Database connection closed");
		connection = nil;
	end
end
local function connect()
	if not test_connection() then
		prosody.unlock_globals();
		local dbh, err = DBI.Connect(
			params.driver, params.database,
			params.username, params.password,
			params.host, params.port
		);
		prosody.lock_globals();
		if not dbh then
			module:log("debug", "Database connection failed: %s", tostring(err));
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
		params.database = resolve_relative_path(prosody.paths.data or ".", params.database or "prosody.sqlite");
	end
	
	assert(params.driver and params.database, "Both the SQL driver and the database need to be specified");
	
	assert(connect());
end

local function getsql(sql, ...)
	module:log("debug", "getsql: %s", sql);
	if params.driver == "PostgreSQL" then
		sql = sql:gsub("`", "\"");
	end
	if not test_connection() then connect(); end
	-- do prepared statement stuff
	local stmt, err = connection:prepare(sql);
	if not stmt and not test_connection() then error("connection failed"); end
	if not stmt then module:log("error", "QUERY FAILED: %s %s", err, debug.traceback()); return nil, err; end
	-- run query
	local ok, err = stmt:execute(...);
	if not ok and not test_connection() then error("connection failed"); end
	if not ok then return nil, err; end
	
	return stmt;
end

local function get_password(username)
	local numstmt, substmt, err;
	module:log("debug", "get_password: checking dbaliases for username=%s", username);
    numstmt, err = getsql("select s.username, s.domain, s.password from subscriber s, dbaliases a where a.alias_username = ? and s.username = a.username and s.domain = a.domain", username);
    if numstmt then
	    module:log("debug", "get_password: checking dbaliases stmt ok");
		for row in numstmt:rows(true) do
	        module:log("debug", "get_password: dbaliases mapped to %s@%s for alias %s", row.username, row.domain, row.password);
			return row.password;
		end
    end
	module:log("debug", "get_password: checking dbaliases stmt failed, checking subscriber");
    substmt, err = getsql("SELECT `password` FROM `subscriber` WHERE `username`=? AND `domain`=?", username, module.host);
    if substmt then
	    module:log("debug", "get_password: checking subscriber stmt ok");
	    for row in substmt:rows(true) do
	        module:log("debug", "get_password: found subscriber %s@%s", username, module.host);
			return row.password;
		end
	end
end


provider = {};

function provider.test_password(username, password)
	return password and get_password(username) == password;
end
function provider.get_password(username)
	return get_password(username);
end
function provider.set_password(username, password)
	return nil, "Setting password is not supported.";
end
function provider.user_exists(username)
	module:log("debug", ">>>>>>>>>> mod_auth_sql:user_exists username=%s", username);
	return get_password(username) and true;
end
function provider.create_user(username, password)
	return nil, "Account creation/modification not supported.";
end
function provider.get_sasl_handler()
	local profile = {
		plain = function(sasl, username, realm)
			local password = get_password(username);
			if not password then return "", nil; end
			return password, true;
		end
	};
	return new_sasl(module.host, profile);
end

function provider.users()
	local stmt, err = getsql("SELECT `username` FROM `subscriber` WHERE `domain`=?", module.host);
	if stmt then
		local next, state = stmt:rows(true)
		return function()
			for row in next, state do
				return row.username;
			end
		end
	end
	return stmt, err;
end


module:provides("auth", provider);
