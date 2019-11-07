examples of messages for testing funtionality
---------------------------------------------

* mod_sipwise_lastactivity:
```
<iq id='last1' to='43991002@192.168.1.102' type='get'>
  <query xmlns='jabber:iq:last'/>
</iq>
```

```
<iq id="last1" to="43991002@192.168.1.102/profanity" type="result">
  <query xmlns="jabber:iq:last" seconds="8"/>
</iq>
```

* mod_sipwise_vcard_cusax:
```
<iq  id='bx81v356' to='43991002@192.168.1.102' type='get'>
  <vCard xmlns='vcard-temp'/>
</iq>
```
response:
```
<iq id="bx81v356" to="43991002@192.168.1.102/profanity" type="result">
  <vCard prodid="-//HandGen//NONSGML vGen v1.0//EN" xmlns="vcard-temp" version="2.0">
    <JABBERID>43991002@192.168.1.102</JABBERID>
    <TEL><VIDEO/><NUMBER>sip:43991002@192.168.1.102</NUMBER></TEL>
    <TEL><VOICE/><NUMBER>43991002</NUMBER></TEL>
    <EMAIL><INTERNET/><PREF/><USERID>default-customer@default.invalid</USERID></EMAIL>
  </vCard>
</iq>
```

* mod_sipwise_vhosts_sql:
```
<iq id="discoitemsreq" to="192.168.1.102" type="get">
  <query xmlns="http://jabber.org/protocol/disco#items"/>
</iq>
```
response:
```
<iq id="discoitemsreq" to="43991002@192.168.1.102/profanity" type="result" from="192.168.1.102">
  <query xmlns="http://jabber.org/protocol/disco#items">
    <item jid="search.192.168.1.102"/>
    <item jid="conference.192.168.1.102"/>
  </query>
</iq>
```

* mod_sipwise_vjud:

discover search fields
```
<iq type='get' to='search.192.168.1.102' id='search1' xml:lang='en'>
  <query xmlns='jabber:iq:search'/>
</iq>
```
response:
```
<iq id="search1" to="43991002@192.168.1.102/profanity" type="result" from="search.192.168.1.102">
  <query xmlns="jabber:iq:search">
    <instructions>Use the enclosed form to search</instructions>
    <x xmlns="jabber:x:data" type="form">
      <title>User Directory Search</title>
      <instructions>Please provide the following information to search for subscribers</instructions>
      <field type="hidden" var="FORM_TYPE"><value>jabber:iq:search</value></field>
      <field label="e164 Phone number" type="text-single" var="e164"/>
      <field label="domain" type="text-single" var="domain"/>
    </x>
    <nick/>
  </query>
</iq>
```

search domain:
```
<iq type='set' to='search.192.168.1.102' id='search2' xml:lang='en'><query xmlns='jabber:iq:search'>
  <x xmlns='jabber:x:data' type='submit'>
    <field type='hidden' var='FORM_TYPE'>
    <value>jabber:iq:search</value>
    </field>
    <field var='domain'>
    <value>192.168.1.102</value>
    </field>
  </x>
  </query>
</iq>
```
response:
```
<iq id="search2" to="43991002@192.168.1.102/profanity" type="result" from="search.192.168.1.102">
  <query xmlns="jabber:iq:search">
    <x xmlns="jabber:x:data" type="result">
      <field type="hidden" var="FORM_TYPE"><value>jabber:iq:search</value></field>
      <reported><field label="domain" type="text-single" var="domain"/></reported>
      <item><field var="domain"><value>192.168.1.102</value></field></item>
    </x>
  </query>
</iq>
```

search number:
```
<iq type='set' to='search.192.168.1.102' id='search3' xml:lang='en'><query xmlns='jabber:iq:search'>
  <x xmlns='jabber:x:data' type='submit'>
    <field type='hidden' var='FORM_TYPE'>
    <value>jabber:iq:search</value>
    </field>
    <field var='e164'>
    <value>43991003</value>
    </field>
  </x>
  </query>
</iq>
```
response:
```
<iq id="search3" type="result" to="43991002@192.168.1.102/profanity" from="search.192.168.1.102">
  <query xmlns="jabber:iq:search">
    <x xmlns="jabber:x:data" type="result">
      <field type="hidden" var="FORM_TYPE"><value>jabber:iq:search</value></field>
      <reported><field label="e164 Phone number" type="text-single" var="e164"/></reported>
      <item><field var="e164"><value>43991003@192.168.1.102</value></field></item>
    </x>
  </query>
</iq>
```
