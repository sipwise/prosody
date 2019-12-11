---
labels:
- 'Stage-Merged'
summary: Message Carbons
...

Introduction
============

This module implements [XEP-0280: Message
Carbons](http://xmpp.org/extensions/xep-0280.html), allowing users to
maintain a shared and synchronized view of all conversations across all
their online clients and devices.

Configuration
=============

As with all modules, you enable it by adding it to the modules\_enabled
list.

        modules_enabled = {
            ...
            "carbons";
            ...
        }

The module has no further configuration.

Clients
=======

Clients that support XEP-0280:

-   [Gajim](http://gajim.org/) (Desktop)
-   [Adium (1.6)](http://adium.im/) (Desktop - OS X)
-   [Yaxim](http://yaxim.org/) (Mobile - Android)
-   [Conversations](https://play.google.com/store/apps/details?id=eu.siacs.conversations)
    (Mobile - Android)
-   [poezio](http://poezio.eu/en/) (Console)

Compatibility
=============

  ------- -----------------------
  0.8     Works
  0.9     Works
  0.10    Included with prosody
  trunk   Included with prosody
  ------- -----------------------
