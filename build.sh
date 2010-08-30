#!/bin/sh

set -e

PRODUCT=AximX51v
RELEASE=0
TEST=1
CLEAN=0
ZIP=0
KCONFIG=0
UPDATE=0

while getopts 'rdczku' OPTION
do
	case $OPTION in
	r)	RELEASE=1
		;;
	d)	TEST=0
		;;
	c)	CLEAN=1
		;;
	z)	ZIP=1
		;;
	k)	KCONFIG=1
		;;
	u)	UPDATE=1
		;;
	?)	echo "Usage: $0 <options>"
		echo "  -d   Debug Build"
		echo "  -r   Release Build"
		echo "  -c   Clean Everything"
		echo "  -z   Create Zip for Distribution"
		echo "  -k   Configure Kernel"
		echo "  -u   Update"
		;;
	esac
done
shift $(($OPTIND - 1))

if [ $RELEASE -eq 1 ]
then
	SUBDIR=rel
else
	SUBDIR=dbg
fi

# Detect mountloop script
# If you have this installed, it will be used to mount the root FS loopback
# Otherwise, regular mount will be used
# This is useful if you setup sudo to not ask for a password when
# running mountloop/umountloop :)
HAVEMOUNTLOOP=`which mountloop | wc -l`
if [ $HAVEMOUNTLOOP -eq 1 ]
then
	HAVEMOUNTLOOP=`which umountloop | wc -l`
fi

checkBuildType()
{
	if [ $RELEASE -eq 1 ]
	then
		BTYPE="release"
	elif [ $TEST -eq 1 ]
	then
		BTYPE="test"
	else
		BTYPE="debug"
	fi

	if [ ! -f .build/type ]
	then
		DIFFTYPE=1
	else
		PREVBTYPE=`cat .build/type`

		if [ "$PREVBTYPE" = "$BTYPE" ]
		then
			DIFFTYPE=0
		else
			echo "Previous build was '$PREVBTYPE'"

			DIFFTYPE=1
		fi
	fi

	if [ $DIFFTYPE -eq 1 ]
	then
		rm -rf build/ramdisk
		rm -rf build/kernel
		rm -rf build/root

		mkdir -p .build
		echo -n "$BTYPE" >.build/type
	fi

	echo "Building '$BTYPE'"
}

downloadTheCode()
{
	if [ ! -d src/platform ]
	then
		mkdir -p src/platform

		(
			set -e
			cd src/platform
			repo init -u git://github.com/paulburton/axdroid-manifest.git -b froyo
			repo sync
		) || exit 1
	fi

	if [ ! -d src/kernel ]
	then
		mkdir -p src

		(
			set -e
			cd src
			git clone git://github.com/paulburton/axdroid_kernel.git kernel
		) || exit 1
	fi

	if [ ! -d src/acx-mac80211 ]
	then
		mkdir -p src

		(
			set -e
			cd src
			git clone git://github.com/paulburton/axdroid-acx-mac80211.git acx-mac80211
		) || exit 1
	fi

	if [ ! -d src/haret ]
	then
		mkdir -p src

		(
			set -e

			cd src
			cvs -d :pserver:anoncvs:anoncvs@anoncvs.handhelds.org:/cvs login
			cvs -d :pserver:anoncvs:anoncvs@anoncvs.handhelds.org:/cvs co haret

			cd haret
			patch -p0 -fr - < ../../haret-build-fix.patch
		) || exit 1
	fi
}

mountLoop()
{
	IMGFILE=$1
	MOUNTPOINT=$2
	FSTYPE=$3

	if [ $HAVEMOUNTLOOP -eq 1 ]
	then
		sudo `which mountloop` "$IMGFILE" "$MOUNTPOINT" "$FSTYPE"
	else
		sudo mount -t "$FSTYPE" -o loop "$IMGFILE" "$MOUNTPOINT"
	fi
}

umountLoop()
{
	MOUNTPOINT=$1

	if [ $HAVEMOUNTLOOP -eq 1 ]
	then
		sudo `which umountloop` "$MOUNTPOINT"
	else
		sudo umount "$MOUNTPOINT"
	fi
}

