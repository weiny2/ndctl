#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2023 Intel Corporation. All rights reserved.

. "$(dirname "$0")/common"

rc=77
set -ex

trap 'err $LINENO' ERR

check_prereq "jq"

modprobe -r cxl_test
modprobe cxl_test
rc=1

dev_path="/sys/bus/platform/devices"
cxl_path="/sys/bus/cxl/devices"

# a test extent tag
test_tag=dc-test-tag

# The test devices have 2G of non DC capacity.  dc0 starts at 2G
# Extent at dpa 2G - 64M long
base_ext_dpa=0x80000000
base_ext_length=67108864
# The pre existing extent is 256M offset 256M length
pre_ext_dpa=0x90000000
pre_ext_length=268435456

mem=""
bus=""
device=""
decoder=""
region=""
dax_dev=""

create_dcd_region()
{
	mem="$1"
	decoder="$2"

	# create region
	region=$($CXL create-region -t dc0 -d "$decoder" -m "$mem" | jq -r ".region")

	if [[ ! $region ]]; then
		echo "create-region failed for $decoder / $mem"
		err "$LINENO"
	fi
}

check_region()
{
	search=$1
	result=$($CXL list -r "$search" | jq -r ".[].region")

	if [ "$result" != "$search" ]; then
		echo "check region failed to find $search"
		err "$LINENO"
	fi
}

check_not_region()
{
	search=$1
	result=$($CXL list -r "$search" | jq -r ".[].region")

	if [ "$result" == "$search" ]; then
		echo "check not region failed; $search found"
		err "$LINENO"
	fi
}

destroy_region()
{
	region=$1
	$CXL disable-region $region
	$CXL destroy-region $region
}

inject_extent()
{
	device="$1"
	dpa="$2"
	length="$3"
	tag="$4"

	echo ${dpa}:${length}:${tag} > "${dev_path}/${device}/dc_inject_extent"
}

remove_extent()
{
	device="$1"
	dpa="$2"
	length="$3"

	echo ${dpa}:${length} > "${dev_path}/${device}/dc_del_extent"
}

create_dax_dev()
{
	reg="$1"

	$DAXCTL create-device -r $reg
	dax_dev=$($DAXCTL list -r $reg -D | jq -er '.[].chardev' | sort | tail -n 1)
}

fail_create_dax_dev()
{
	reg="$1"

	set +e
	result=$($DAXCTL create-device -r $reg)
	set -e
	if [ "$result" == "0" ]; then
		echo "FAIL device created"
		err "$LINENO"
	fi
}

shrink_dax_dev()
{
	dev="$1"
	new_size="$2"

	modprobe -r device_dax
	$DAXCTL reconfigure-device $dev -s $new_size
}

destroy_dax_dev()
{
	dev="$1"

	$DAXCTL disable-device $dev
	$DAXCTL destroy-device $dev
}

check_dax_dev()
{
	search="$1"
	size="$2"
	result=$($DAXCTL list -d $search | jq -er '.[].chardev')
	if [ "$result" != "$search" ]; then
		echo "check dax device failed to find $search"
		err "$LINENO"
	fi
	result=$($DAXCTL list -d $search | jq -er '.[].size')
	if [ "$result" != "$size" ]; then
		echo "check dax device failed incorrect size $result; exp $size"
		err "$LINENO"
	fi
}

# check that the dax device is not there.
check_not_dax_dev()
{
	search="$1"
	result=$($DAXCTL list -r $reg -D | jq -er '.[].chardev')
	if [ "$result" == "$search" ]; then
		echo "FAIL found $search"
		err "$LINENO"
	fi
}

check_extent_cnt()
{
	reg=$1
	expected=$2
	cnt=$(ls -la /sys/bus/cxl/devices/${reg}/dax_${reg}/extent*/length | wc -l)
	if [ "$cnt" != "$expected" ]; then
		echo "FAIL found $cnt extents; expected $expected"
		err "$LINENO"
	fi
}

readarray -t memdevs < <("$CXL" list -b cxl_test -Mi | jq -r '.[].memdev')

