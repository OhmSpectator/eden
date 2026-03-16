#!/bin/bash
# Reset Eden to a clean state with stock monolithic EVE (15.11.0)
set -e

cd "$(dirname "$0")"

echo "=== Stopping Eden ==="
./eden stop 2>/dev/null || true
docker rm -f eden_adam eden_redis eden_registry eden_eserver 2>/dev/null || true

echo "=== Cleaning state ==="
rm -rf dist/default-* ~/.eden

echo "=== Configuring ==="
./eden config add default
./eden config set default --key=eve.accel --value=true
./eden config set default --key=eve.tpm --value=true
./dist/bin/eden+ports.sh 2223:2223 2224:2224 5912:5902 5911:5901 \
    8027:8027 8028:8028 8029:8029 8030:8030 8031:8031

echo "=== Setup (downloading 15.11.0) ==="
./eden setup

echo "=== Starting ==="
./eden start

echo "=== Onboarding ==="
./eden eve onboard

echo "=== Ready ==="
./eden eve status
