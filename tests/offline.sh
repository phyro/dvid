#!/usr/bin/env bash
# offline.sh: check every command against a fake deem, without the API
#
#   tests/offline.sh
#
# The fake deem writes the arguments it got to $CALLS and answers with
# canned lines, so each check sees what a command asked deem and what it
# made of the answer. Prints one line per failed check; exit 1 if any.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export CALLS=$tmp/calls
cat > "$tmp/deem" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case " $* " in
  *"/cam.deem "*)
    # dvid (cam.deem): FAKE_FRAMES, each frame's answers, name=answer
    # comma-separated, frames by ; (the name may be empty, the answer -);
    # FAKE_DELAY seconds each
    # (or, without it, FAKE_SCORES or FAKE_LABELS, a frame each)
    if [ -n "${FAKE_FRAMES+x}" ]; then IFS=';' read -ra frames <<< "$FAKE_FRAMES"
    else
      case " $* " in
        *'"kind": "labels"'*) IFS=, read -ra frames <<< "${FAKE_LABELS:-}"; frames=("${frames[@]/%/=-}") ;;
        *) read -ra frames <<< "${FAKE_SCORES:-}"; frames=("${frames[@]/#/=}") ;;
      esac
    fi
    i=0
    while read -r path; do
      sleep "${FAKE_DELAY:-0}"
      [ -z "${FAKE_SIZES:-}" ] || ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$path" >> "$FAKE_SIZES"
      IFS=, read -ra ps <<< "${frames[i]:-=0.9}"
      printf '%s' "$path"; for x in "${ps[@]}"; do printf '\t%s\t%s' "${x%%=*}" "${x#*=}"; done; echo
      i=$((i + 1))
    done
    exit "${FAKE_EXIT:-0}" ;;
esac
EOF
chmod +x "$tmp/deem"
export PATH="$root/bin:$tmp:$PATH"
failed=0

# check NAME WANT GOT: report a difference
check() {
  [ "$2" == "$3" ] && return
  failed=1
  printf 'FAIL %s\n  want: %q\n  got:  %q\n' "$1" "$2" "$3"
}
# asked: the latest cam.deem call as the question form would have it: the
# question, -o and the labels for a labels test, and deem's flags
asked() {
  last | python3 -I -c '
import json, re, sys
m = re.match(r"run -I -r --arg tests (\[.*\]) \S*cam\.deem(.*)$", sys.stdin.read().rstrip("\n"))
t = json.loads(m.group(1))[0]
print(t["q"] + (" -o " + ",".join(t["labels"]) if "labels" in t else "") + m.group(2))'
}
# last: the arguments of the latest deem call
last() { tail -n 1 "$CALLS"; }

for f in "$root/bin/dvid" "$0"; do
  bash -n "$f" || { failed=1; echo "FAIL syntax: $f"; }
done

# Needing no video: dvid's errors are found before the video is read, so
# a stand-in path will do.
v=clip.mp4
msg=$(dvid --all -t 0.8 x v 2>&1 > /dev/null)
check 'dvid --all -t is an error' 2 $?
check 'dvid --all -t says why' 'dvid: -t marks out runs; --all prints every score' "$msg"
msg=$(dvid -t 0.8 --labels a,b v 2>&1 > /dev/null)
check 'dvid --labels -t is an error' 2 $?
check 'dvid --labels -t says why' 'dvid: -t is for WHAT; --labels picks the label that fits best' "$msg"
msg=$(dvid grep x v 2>&1 > /dev/null)
check 'dvid grep (an old verb) is an error' 2 $?
check 'dvid grep says there are no verbs' 'dvid: there are no verbs: dvid WHAT VIDEO for runs, --labels for sections, --all for every frame' "$msg"
msg=$(dvid --labels 'no fire, fire' 'what do we see?' v 2>&1 > /dev/null)
check 'dvid --labels: a WHAT is an error' 2 $?
check 'dvid --labels: a WHAT says to use -q' "dvid: --labels takes no WHAT; to ask your own question: -q 'what do we see?'" "$msg"
dvid --all --starts x v > /dev/null 2>&1
check 'dvid --all --starts is a usage error' 2 $?
shown=$(dvid --show 'x' clip.mp4)
check 'dvid --show has ffmpeg' 1 "$(grep -c ffmpeg <<< "$shown")"
check 'dvid --show has deem run -I -r' 1 "$(grep -c 'deem run -I -r' <<< "$shown")"
check 'dvid --show has runs.awk' 1 "$(grep -c "programs/runs.awk" <<< "$shown")"

