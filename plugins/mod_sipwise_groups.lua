-- Load PBX groups from DDBB
-- Copyright (C) 2013 Sipwise GmbH <development@sipwise.com>
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

local lookup_query = [[
SELECT g.username, s.username, d.domain
FROM provisioning.voip_subscribers AS s
LEFT JOIN provisioning.voip_domains AS d ON s.domain_id = d.id
LEFT JOIN provisioning.voip_pbx_groups AS ug ON s.id = ug.subscriber_id
LEFT JOIN provisioning.voip_subscribers AS g ON g.id = ug.group_id
LEFT JOIN provisioning.voip_usr_preferences as p ON p.subscriber_id = s.id
WHERE s.account_id = ? AND s.is_pbx_group = 0 AND s.is_pbx_pilot = 0
AND ug.group_id IS NOT NULL
AND (p.attribute_id = ? AND p.value = '1')
ORDER BY s.username;
]];

local lookup_with_dn_query = [[
SELECT s.username, d.domain, p.value
FROM provisioning.voip_subscribers AS s
LEFT JOIN provisioning.voip_domains AS d ON s.domain_id = d.id
LEFT JOIN provisioning.voip_usr_preferences as p ON p.subscriber_id = s.id
LEFT JOIN provisioning.voip_pbx_groups AS ug ON s.id = ug.subscriber_id
WHERE s.account_id = ? AND s.is_pbx_group = 0 AND s.is_pbx_pilot = 0
AND ug.group_id IS NOT NULL
AND p.attribute_id = ?
ORDER BY s.username;
]];

local lookup_user_group_query = [[
SELECT g.username
FROM provisioning.voip_subscribers AS s
LEFT JOIN provisioning.voip_domains AS d ON s.domain_id = d.id
LEFT JOIN provisioning.voip_pbx_groups AS ug ON s.id = ug.subscriber_id
LEFT JOIN provisioning.voip_subscribers AS g ON g.id = ug.group_id
WHERE s.account_id = ? AND
s.username = ? AND d.domain = ? AND
s.is_pbx_group = 0 AND s.is_pbx_pilot = 0 AND ug.group_id IS NOT NULL;
]];

local lookup_users_by_groups_query = [[
SELECT g.username, s.username, d.domain
FROM provisioning.voip_subscribers AS s
LEFT JOIN provisioning.voip_domains AS d ON s.domain_id = d.id
LEFT JOIN provisioning.voip_pbx_groups AS ug ON s.id = ug.subscriber_id
LEFT JOIN provisioning.voip_subscribers AS g ON g.id = ug.group_id
LEFT JOIN provisioning.voip_usr_preferences as p ON p.subscriber_id = s.id
WHERE s.account_id = ? AND s.is_pbx_group = 0 AND s.is_pbx_pilot = 0
AND ug.group_id IS NOT NULL
AND (p.attribute_id = ? AND p.value = '1') AND g.username in (?)
ORDER BY s.username;
]];

local lookup_all_query = [[
SELECT s.username, d.domain
FROM provisioning.voip_subscribers AS s
LEFT JOIN provisioning.voip_domains AS d ON s.domain_id = d.id
LEFT JOIN provisioning.voip_usr_preferences as p ON p.subscriber_id = s.id
WHERE s.account_id = ? AND s.is_pbx_group = 0 AND s.is_pbx_pilot = 0
AND (p.attribute_id = ? AND p.value = '1')
ORDER BY s.username;
]];

local account_id_query = [[
SELECT account_id
FROM provisioning.voip_subscribers
WHERE username = ? AND
domain_id = ( SELECT id FROM provisioning.voip_domains where domain = ?);
]]

local lookupt_preference_id_query = [[
SELECT id
FROM provisioning.voip_preferences
WHERE attribute = ?;
]]

-- from table to string
-- t = {'a','b'}
-- implode(",",t,"'")
-- "'a','b'"
-- implode("#",t)
-- "a#b"
local function implode(delimiter, list, quoter)
    local len = #list
    if not delimiter then
        error("delimiter is nil")
    end
    if len == 0 then
        return nil
    end
    if not quoter then
        quoter = ""
    end
    local string = quoter .. list[1] .. quoter
    for i = 2, len do
        string = string .. delimiter .. quoter .. list[i] .. quoter
    end
    return string
end

local mod_sql = module:require("sql");
local params = module:get_option("auth_sql", module:get_option("auth_sql"));
local engine = mod_sql:create_engine(params);
engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");

-- Reconnect to DB if necessary
local function reconect_check()
	if not engine.conn:ping() then
		engine.conn = nil;
		module:log("debug", "DDBB reconecting");
		engine:connect();
	end
