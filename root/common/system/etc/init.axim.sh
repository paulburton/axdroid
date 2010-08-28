#!/bin/sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/system/bin
export BOOTCLASSPATH=/system/framework/core.jar:/system/framework/ext.jar:/system/framework/framework.jar:/system/framework/android.policy.jar:/system/framework/services.jar

COMPCACHESZ=8196

HAVEVRAM=`cat /proc/mtd | grep "Video SDRAM" | wc -l`
ISVGA=$HAVEVRAM

if [ ! $HAVEVRAM -eq 0 ]
then
	echo "Using 2700g Video RAM as fast swap" > /dev/console

	VRAMMTDNUM=`cat /proc/mtd | grep "Video SDRAM" | awk '{print substr($1,4,1)}'`
	VRAMMTDBLOCK="/dev/block/mtdblock$VRAMMTDNUM"

	while [ ! -e "$VRAMMTDBLOCK" ]
	do
		echo "Waiting for VRAMMTDBLOCK"
	done

	mkswap $VRAMMTDBLOCK
	swapon -p 10 $VRAMMTDBLOCK
fi

if [ -e /dev/block/ramzswap0 ]
then
	rzscontrol /dev/block/ramzswap0 --init --disksize_kb=$COMPCACHESZ
	swapon -p 20 /dev/block/ramzswap0
fi

if [ -e "/mnt/sdcard/swap.img" ]
then
	swapon /mnt/sdcard/swap.img
fi

echo 40 > /proc/sys/vm/swappiness

if [ ! $ISVGA -eq 0 ]
then
	/system/bin/setprop ro.sf.lcd_density 160
else
	/system/bin/setprop ro.sf.lcd_density 90
	/system/bin/setprop debug.sf.nobootanimation 1
fi

route add default gw 10.0.0.1 dev usb0

