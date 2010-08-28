#!/bin/sh

echo "Axdroid realroot init"

DEBUG=1

if [ $DEBUG -eq 1 ]
then
	ifconfig usb0 10.0.0.2 netmask 255.255.255.0 up
	telnetd -l /bin/sh
fi

/init

