# haproxy_benchmark

This script is used to benchmark HAProxy (or asynch_mode_nginx) on a
single node. It will stress the proxy's TLS termination by default.

## Requirements

This script assumes it's running on RHEL-9.2 or later. It must be run as
root. It will install dependencies for tests.

## Usage

```
# sh haproxy_benchmark.sh
>>> Setting up test environment
[..]
>>> Starting HAProxy
>>> Sanity checking test setup
>>> Running benchmark, run 1 of 10
[..]
10 test runs of 60 seconds each
4 haproxy threads
8 servers, 16 clients at 1024 requests per second

Requests Per Second (mean): 9973.91
stddev: 226.69
```

## Tunables

There are some variables defined in `common.sh` that may change the test
behavior.

e.g.

- `USE_QATENGINE`
- `NETWORK_LATENCY`
- `NUM_PROXY_THREADS`
