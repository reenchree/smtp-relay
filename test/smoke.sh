#!/usr/bin/env bash
# Container smoke test: the built image, read-only rootfs, uid 65534, against a fake SES.
#   test/smoke.sh IMAGE [PLATFORM]
set -euo pipefail

image=${1:?usage: smoke.sh IMAGE [PLATFORM]}
platform=${2:-linux/amd64}
id=smoke-$$
here=$(cd "$(dirname "$0")" && pwd)

cleanup() {
  docker logs "relay-$id" >"${SMOKE_LOG:-/dev/null}" 2>&1 || true
  docker rm -f "relay-$id" "fakeses-$id" >/dev/null 2>&1 || true
  docker network rm "net-$id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "net-$id" >/dev/null
subnet=$(docker network inspect "net-$id" -f '{{(index .IPAM.Config 0).Subnet}}')
run=(docker run -d --platform "$platform" --network "net-$id" --read-only --user 65534:65534 --cap-drop ALL)

"${run[@]}" --name "fakeses-$id" -v "$here:/test:ro" --entrypoint bundle "$image" \
  exec ruby /test/fake_ses.rb >/dev/null
"${run[@]}" --name "relay-$id" \
  -e ALLOWED_FROM_DOMAIN=reenchree.dev -e ALLOWED_CIDRS="$subnet" -e MAX_BYTES=100000 \
  -e AWS_REGION=us-west-2 -e AWS_ACCESS_KEY_ID=smoke -e AWS_SECRET_ACCESS_KEY=smoke \
  -e AWS_ENDPOINT_URL_SESV2="http://fakeses-$id:4566" "$image" >/dev/null

for _ in $(seq 60); do
  docker logs "relay-$id" 2>&1 | grep -q listening && break
  sleep 1
done
sleep 2 # fake SES boot

docker run --rm --platform "$platform" --network "net-$id" --read-only --user 65534:65534 \
  -v "$here:/test:ro" --entrypoint ruby "$image" /test/smoke_client.rb "relay-$id" "fakeses-$id"

logs=$(docker logs "relay-$id" 2>&1)
if grep -q 'smoke-marker' <<<"$logs"; then
  echo "FAIL relay logged message content"
  exit 1
fi
echo "PASS relay logs contain no message content"
