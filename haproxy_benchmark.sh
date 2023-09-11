#!/bin/sh
#
# SPDX-License-Identifier: MIT
#
# This script benchmarks HAProxy in the below topology. The goal is to stress
# the HAProxy SSL termination by scaling the number of HTTPS clients. The
# document returned is trivial in size.
#
#       client-1 (NS)          client-N (NS)
#       +----------+           +----------+  
#       |   https  |           |   https  |
#       |  client  |    ...    |  client  |
#       |          |           |          |
#       +----------+           +----------+
#                 \              /
#                  \     SSL    /
#                   \   HTTPS  /
#                    \        /
#                     haproxy (NS)
#                   +----------+
#                   |          |
#                   |  HAProxy |
#                   |          |
#                   +----------+
#                     /      \
#                    /  HTTP  \
#                   /          \
#                  /            \
#           app-1 (NS)          app-N (NS)
#         +----------+        +----------+
#         |   http   |        |   http   |
#         |  server  |  ...   |  server  |
#         | (apache) |        | (apache) |
#         +----------+        +----------+
#
set -e

# These are benchmark tunables that may affect the results of the benchmark.
# They may be changed independently.
#
# general
USE_QATENGINE=1
NUM_RUNS=10 # to produce mean and stddev
DURATION=60
# XXX: TLSv1.3 requires ApacheBench from httpd 2.5.0 or later, as of 2023-08-25 that's "trunk"
TLS_VERSION="TLSv1.2" # TLSv1.2 or TLSv1.3
#TLS_CIPHER="ECDHE-RSA-AES128-GCM-SHA256" # empty means use default
# scale http and haproxy
NUM_HTTPD_INSTANCES=8
NUM_HTTPC_INSTANCES=16
CLIENT_REQS_PER_SEC=1024
NUM_HAPROXY_THREADS=1
# simulated network latency/jitter/loss
NETWORK_LATENCY=50 # empty disables all network simulation
NETWORK_JITTER=20
NETWORK_QUEUE_LIMIT=$(expr ${CLIENT_REQS_PER_SEC} \* 2)
NETWORK_LOSS_PERCENT=1

status() {
	echo ">>> $@"
}

install_dependencies() {
	rpm -q -i haproxy >/dev/null || dnf -y install haproxy
	rpm -q -i httpd >/dev/null || dnf -y install httpd
	rpm -q -i httpd-tools >/dev/null || dnf -y install httpd-tools

	if test -n "${NETWORK_LATENCY}"; then
		rpm -q -i kernel-modules-extra >/dev/null || dnf -y install kernel-modules-extra
	fi

	if test -n "${USE_QATENGINE}"; then
		rpm -q -i qatengine >/dev/null || dnf -y install qatengine

		grep "intel_iommu=on" /proc/cmdline || {
			echo "kernel cmdline must contain intel_iommu=on, please add and reboot"
			exit 1
		}
	fi
}

set_system_limits() {
	ulimit -n 999999999
}

cleanup() {
	killall haproxy &>/dev/null || true
	killall httpd &>/dev/null || true

	ip netns delete haproxy &>/dev/null || true

	for I in $(seq ${NUM_HTTPD_INSTANCES}); do
		ip netns delete app${I} &>/dev/null || true
	done
	for I in $(seq ${NUM_HTTPC_INSTANCES}); do
		ip netns delete client${I} &>/dev/null || true
	done
}