# dvid: a real video, cut by ffmpeg, scored by the fake deem
if command -v ffmpeg > /dev/null && command -v ffprobe > /dev/null; then
  ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=5 -t 140 "$tmp/my video.mp4"
  v="$tmp/my video.mp4"
  got=$(FAKE_SCORES='0.9 0.8 0.2 0.7 0.1' dvid 'the dog is on the couch' --api d3 "$v")
  check 'dvid merges neighbours' "$(printf '00:00:00\t00:01:00\t0.9\n00:01:30\t00:02:00\t0.7')" "$got"
  check 'dvid asks' 'This is a frame from a video. Is this true in it: the dog is on the couch? --api d3' "$(asked)"
  got=$(FAKE_SCORES='0.1 0.1 0.1 0.2 0.6' dvid 'x' "$v")
  check 'dvid: the last run ends with the video' "$(printf '00:02:00\t00:02:20\t0.6')" "$got"
  got=$(FAKE_SCORES='0.9 0.8 0.2 0.7 0.1' dvid -t 0.75 'x' "$v")
  check 'dvid -t' "$(printf '00:00:00\t00:01:00\t0.9')" "$got"
  got=$(FAKE_SCORES='0.3 0.9 0.8 0.1' dvid --every 10s --from 1:00 --to 1:40 'x' "$v")
  check 'dvid --every --from --to' "$(printf '00:01:10\t00:01:30\t0.9')" "$got"
  FAKE_SCORES='0.1 0.2 0.1 0.1 0.1' dvid 'x' "$v" > /dev/null
  check 'dvid finds nothing: exit 1' 1 $?
  FAKE_EXIT=2 dvid 'x' "$v" > /dev/null
  check 'dvid: deem fails: exit 2' 2 $?
  FAKE_SCORES='0.1 0.1 0.1 0.1 0.1' FAKE_EXIT=2 dvid 'x' "$v" > /dev/null
  check 'dvid: deem fails, nothing found: exit 2' 2 $?
  dvid -q 'is the dog there?' "$v" > /dev/null
  check 'dvid -q' 'is the dog there?' "$(asked)"
  want=$(FAKE_SCORES='0.9 0.8 0.2 0.7 0.1' dvid --from 30 "the dog's here" "$v")
  shown=$(dvid --show --from 30 "the dog's here" "$v")
  check '--show runs as printed: dvid' "$want" "$(FAKE_SCORES='0.9 0.8 0.2 0.7 0.1' eval "$shown")"

  got=$(FAKE_SCORES='0.1 0.2 0.9 0.8 0.7' dvid --all 'flames are visible' "$v")
  check 'dvid --all' "$(printf '00:00:00\t0.1\n00:00:30\t0.2\n00:01:00\t0.9\n00:01:30\t0.8\n00:02:00\t0.7')" "$got"
  check 'dvid --all asks' 'This is a frame from a video. Is this true in it: flames are visible?' "$(asked)"
  got=$(FAKE_LABELS='no fire,no fire,one spot,most of it,most of it' dvid --all --labels 'no fire,one spot,most of it' "$v" | uniq -f1)
  check 'dvid --all --labels | uniq -f1' "$(printf '00:00:00\tno fire\n00:01:00\tone spot\n00:01:30\tmost of it')" "$got"
  check 'dvid --all --labels asks' "This is a frame from a video. Which of these fits it best? -o no fire,one spot,most of it" "$(asked)"
  dvid --all -q 'how much is on fire?' --labels a,b --api d3 "$v" > /dev/null
  check 'dvid --all -q --labels' 'how much is on fire? -o a,b --api d3' "$(asked)"
  got=$(FAKE_SCORES='0.1 0.2 0.3 0.4' dvid --all --every 20s --from 1:00 x "$v" | cut -f1 | paste -sd' ')
  check 'dvid --all --every --from' '00:01:00 00:01:20 00:01:40 00:02:00' "$got"
  want=$(FAKE_LABELS='a,b,b,a,a' dvid --all --labels "a,b's" "$v")
  shown=$(dvid --all --show --labels "a,b's" "$v")
  check '--show runs as printed: dvid --all' "$want" "$(FAKE_LABELS='a,b,b,a,a' eval "$shown")"

  # split: five frames, at 0s, 30s, 60s, 90s and 120s of 140s
  got=$(FAKE_LABELS='intro,intro,demo,intro,intro' dvid --labels intro,demo "$v")
  check 'dvid --labels: a short section joins the one before' "$(printf '00:00:00\t00:02:20\tintro')" "$got"
  check 'dvid asks' 'This is a frame from a video. Which of these fits it best? -o intro,demo' "$(asked)"
  got=$(FAKE_LABELS='intro,demo,demo,demo,demo' dvid --labels intro,demo "$v")
  check 'dvid --labels: a short first section joins the one after' "$(printf '00:00:00\t00:02:20\tdemo')" "$got"
  got=$(FAKE_LABELS='a,a,b,b' dvid --every 10s --from 1:00 --to 1:40 --labels a,b "$v")
  check 'dvid --every --from --to' "$(printf '00:01:00\t00:01:20\ta\n00:01:20\t00:01:40\tb')" "$got"
  dvid -q 'what is on screen?' --labels a,b --api d3 "$v" > /dev/null
  check 'dvid -q' 'what is on screen? -o a,b --api d3' "$(asked)"
  want=$(FAKE_LABELS='a,b,b,a,a' dvid --labels "a,b's" "$v")
  shown=$(dvid --show --labels "a,b's" "$v")
  check '--show runs as printed: dvid --labels' "$want" "$(FAKE_LABELS='a,b,b,a,a' eval "$shown")"
  dvid --api d3 --labels a,b "$v" > /dev/null
  check 'dvid --labels: deem flags before --labels' 'This is a frame from a video. Which of these fits it best? -o a,b --api d3' "$(asked)"
  dvid --all 'x' --every 1m --api d3 "$v" > /dev/null
  check 'dvid --all: own flags after WHAT' 'This is a frame from a video. Is this true in it: x? --api d3' "$(asked)"
  # --frames 4: a 2x2 grid of the frames across each --every, whole grids only
  got=$(FAKE_SIZES="$tmp/sizes" FAKE_SCORES='0.1 0.9 0.8 0.2' dvid --all --frames 4 x --api d3 "$v")
  check 'dvid --frames 4: a grid each --every, the last whole one' "$(printf '00:00:00\t0.1\n00:00:30\t0.9\n00:01:00\t0.8\n00:01:30\t0.2')" "$got"
  check 'dvid --frames 4 asks about the grid' 'These are 4 frames from a video, 10 s apart, in reading order: left to right, top to bottom. Does this happen in them: x? --api d3' "$(asked)"
  check 'dvid --frames 4: 4 frames of 320x240, 4 px apart' 644,484 "$(head -1 "$tmp/sizes")"
  got=$(FAKE_SCORES='0.2 0.9 0.8 0.1' dvid --every 10s --frames 4 --from 1:00 --to 1:40 x "$v")
  check 'dvid --frames 4 --from --to' "$(printf '00:01:10\t00:01:30\t0.9')" "$got"
  dvid --frames 4 --every 20s --labels a,b "$v" > /dev/null
  check 'dvid --frames 4 --labels asks' 'These are 4 frames from a video, 6.7 s apart, in reading order: left to right, top to bottom. Which of these fits them best? -o a,b' "$(asked)"
  want=$(FAKE_SCORES='0.9 0.2 0.7 0.1' dvid --frames 4 --from 10 "it's a wave" "$v")
  shown=$(dvid --show --frames 4 --from 10 "it's a wave" "$v")
  check '--show runs as printed: dvid --frames 4' "$want" "$(FAKE_SCORES='0.9 0.2 0.7 0.1' eval "$shown")"
  msg=$(dvid --frames 4 --every 3m x "$v" 2>&1 > /dev/null)
  check 'dvid --frames 4, a video shorter than --every: exit 2' 2 $?
  check 'dvid --frames 4, a video shorter than --every, says so' 'dvid: the video is shorter than --every, the time 4 frames cover: lower --every' "$msg"
  dvid -q 'Q' extra "$v" > /dev/null 2>&1
  check 'dvid -q and a WHAT is an error' 2 $?

  # Live: times are the clock's, so a pipe is read at its own pace
  ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=5 -t 140 -f mpegts "$tmp/live.ts"
  live() { FAKE_FRAMES=$1 dvid "${@:2}" <(cat "$tmp/live.ts"); }
  FAKE_EXIT=2 live '' --all x > /dev/null
  check 'dvid, live: deem fails: exit 2' 2 $?
  dvid --all x <(echo not a video) > /dev/null 2>&1
  check 'dvid, live: ffmpeg fails: exit 2' 2 $?
  for a in '--from 10 x' '--all --to 1:00 x'; do
    dvid $a <(cat "$tmp/live.ts") > /dev/null 2>&1
    check "dvid $a, live, is a usage error" 2 $?
  done
  check 'dvid --starts, a file' "$(printf '00:00:00\t0.9\n00:01:30\t0.7')" "$(FAKE_SCORES='0.9 0.8 0.2 0.7 0.1' dvid --starts x "$v")"
  check 'dvid --starts, a file' "$(printf '00:01:00\ta\n00:01:20\tb')" "$(FAKE_LABELS='a,a,b,b' dvid --starts --every 10s --from 1:00 --to 1:40 --labels a,b "$v")"
  # Live: a pipe at the video's own pace; times are the clock's
  ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=5 -t 6 -f mpegts "$tmp/six.ts"
  rt() { ffmpeg -loglevel error -re -i "$tmp/six.ts" -c copy -f mpegts -; }
  now=$(date +%s)
  got=$(FAKE_SCORES='0.1 0.9 0.8' dvid --all --every 2s x <(rt))
  check 'dvid --all, live: a frame every 2s' "$(printf '0.1\n0.9')" "$(cut -f2 <<< "$got" | head -2)"
  first=$(date -d "$(head -1 <<< "$got" | cut -f1)" +%s)
  check 'dvid --all, live: the clock time of the frame' 1 "$(( first >= now && first <= now + 4 ))"
  check 'dvid --all, live: 2s apart' 2 "$(( $(date -d "$(sed -n 2p <<< "$got" | cut -f1)" +%s) - first ))"
  got=$(FAKE_SCORES='0.9 0.8 0.1' dvid --every 2s x <(rt))
  check 'dvid, live' 0.9 "$(cut -f3 <<< "$got")"
  got=$(FAKE_SCORES='0.1 0.9 0.8' dvid --starts --every 2s x <(rt) | head -1)
  check 'dvid --starts, live: start and score' 1 "$(grep -cE '^[0-9:]{8}'$'\t''0\.9$' <<< "$got")"
  check 'dvid, live, asks about a frame' 'This is a frame from a video. Is this true in it: x?' "$(asked)"
  got=$(FAKE_SCORES='0.1 0.9 0.8' dvid --all --every 2s --frames 4 x <(rt))
  check 'dvid --frames 4, live: a grid every 2s' "$(printf '0.1\n0.9')" "$(cut -f2 <<< "$got" | head -2)"
  check 'dvid --frames 4, live, asks about the grid' 'These are 4 frames from a video, 0.67 s apart, in reading order: left to right, top to bottom. Does this happen in them: x?' "$(asked)"
  check 'dvid --labels, live' "$(printf 'a\nb')" "$(FAKE_FRAMES='a=-;a=-;b=-;b=-;b=-;b=-;b=-' dvid --every 1s --labels a,b <(rt) | cut -f3 | uniq)"
  FAKE_EXIT=2 dvid --all --every 2s x <(rt) > /dev/null
  check 'dvid, live: deem fails: exit 2' 2 $?
  check 'dvid, live: not behind' '' "$(FAKE_SCORES='0.1' dvid --all --every 2s x <(rt) 2>&1 > /dev/null)"
  # started a second past a multiple of --every, the first frame is a
  # fraction of a tick before the second dvid started: two frames, two times
  ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=5 -t 11 -f mpegts "$tmp/eleven.ts"
  until [ $(( $(date +%s) % 5 )) = 1 ]; do sleep 0.05; done
  got=$(FAKE_SCORES='0.1 0.9' dvid --all --every 5s x \
    <(ffmpeg -loglevel error -re -i "$tmp/eleven.ts" -c copy -f mpegts -) 2>&1)
  check 'dvid, live: started off --every, a time a frame' 2 "$(grep -c $'\t0\\.[19]$' <<< "$got")"
  check 'dvid, live, --every 500ms: a frame a half second' 1 "$(n=$(dvid --all --every 500ms x <(rt) | wc -l); echo $(( n >= 11 && n <= 13 )))"
  # answers that take 1.5s, a frame every 0.5s: behind by frame 6
  got=$(FAKE_DELAY=1.5 dvid --all --every 500ms x <(rt) 2>&1 > /dev/null)
  check 'dvid, live: says when it falls behind, once' 1 "$(grep -cE '^dvid: [0-9:.]{12} falling behind: frame [0-9]+ answered [0-9.]+s after it was taken, [0-9]+ waiting$' <<< "$got")"
  check 'dvid, live: nothing else on stderr' 1 "$(wc -l <<< "$got")"
  mkfifo "$tmp/cam"
  rt > "$tmp/cam" &
  want=$(FAKE_FRAMES='=0.9;=0.1;=0.9' dvid --all --every 2s "it's a" "$tmp/cam" | cut -f2 | head -2)
  rt > "$tmp/cam" &
  shown=$(dvid --all --show --every 2s "it's a" "$tmp/cam")
  check '--show runs as printed: dvid --all, live' "$want" "$(FAKE_FRAMES='=0.9;=0.1;=0.9' eval "$shown" | cut -f2 | head -2)"

  # A URL: one with a length is read as a file, seeking over HTTP; a
  # stream (a live HLS playlist, which grows) is live
  mkdir "$tmp/www"; ln -s "$v" "$tmp/www/v.mp4"
  port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  # http.server, with Range, which ffmpeg seeks by
  python3 -I -c '
