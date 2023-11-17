#!/bin/bash
# This script will apply traffic shaping on LAN interfaces of LAB gateway
# in order to simulate low bandwidth and high latency satellite links.
# Two pair of values are provided to apply traffic shaping for two different source/destination IPs,
# in order to simulate dual satellite scenarios.
# ingress queueing is applied to limit upload speeds.

TC='/sbin/tc'
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

timestamp=`date +"%b %d %H:%M:%S"`
log=/var/log/shaper
base=`basename "$0"`

# Interfaces to apply traffic shaping
WAN=enp2s0
SAT1=enp3s0
SAT2=enp4s0

# Define you link characteristics below and the WAN IP of the client device you need to shape.
# Satellite 1
down1=128kbit
up1=128kbit
latency1=1000ms
deviation1=100ms
packet_loss1=3%
# The IP of the client WAN1 port
WANIP1=192.168.28.64

# Satellite 2
down2=512kbit
up2=256kbit
latency2=700ms
deviation2=60ms
packet_loss2=0%
# The IP of the client WAN2 port
WANIP2=192.168.29.64

echo "$timestamp: $base: traffic shaper started" >> $log

# Do the job
if [ "${1}" = "clear" ];then
	for DEV in {$SAT1,$SAT2};do
		echo "Cleaning traffic queues on interface $DEV"
		tc qdisc del dev $DEV root > /dev/null 2>&1
		tc qdisc del dev ifb0 root > /dev/null 2>&1
	done
	exit 0
else
	for DEV in $SAT1;do

		echo "Applying traffic shaping at interface: " $DEV
		tc qdisc del dev $DEV root > /dev/null 2>&1 || echo error at line $LINENO

		tc qdisc add dev $DEV parent root handle 1: hfsc default 10 || echo error at line $LINENO
		tc class add dev $DEV parent 1: classid 1:1 hfsc ls rate 100mbit ul rate 100mbit || echo error at line $LINENO
		tc class add dev $DEV parent 1:1 classid 1:10 hfsc ls rate 90mbit ul rate 90mbit || echo error at line $LINENO

		tc class add dev $DEV parent 1:1 classid 1:11 hfsc ls rate "${down1}" ul rate "${down1}" || echo error at line $LINENO
		tc qdisc add dev $DEV parent 1:11 handle 20 netem delay "${latency1}" $deviation1 loss "${packet_loss1}" || echo error at line $LINENO

		tc class add dev $DEV parent 1:1 classid 1:12 hfsc ls rate "${down2}" ul rate "${down2}" || echo error at line $LINENO
		tc qdisc add dev $DEV parent 1:12 handle 30 netem delay "${latency2}" $deviation2 loss "${packet_loss2}" || echo error at line $LINENO

		# All classes get stochastic fairness
		tc qdisc add dev $DEV parent 1:10 handle 100: sfq perturb 10 || echo error at line ${LINENO}
		tc qdisc add dev $DEV parent 20: handle 101: sfq perturb 10 || echo error at line ${LINENO}
		tc qdisc add dev $DEV parent 30: handle 102: sfq perturb 10 || echo error at line ${LINENO}

		# Ingress queueing to limit upload from LAN
		ip link set dev ifb0 down
		modprobe ifb numifbs=1
		ip link set dev ifb0 up

		# Start clean
		tc qdisc del dev $DEV ingress > /dev/null 2>&1
		tc qdisc del dev ifb0 root > /dev/null 2>&1

		tc qdisc add dev $DEV handle ffff: ingress

		# Limit incoming traffic on internal LAN interface: limit upload
		tc qdisc add dev ifb0 parent root handle 2: hfsc default 10 || echo error at line $LINENO
		tc class add dev ifb0 parent 2: classid 2:1 hfsc ls rate 100mbit ul rate 100mbit || echo error at line $LINENO
		tc class add dev ifb0 parent 2:1 classid 2:10 hfsc ls rate 90mbit ul rate 90mbit || echo error at line $LINENO
		tc class add dev ifb0 parent 2:1 classid 2:11 hfsc ls rate "${up1}" ul rate "${up1}" || echo error at line $LINENO
		tc class add dev ifb0 parent 2:1 classid 2:12 hfsc ls rate "${up2}" ul rate "${up2}" || echo error at line $LINENO

		tc qdisc add dev ifb0 parent 2:10 handle 200: sfq perturb 10 || echo error at line $LINENO
		tc qdisc add dev ifb0 parent 2:11 handle 201: sfq perturb 10 || echo error at line $LINENO
		tc qdisc add dev ifb0 parent 2:12 handle 202: sfq perturb 10 || echo error at line $LINENO

		# Satellite 1
		# Limit Download
		tc filter add dev $DEV parent 1: protocol ip u32 match ip dst "${WANIP1}" flowid 1:11 || echo error at line $LINENO
		# Limit Upload
		tc filter add dev $DEV parent ffff: protocol ip u32 match ip src "${WANIP1}" action mirred egress redirect dev ifb0
		tc filter add dev ifb0 parent 2: protocol ip u32 match ip src "${WANIP1}" flowid 2:11 || echo error at line $LINENO

		# Satellite 2
		# Limit Download
		tc filter add dev $DEV parent 1: protocol ip u32 match ip dst "${WANIP2}" flowid 1:12 || echo error at line $LINENO
		# Limit Upload
		tc filter add dev $DEV parent ffff: protocol ip u32 match ip src "${WANIP2}" action mirred egress redirect dev ifb0
		tc filter add dev ifb0 parent 2: protocol ip u32 match ip src "${WANIP2}" flowid 2:12 || echo error at line $LINENO
	done
fi

echo "$timestamp: $base: traffic shaper completed" >> $log
