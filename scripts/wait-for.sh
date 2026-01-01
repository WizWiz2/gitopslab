#!/bin/bash
set -e

# Helper script to wait for a service
# Usage: ./wait-for.sh <host> <port> <timeout_sec>

host="$1"
port="$2"
timeout="${3:-60}"

echo "Waiting for $host:$port (timeout: $timeout s)..."

start_ts=$(date +%s)
while :; do
    if nc -z "$host" "$port"; then
        echo "$host:$port is ready!"
        exit 0
    fi

    now_ts=$(date +%s)
    if [ $((now_ts - start_ts)) -ge "$timeout" ]; then
        echo "Timeout waiting for $host:$port"
        exit 1
    fi
    sleep 2
done
