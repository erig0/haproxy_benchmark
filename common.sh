# SPDX-License-Identifier: MIT
#
# This script benchmarks an http proxy in the below topology. The goal is to
# stress the proxy's SSL termination by scaling the number of HTTPS clients.
# The document returned is trivial in size.
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
#                     proxy (NS)
#                   +----------+
#                   |          |
#                   |  proxy   |
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

# These are benchmark tunables that may affect the results of the benchmark.
# They may be changed independently.
#
# general
USE_QATENGINE=
USE_CPU_PINNING=1
NUM_RUNS=10 # to produce mean and stddev
DURATION=60
# XXX: TLSv1.3 requires ApacheBench from httpd 2.5.0 or later, as of 2023-08-25 that's "trunk"
TLS_VERSION="TLSv1.2" # TLSv1.2 or TLSv1.3
TLS_CIPHER="ECDHE-RSA-AES256-GCM-SHA384" # empty means use default
# scale http and proxy
NUM_HTTPD_INSTANCES=8
NUM_HTTPC_INSTANCES=16
CLIENT_REQS_PER_SEC=1024
NUM_PROXY_THREADS=4
# simulated network latency/jitter/loss
NETWORK_LATENCY=50 # empty disables all network simulation
NETWORK_JITTER=4
NETWORK_QUEUE_LIMIT=$(expr ${CLIENT_REQS_PER_SEC} \* 2)
NETWORK_LOSS_PERCENT=0.1

status() {
	echo ">>> $@"
}

install_dependencies() {
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
	ulimit -l unlimited
}

cleanup() {
	killall httpd &>/dev/null || true

	ip netns delete proxy &>/dev/null || true

	for I in $(seq ${NUM_HTTPD_INSTANCES}); do
		ip netns delete app${I} &>/dev/null || true
	done
	for I in $(seq ${NUM_HTTPC_INSTANCES}); do
		ip netns delete client${I} &>/dev/null || true
	done
}

create_topology() {
	ip netns add proxy

	for I in $(seq ${NUM_HTTPD_INSTANCES}); do
		ip link add app${I}-ha type veth peer name app${I}

		ip netns add app${I}

		ip link set app${I} netns app${I}
		ip netns exec app${I} ip link set app${I} up
		ip netns exec app${I} ip addr add 10.111.${I}.2/24 dev app${I}

		ip link set app${I}-ha netns proxy
		ip netns exec proxy ip link set app${I}-ha up
		ip netns exec proxy ip addr add 10.111.${I}.1/24 dev app${I}-ha
	done

	for I in $(seq ${NUM_HTTPC_INSTANCES}); do
		ip link add client${I}-ha type veth peer name client${I}

		ip netns add client${I}

		ip link set client${I} netns client${I}
		ip netns exec client${I} ip link set client${I} up
		ip netns exec client${I} ip addr add 10.222.${I}.2/24 dev client${I}

		ip link set client${I}-ha netns proxy
		ip netns exec proxy ip link set client${I}-ha up
		ip netns exec proxy ip addr add 10.222.${I}.1/24 dev client${I}-ha

		# simulate a real network
		if test -n "${NETWORK_LATENCY}"; then
			ip netns exec client${I} tc qdisc add dev client${I} root netem limit ${NETWORK_QUEUE_LIMIT} delay $(expr ${NETWORK_LATENCY} / 2)ms $(expr ${NETWORK_JITTER} / 2)ms loss random ${NETWORK_LOSS_PERCENT}
			ip netns exec proxy tc qdisc add dev client${I}-ha root netem limit ${NETWORK_QUEUE_LIMIT} delay $(expr ${NETWORK_LATENCY} / 2)ms $(expr ${NETWORK_JITTER} / 2)ms loss random ${NETWORK_LOSS_PERCENT}
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

		CMD="ip netns exec app${I} "
		if test -n "${USE_CPU_PINNING}"; then
			CMD="${CMD} taskset -c $(expr ${NUM_PROXY_THREADS} + ${I})"
		fi
		${CMD} httpd -d $(pwd) -f httpd-app-${I}.conf &
	done
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
}

