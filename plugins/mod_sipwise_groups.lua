-- Load PBX groups from DDBB
-- Copyright (C) 2013 Sipwise GmbH <development@sipwise.com>

local lookup_query = [[
SELECT g.name, s.username, d.domain
FROM provisioning.voip_subscribers AS s
LEFT JOIN provisioning.voip_domains AS d ON s.domain_id = d.id
LEFT JOIN provisioning.voip_pbx_groups AS g ON s.pbx_group_id = g.id
WHERE account_id = ? AND s.is_pbx_group = 0 AND s.pbx_group_id IS NOT NULL
ORDER BY s.username;
]];

local lookup_all_query = [[
SELECT s.username, d.domain
FROM provisioning.voip_subscribers AS s
LEFT JOIN provisioning.voip_domains AS d ON s.domain_id = d.id
WHERE account_id = ? AND s.is_pbx_group = 0
ORDER BY s.username;
]];

local account_id_query = [[
SELECT account_id
FROM provisioning.voip_subscribers
WHERE username = ? AND
domain_id = ( SELECT id FROM provisioning.voip_domains where domain = ?);
]]

local mod_sql = module:require("sql");
local params = module:get_option("auth_sql", module:get_option("auth_sql"));

local engine = mod_sql:create_engine(params);
engine:execute("SET NAMES 'utf8' COLLATE 'utf8_bin';");

function inject_roster_contacts(username, host, roster)
	module:log("debug", "Injecting group members to roster");
	local bare_jid = username.."@"..host;
	local account_id = lookup_account_id(username, host);
	local groups = lookup_groups(account_id);

	local function import_jids_to_roster(group_name)
		for _,jid in pairs(groups[group_name]) do
			-- Add them to roster
			module:log("debug", "processing jid %s in group %s", tostring(jid), tostring(group_name));
			if jid ~= bare_jid then
				if not roster[jid] then roster[jid] = {}; end
				roster[jid].subscription = "both";
				if groups[group_name][jid] then
					roster[jid].name = groups[group_name][jid];
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

function lookup_account_id(username, host)
	module:log("debug", "lookup user '%s@%s'", username, host);
	-- Reconnect to DB if necessary
	if not engine.conn:ping() then
		engine.conn = nil;
		module:log("debug", "DDBB reconecting");
		engine:connect();
	end
	for row in engine:select(account_id_query, username, host) do
		module:log("debug", "user '%s@%s' belongs to %d", username, host, row[1]);
		return row[1]
	end
	module:log("debug", "no account_id found!");
end

function lookup_groups(account_id)
	local groups = {};
	-- Reconnect to DB if necessary
	if not engine.conn:ping() then
		engine.conn = nil;
		module:log("debug", "DDBB reconecting");
		engine:connect();
	end
	if account_id then
		module:log("debug", "lookup_groups for account_id:%s", account_id);
		for row in engine:select(lookup_query, account_id) do
			module:log("debug", "found group:'%s' user:'%s' domain:'%s'", row[1], row[2], row[3]);
			if not groups[row[1]] then
				groups[row[1]] = {};
			end
			table.insert(groups[row[1]], row[2].."@"..row[3]);
		end
		module:log("debug", "lookup_all for account_id:%s", account_id);
		groups['all'] = {};
		for row in engine:select(lookup_all_query, account_id) do
			table.insert(groups['all'], row[1].."@"..row[2]);
		end
	end
	return groups;
end

function module.load()	
	module:hook("roster-load", inject_roster_contacts);
	module:log("info", "Groups loaded successfully");
end
