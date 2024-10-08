#!/bin/bash
# This script will apply traffic shaping on LAN interfaces of LAB gateway
# in order to simulate low bandwidth and high latency satellite links.
# Two pairs of values are provided to apply traffic shaping for two different source/destination IPs,
# in order to simulate dual satellite scenarios.
# Ingress queueing is applied to limit upload speeds at the special virtual interface ifb0.

TC='/sbin/tc'
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

timestamp=`date +"%b %d %H:%M:%S"`
log=/var/log/shaper
base=`basename "$0"`

# Interfaces
WAN=enp1s0 # This is the WAN interface for internet access
SATELLITE_IFS=('enp3s0') # This is a space sperated list of internal LAN interfaces where traffic shaping is applied to client devices. 

# Define you link characteristics below and the WAN IP of the client device you need to shape.
# Satellite 1
down1=128kbit
up1=128kbit
latency1=1900ms
deviation1=100ms
packet_loss1=3%
# The IP of the client WAN1 port
WANIP1=172.31.0.151

# Satellite 2
down2=512kbit
up2=256kbit
latency2=700ms
deviation2=60ms
packet_loss2=0%
# The IP of the client WAN2 port
WANIP2=192.168.29.64

print_help(){
		warn_print "Usage:"
		warn_print "$base <start|stop|stats|help>"
}

info_print()
{
    echo -e "\e[33m\e[36m$1\e[33m\e[0m"
}

warn_print()
{
    echo -e "\e[33m\e[33m$1\e[33m\e[0m"
}




# Do the job
case "${1}" in
	"stop")
		SATELLITE_IFS+=(ifb0)
		for DEV in "${SATELLITE_IFS[@]}" ;do
			info_print "Cleaning traffic queues on interface $DEV" | tee >> $log
			tc qdisc del dev $DEV root > /dev/null 2>&1
		done
		exit 0
		;;
	"stats")
		SATELLITE_IFS+=(ifb0)
		for DEV in "${SATELLITE_IFS[@]}";do
			info_print "QoS stats at interface $DEV" | tee >> $log
			tc -s qdisc show dev $DEV
		done
		exit 0
		;;
	"start")
		info_print "$timestamp: $base: traffic shaper started" | tee >> $log
		for DEV in "${SATELLITE_IFS[@]}";do

			info_print "Applying traffic shaping at interface: $DEV" | tee >> $log
			
			tc qdisc del dev $DEV root > /dev/null 2>&1

			tc qdisc add dev $DEV parent root handle 1: hfsc default 10 || warn_print error at line $LINENO
			tc class add dev $DEV parent 1: classid 1:1 hfsc ls rate 100mbit ul rate 100mbit || warn_print error at line $LINENO
			tc class add dev $DEV parent 1:1 classid 1:10 hfsc ls rate 90mbit ul rate 90mbit || warn_print error at line $LINENO

			tc class add dev $DEV parent 1:1 classid 1:11 hfsc ls rate "${down1}" ul rate "${down1}" || warn_print error at line $LINENO
			tc qdisc add dev $DEV parent 1:11 handle 20 netem delay "${latency1}" $deviation1 loss "${packet_loss1}" || warn_print error at line $LINENO

			tc class add dev $DEV parent 1:1 classid 1:12 hfsc ls rate "${down2}" ul rate "${down2}" || warn_print error at line $LINENO
			tc qdisc add dev $DEV parent 1:12 handle 30 netem delay "${latency2}" $deviation2 loss "${packet_loss2}" || warn_print error at line $LINENO

			# All classes get stochastic fairness
			tc qdisc add dev $DEV parent 1:10 handle 100: sfq perturb 10 || warn_print error at line ${LINENO}
			tc qdisc add dev $DEV parent 20: handle 101: sfq perturb 10 || warn_print error at line ${LINENO}
			tc qdisc add dev $DEV parent 30: handle 102: sfq perturb 10 || warn_print error at line ${LINENO}

			# Ingress queueing to limit upload from LAN
			ip link set dev ifb0 down
			modprobe ifb numifbs=1
			ip link set dev ifb0 up

			# Start clean
			tc qdisc del dev $DEV ingress > /dev/null 2>&1
			tc qdisc del dev ifb0 root > /dev/null 2>&1

			tc qdisc add dev $DEV handle ffff: ingress

			# Limit incoming traffic on internal LAN interface: limit upload
			tc qdisc add dev ifb0 parent root handle 2: hfsc default 10 || warn_print error at line $LINENO
			tc class add dev ifb0 parent 2: classid 2:1 hfsc ls rate 100mbit ul rate 100mbit || warn_print error at line $LINENO
			tc class add dev ifb0 parent 2:1 classid 2:10 hfsc ls rate 90mbit ul rate 90mbit || warn_print error at line $LINENO
			tc class add dev ifb0 parent 2:1 classid 2:11 hfsc ls rate "${up1}" ul rate "${up1}" || warn_print error at line $LINENO
			tc class add dev ifb0 parent 2:1 classid 2:12 hfsc ls rate "${up2}" ul rate "${up2}" || warn_print error at line $LINENO

			tc qdisc add dev ifb0 parent 2:10 handle 200: sfq perturb 10 || warn_print error at line $LINENO
			tc qdisc add dev ifb0 parent 2:11 handle 201: sfq perturb 10 || warn_print error at line $LINENO
			tc qdisc add dev ifb0 parent 2:12 handle 202: sfq perturb 10 || warn_print error at line $LINENO

			# Satellite 1
			# Limit Download
			tc filter add dev $DEV parent 1: protocol ip u32 match ip dst "${WANIP1}" flowid 1:11 || warn_print error at line $LINENO
			# Limit Upload
			tc filter add dev $DEV parent ffff: protocol ip u32 match ip src "${WANIP1}" action mirred egress redirect dev ifb0
			tc filter add dev ifb0 parent 2: protocol ip u32 match ip src "${WANIP1}" flowid 2:11 || warn_print error at line $LINENO

			# Satellite 2
			# Limit Download
			tc filter add dev $DEV parent 1: protocol ip u32 match ip dst "${WANIP2}" flowid 1:12 || warn_print error at line $LINENO
			# Limit Upload
			tc filter add dev $DEV parent ffff: protocol ip u32 match ip src "${WANIP2}" action mirred egress redirect dev ifb0
			tc filter add dev ifb0 parent 2: protocol ip u32 match ip src "${WANIP2}" flowid 2:12 || warn_print error at line $LINENO
		done
		info_print "$timestamp: $base: traffic shaper completed" >> $log
		;;
	"help")
		print_help;
		;;
	*)
		print_help;
		;;
esac

