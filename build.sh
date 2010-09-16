#!/bin/sh

set -e

PRODUCT=AximX51v
RELEASE=0
TEST=1
CLEAN=0
ZIP=0
KCONFIG=0
UPDATE=0

KERNELVER="2.6.32"
ROOTDIR=`pwd`

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

if [ -z "$NUMJOBS" ]
then
	NUMJOBS=`grep processor /proc/cpuinfo | wc -l`
	if [ $NUMJOBS -lt 1 ]
	then
		NUMJOBS=1
	fi
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

downloadFile()
{
	URL=$1

	if [ $# -gt 1 ]
	then
		NAME=$2
	else
		NAME=`basename "$URL"`
	fi

	mkdir -p dl

	if [ -f "dl/$NAME" ]
	then
		return 0
	fi

	wget -O "dl/$NAME" "$URL"
}

downloadTheCode()
{
	mkdir -p src
	cd src

	if [ ! -d platform ]
	then
		mkdir platform
		cd platform
		repo init -u git://github.com/paulburton/axdroid-manifest.git -b froyo
		repo sync
		cd ..
	fi

	if [ ! -d kernel-$KERNELVER ]
	then
		git clone git://github.com/paulburton/axdroid-kernel.git kernel-$KERNELVER -b android-$KERNELVER
	fi

	rm -f kernel
	ln -s kernel-$KERNELVER kernel

	if [ ! -d acx-mac80211 ]
	then
		git clone git://github.com/paulburton/axdroid-acx-mac80211.git acx-mac80211
	fi

	if [ ! -d haret ]
	then
		git clone git://gitorious.org/axdroid/haret.git haret
	fi

	if [ ! -d crosstool-ng ]
	then
		hg clone http://ymorin.is-a-geek.org/hg/crosstool-ng crosstool-ng
	fi

	if [ ! -d compcache ]
	then
		hg clone https://compcache.googlecode.com/hg/ compcache
	fi

	cd ..
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

buildCrossToolNG()
{
	CT_PREFIX=`pwd`/toolchain/crosstool-ng

	if [ -f toolchain/crosstool-ng/bin/ct-ng ]
	then
		return 0
	fi

	(
		set -e
		cd src/crosstool-ng

		./configure --prefix=$CT_PREFIX
		make
		make install
	) || exit 1
}

buildToolchain()
{
	TOOLTARGET=arm-axdroid-linux-gnueabi
	TOOLBIN=`pwd`/toolchain/build/$TOOLTARGET/bin

	if [ -f $TOOLBIN/$TOOLTARGET-gcc ]
	then
		return 0
	fi

	buildCrossToolNG

	configureKernel
	(
		set -e
		cd src/kernel
		make headers_install ARCH=arm INSTALL_HDR_PATH=../../toolchain/kernel_headers
	) || exit 1

	mkdir -p dl

	(
		set -e
		cd toolchain

		export PATH="$PATH:./crosstool-ng/bin"

		cp ../config/crosstool-ng.config .config
		sed -i "s/CT_PARALLEL_JOBS=./CT_PARALLEL_JOBS=$NUMJOBS/" .config

		ct-ng build
	) || exit 1
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

	downloadFile http://www.busybox.net/downloads/$BUSYBOXTAR

	(
		set -e
		cd .build

		export PATH="$PATH:$TOOLBIN"

		rm -rf $BUSYBOXDIR
		tar xjf ../dl/$BUSYBOXTAR
		cp ../config/busybox.config $BUSYBOXDIR/.config

		make -C $BUSYBOXDIR -j$NUMJOBS
		make -C $BUSYBOXDIR install

		mkdir -p ../build/busybox
		cp -r $BUSYBOXDIR/_install/* ../build/busybox/
	) || exit 1

	rm -f build/ramdisk/ramdisk.cpio
	rm -f build/root/root.img
}

buildInitLogo()
{
	SUFFIX=$1
	PNGFILE="graphics/initlogo/initlogo$SUFFIX.png"
	RAWFILE=".build/root/mnt/initlogo$SUFFIX.raw"
	RLEFILE=".build/root/mnt/initlogo$SUFFIX.rle"

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

	(
		set -e
		cd src/compcache
		export PATH="$PATH:$TOOLBIN"

		if [ "$KERNELVER" = "2.6.32" ]
		then
			sed -i 's|//#define CONFIG_SWAP_FREE_NOTIFY|#define CONFIG_SWAP_FREE_NOTIFY|' compat.h
		fi

		PATH="$PATH:$TOOLBIN" ARCH=arm CROSS_COMPILE=$TOOLTARGET- \
			make KERNELDIR=`pwd`/../../src/kernel
	) || exit 1

	mkdir -p .build/root/mnt/lib/modules
	cp src/compcache/zram.ko .build/root/mnt/lib/modules/
}

buildWiFiModule()
{
	(
		cd src/acx-mac80211

		PATH="$PATH:$TOOLBIN" ARCH=arm CROSS_COMPILE=$TOOLTARGET- \
			EXTRA_KCONFIG="CONFIG_ACX_MAC80211=m CONFIG_ACX_MAC80211_PCI=n CONFIG_ACX_MAC80211_USB=n CONFIG_ACX_MAC80211_MEM=y CONFIG_MACH_X50=y" \
			make KERNELDIR=`pwd`/../../src/kernel KVERSION=$KERNELVER || exit 1

		cd platform-aximx50

		PATH="$PATH:$TOOLBIN" ARCH=arm CROSS_COMPILE=$TOOLTARGET- \
			EXTRA_KCONFIG="CONFIG_AXIMX50_ACX=m" \
			make KERNELDIR=`pwd`/../../../src/kernel KVERSION=$KERNELVER || exit 1
	) || exit 1

	mkdir -p .build/root/mnt/lib/modules
	cp src/acx-mac80211/acx-mac80211.ko .build/root/mnt/lib/modules/
	cp src/acx-mac80211/platform-aximx50/aximx50_acx.ko .build/root/mnt/lib/modules/
}

buildRamDisk()
{
	if [ -f build/ramdisk/ramdisk.cpio ]
	then
		return 0
	fi

	rm -rf .build/ramdisk
	mkdir -p build/ramdisk
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

	(
		set -e
		cd .build/ramdisk
		find . -print0 | cpio -H newc -ov -0 > ../../build/ramdisk/ramdisk.cpio
	) || exit 1

	rm -f build/kernel/zImage
}

configureKernel()
{
	disableAlways="UID16 SYSCTL_SYSCALL"
	disableInRelease="ANDROID_LOGGER KALLSYMS PRINTK BUG"

	cp config/kernel.config src/kernel/.config

	for confOption in $disableAlways
	do
		sed -i "s/CONFIG_$confOption=y/CONFIG_$confOption=n/" src/kernel/.config
	done

	if [ $RELEASE -eq 1 ]
	then
		for confOption in $disableInRelease
		do
			sed -i "s/CONFIG_$confOption=y/CONFIG_$confOption=n/" src/kernel/.config
		done
	fi
}

buildKernel()
{
	if [ -f build/kernel/zImage ]
	then
		return 0
	fi

	configureKernel

	PATH="$PATH:$TOOLBIN" ARCH=arm CROSS_COMPILE=$TOOLTARGET- \
		make -C src/kernel -j$NUMJOBS

	PATH="$PATH:$TOOLBIN" ARCH=arm CROSS_COMPILE=$TOOLTARGET- \
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
	#FWVER="Axim"
	FWVER="1.10.7.K"
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
		make -j$NUMJOBS
	) || exit 1

	if [ $RELEASE -eq 1 -o $TEST -eq 1 ]
	then
		OUTDIR=
	else
		OUTDIR=debug
	fi

	rm -rf .build/root
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

	chmod 777 .build/root/mnt/system/media
	chmod 777 .build/root/mnt/system/media/audio
	bash -c "chmod 777 .build/root/mnt/system/media/audio/{alarms,notifications,ringtones,ui}"
	bash -c "chmod 777 .build/root/mnt/system/media/audio/{alarms,notifications,ringtones,ui}/*"

	rm -f .build/root/mnt/init.goldfish.rc
	rm -f .build/root/mnt/system/etc/init.goldfish.sh

	cp -r root/common/* .build/root/mnt/
	if [ -d root/$SUBDIR ]
	then
		cp -r root/$SUBDIR/* .build/root/mnt/
	fi

	mkdir -p .build/root/mnt/dev
	mkdir -p .build/root/mnt/proc
	mkdir -p .build/root/mnt/sys

	if [ $RELEASE -eq 1 ]
	then
		sed -i 's/DEBUG=1/DEBUG=0/' .build/root/mnt/axdroid.sh
	fi

	buildInitLogo "VGA"
	buildInitLogo "QVGA"
	buildCompCache
	buildWiFiModule
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

buildUpx()
{
	UPXVER="3.06"

	if [ -f build/upx/upx -a -f build/upx/version ]
	then
		CURRVER=`cat build/upx/version`

		if [ "$CURRVER" = "$UPXVER" ]
		then
			return 0
		fi
	fi

	ARCH=`uname -m`

	if [ "$ARCH" = "x86_64" ]
	then
		UPXBUILD="amd64_linux"
	else
		UPXBUILD="i386_linux"
	fi

	wget -O build/upx.tar.bz2 "http://upx.sourceforge.net/download/upx-$UPXVER-$UPXBUILD.tar.bz2"
	(
		cd build
		tar xjf upx.tar.bz2 || exit 1
	) || exit 1

	mkdir -p build/upx
	mv build/upx-$UPXVER-$UPXBUILD/upx build/upx/upx
	echo "$UPXVER" >build/upx/version

	rm -r build/upx-$UPXVER-$UPXBUILD
	rm build/upx.tar.bz2
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
	cp src/haret/out/haret.exe build/haret/haret.exe
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
	buildUpx

	rm -rf output
	mkdir output

	cp -au build/root/root.img output/
	cp -au build/swap/swap.img output/

	./build/haret/make-bootbundle.py -o output/bootlinux.exe.nocomp \
		build/haret/haret.exe build/kernel/zImage /dev/null \
		build/haret/default.txt

	build/upx/upx --lzma -9 -o output/bootlinux.exe output/bootlinux.exe.nocomp
	rm output/bootlinux.exe.nocomp

	# Please, if you want to distribute your own build of Axdroid then go ahead
	# but make it clear that it didn't come from me! Thankyou, Paul.
	hostName=`hostname`
	[ "$hostName" = "paul-desktop" ] && cp README.release output/README.txt
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
	ARCH=arm make -C src/haret clean
	ARCH=arm make -C src/crosstool-ng clean
	ARCH=arm make -C src/acx-mac80211 KERNELDIR=$ROOTDIR/src/kernel clean
	ARCH=arm make -C src/acx-mac80211/platform-aximx50 KERNELDIR=$ROOTDIR/src/kernel clean
	cd src/compcache; ARCH=arm make KERNELDIR=$ROOTDIR/src/kernel clean; cd $ROOTDIR

	(
		cd src/platform
		make clobber
	)
elif [ $KCONFIG -eq 1 ]
then
	cp config/kernel.config src/kernel/.config

	ARCH=arm make -C src/kernel xconfig

	cp src/kernel/.config config/kernel.config
	cp config/kernel.config src/kernel/arch/arm/configs/aximx50_defconfig
elif [ $UPDATE -eq 1 ]
then
	if [ ! "$AXDROID_SELFUPDATED" = "1" ]
	then
		git pull origin master
		AXDROID_SELFUPDATED=1 ./build.sh -u $@
		exit $?
	fi

	downloadTheCode
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
	(
		cd src/crosstool-ng
		hg update
	)
	(
		cd src/compcache
		hg update
	)
else
	downloadTheCode
	checkBuildType

	mkdir -p .build

	buildToolchain
	buildBusyBox
	buildRamDisk
	buildKernel
	buildPlatform
	buildSwap
	buildHaReT
	buildOutput

	if [ ! -z "$AXDROID_SD" ]
	then
		for card in $AXDROID_SD
		do
			buildSDCard "$card"
		done
	fi

	if [ $ZIP -eq 1 ]
	then
		buildDistZip
	fi
fi

