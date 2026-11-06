#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE=${NAMESPACE:-praxis-standalone}
RELEASE=${RELEASE:-praxis-gateway}
MODEL=${MODEL:-gpt-6-luna}
EMBEDDING_MODEL=${EMBEDDING_MODEL:-vllm-embedding/Nomic-embed-text-v2-moe}
VECTOR_STORE_PROVIDER=${VECTOR_STORE_PROVIDER:-milvus-remote}
URL=http://127.0.0.1:18080
mkdir -p .cache
WORK=$(mktemp -d "$PWD/.cache/test.XXXXXX")
RESOURCES=()

api() {
  local path=$1
  shift
  curl -sS --fail-with-body --noproxy '*' --connect-timeout 5 --max-time 360 "$URL$path" "$@"
}

post() {
  api "$1" -H 'Content-Type: application/json' -d "$2"
}

cleanup() {
  local rc=$? i
  for ((i=${#RESOURCES[@]}-1; i>=0; i--)); do
    if ! api "${RESOURCES[i]}" -X DELETE | jq -e '.deleted == true' >/dev/null; then
      echo "Cleanup failed: ${RESOURCES[i]}" >&2
      rc=1
    fi
  done
  kill "$PF_PID" 2>/dev/null || true
  wait "$PF_PID" 2>/dev/null || true
  exit "$rc"
}

oc -n "$NAMESPACE" port-forward "deployment/$RELEASE" \
  --address 127.0.0.1 18080:8080 19901:9901 >"$WORK/port-forward.log" 2>&1 &
PF_PID=$!
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for _ in {1..50}; do
  kill -0 "$PF_PID"
  if curl -fsS --noproxy '*' --max-time 1 http://127.0.0.1:19901/healthy >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
curl -fsS --noproxy '*' --max-time 2 http://127.0.0.1:19901/healthy >/dev/null

respond() {
  local request
  request=$(jq -nc --arg model "$MODEL" --argjson options "$1" '
    {model:$model,reasoning:{effort:"none"},store:true,max_output_tokens:256} + $options')
  if [[ $(jq -r '.stream // false' <<<"$request") == true ]]; then
    post /v1/responses "$request" >"$WORK/stream.sse"
    sed -n 's/^data: //p' "$WORK/stream.sse" | sed '/^\[DONE\]\r\?$/d' | jq -se '
      if any(.[]; .type == "error" or .type == "response.failed" or .type == "response.incomplete")
      then error("stream failed") else
        [.[] | select(.type == "response.completed")] |
        if length == 1 then .[0].response else error("missing completed response") end
      end' >"$WORK/response.json"
  else
    post /v1/responses "$request" >"$WORK/response.json"
  fi
  RESPONSE_ID=$(jq -er '.id' "$WORK/response.json")
  RESOURCES+=("/v1/responses/$RESPONSE_ID")
  jq -e '.status == "completed"' "$WORK/response.json" >/dev/null
  api "/v1/responses/$RESPONSE_ID" | jq -e --slurpfile response "$WORK/response.json" '
    .status == "completed" and .output == $response[0].output' >/dev/null
  api "/v1/responses/$RESPONSE_ID/input_items" | jq -e '.data | length > 0' >/dev/null
}

echo 'Paid test: four Responses requests, normally six inference calls, plus OGX indexing/search.'
echo "Artifacts: $WORK"

echo 'Checking OGX connectivity before model calls'
api /v1/files --max-time 10 >/dev/null

echo 'Conversations create/update/read'
CONVERSATION=$(post /v1/conversations '{"metadata":{"test":"praxis-standalone"}}' | jq -er '.id')
RESOURCES+=("/v1/conversations/$CONVERSATION")
post "/v1/conversations/$CONVERSATION" '{"metadata":{"test":"updated"}}' >/dev/null
api "/v1/conversations/$CONVERSATION" | jq -e '.metadata.test == "updated"' >/dev/null

echo 'Buffered Responses, conversation items and store retrieval'
CODE="remember-$RANDOM-$RANDOM"
respond "$(jq -nc --arg conversation "$CONVERSATION" --arg input "Remember this code: $CODE. Reply only OK." '
  {conversation:$conversation,input:$input}')"
PREVIOUS=$RESPONSE_ID
api "/v1/conversations/$CONVERSATION/items" | jq -e '
  any(.data[]; .role == "user") and any(.data[]; .role == "assistant")' >/dev/null

echo 'Streaming previous_response_id continuation and persistence'
respond "$(jq -nc --arg previous "$PREVIOUS" '
  {previous_response_id:$previous,input:"What code did I ask you to remember? Reply only with that code.",stream:true}')"
jq -e --arg code "$CODE" 'any(.output[]?.content[]?; .type == "output_text" and (.text | contains($code)))' "$WORK/response.json" >/dev/null

echo 'Files upload/read/download'
CODE="launch-$RANDOM-$RANDOM"
printf 'The launch code is %s.\n' "$CODE" >"$WORK/sample.txt"
FILE=$(api /v1/files -F "file=@$WORK/sample.txt;type=text/plain" -F purpose=assistants | jq -er '.id')
RESOURCES+=("/v1/files/$FILE")
api "/v1/files/$FILE" | jq -e --arg id "$FILE" '.id == $id' >/dev/null
api "/v1/files/$FILE/content" >"$WORK/download.txt"
cmp "$WORK/sample.txt" "$WORK/download.txt"

echo 'Vector Store indexing and direct search'
STORE=$(post /v1/vector_stores "$(jq -nc --arg model "$EMBEDDING_MODEL" --arg provider "$VECTOR_STORE_PROVIDER" '
  {name:"praxis-standalone-test",embedding_model:$model,provider_id:$provider}')" | jq -er '.id')
RESOURCES+=("/v1/vector_stores/$STORE")
# OGX uses document_id metadata as the search result's file_id.
post "/v1/vector_stores/$STORE/files" "$(jq -nc --arg id "$FILE" '{file_id:$id,attributes:{document_id:$id}}')" >/dev/null
for _ in {1..30}; do
  api "/v1/vector_stores/$STORE/files/$FILE" >"$WORK/index.json"
  case $(jq -r '.status' "$WORK/index.json") in
    completed|failed|cancelled) break ;;
  esac
  sleep 2
done
jq -e '.status == "completed"' "$WORK/index.json" >/dev/null
post "/v1/vector_stores/$STORE/search" '{"query":"What is the launch code?","rewrite_query":false}' |
  jq -e --arg code "$CODE" --arg file "$FILE" '
    any(.data[]; .file_id == $file and any(.content[]; .text | contains($code)))' >/dev/null

for stream in false true; do
  echo "Hosted file_search loop, stream=$stream"
  respond "$(jq -nc --arg store "$STORE" --argjson stream "$stream" '
    {input:"Find the launch code in the uploaded document. Reply only with that code.",
     tools:[{type:"file_search",vector_store_ids:[$store],max_num_results:3}],
     tool_choice:{type:"file_search"},include:["file_search_call.results"],stream:$stream}')"
  jq -e --arg code "$CODE" --arg file "$FILE" '
    any(.output[]; .type == "file_search_call" and .status == "completed" and
      any(.results[]?; .file_id == $file and (.text | contains($code)))) and
    any(.output[]?.content[]?; .type == "output_text" and (.text | contains($code)))
  ' "$WORK/response.json" >/dev/null
done

echo 'Tests passed; deleting test resources and stopping port-forward.'
