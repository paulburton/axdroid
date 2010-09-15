#!/bin/sh

echo "Axdroid realroot init"

DEBUG=1
COMPCACHE=1

echo /sbin/axdroid_hotplug >/proc/sys/kernel/hotplug

insmod /lib/modules/acx-mac80211.ko
insmod /lib/modules/aximx50_acx.ko

if [ $COMPCACHE -eq 1 ]
then
	insmod /lib/modules/zram.ko num_devices=1
fi

if [ $DEBUG -eq 1 ]
then
	ifconfig usb0 10.0.0.2 netmask 255.255.255.0 up
	PATH="$PATH:/system/bin" telnetd -l /bin/sh
fi

if [ $DEBUG -eq 0 ]
then
	VGA=`cat /proc/mtd | grep "Video SDRAM" | wc -l`
	if [ $VGA -eq 1 ]
	then
		cp /initlogoVGA.rle /initlogo.rle
	else
		cp /initlogoQVGA.rle /initlogo.rle
	fi
else
	rm -f /initlogo.rle
fi

/init

