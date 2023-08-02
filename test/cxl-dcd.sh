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

#
# The test devices have 2G of non DC capacity.  A single DC reagion of 1G is
# added beyond that.
#
# The testing centers around 3 extents.  Two are pre-existing on test load
# called pre-existing.  The other is created within this script alone called
# base.

#
# | 2G non- |      DC region (1G)                                   |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |--------|       |----------|      |----------|         |
# |         | (base) |       | (pre)-   |      | (pre2)-  |         |
# |         |        |       | existing |      | existing |         |

dcsize=""

# base extent at dpa 2G - 64M long
base_ext_dpa=0x80000000
base_ext_length=0x4000000

# pre existing extent base + 256M, 64M length
pre_ext_dpa=0x88000000
pre_ext_length=0x4000000

# pre2 existing extent base + 512M, 64M length
pre2_ext_dpa=0x90000000
pre2_ext_length=0x4000000

mem=""
bus=""
device=""
decoder=""

create_dcd_region()
{
	mem="$1"
	decoder="$2"
	if [ "$3" != "" ]; then
		reg_size_str="-s $3"
	fi

	# create region
	region=$($CXL create-region -t dc0 -d "$decoder" -m "$mem" ${reg_size_string} | jq -r ".region")

	if [[ ! $region ]]; then
		echo "create-region failed for $decoder / $mem"
		err "$LINENO"
	fi

	echo ${region}
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

	dax_dev=$($DAXCTL create-device -r $reg | jq -er '.[].chardev')

	echo ${dax_dev}
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

	$DAXCTL disable-device $dev
	$DAXCTL reconfigure-device $dev -s $new_size
	$DAXCTL enable-device $dev
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
	if [ "$result" -ne "$size" ]; then
		echo "check dax device failed incorrect size $result; exp $size"
		err "$LINENO"
	fi
}

# check that the dax device is not there.
check_not_dax_dev()
{
	reg="$1"
	search="$2"
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
	cnt=$(ls -la /sys/bus/cxl/devices/${reg}/dax_${reg}/extent*/uevent | wc -l)
	if [ "$cnt" -ne "$expected" ]; then
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
		  select(.max_available_extent >= ${dcsize}) |
		  .decoder")
	if [[ $decoder ]]; then
		bus=`"$CXL" list -b cxl_test -m ${mem} | jq -r '.[].bus'`
		device=$($CXL list -m $mem | jq -r '.[].host')
		break
	fi
done

echo "TEST: DCD test device bus:${bus} decoder:${decoder} mem:${mem} device:${device} size:${dcsize}"

if [ "$decoder" == "" ] || [ "$device" == "" ] || [ "$dcsize" == "" ]; then
	echo "No mem device/decoder found with DCD support"
	exit 77
fi

echo ""
echo "Test: pre-existing extent"
echo ""
region=$(create_dcd_region ${mem} ${decoder})
check_region ${region}
# should be a pre-created extent
check_extent_cnt ${region} 2

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |                   |----------|         |----------|   |
# |         |                   | (pre)-   |         | (pre2)-  |   |
# |         |                   | existing |         | existing |   |

# Remove the pre-created test extent out from under dax device
# stack should hold ref until dax device deleted
echo ""
echo "Test: Remove extent from under DAX dev"
echo ""
dax_dev=$(create_dax_dev ${region})
check_extent_cnt ${region} 2
remove_extent ${device} $pre_ext_dpa $pre_ext_length
length="$(($pre_ext_length + $pre2_ext_length))"
check_dax_dev ${dax_dev} $length
check_extent_cnt ${region} 2
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}

# In-use extents are not released.  Remove after use.
check_extent_cnt ${region} 2
remove_extent ${device} $pre_ext_dpa $pre_ext_length
remove_extent ${device} $pre2_ext_dpa $pre2_ext_length
check_extent_cnt ${region} 0

echo ""
echo "Test: Create dax device spanning 2 extents"
echo ""
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |--------|          |----------|                        |
# |         | (base) |          | (pre)-   |                        |
# |         |        |          | existing |                        |

check_extent_cnt ${region} 2
dax_dev=$(create_dax_dev ${region})

# Test dev dax spanning sparse extents
echo ""
echo "Test: dev dax is spanning sparse extents"
echo ""
ext_sum_length="$(($base_ext_length + $pre_ext_length))"
check_dax_dev ${dax_dev} $ext_sum_length

# Test dev dax spanning sparse extents
echo ""
echo "Test: Remove extents under sparse dax device"
echo ""
remove_extent ${device} $base_ext_dpa $base_ext_length
check_extent_cnt ${region} 2
remove_extent ${device} $pre_ext_dpa $pre_ext_length
check_extent_cnt ${region} 2
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}

# In-use extents are not released.  Remove after use.
check_extent_cnt ${region} 2
remove_extent ${device} $base_ext_dpa $base_ext_length
remove_extent ${device} $pre_ext_dpa $pre_ext_length
check_extent_cnt ${region} 0


# Test partial extent remove
echo ""
echo "Test: partial extent remove"
echo ""
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
dax_dev=$(create_dax_dev ${region})

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |--------|                                              |
# |         | (base) |                                              |
# |         |    |---|                                              |
#                  Partial

