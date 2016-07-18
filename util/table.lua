--
-- Copyright 2013 SipWise Team <development@sipwise.com>
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This package is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program. If not, see <http://www.gnu.org/licenses/>.
-- .
-- On Debian systems, the complete text of the GNU General
-- Public License version 3 can be found in "/usr/share/common-licenses/GPL-3".
--
-- Lua utils

local type = type;
local string = string;
local t_insert, t_concat = table.insert, table.concat;
local table = table;

-- copy a table
function table.deepcopy(object)
    local lookup_table = {}
    local function _copy(obj)
        if type(obj) ~= "table" then
            return object
        elseif lookup_table[obj] then
            return lookup_table[obj]
        end
        local new_table = {}
        lookup_table[object] = new_table
        for index, value in pairs(obj) do
            new_table[_copy(index)] = _copy(value)
        end
        return setmetatable(new_table, getmetatable(obj))
    end
    return _copy(object)
end

function table.contains(tbl, element)
    if tbl then
      for _, value in pairs(tbl) do
        if value == element then
          return true
        end
      end --for
    end --if
    return false
end

-- add if element is not in table
function table.add(t, element)
  if not table.contains(t, element) then
    t_insert(t, element)
  end
end

function table.val_to_str ( v )
  if "string" == type( v ) then
    v = string.gsub( v, "\n", "\\n" )
    if string.match( string.gsub(v,"[^'\"]",""), '^"+$' ) then
      return "'" .. v .. "'"
    end
    return '"' .. string.gsub(v,'"', '\\"' ) .. '"'
  else
    return "table" == type( v ) and table.tostring( v ) or
      tostring( v )
  end
end

function table.key_to_str ( k )
  if "string" == type( k ) and string.match( k, "^[_%a][_%a%d]*$" ) then
    return k
  else
    return "[" .. table.val_to_str( k ) .. "]"
  end
end

function table.tostring( tbl )
  local result, done = {}, {}
  for k, v in ipairs( tbl ) do
    t_insert( result, table.val_to_str( v ) )
    done[ k ] = true
  end
  for k, v in pairs( tbl ) do
    if not done[ k ] then
      t_insert( result,
        table.key_to_str( k ) .. "=" .. table.val_to_str( v ) )
    end
  end
  return "{" .. t_concat( result, "," ) .. "}"
end

-- from table to string
-- t = {'a','b'}
-- implode(",",t,"'")
-- "'a','b'"
-- implode("#",t)
-- "a#b"
function table.implode(delimiter, list, quoter)
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
    local str = quoter .. list[1] .. quoter
    for i = 2, len do
        str = str .. delimiter .. quoter .. list[i] .. quoter
    end
    return string
end

function table.keys(tbl)
  local keys = {}
  local n = 0

  for k,_ in pairs(tbl) do
    n = n+1
    keys[n] = k
  end
  return keys
end

-- from string to table
function string.explode(delimiter, text)
    local list = {}
    local pos = 1

    if not delimiter then
        error("delimiter is nil")
    end
    if not text then
        error("text is nil")
    end
    if string.find("", delimiter, 1) then
        -- We'll look at error handling later!
        error("delimiter matches empty string!")
    end
    while 1 do
        local first, last = string.find(text, delimiter, pos)
        -- print (first, last)
        if first then
            t_insert(list, string.sub(text, pos, first-1))
            pos = last+1
        else
            t_insert(list, string.sub(text, pos))
            break
        end
    end
    return list
end

function string.starts(String,Start)
   return string.sub(String,1,string.len(Start))==Start
end

function string.ends(String,End)
   return End=='' or string.sub(String,-string.len(End))==End
end

return {table=table, string=string}
