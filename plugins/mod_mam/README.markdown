---
labels:
- 'Stage-Beta'
summary: 'XEP-0313: Message Archive Management'
...

Introduction
============

Implementation of [XEP-0313: Message Archive Management].

Details
=======

This module will archive all messages that match the simple rules setup
by the user, and allow the user to access this archive.

Usage
=====

First copy the module to the prosody plugins directory.

Then add "mam" to your modules\_enabled list:

``` {.lua}
modules_enabled = {
    -- ...
    "mam",
    -- ...
}
```

Configuration
=============

Option summary
--------------

  option                         type                    default
  ------------------------------ ----------------------- -----------
  max\_archive\_query\_results   number                  `50`
  default\_archive\_policy       boolean or `"roster"`   `true`
  archive\_expires\_after        string                  `"1w"`
  archive\_cleanup\_interval     number                  `4*60*60`


Storage backend
---------------

mod\_mam uses the store "archive2"[^1]. See [Prosodys data storage
documentation][doc:storage] for information on how to configure storage.

For example, to use mod\_storage\_sql (requires Prosody 0.10 or later):

``` {.lua}
storage = {
  archive2 = "sql";
}
```

If no archive-capable storage backend can be opened then an in-memory
one will be used as fallback.

Query size limits
-----------------

    max_archive_query_results = 20;

This is the largest number of messages that are allowed to be retrieved
in one request *page*. A query that does not fit in one page will
include a reference to the next page, letting clients page through the
result set. Setting large number is not recomended, as Prosody will be
blocked while processing the request and will not be able to do anything
else.

Archive expiry
--------------

Messages in the archive will expire after some time, by default one
week. This can be changed by setting `archive_expires_after`:

``` {.lua}
archive_expires_after = "1d" -- one day

archive_expires_after = "1w" -- one week, the default

archive_expires_after = "2m" -- two months

archive_expires_after = "1y" -- one year

archive_expires_after = 60 * 60 -- one hour

archive_expires_after = "never" -- forever
```

The format is an integer number of seconds or a multiple of a period
given by a suffix that can be one of `d` (day), `w` (week), `m` (month)
or `y` (year). No multiplier means seconds.

Message matching policy
-----------------------

The MAM protocol includes a way for clients to control what messages
should be stored. This allows users to enable or disable archiving by
default or for specific contacts.

``` {.lua}
default_archive_policy = true
```

  `default_archive_policy =`   Meaning
  ---------------------------- ------------------------------------------------------
  `false`                      Store no messages.
  `"roster"`                   Store messages to/from contacts in the users roster.
  `true`                       Store all messages. This is the default.

Compatibility
=============

  ------- ---------------
  trunk   Works
  0.10    Works
  0.9     Works
  0.8     Does not work
  ------- ---------------

[^1]: Might be changed to "mam" at some point

