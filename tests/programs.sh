#!/usr/bin/env bash
# programs.sh: check programs/cam.deem with the real deem, and programs/runs.awk, without the API
#
#   tests/programs.sh
#
# deem runs each program against a fake server that answers as a model
# that is always right would: each record says what's true of it. Prints
# one line per failed check; exit 1 if any.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
pids=()
trap 'kill "${pids[@]}" 2>/dev/null; rm -rf "$tmp"' EXIT
failed=0

# check NAME WANT GOT: report a difference
check() {
  [ "$2" == "$3" ] && return
  failed=1
  printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$1" "$2" "$3"
}

if command -v deem > /dev/null; then
# A record is "N SCORE WORD...": a yes/no question ending "true: WORD?" is
# yes when `now` has WORD; a choice is the option `now` has. Each request
# is a line in $tmp/got: how many questions, and the value.
cat > "$tmp/fake.py" <<'EOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
def answer(q, state):
    if isinstance(state, str):  # the record itself, not {now: ...}
        state = {"now": state}
    now = state["now"].split()
    if q["type"] == "noul":
        word = q["instructions"].rsplit("true: ", 1)[1].rstrip("?")
        return {"type": "noul", "noul": 0.9 if word in now else 0.1}
    opts = sorted(q["criteria"])
    return {"type": "choice", "choice": next((o for o in opts if o in now), opts[0])}
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["content-length"])))
        qs = req["questions"]
        with open(sys.argv[2], "a") as f:
            f.write("%d\t%s\n" % (len(qs), json.dumps(req["state"], separators=(",", ":"))))
        out = json.dumps({"model": "fake", "usage": {"input_tokens": 1, "output_tokens": 1},
                          "answers": {k: answer(q, req["state"]) for k, q in qs.items()}}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -I "$tmp/fake.py" "$port" "$tmp/got" & pids+=($!)
for _ in $(seq 50); do
  curl -s -o /dev/null "http://127.0.0.1:$port/" && break
  sleep 0.1
done
export JEV_BASE_URL=http://127.0.0.1:$port/v1 JEV_API_KEY=test
export XDG_CONFIG_HOME=$tmp/config HOME=$tmp

# cam: each record's scores, as it comes. A test is true when the record
# has its word; one request a record, every question in it.
cam() { deem run -r "$root/programs/cam.deem" --arg tests "$@"; }
up='{"label": "thumbs up", "q": "is this true: up?"}'
sleepy='{"label": "asleep", "q": "is this true: asleep?"}'
nails='{"label": "nails", "q": "is this true: nails?"}'
printf '%s\n' '1 none up' '2 none' '3 none up nails' '4 none asleep' > "$tmp/cam"
: > "$tmp/got"
check 'cam' "$(printf '%s\tthumbs up\t%s\tasleep\t%s\tnails\t%s\n' '1 none up' 0.9 0.1 0.1 '2 none' 0.1 0.1 0.1 \
  '3 none up nails' 0.9 0.1 0.9 '4 none asleep' 0.1 0.9 0.1)" "$(cam "[$up, $sleepy, $nails]" "$tmp/cam")"
check 'cam: a request a record' 4 "$(grep -c '^3'$'\t''{"now":' "$tmp/got")"
check 'cam: labels, and the frame itself' "$(printf '%s\tup\t-\n' '1 none up')" \
  "$(head -1 "$tmp/cam" | cam '[{"kind": "labels", "bare": true, "labels": ["down", "up"], "q": "which fits?"}]')"
# a live stream: a record prints before the input ends
check 'cam: prints as it comes' '1 none up	thumbs up	0.9' \
  "$(timeout 5 deem run -r "$root/programs/cam.deem" --arg tests "[$up]" < <(echo '1 none up'; sleep 10) | head -1)"
else
  echo 'skipped: the cam checks need deem (not installed)' >&2
fi

# runs.awk: answers about frames named by their time in ms, as lines
runs() { awk -F '\t' -v every=10 -f "$root/programs/runs.awk" "$@"; }
printf '%s\n' $'d/0000000000000.jpg\tup\t0.9\tasleep\t0.1' $'d/0000000010000.jpg\tup\t0.8\tasleep\t0.7' \
  $'d/0000000020000.jpg\tup\t0.1\tasleep\t0.9' $'d/0000000030000.jpg\tup\t0.9\tasleep\t0.2' > "$tmp/answers"
check 'runs: grep --starts' "$(printf '00:00:00\t0.9\n00:00:30\t0.9')" \
  "$(cut -f1-3 "$tmp/answers" | runs -v mode=grep -v t=0.5 -v starts=1)"
check 'runs: grep, the best score' "$(printf '00:00:00\t00:00:20\t0.9\n00:00:30\t00:00:40\t0.9')" \
  "$(cut -f1-3 "$tmp/answers" | runs -v mode=grep -v t=0.5)"
check 'runs: series' "$(printf '00:00:00\t0.9\n00:00:10\t0.8\n00:00:20\t0.1\n00:00:30\t0.9')" \
  "$(cut -f1-3 "$tmp/answers" | runs -v mode=series)"
printf '%s\n' $'d/0000000000000.jpg\ta\t-' $'d/0000000010000.jpg\ta\t-' $'d/0000000020000.jpg\tb\t-' \
  $'d/0000000030000.jpg\ta\t-' $'d/0000000040000.jpg\ta\t-' > "$tmp/labels"
check 'runs: split, a short section joins the one before' "$(printf '00:00:00\t00:00:50\ta')" "$(runs -v mode=split -v min=20 < "$tmp/labels")"
check 'runs: split, min 0' "$(printf '00:00:00\t00:00:20\ta\n00:00:20\t00:00:30\tb\n00:00:30\t00:00:45\ta')" \
  "$(runs -v mode=split -v min=0 -v end=45 < "$tmp/labels")"
# frames 10 and 20 missing: 0's answer lasts to 30
check 'runs: a missing frame has the answer of the one before' "$(printf '00:00:00\t00:00:30\t0.9\n00:00:40\t00:01:00\t0.9')" \
  "$(printf '%s\n' $'d/0000000000000.jpg\tx\t0.9' $'d/0000000030000.jpg\tx\t0.1' $'d/0000000040000.jpg\tx\t0.9' | runs -v mode=grep -v t=0.5 -v end=60)"
check 'runs: split, a missing frame counts' "$(printf '00:00:00\t00:00:40\ta\n00:00:40\t00:01:00\tb')" \
  "$(printf '%s\n' $'d/0000000000000.jpg\ta\t-' $'d/0000000040000.jpg\tb\t-' $'d/0000000050000.jpg\tb\t-' | runs -v mode=split -v min=20 -v end=60)"
printf '' | runs -v mode=grep -v t=0.5
check 'runs: nothing found: exit 1' 1 $?

[ "$failed" = 0 ] && echo 'all checks passed'
exit "$failed"
