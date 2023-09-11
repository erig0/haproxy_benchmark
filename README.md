# haproxy_benchmark

This script is used to benchmark HAProxy on a single node. It will
stress HAPorxy TLS termination by default.

## Requirements

This script assumes it's running on RHEL-9.2 or later. It must be run as
root. It will install dependencies for tests.

## Tunables

There are some variable defined in the script that may change the test
behavior.

e.g.

- `USE_QATENGINE`
- `NETWORK_LATENCY`
- `NUM_HAPROXY_THREADS`