for mem in ${memdevs[@]}; do
	dcsize=$($CXL list -m $mem | jq -r '.[].dc0_size')
	if [ "$dcsize" == "null" ]; then
		continue
	fi
	decoder=$($CXL list -b cxl_test -D -d root -m "$mem" |
		  jq -r ".[] |
		  select(.dc0_capable == true) |
		  select(.nr_targets == 1) |
		  select(.size >= ${dcsize}) |
		  .decoder")
	if [[ $decoder ]]; then
		bus=`"$CXL" list -b cxl_test -m ${mem} | jq -r '.[].bus'`
		device=$($CXL list -m $mem | jq -r '.[].host')
		break
	fi
done

echo "TEST: DCD test device bus:${bus} decoder:${decoder} mem:${mem} device:${device}"

if [ "$decoder" == "" ] || [ "$device" == "" ]; then
	echo "No mem device/decoder found with DCD support"
	exit 77
fi

create_dcd_region ${mem} ${decoder}

check_region ${region}

# should be a pre-created extent
check_extent_cnt ${region} 1

create_dax_dev ${region}

# Remove the pre-created test extent out from under dax device
# stack should hold ref until dax device deleted
echo ""
echo "Test: Remove pre-created test extent"
echo ""
remove_extent ${device} $pre_ext_dpa $pre_ext_length

check_dax_dev ${dax_dev} $pre_ext_length
check_extent_cnt ${region} 1

destroy_dax_dev ${dax_dev}
check_not_dax_dev ${dax_dev}
check_extent_cnt ${region} 0

echo ""
echo "Test: Add pre-created test extent back"
echo ""

inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
check_extent_cnt ${region} 2
create_dax_dev ${region}

# Test dev dax spanning sparse extents
echo ""
echo "Test: dev dax spanning sparse extents"
echo ""
ext_sum_length="$(($base_ext_length + $pre_ext_length))"
check_dax_dev ${dax_dev} $ext_sum_length

remove_extent ${device} $base_ext_dpa $base_ext_length
check_extent_cnt ${region} 2
remove_extent ${device} $pre_ext_dpa $pre_ext_length
check_extent_cnt ${region} 2
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${dax_dev}
check_extent_cnt ${region} 0


# Test partial extent remove
echo ""
echo "Test: partial extent remove"
echo ""
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
create_dax_dev ${region}
partial_ext_dpa="$(($base_ext_dpa + ($base_ext_length / 2)))"
partial_ext_length="$(($base_ext_length / 2))"
echo "Removing Partial : $partial_ext_dpa $partial_ext_length"
remove_extent ${device} $partial_ext_dpa $partial_ext_length
check_extent_cnt ${region} 1
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${dax_dev}
check_extent_cnt ${region} 0

# Test multiple extent remove
# Not done yet.
echo ""
echo "Test: multiple extent remove"
echo ""
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
check_extent_cnt ${region} 2
create_dax_dev ${region}
partial_ext_dpa="$(($base_ext_dpa + ($base_ext_length / 2)))"
partial_ext_length="$(($pre_ext_dpa - $base_ext_dpa))"
echo "Removing multiple in span : $partial_ext_dpa $partial_ext_length"
remove_extent ${device} $partial_ext_dpa $partial_ext_length
check_extent_cnt ${region} 2
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${dax_dev}
check_extent_cnt ${region} 0

# Test extent create and region destroy without extent removal

inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
check_extent_cnt ${region} 2

# clean up region
destroy_region ${region}

# region should come down even with extents
check_not_region ${region}


# destroy a region with dax devices in it
create_dcd_region ${mem} ${decoder}
check_region ${region}
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
check_extent_cnt ${region} 1
create_dax_dev ${region}
destroy_region ${region}
check_not_region ${region}


# 1 extent
# create a dax device without space
# resize
# create dev
create_dcd_region ${mem} ${decoder}
check_region ${region}
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
check_extent_cnt ${region} 1
create_dax_dev ${region}
check_dax_dev ${dax_dev} $pre_ext_length
fail_create_dax_dev ${region}
resize_ext_length=$(($pre_ext_length / 2))
shrink_dax_dev ${dax_dev} $resize_ext_length
check_dax_dev ${dax_dev} $resize_ext_length
create_dax_dev ${region}
check_dax_dev ${dax_dev} $resize_ext_length
destroy_region ${region}
check_not_region ${region}


# 2 extent
# create dax dev
# resize into 1st extent
# create dev on rest of 1st and all of second
# Ensure both devices are correct
create_dcd_region ${mem} ${decoder}
check_region ${region}
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
check_extent_cnt ${region} 2
create_dax_dev ${region}
ext_sum_length="$(($base_ext_length + $pre_ext_length))"
check_dax_dev ${dax_dev} $ext_sum_length
resize_ext_length=33554432 # 32MB
shrink_dax_dev ${dax_dev} $resize_ext_length
check_dax_dev ${dax_dev} $resize_ext_length
create_dax_dev ${region}
remainder_length=$((ext_sum_length - $resize_ext_length))
check_dax_dev ${dax_dev} $remainder_length
remainder_length=$((remainder_length / 2))
shrink_dax_dev ${dax_dev} $remainder_length
check_dax_dev ${dax_dev} $remainder_length
create_dax_dev ${region}
check_dax_dev ${dax_dev} $remainder_length
destroy_region ${region}
check_not_region ${region}


# Test event reporting
# results expected
num_dcd_events_expected=2

echo "TEST: Prep event trace"
echo "" > /sys/kernel/tracing/trace
echo 1 > /sys/kernel/tracing/events/cxl/enable
echo 1 > /sys/kernel/tracing/tracing_on

inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
remove_extent ${device} $base_ext_dpa $base_ext_length

echo 0 > /sys/kernel/tracing/tracing_on

echo "TEST: Events seen"
trace_out=$(cat /sys/kernel/tracing/trace)

# Look for DCD events
num_dcd_events=$(grep -c "cxl_dynamic_capacity" <<< "${trace_out}")
echo "     LOG     (Expected) : (Found)"
echo "     DCD events    ($num_dcd_events_expected) : $num_dcd_events"

if [ "$num_dcd_events" -ne $num_dcd_events_expected ]; then
	err "$LINENO"
fi

#echo "TEST: dmesg from ${device}"
#log=$(journalctl -r -k --since "-$((SECONDS+1))s" | grep -q ${device})
# FIXME look for something interesting
#grep -q <something interesting> <<< $log

modprobe -r cxl_test

check_dmesg "$LINENO"

exit 0