create_topology() {
	ip netns add haproxy

	for I in $(seq ${NUM_HTTPD_INSTANCES}); do
		ip link add app${I}-ha type veth peer name app${I}

		ip netns add app${I}

		ip link set app${I} netns app${I}
		ip netns exec app${I} ip link set app${I} up
		ip netns exec app${I} ip addr add 10.111.${I}.2/24 dev app${I}

		ip link set app${I}-ha netns haproxy
		ip netns exec haproxy ip link set app${I}-ha up
		ip netns exec haproxy ip addr add 10.111.${I}.1/24 dev app${I}-ha
	done

	for I in $(seq ${NUM_HTTPC_INSTANCES}); do
		ip link add client${I}-ha type veth peer name client${I}

		ip netns add client${I}

		ip link set client${I} netns client${I}
		ip netns exec client${I} ip link set client${I} up
		ip netns exec client${I} ip addr add 10.222.${I}.2/24 dev client${I}

		ip link set client${I}-ha netns haproxy
		ip netns exec haproxy ip link set client${I}-ha up
		ip netns exec haproxy ip addr add 10.222.${I}.1/24 dev client${I}-ha

		# simulate a real network
		if test -n "${NETWORK_LATENCY}"; then
			ip netns exec client${I} tc qdisc add dev client${I} root netem limit ${NETWORK_QUEUE_LIMIT} delay ${NETWORK_LATENCY}ms ${NETWORK_JITTER}ms loss random ${NETWORK_LOSS_PERCENT}
			ip netns exec haproxy tc qdisc add dev client${I}-ha root netem limit ${NETWORK_QUEUE_LIMIT} delay ${NETWORK_LATENCY}ms ${NETWORK_JITTER}ms loss random ${NETWORK_LOSS_PERCENT}
		fi
	done
}

create_ssl_cert() {
	openssl req -x509 -newkey rsa:2048 -keyout ./testing.key -out ./testing.crt -sha256 -days 1 -nodes -subj "/C=XX/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=CommonNameOrHostname"
	cat ./testing.crt ./testing.key > ./testing.pem
}

start_httpd() {
	echo "Hello World!" > index.html

	for I in $(seq ${NUM_HTTPD_INSTANCES}); do
		cat > httpd-app-${I}.conf <<-HERE
			ServerName 10.111.${I}.2
			Listen 8080
			DocumentRoot "$(pwd)"
			LoadModule mpm_event_module /usr/lib64/httpd/modules/mod_mpm_event.so
			LoadModule unixd_module /usr/lib64/httpd/modules/mod_unixd.so
			LoadModule authz_core_module /usr/lib64/httpd/modules/mod_authz_core.so
			ErrorLog httpd-app-${I}.log
			PidFile httpd-app-${I}.pid
		HERE

		ip netns exec app${I} httpd -d $(pwd) -f httpd-app-${I}.conf &
	done
}

