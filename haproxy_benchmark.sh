#!/bin/sh
#
# SPDX-License-Identifier: MIT
#
set -e

. "$(dirname $(readlink -f ${0}))/common.sh"

install_haproxy() {
	rpm -q -i haproxy >/dev/null && return

	status "Installing HAProxy"
	dnf -y install haproxy
}

cleanup_haproxy() {
	killall haproxy &>/dev/null || true
	cleanup
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
		    nbthread ${NUM_PROXY_THREADS}
		    $(test -n "${USE_CPU_PINNING}" && echo "
		    cpu-map auto:1/1-${NUM_PROXY_THREADS} 1-${NUM_PROXY_THREADS}
		    ")
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
	ip netns exec proxy haproxy -f ./haproxy.cfg

	# give qatengine time to start
	if test -n "${USE_QATENGINE}"; then
		status "Allowing qatengine time to start (30s)"
		sleep 30
	fi
}

main() {
	install_haproxy
	setup
	start_haproxy
	sanity_check

	benchmark_proxy_ab
	show_results
}

trap cleanup_haproxy EXIT
main