buildBusyBox()
{
	if [ -f build/busybox/bin/busybox ]
	then
		return 0
	fi

	BUSYBOXVER=1.17.1
	BUSYBOXTAR=busybox-$BUSYBOXVER.tar.bz2
	BUSYBOXDIR=busybox-$BUSYBOXVER

	(
		set -e
		cd .build

		if [ ! -f $BUSYBOXTAR ]
		then
			wget http://www.busybox.net/downloads/$BUSYBOXTAR -O $BUSYBOXTAR
		fi

		rm -rf $BUSYBOXDIR
		tar xjf $BUSYBOXTAR
		cp ../busybox.config $BUSYBOXDIR/.config

		CFLAGS="-mcpu=xscale -mtune=iwmmxt" make -C $BUSYBOXDIR -j4
		make -C $BUSYBOXDIR install

		mkdir -p ../build/busybox
		cp -r $BUSYBOXDIR/_install/* ../build/busybox/
	) || exit 1

	rm -f build/ramdisk/ramdisk.cpio
}

buildInitLogo()
{
	SUFFIX=$1
	PNGFILE="graphics/initlogo/initlogo$SUFFIX.png"
	RAWFILE=".build/ramdisk/initlogo$SUFFIX.raw"
	RLEFILE=".build/ramdisk/initlogo$SUFFIX.rle"

	if [ ! -f "$PNGFILE" ]
	then
		echo "Unable to find initlogo PNG $PNGFILE"
		return 1
	fi

	convert -depth 8 "$PNGFILE" rgb:$RAWFILE
	src/platform/out/host/linux-x86/bin/rgb2565 -rle < $RAWFILE > $RLEFILE
	rm $RAWFILE
}

buildCompCache()
{
	CCVER="0.6.2"
	CCDIR=".build/compcache-$CCVER"
	CCTAR="compcache-$CCVER.tar.gz"

	if [ ! -f ".build/$CCTAR" ]
	then
		wget http://compcache.googlecode.com/files/$CCTAR -O .build/$CCTAR
	fi

	rm -rf $CCDIR

	(
		set -e
		cd .build
		tar xzf $CCTAR
	) || exit 1

	buildKernel

	(
		set -e

		cd $CCDIR

		sed -i 's|//#define CONFIG_SWAP_FREE_NOTIFY|#define CONFIG_SWAP_FREE_NOTIFY|' compat.h

		PATH=$PATH:`pwd`/../../src/platform/prebuilt/linux-x86/toolchain/arm-eabi-4.4.0/bin \
		ARCH=arm CROSS_COMPILE=arm-eabi- CFLAGS="-mcpu=xscale -mtune=iwmmxt" \
		make KERNEL_BUILD_PATH=`pwd`/../../src/kernel

		# The makefile builds this for the host machine...
		cd sub-projects/rzscontrol
		rm rzscontrol
		CFLAGS="-mcpu=xscale -mtune=iwmmxt" arm-none-linux-gnueabi-gcc -g -Wall \
			-D_GNU_SOURCE rzscontrol.c -o rzscontrol -static -I ../include -I../..
	) || exit 1

	mkdir -p .build/ramdisk/lib/modules
	cp $CCDIR/ramzswap.ko .build/ramdisk/lib/modules/
	cp $CCDIR/sub-projects/rzscontrol/rzscontrol .build/ramdisk/bin/
}

buildWiFiModule()
{
	buildKernel

	(
		cd src/acx-mac80211

		PATH=$PATH:`pwd`/../../src/platform/prebuilt/linux-x86/toolchain/arm-eabi-4.4.0/bin \
		ARCH=arm CROSS_COMPILE=arm-eabi- CFLAGS="-mcpu=xscale -mtune=iwmmxt" \
		EXTRA_KCONFIG="CONFIG_ACX_MAC80211=m CONFIG_ACX_MAC80211_PCI=n CONFIG_ACX_MAC80211_USB=n CONFIG_ACX_MAC80211_MEM=y CONFIG_MACH_X50=y" \
		make KERNELDIR=`pwd`/../../src/kernel KVERSION=2.6.32 || exit 1

		cd platform-aximx50

		PATH=$PATH:`pwd`/../../../src/platform/prebuilt/linux-x86/toolchain/arm-eabi-4.4.0/bin \
		ARCH=arm CROSS_COMPILE=arm-eabi- CFLAGS="-mcpu=xscale -mtune=iwmmxt" \
		EXTRA_KCONFIG="CONFIG_AXIMX50_ACX=m" \
		make KERNELDIR=`pwd`/../../../src/kernel KVERSION=2.6.32 || exit 1
	) || exit 1

	mkdir -p .build/ramdisk/lib/modules
	cp src/acx-mac80211/acx-mac80211.ko .build/ramdisk/lib/modules/
	cp src/acx-mac80211/platform-aximx50/aximx50_acx.ko .build/ramdisk/lib/modules/
}

buildRamDisk()
{
	if [ -f build/ramdisk/ramdisk.cpio ]
	then
		return 0
	fi

	mkdir -p build/ramdisk
	touch build/ramdisk/ramdisk.cpio

	rm -f build/kernel/zImage

	rm -rf .build/ramdisk
	mkdir -p .build/ramdisk

	cp -r build/busybox/* .build/ramdisk/
	rm -f .build/ramdisk/linuxrc

	mkdir .build/ramdisk/dev
	mkdir .build/ramdisk/proc
	mkdir .build/ramdisk/sys

	cp -r ramdisk/common/* .build/ramdisk/
	if [ -d ramdisk/$SUBDIR ]
	then
		cp -r ramdisk/$SUBDIR/* .build/ramdisk/
	fi

	if [ $RELEASE -eq 1 ]
	then
		sed -i 's/DEBUG=1/DEBUG=0/' .build/ramdisk/init
	fi

	buildInitLogo "VGA"
	buildInitLogo "QVGA"
	buildKernel			# For modules
	buildCompCache
	buildWiFiModule

	(
		set -e
		cd .build/ramdisk
		find . -print0 | cpio -H newc -ov -0 > ../../build/ramdisk/ramdisk.cpio
	) || exit 1

	rm -f build/kernel/zImage
}

buildKernel()
{
	if [ -f build/kernel/zImage ]
	then
		return 0
	fi

	cp kernel.config src/kernel/.config

	if [ $RELEASE -eq 1 ]
	then
		sed -i 's/CONFIG_ANDROID_LOGGER=y/CONFIG_ANDROID_LOGGER=n/' src/kernel/.config
	fi

	PATH=$PATH:`pwd`/src/platform/prebuilt/linux-x86/toolchain/arm-eabi-4.4.0/bin \
	ARCH=arm CROSS_COMPILE=arm-eabi- CFLAGS="-mcpu=xscale -mtune=iwmmxt" \
	make -C src/kernel -j4

	PATH=$PATH:`pwd`/src/platform/prebuilt/linux-x86/toolchain/arm-eabi-4.4.0/bin \
	ARCH=arm CROSS_COMPILE=arm-eabi- CFLAGS="-mcpu=xscale -mtune=iwmmxt" \
	make -C src/kernel modules_install INSTALL_MOD_PATH=`pwd`/.build/ramdisk

	mkdir -p build/kernel
	cp src/kernel/arch/arm/boot/zImage build/kernel/
}

clonePermissions()
{
	PDIR=$1
	FDIR=$2

	find $PDIR -printf "chmod %m %p \n" > .build/root/chmodscript
	sed -i "s|$PDIR|$FDIR|g" .build/root/chmodscript
	. .build/root/chmodscript
	rm .build/root/chmodscript
}

buildWiFiFirmware()
{
	FWVER="Axim"
	#FWVER="1.10.7.K"
	CURRVER=""

	mkdir -p build/wifi

	if [ -f build/wifi/version ]
	then
		CURRVER=`cat build/wifi/version`
	fi

	if [ ! "$CURRVER" = "$FWVER" ]
	then
		rm -f build/wifi/WLANGEN.BIN
		rm -f build/wifi/RADIO0d.BIN
	fi

	if [ ! -f build/wifi/WLANGEN.BIN ]
	then
		wget -O build/wifi/WLANGEN.BIN http://www.paulburton.eu/project/axdroid/wifi_fw/$FWVER/WLANGEN.BIN
	fi
	if [ ! -f build/wifi/RADIO0d.BIN ]
	then
		wget -O build/wifi/RADIO0d.BIN http://www.paulburton.eu/project/axdroid/wifi_fw/$FWVER/RADIO0d.BIN
	fi

	echo "$FWVER" >build/wifi/version

	mkdir -p .build/root/mnt/lib/firmware
	cp build/wifi/WLANGEN.BIN .build/root/mnt/lib/firmware/
	cp build/wifi/RADIO0d.BIN .build/root/mnt/lib/firmware/
}

buildPlatform()
{
	ROOTSIZE=128

	if [ -f build/root/root.img ]
	then
		CURRSIZE=`ls -l build/root/root.img | awk '{print $5}'`
		CURRSIZE=$(($CURRSIZE / (1024 * 1024)))

		if [ $CURRSIZE -eq $ROOTSIZE ]
		then
			return 0
		fi
	fi

	(
		set -e
		cd src/platform
		#. build/envsetup.sh

		if [ $RELEASE -eq 1 -o $TEST -eq 1 ]
		then
			VARIANT=user
			TYPE=release
		else
			VARIANT=eng
			TYPE=debug
		fi

		PLATFORM_VERSION_CODENAME=REL \
		PLATFORM_VERSION=2.2 \
		TARGET_PRODUCT=$PRODUCT \
		TARGET_BUILD_VARIANT=$VARIANT \
		TARGET_SIMULATOR=false \
		TARGET_BUILD_TYPE=$TYPE \
		TARGET_BUILD_APPS= \
		TARGET_ARCH=arm \
		HOST_ARCH=x86 \
		HOST_OS=linux \
		HOST_BUILD_TYPE=release \
		BUILD_ID=MASTER \
		WITH_DEXPREOPT=1 \
		make -j4
	) || exit 1

	if [ $RELEASE -eq 1 -o $TEST -eq 1 ]
	then
		OUTDIR=
	else
		OUTDIR=debug
	fi

	mkdir -p .build/root
	dd if=/dev/zero of=.build/root/root.img bs=1M count=$ROOTSIZE
	mkfs.ext4 -F .build/root/root.img

	rm -rf .build/root/mnt/
	mkdir .build/root/mnt/
	mountLoop .build/root/root.img .build/root/mnt/ ext4

	cp -r src/platform/out/$OUTDIR/target/product/axim/root/* .build/root/mnt/

	xyaffs2 src/platform/out/$OUTDIR/target/product/axim/system.img .build/root/mnt/system/
	xyaffs2 src/platform/out/$OUTDIR/target/product/axim/userdata.img .build/root/mnt/data/

	clonePermissions src/platform/out/$OUTDIR/target/product/axim/system/ .build/root/mnt/system/
	clonePermissions src/platform/out/$OUTDIR/target/product/axim/data/ .build/root/mnt/data/

	rm -f .build/root/mnt/init.goldfish.rc
	rm -f .build/root/mnt/system/etc/init.goldfish.sh

	cp -r root/common/* .build/root/mnt/
	if [ -d root/$SUBDIR ]
	then
		cp -r root/$SUBDIR/* .build/root/mnt/
	fi

	if [ $RELEASE -eq 1 ]
	then
		sed -i 's/DEBUG=1/DEBUG=0/' .build/root/mnt/axdroid.sh
	fi

	buildWiFiFirmware

	umountLoop .build/root/mnt
	mkdir -p build/root
	mv .build/root/root.img build/root/
}

buildSwap()
{
	SWAPSIZE=64

	if [ -f build/swap/swap.img ]
	then
		CURRSIZE=`ls -l build/swap/swap.img | awk '{print $5}'`
		CURRSIZE=$(($CURRSIZE / (1024 * 1024)))

		if [ $CURRSIZE -eq $SWAPSIZE ]
		then
			return 0
		fi
	fi

	mkdir -p build/swap/
	dd if=/dev/zero of=build/swap/swap.img bs=1M count=$SWAPSIZE
	mkswap build/swap/swap.img
}

buildHaReT()
{
	if [ -f build/haret/haret.exe -a -f build/haret/default.txt -a -f build/haret/make-bootbundle.py ]
	then
		return 0
	fi

	(
		cd src/haret
		make LDFLAGS=-static-libgcc
	) || exit 1

	rm -rf build/haret
	mkdir -p build/haret
	upx -9 -o build/haret/haret.exe src/haret/out/haret.exe
	cp src/haret/tools/make-bootbundle.py build/haret/

	echo "set GAFR(34) 1 
set GAFR(35) 1 
set GAFR(37) 1 
set GAFR(39) 2 
set GAFR(40) 2 
set GAFR(41) 2 
set GPDR(34) 0 
set GPDR(35) 0 
set GPDR(37) 0 
set GPLR(34) 1 
set GPLR(35) 1 
set GPLR(37) 1 
set GPLR(39) 1

set com \"1\"
set mtype \"740\"
set cmdline \"rw\"
ramboot
" > build/haret/default.txt
}

buildOutput()
{
	rm -rf output
	mkdir output

	cp -au build/root/root.img output/
	cp -au build/swap/swap.img output/

	./build/haret/make-bootbundle.py -o output/bootlinux.exe \
		build/haret/haret.exe build/kernel/zImage /dev/null \
		build/haret/default.txt
}

buildSDCard()
{
	SDROOT=$1

	if [ ! -d $SDROOT ]
	then
		echo "SD Card $SDROOT not present, skipping"
		return 0
	fi

	cp -uv output/[!swap.img]* $SDROOT/

	if [ ! -f $SDROOT/swap.img ]
	then
		cp -uv output/swap.img $SDROOT/
	else
		SDSWAPSIZE=`ls -s $SDROOT/swap.img | awk '{print $1}'`
		NEWSWAPSIZE=`ls -s output/swap.img | awk '{print $1}'`

		if [ ! $SDSWAPSIZE -eq $NEWSWAPSIZE ]
		then
			echo "Swap file size changed"
			cp -uv output/swap.img $SDROOT/
		fi
	fi
}

buildDistZip()
{
	ZIPFILE=axdroid_`date +%Y%m%d`

	if [ $RELEASE -eq 1 ]
	then
		ZIPFILE=$ZIPFILE"_rel"
	else
		ZIPFILE=$ZIPFILE"_dbg"
	fi

	rm -f $ZIPFILE.zip
	zip -rj9 $ZIPFILE output
}

if [ $CLEAN -eq 1 ]
then
	rm -rf .build
	rm -rf build
	rm -rf output

	ARCH=arm make -C src/kernel clean
	ARCH=arm make -C src/acx-mac80211 KERNELDIR=`pwd`/src/kernel clean
	ARCH=arm make -C src/acx-mac80211/platform-aximx50 KERNELDIR=`pwd`/src/kernel clean

	(
		cd src/platform
		make clobber
	)
elif [ $KCONFIG -eq 1 ]
then
	cp kernel.config src/kernel/.config

	ARCH=arm make -C src/kernel xconfig

	cp src/kernel/.config kernel.config
	cp kernel.config src/kernel/arch/arm/configs/aximx50_defconfig
elif [ $UPDATE -eq 1 ]
then
	git pull origin master

	(
		cd src/kernel
		git pull
	)
	(
		cd src/acx-mac80211
		git pull
	)
	(
		cd src/platform
		repo sync
	)
else
	downloadTheCode
	checkBuildType

	mkdir -p .build

	buildPlatform
	buildBusyBox
	buildRamDisk
	buildKernel
	buildSwap
	buildHaReT
	buildOutput

	for card in $AXDROID_SD
	do
		buildSDCard "$card"
	done

	if [ $ZIP -eq 1 ]
	then
		buildDistZip
	fi
fi

