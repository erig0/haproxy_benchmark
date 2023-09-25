#!/bin/sh
#
# SPDX-License-Identifier: MIT
#
set -e

. "$(dirname $(readlink -f ${0}))/common.sh"

install_nginx_async() {
	command -v nginx >/dev/null 2>&1 && return

	status "building and installing nginx-async"
	rpm -q -i zlib-devel >/dev/null || dnf -y install zlib-devel
	wget https://github.com/intel/asynch_mode_nginx/archive/refs/tags/v0.5.1.tar.gz
	tar xf v0.5.1.tar.gz
	cd asynch_mode_nginx-0.5.1
	./configure --prefix=/usr --without-http_rewrite_module --with-http_ssl_module --add-dynamic-module=modules/nginx_qat_module/ --with-cc-opt="-DNGX_SECURE_MEM -I/include -Wno-error=deprecated-declarations" --with-ld-opt="-L/src"
	make
	make install
	cd -
}

cleanup_nginx_async() {
	killall nginx &>/dev/null || true
	cleanup
}

start_nginx_async() {
	cat > nginx.conf <<-HERE
		worker_processes  ${NUM_PROXY_THREADS};
	    	$(test -n "${USE_CPU_PINNING}" && echo "
		worker_cpu_affinity auto;
		")

	    	$(test -n "${USE_QATENGINE}" && echo '
		load_module /usr/modules/ngx_ssl_engine_qat_module.so;
		ssl_engine {
		    use_engine qatengine;
		    default_algorithms ALL;
		}
		')

		events {
		    worker_connections 2000000;
		}

		http {
		upstream backend {
		    $(for I in $(seq ${NUM_HTTPD_INSTANCES}); do echo "
		    server 10.111.${I}.2:8080;
		    ";
		    done)
		}

		server {
		    $(for I in $(seq ${NUM_HTTPC_INSTANCES}); do echo "
		    listen 10.222.${I}.1:8080;
		    ";
		    done)

		    location /index.html {
		        proxy_pass http://backend;
		    }
		}

		server {
		    $(for I in $(seq ${NUM_HTTPC_INSTANCES}); do echo "
		    listen 10.222.${I}.1:4443 ssl;
		    ";
		    done)

		    ssl_asynch on;
		    ssl_protocols ${TLS_VERSION};
		    $(test -n "${TLS_CIPHER}" && {
		      test "${TLS_VERSION}" = "TLSv1.3" && echo "
		    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA384;
		    ssl_conf_command Ciphersuites ${TLS_CIPHER};
		    " || echo "
		    ssl_ciphers ${TLS_CIPHER};
		    "; })
		    ssl_certificate $(pwd)/testing.crt;
		    ssl_certificate_key $(pwd)/testing.key;

		    location /index.html {
		        proxy_pass http://backend;
		    }
		}
		}
	HERE

	status "Starting nginx-async"
	ip netns exec proxy nginx -c $(pwd)/nginx.conf

	# give qatengine time to start
	if test -n "${USE_QATENGINE}"; then
		status "Allowing qatengine time to start (30s)"
		sleep 30
	fi
}

main() {
	install_nginx_async
	setup
	start_nginx_async
	sanity_check

	benchmark_proxy_ab
	show_results
}

trap cleanup_nginx_async EXIT
main
