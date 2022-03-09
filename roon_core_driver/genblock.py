#!/usr/bin/env python

id_31XX = 3101
id_40XX = 4001
for proxy in xrange(5002,5007):
    for n in xrange(1,33):
        print """        <connection proxybindingid="%d">
            <id>%d</id>
            <type>6</type>
            <connectionname>Zone %d</connectionname>
            <consumer>True</consumer>
            <linelevel>False</linelevel>
            <classes>
                <class>
                    <classname>RF_ROON_NET_ZONE</classname>
                    <autobind>True</autobind>
                </class>
            </classes>
            </connection>
            <connection proxybindingid="%d">
                <id>%d</id>
                <type>6</type>
                <connectionname>Audio %d</connectionname>
                <consumer>False</consumer>
                <linelevel>False</linelevel>
                <classes>
                    <class>
                        <classname>RF_ROON_NET_AUDIO</classname>
                        <autobind>True</autobind>
                    </class>
                </classes>
            </connection>"""%(proxy, id_31XX, n, proxy, id_40XX, n)
        id_31XX += 1
        id_40XX += 1
