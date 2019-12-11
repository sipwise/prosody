---
summary: Client State Indication support
labels:
- 'Stage-Merged'
...

Introduction
============

This module implements [XEP-0352: Client State
Indication](http://xmpp.org/extensions/xep-0352.html), a way for mobile
clients to tell the server that they are sitting in someones pocket and
would rather not get some less urgent things pushed to it.

This module has been merged into Prosody 0.11. Please see the
[mod_csi documentation](https://prosody.im/doc/modules/mod_csi) for more
information about how it is used.

Configuration
=============

There is no configuration for this module, just add it to
modules\_enabled as normal.

Compatibility
=============

  ----- -------
  0.9   Works
  ----- -------
  0.10  Works
  ----- -------
  0.11  Works (included)
  ----- -------