end

-- returns the attribute_id of 'shared_buddylist_visiblility' preference
local function lookup_buddy_id()
	local res, row;
	reconect_check();
	res = engine:select(lookupt_preference_id_query,
		'shared_buddylist_visibility');
	for row in res do
		return row[1]
	end
	module:log("error", "no 'shared_buddylist_visiblility' preference found!");
end
local buddylist_preference_id = lookup_buddy_id();

-- returns the attribute_id of 'display_name' preference
local function lookup_displayname_id()
	local res, row;
	reconect_check();
	res = engine:select(lookupt_preference_id_query,
		'display_name');
	for row in res do
		return row[1]
	end
	module:log("error", "no 'display_name' preference found!");
end
local displayname_preference_id = lookup_displayname_id();


-- "roster-load" callback
function inject_roster_contacts(username, host, roster)
	module:log("debug", "Injecting group members to roster");
	local bare_jid = username.."@"..host;
	local account_id, groups, display_names;

	-- returns the account_id of username@host subscriber
	local function lookup_account_id()
		local row;
		--module:log("debug", "lookup user '%s@%s'", username, host);
		reconect_check();
		for row in engine:select(account_id_query, username, host) do
			module:log("debug", "user '%s@%s' belongs to %d",
				username, host, row[1]);
			return row[1];
		end
		module:log("debug", "no account_id found!");
	end

	-- returns a table with the pbx groups the subscriber
	-- belongs to
	local function lookup_user_groups()
		local res, row;
		local result = {};
		reconect_check();
		res = engine:select(lookup_user_group_query, account_id,
			username, host, buddylist_preference_id);
		for row in res do
			module:log("debug", "found group:'%s'",	row[1]);
			table.insert(result, row[1]);
		end
		return result;
	end

	-- returns a table with the subscribers display_name
	-- key is username@domain
	local function lookup_users_dn()
		local res, row;
		local result = {};
		reconect_check();
		res = engine:select(lookup_with_dn_query, account_id,
			displayname_preference_id);
		for row in res do
			result[row[1].."@"..row[2]] = row[3];
		end
		return result;
	end

	-- returns a dictionary with all the subscribers of the account
	-- key is the name of the pbx group
	-- if all is true a 'all' group will be added with all subscribers
	-- if all_groups is false only the groups that bare_jid belongs will be added
	local function lookup_groups(all, all_groups)
		local row, res;
		local user_groups = {};
		local result = {};
		if account_id then
			reconect_check();

			if all_groups then
				module:log("debug", "lookup_groups for account_id:%s",
					account_id);
				res = engine:select(lookup_query, account_id, buddylist_preference_id);
			else
				module:log("debug", "lookup_groups for account_id:%s jid:%s@%s",
					account_id, username, host);
				user_groups = lookup_user_groups();
				res =  engine:select(lookup_users_by_groups_query,
					account_id, buddylist_preference_id, implode(",",user_groups));
			end
			for row in res do
				--module:log("debug", "found group:'%s' user:'%s' domain:'%s'",
				--	row[1], row[2], row[3]);
				if not result[row[1]] then
					result[row[1]] = {};
				end
				table.insert(result[row[1]], row[2].."@"..row[3]);
			end
			if all then
				--module:log("debug", "lookup_all for account_id:%s", account_id);
				result['all'] = {};
				for row in engine:select(lookup_all_query,
					account_id, buddylist_preference_id) do
					table.insert(result['all'], row[1].."@"..row[2]);
				end
			end
		end
		return result;
	end

	account_id = lookup_account_id();
	-- TODO: set this parameters from usr_preferences
	groups = lookup_groups(true, true);
	display_names = lookup_users_dn();

	local function import_jids_to_roster(group_name)
		local _, jid;
		for _,jid in pairs(groups[group_name]) do
			-- Add them to roster
			module:log("debug", "processing jid %s in group %s",
				tostring(jid), tostring(group_name));
			if jid ~= bare_jid then
				if not roster[jid] then roster[jid] = {}; end
				roster[jid].subscription = "both";
				-- If we have the subscriber display name
				if display_names[jid] then
					roster[jid].name = display_names[jid];
				end
				if not roster[jid].groups then
					roster[jid].groups = { [group_name] = true };
				end
				roster[jid].groups[group_name] = true;
				roster[jid].persist = false;
			end
		end
	end

	for group_name in pairs(groups) do
		module:log("debug", "Importing group %s", group_name);
		import_jids_to_roster(group_name);
	end

	if roster[false] then
		roster[false].version = true;
	end
end

function module.load()
	module:hook("roster-load", inject_roster_contacts);
	module:log("info", "Groups loaded successfully");
end