start_haproxy() {
	cat > haproxy.cfg <<-HERE
		global
		    daemon
		    $(test -n "${USE_QATENGINE}" && echo '
		    ssl-engine qatengine algo ALL
		    ssl-mode-async
		    ')
		    ssl-default-bind-options ssl-min-ver ${TLS_VERSION} ssl-max-ver ${TLS_VERSION}
		    $(test -n "${TLS_CIPHER}" && {
		    test "${TLS_VERSION}" = "TLSv1.3" && echo "
		    ssl-default-bind-ciphersuites ${TLS_CIPHER}
		    " || echo "
		    ssl-default-bind-ciphers ${TLS_CIPHER}
		    "; })
		    nbthread ${NUM_HAPROXY_THREADS}
		    maxconn 2000000

		defaults
		    mode                    http
		    timeout http-request    10s
		    timeout queue           1m
		    timeout connect         10s
		    timeout client          1m
		    timeout server          1m
		    timeout http-keep-alive 10s
		    timeout check           10s

		frontend main
		$(for I in $(seq ${NUM_HTTPC_INSTANCES}); do echo "
		    bind 10.222.${I}.1:8080
		    bind 10.222.${I}.1:4443 ssl crt $(pwd)/testing.pem
		    ";
	    	done)
		    default_backend             app

		backend app
		    balance     roundrobin
		$(for I in $(seq ${NUM_HTTPD_INSTANCES}); do echo "
		    server  app${I} 10.111.${I}.2:8080";
		done)
	HERE

	status "Starting HAProxy"
	if test ${NUM_HAPROXY_THREADS} -eq 1; then
		ip netns exec haproxy taskset -c 2 haproxy -f ./haproxy.cfg
	else
		ip netns exec haproxy haproxy -f ./haproxy.cfg
	fi
}

benchmark_haproxy_ab() {
	rm ./aggregates &>/dev/null || true
	for run in $(seq ${NUM_RUNS}); do
		status "Running benchmark, run ${run} of ${NUM_RUNS}"
		PIDS=""
		for I in $(seq ${NUM_HTTPC_INSTANCES}); do
			#ip netns exec client${I} ab -c ${CLIENT_REQS_PER_SEC} -n $(expr ${CLIENT_REQS_PER_SEC} \* $(expr ${DURATION} + 10)) -t ${DURATION} "http://10.222.${I}.1:8080/index.html" > ab-${I}.txt 2>&1 &
			ip netns exec client${I} ab -f $(echo ${TLS_VERSION} |tr -d 'v') -E $(pwd)/testing.pem -c ${CLIENT_REQS_PER_SEC} -n $(expr ${CLIENT_REQS_PER_SEC} \* $(expr ${DURATION} + 10)) -t ${DURATION} "https://10.222.${I}.1:4443/index.html" > ab-${I}.txt 2>&1 &
			PIDS="${PIDS} $!"
		done
		wait ${PIDS}

		bc <<-HERE >> ./aggregates
			$(for I in $(seq ${NUM_HTTPC_INSTANCES}); do
				awk '/^Requests per second:/{ printf "%s + ", $4 };d' ab-${I}.txt
			done) 0
		HERE

		status "Letting HAProxy drain connections"
		rm ab-*.txt
		sleep ${DURATION} # drain connections; since we don't restart haproxy
	done

	bc <<-HERE > ./mean
		scale=2
		($(cat ./aggregates |while read LINE; do
			printf "${LINE} + "
		done) 0) / ${NUM_RUNS}
	HERE

	bc <<-HERE > ./stddev
		scale=2
		sqrt( ($(cat ./aggregates |while read LINE; do
			printf "(${LINE} - $(cat ./mean))^2 + "
			done) 0) / (${NUM_RUNS} - 1) )
	HERE
}

setup() {
	status "Setting up test environment"
	install_dependencies
	if test -n "${USE_QATENGINE}"; then
		setenforce 0 # needed if newer qatengine and old SELinux policies
		systemctl start qat
	fi
	set_system_limits

	create_topology
	create_ssl_cert

	start_httpd
	start_haproxy
	sleep 3 # to allow listen() etc. to complete
}

sanity_check() {
	status "Sanity checking test setup"
	# httpd instances
	for I in $(seq ${NUM_HTTPD_INSTANCES}); do
		ip netns exec haproxy curl "http://10.111.${I}.2:8080/index.html" 2>&1 |grep "Hello World" >/dev/null
	done

	# haproxy
	for I in $(seq ${NUM_HTTPC_INSTANCES}); do
		ip netns exec client${I} curl "http://10.222.${I}.1:8080/index.html" 2>&1 |grep "Hello World" >/dev/null
		ip netns exec client${I} curl --insecure --$(echo "${TLS_VERSION}" |tr 'TLS' 'tls') "https://10.222.${I}.1:4443/index.html" 2>&1 |grep "Hello World" >/dev/null
	done
}

show_results() {
	printf "\n"
	printf "${NUM_RUNS} test runs of ${DURATION} seconds each\n"
	printf "${NUM_HAPROXY_THREADS} haproxy threads\n"
	printf "${NUM_HTTPD_INSTANCES} servers, ${NUM_HTTPC_INSTANCES} clients at ${CLIENT_REQS_PER_SEC} requests per second\n"
	if test -n "${NETWORK_LATENCY}"; then
		printf "simulated network latency ${NETWORK_LATENCY}ms, jitter ${NETWORK_JITTER}ms, loss ${NETWORK_LOSS_PERCENT}%%\n"
	fi
	printf "\n"
	printf "Requests Per Second (mean): %s\n" $(cat ./mean)
	printf "stddev: %s\n" $(cat ./stddev)
}

#################
#################

trap cleanup EXIT

setup
sanity_check

benchmark_haproxy_ab
show_results