partial_ext_dpa="$(($base_ext_dpa + ($base_ext_length / 2)))"
partial_ext_length="$(($base_ext_length / 2))"
echo "Removing Partial : $partial_ext_dpa $partial_ext_length"
remove_extent ${device} $partial_ext_dpa $partial_ext_length
check_extent_cnt ${region} 1
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}

# In-use extents are not released.  Remove after use.
check_extent_cnt ${region} 1
remove_extent ${device} $partial_ext_dpa $partial_ext_length
check_extent_cnt ${region} 0

# Test multiple extent remove
echo ""
echo "Test: multiple extent remove with single extent remove command"
echo ""
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag
check_extent_cnt ${region} 2
dax_dev=$(create_dax_dev ${region})

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |--------|          |-------------------|               |
# |         | (base) |          | (pre)-existing    |               |
#                |------------------|
#                  Partial

partial_ext_dpa="$(($base_ext_dpa + ($base_ext_length / 2)))"
partial_ext_length="$(($pre_ext_dpa - $base_ext_dpa))"
echo "Removing multiple in span : $partial_ext_dpa $partial_ext_length"
remove_extent ${device} $partial_ext_dpa $partial_ext_length
check_extent_cnt ${region} 2
destroy_dax_dev ${dax_dev}
check_not_dax_dev ${region} ${dax_dev}

# Test extent create and region destroy without extent removal
echo ""
echo "Test: Destroy region without extent removal"
echo ""

# In-use extents are not released.
check_extent_cnt ${region} 2
destroy_region ${region}
check_not_region ${region}


echo ""
echo "Test: Destroy region with extents and dax devices"
echo ""
region=$(create_dcd_region ${mem} ${decoder})
check_region ${region}
check_extent_cnt ${region} 0
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |                   |----------|                        |
# |         |                   | (pre)-   |                        |
# |         |                   | existing |                        |

check_extent_cnt ${region} 1
dax_dev=$(create_dax_dev ${region})
destroy_region ${region}
check_not_region ${region}

echo ""
echo "Test: Fail sparse dax dev creation without space"
echo ""
region=$(create_dcd_region ${mem} ${decoder})
check_region ${region}
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |                   |-------------------|               |
# |         |                   | (pre)-existing    |               |

check_extent_cnt ${region} 1

# |         |                   | dax0.1            |               |

dax_dev=$(create_dax_dev ${region})
check_dax_dev ${dax_dev} $pre_ext_length
fail_create_dax_dev ${region}

echo ""
echo "Test: Resize sparse dax device"
echo ""

# Shrink
# |         |                   | dax0.1  |                         |
resize_ext_length=$(($pre_ext_length / 2))
shrink_dax_dev ${dax_dev} $resize_ext_length
check_dax_dev ${dax_dev} $resize_ext_length

# Fill
# |         |                   | dax0.1  | dax0.2  |               |
dax_dev=$(create_dax_dev ${region})
check_dax_dev ${dax_dev} $resize_ext_length
destroy_region ${region}
check_not_region ${region}


# 2 extent
# create dax dev
# resize into 1st extent
# create dev on rest of 1st and all of second
# Ensure both devices are correct

echo ""
echo "Test: Resize sparse dax device across extents"
echo ""
region=$(create_dcd_region ${mem} ${decoder})
check_region ${region}
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag
inject_extent ${device} $base_ext_dpa $base_ext_length $test_tag

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |--------|          |-------------------|               |
# |         | (base) |          | (pre)-existing    |               |

check_extent_cnt ${region} 2
dax_dev=$(create_dax_dev ${region})
ext_sum_length="$(($base_ext_length + $pre_ext_length))"

# |         | dax0.1 |          |  dax0.1           |               |

check_dax_dev ${dax_dev} $ext_sum_length
resize_ext_length=33554432 # 32MB

# |         | D1 |                                                  |

shrink_dax_dev ${dax_dev} $resize_ext_length
check_dax_dev ${dax_dev} $resize_ext_length

# |         | D1 | D2|          | dax0.2            |               |

dax_dev=$(create_dax_dev ${region})
remainder_length=$((ext_sum_length - $resize_ext_length))
check_dax_dev ${dax_dev} $remainder_length

# |         | D1 | D2|          | dax0.2 |                          |

remainder_length=$((remainder_length / 2))
shrink_dax_dev ${dax_dev} $remainder_length
check_dax_dev ${dax_dev} $remainder_length

# |         | D1 | D2|          | dax0.2 |  dax0.3  |               |

dax_dev=$(create_dax_dev ${region})
check_dax_dev ${dax_dev} $remainder_length
destroy_region ${region}
check_not_region ${region}


echo ""
echo "Test: Rejecting overlapping extents"
echo ""

region=$(create_dcd_region ${mem} ${decoder})
check_region ${region}
inject_extent ${device} $pre_ext_dpa $pre_ext_length $test_tag

# | 2G non- |      DC region                                        |
# |  DC cap |                                                       |
# |  ...    |-------------------------------------------------------|
# |         |                   |-------------------|               |
# |         |                   | (pre)-existing    |               |

check_extent_cnt ${region} 1

# Attempt overlapping extent
#
# |         |          |-----------------|                          |
# |         |          | overlapping     |                          |

partial_ext_dpa="$(($base_ext_dpa + ($pre_ext_dpa / 2)))"
partial_ext_length=$pre_ext_length
inject_extent ${device} $partial_ext_dpa $partial_ext_length $test_tag

# Should only see the original ext
check_extent_cnt ${region} 1
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
