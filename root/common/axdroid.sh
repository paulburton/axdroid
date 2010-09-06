#!/bin/sh

echo "Axdroid realroot init"

DEBUG=1

insmod /lib/modules/acx-mac80211.ko
#insmod /lib/modules/aximx50_acx.ko

if [ $DEBUG -eq 1 ]
then
	ifconfig usb0 10.0.0.2 netmask 255.255.255.0 up
	PATH="$PATH:/system/bin" telnetd -l /bin/sh
fi

/init

