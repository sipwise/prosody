---
summary: Client State Indication support
...

Introduction
============

This module implements [Client State
Indication](http://xmpp.org/extensions/xep-0352.html), a way for mobile
clients to tell the server that they are sitting in someones pocket and
would rather not get some less urgent things pushed to it.

However this module does not do anything by itself. Deciding what things
are considered "less urgent" is left to other modules.

-   [mod\_throttle\_presence](/mod_throttle_presence.html) supresses
    presence updates
-   [mod\_filter\_chatstates](/mod_filter_chatstates.html) removes chat
    states (*Someone is typing...*)

Configuration
=============

There is no configuration for this module, just add it to
modules\_enabled as normal.

Compatibility
=============

  ----- -------
  0.9   Works
  ----- -------