import http.server, os, re, sys
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def send_head(self):
        path, r = self.translate_path(self.path), self.headers.get("Range")
        m = r and os.path.isfile(path) and re.match(r"bytes=(\d+)-(\d*)$", r)
        if not m: return super().send_head()
        size = os.path.getsize(path); a = int(m[1]); b = min(int(m[2] or size - 1), size - 1)
        if a >= size: self.send_error(416); return None
        f = open(path, "rb"); f.seek(a)
        self.send_response(206); self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {a}-{b}/{size}"); self.send_header("Content-Length", str(b - a + 1))
        self.send_header("Accept-Ranges", "bytes"); self.end_headers()
        self.left = b - a + 1; return f
    def copyfile(self, src, dst):
        n = getattr(self, "left", None)
        if n is None: return super().copyfile(src, dst)
        while n > 0:
            buf = src.read(min(n, 65536))
            if not buf: break
            dst.write(buf); n -= len(buf)
os.chdir(sys.argv[1])
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()' "$tmp/www" "$port" 2> /dev/null & srv=$!
  until python3 -I -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])))' "$port" 2> /dev/null; do sleep 0.1; done
  url=http://127.0.0.1:$port
  check 'dvid, a URL: --from --to' "$(printf '00:01:10\t00:01:30\t0.9')" \
    "$(FAKE_SCORES='0.3 0.9 0.8 0.1' dvid --every 10s --from 1:00 --to 1:40 x "$url/v.mp4")"
  check 'dvid --frames 4, a URL' "$(printf '00:01:10\t00:01:30\t0.9')" \
    "$(FAKE_SCORES='0.2 0.9 0.8 0.1' dvid --every 10s --frames 4 --from 1:00 --to 1:40 x "$url/v.mp4")"
  want=$(FAKE_SCORES='0.9 0.8 0.2 0.7 0.1' dvid --from 30 "the dog's here" "$url/v.mp4")
  shown=$(dvid --show --from 30 "the dog's here" "$url/v.mp4")
  check '--show runs as printed: dvid, a URL' "$want" "$(FAKE_SCORES='0.9 0.8 0.2 0.7 0.1' eval "$shown")"
  msg=$(dvid x "$url/none.mp4" 2>&1 > /dev/null)
  check "dvid, a URL that can't be read: exit 2" 2 $?
  check "dvid, a URL that can't be read, says so" "dvid: can't read the video '$url/none.mp4'" "$(tail -1 <<< "$msg")"
  ffmpeg -loglevel error -f lavfi -i testsrc=size=320x240:rate=5 -t 10 -f mpegts "$tmp/ten.ts"
  ffmpeg -loglevel error -re -i "$tmp/ten.ts" -c copy -f hls -hls_time 1 -hls_list_size 4 "$tmp/www/cam.m3u8" & hls=$!
  until [ -e "$tmp/www/cam.m3u8" ]; do sleep 0.1; done
  dvid --from 10 x "$url/cam.m3u8" > /dev/null 2>&1
  check 'dvid --from, a live URL, is a usage error' 2 $?
  now=$(date +%s)
  got=$(FAKE_SCORES='0.9 0.9 0.9 0.9 0.9' dvid --all --every 2s x "$url/cam.m3u8")
  check 'dvid --all, a live URL: ends with the stream' 0 $?
  first=$(date -d "$(head -1 <<< "$got" | cut -f1)" +%s)
  check 'dvid --all, a live URL: the clock time of the frame' 1 "$(( first >= now && first <= now + 12 ))"
  wait "$hls"; kill "$srv"
