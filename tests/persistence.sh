#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE=${NAMESPACE:-praxis-standalone}
RELEASE=${RELEASE:-praxis-gateway}
MODEL=${MODEL:-gpt-6-luna}
URL=http://127.0.0.1:18080
mkdir -p .cache
WORK=$(mktemp -d "$PWD/.cache/persistence.XXXXXX")
RESOURCES=()
PF_PID=

api() {
  local path=$1
  shift
  curl -sS --fail-with-body --noproxy '*' --connect-timeout 5 --max-time 360 "$URL$path" "$@"
}

post() {
  api "$1" -H 'Content-Type: application/json' -d "$2"
}

stop_port_forward() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=
  fi
}

start_port_forward() {
  oc -n "$NAMESPACE" port-forward "deployment/$RELEASE" \
    --address 127.0.0.1 18080:8080 19901:9901 >>"$WORK/port-forward.log" 2>&1 &
  PF_PID=$!
  for _ in {1..50}; do
    kill -0 "$PF_PID"
    if curl -fsS --noproxy '*' --max-time 1 http://127.0.0.1:19901/healthy >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  curl -fsS --noproxy '*' --max-time 2 http://127.0.0.1:19901/healthy >/dev/null
}

retained() {
  local path=$1
  shift
  if ! api "$path" >"$WORK/after.json" 2>/dev/null; then
    echo "State lost after restart: GET $path returned: $(jq -r '.error.message // "error"' "$WORK/after.json" 2>/dev/null)" >&2
    echo 'Stored state must not be on pod-local storage (STORE_BACKEND=sqlite loses it on restart).' >&2
    exit 1
  fi
  if ! jq -e "$@" "$WORK/after.json" >/dev/null; then
    echo "State changed after restart: GET $path (see $WORK/after.json)" >&2
    exit 1
  fi
}

cleanup() {
  local rc=$? i status
  for ((i=${#RESOURCES[@]}-1; i>=0; i--)); do
    # A 404 means the resource is already gone, e.g. after a failed restart check.
    status=$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 30 -o "$WORK/delete.json" \
      -w '%{http_code}' -X DELETE "$URL${RESOURCES[i]}" || true)
    if [[ $status != 404 ]] && ! jq -e '.deleted == true' "$WORK/delete.json" >/dev/null 2>&1; then
      echo "Cleanup failed: ${RESOURCES[i]}" >&2
      rc=1
    fi
  done
  stop_port_forward
  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
start_port_forward

echo 'Paid test: one Responses request, then a Praxis rollout restart.'
echo "Artifacts: $WORK"

echo 'Creating a Conversation and a stored Response'
CONVERSATION=$(post /v1/conversations '{"metadata":{"test":"persistence"}}' | jq -er '.id')
RESOURCES+=("/v1/conversations/$CONVERSATION")
CODE="persist-$RANDOM-$RANDOM"
post /v1/responses "$(jq -nc --arg model "$MODEL" --arg conversation "$CONVERSATION" \
  --arg input "Remember this code: $CODE. Reply only OK." '
  {model:$model,reasoning:{effort:"none"},store:true,max_output_tokens:256,
   conversation:$conversation,input:$input}')" >"$WORK/response.json"
RESPONSE_ID=$(jq -er '.id' "$WORK/response.json")
RESOURCES+=("/v1/responses/$RESPONSE_ID")
jq -e '.status == "completed"' "$WORK/response.json" >/dev/null
api "/v1/conversations/$CONVERSATION/items" >"$WORK/items-before.json"

OLD_POD=$(oc -n "$NAMESPACE" get pods \
  -l "app.kubernetes.io/name=praxis-gateway,app.kubernetes.io/instance=$RELEASE" \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
echo "Restarting Praxis (replacing pod $OLD_POD)"
stop_port_forward
oc -n "$NAMESPACE" rollout restart "deployment/$RELEASE" >/dev/null
oc -n "$NAMESPACE" rollout status "deployment/$RELEASE" --timeout=5m >/dev/null
oc -n "$NAMESPACE" wait "pod/$OLD_POD" --for=delete --timeout=2m >/dev/null
start_port_forward

echo 'Checking state after restart'
retained "/v1/conversations/$CONVERSATION" '.metadata.test == "persistence"'
retained "/v1/conversations/$CONVERSATION/items" --slurpfile before "$WORK/items-before.json" '
  .data == $before[0].data and any(.data[]; .role == "user") and any(.data[]; .role == "assistant")'
retained "/v1/responses/$RESPONSE_ID" --slurpfile response "$WORK/response.json" '
  .status == "completed" and .output == $response[0].output'
retained "/v1/responses/$RESPONSE_ID/input_items" --arg code "$CODE" '
  any(.data[]?.content[]?; (.text // "") | contains($code))'
echo 'Persistence test passed; deleting test resources and stopping port-forward.'