sanity_check() {
	status "Sanity checking test setup"
	# httpd instances
	for I in $(seq ${NUM_HTTPD_INSTANCES}); do
		ip netns exec proxy curl --retry 3 "http://10.111.${I}.2:8080/index.html" 2>&1 |grep "Hello World" >/dev/null
	done

	# proxy
	for I in $(seq ${NUM_HTTPC_INSTANCES}); do
		ip netns exec client${I} curl --retry 3 "http://10.222.${I}.1:8080/index.html" 2>&1 |grep "Hello World" >/dev/null
		ip netns exec client${I} curl --retry 3 --insecure --$(echo "${TLS_VERSION}" |tr 'TLS' 'tls') "https://10.222.${I}.1:4443/index.html" 2>&1 |grep "Hello World" >/dev/null
	done

	if test -n "${USE_CPU_PINNING}" && test $(nproc) -lt $(expr ${NUM_PROXY_THREADS} + ${NUM_HTTPD_INSTANCES} + ${NUM_HTTPC_INSTANCES}); then
		printf "Cannot use CPU pinning because there are not enough CPU."
		printf "Need %d for proxy, %d for httpd, %d https clients." ${NUM_PROXY_THREADS} ${NUM_HTTPD_INSTANCES} ${NUM_HTTPC_INSTANCES}
		exit 1
	fi
}

benchmark_proxy_ab() {
	rm ./aggregates &>/dev/null || true
	for run in $(seq ${NUM_RUNS}); do
		status "Running benchmark, run ${run} of ${NUM_RUNS}"
		PIDS=""
		for I in $(seq ${NUM_HTTPC_INSTANCES}); do
			CMD="ip netns exec client${I}"
			if test -n "${USE_CPU_PINNING}"; then
				CMD="${CMD} taskset -c $(expr ${NUM_PROXY_THREADS} + ${NUM_HTTPD_INSTANCES} + ${I})"
			fi
			#${CMD} ab -c ${CLIENT_REQS_PER_SEC} -n $(expr ${CLIENT_REQS_PER_SEC} \* $(expr ${DURATION} + 10)) -t ${DURATION} "http://10.222.${I}.1:8080/index.html" > ab-${I}.txt 2>&1 &
			${CMD} ab -f $(echo ${TLS_VERSION} |tr -d 'v') -E $(pwd)/testing.pem -c ${CLIENT_REQS_PER_SEC} -n $(expr ${CLIENT_REQS_PER_SEC} \* $(expr ${DURATION} + 10)) -t ${DURATION} "https://10.222.${I}.1:4443/index.html" > ab-${I}.txt 2>&1 &
			PIDS="${PIDS} $!"
		done
		wait ${PIDS}

		bc <<-HERE >> ./aggregates
			$(for I in $(seq ${NUM_HTTPC_INSTANCES}); do
				awk '/^Requests per second:/{ printf "%s + ", $4 };d' ab-${I}.txt
			done) 0
		HERE

		status "Letting proxy drain connections"
		rm ab-*.txt
		sleep ${DURATION} # drain connections; since we don't restart proxy
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

show_results() {
	printf "\n"
	printf "${NUM_RUNS} test runs of ${DURATION} seconds each\n"
	printf "${NUM_PROXY_THREADS} proxy threads\n"
	printf "${NUM_HTTPD_INSTANCES} servers, ${NUM_HTTPC_INSTANCES} clients at ${CLIENT_REQS_PER_SEC} requests per second\n"
	if test -n "${NETWORK_LATENCY}"; then
		printf "simulated network latency ${NETWORK_LATENCY}ms, jitter ${NETWORK_JITTER}ms, loss ${NETWORK_LOSS_PERCENT}%%\n"
	fi
	if test -n "${USE_CPU_PINNING}"; then
		printf "CPU pinning is enabled.\n"
		printf "proxy using CPUs: 1-${NUM_PROXY_THREADS}\n"
		printf "httpd using CPUs: $(expr ${NUM_PROXY_THREADS} + 1)-$(expr ${NUM_PROXY_THREADS} + ${NUM_HTTPD_INSTANCES})\n"
		printf "https clients using CPUs: $(expr ${NUM_PROXY_THREADS} + ${NUM_HTTPD_INSTANCES} + 1)-$(expr ${NUM_PROXY_THREADS} + ${NUM_HTTPD_INSTANCES} + ${NUM_HTTPC_INSTANCES})\n"
	fi
	printf "\n"
	printf "Requests Per Second (mean): %s\n" $(cat ./mean)
	printf "stddev: %s\n" $(cat ./stddev)
}