else
  echo 'skipped: the checks that need ffmpeg (not installed)' >&2
fi
for a in '' x 'grep x f.mp4' 'series x f.mp4' 'split --labels a,b f.mp4' \
         '--every 0s x f.mp4' '--every 1.5x x f.mp4' '--every 0.0001s x f.mp4' '--from 1:xx x f.mp4' \
         '--all' '--all x' '--labels' '--labels a,b' '-q' '-q Q' '-t 2 x f.mp4' \
         '--all --starts x f.mp4' '--all -t 0.5 x f.mp4' '-t 0.5 --labels a,b f.mp4' \
         '--frames 2 x f.mp4' '--frames 9 x f.mp4' '--frames x x f.mp4' '--frames'; do
  dvid $a > /dev/null 2>&1
  check "dvid $a is a usage error" 2 $?
done

dvid x "$tmp/no such video.mp4" > /dev/null 2>&1
check 'dvid: a video ffmpeg cannot read: exit 2' 2 $?
msg=$(dvid x "" 2>&1 > /dev/null)
check 'dvid: an empty video name: exit 2' 2 $?
check 'dvid: an empty video name says so' "dvid: no video '' (the last word is the video)" "$msg"

[ "$failed" = 0 ] && echo 'all checks passed'
exit "$failed"
