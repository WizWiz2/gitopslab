#!/usr/bin/env bash
status_code="0"
url="$1"

# Wait for 5 minutes max
timeout=300

while true; do
    status_code=$(curl --write-out "%{http_code}" --silent --output /dev/null "$url")
    if [[ "$status_code" -ge 200 && "$status_code" -lt 400 ]] ; then
        break
    fi
    if [[ "$timeout" -le 0 ]]; then
        echo "Timeout waiting for $url"
        exit 1
    fi
    echo "Waiting for $url ($status_code)..."
    sleep 5
    timeout=$((timeout - 5))
done
