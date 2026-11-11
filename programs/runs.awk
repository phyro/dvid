# runs.awk: dvid's answers about frames, as the lines dvid prints
#
#   ... | deem run -I -r --arg tests "$tests" programs/cam.deem |
#     awk -F '\t' -v mode=grep -v every=30 -v end=600 -f programs/runs.awk
#
# A frame's file name is its time in milliseconds: its position in the
# video, or, live, the clock's, since the epoch. Each input line is a frame's path, then a name and an
# answer for each test (programs/cam.deem): a moment's label and its score,
# or the label a labels test chose and "-".
#
# mode series prints each frame's answer, time<TAB>score or label. grep
# prints each run of frames that score above t as start<TAB>end<TAB>score,
# the run's best: from its first frame to the next frame that doesn't, or
# at the end to end (seconds, if known: the video's end) or a frame after
# its last. A missing frame has the answer of the one before it. split
# prints sections of one label: a run of fewer than min seconds of frames
# joins the section before it, or at first the one after.
#
# A line prints as soon as it is known: a run once it ends, a section once
# the next has lasted min. starts prints start<TAB>score or label as a run
# or section starts, instead. Times are [HH:]MM:SS from the video's start,
# or live the clock's time of day. Nothing found is exit 1.
#
# live also deletes each frame once answered, so the frames left in its
# folder are the ones waiting, and says on stderr when an answer comes
# more than max(5 s, two frames) after its frame was written, and when
# they catch up.
BEGIN {
  if (live) {
    "date +%z" | getline z; close("date +%z")
    off = (substr(z, 1, 1) == "-" ? -1 : 1) * (substr(z, 2, 2) * 3600 + substr(z, 4, 2) * 60)
  }
}
function at(p) { sub(/.*\//, "", p); sub(/\.jpg$/, "", p); return p / 1000 }
function hms(s) { s = int(s + 0.5); return sprintf("%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
function clock(s) { s = int(s + off); s = (s % 86400 + 86400) % 86400
  return sprintf("%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
function fmt(s) { return live ? clock(s) : hms(s) }
function emit(a, b, x,   line) {
  line = fmt(a) (starts ? "" : "\t" fmt(b)) (x == "" ? "" : "\t" x); found = 1
  print line; fflush()
}
# A run ends at e: where the next frame says otherwise; at the end, where
# the video ends (or, unknown, a frame after its last).
function close_run(l, e) { if (!starts) emit(ra[l], e, mode == "grep" ? best[l] : l); delete open[l] }
function final(s) { return end + 0 > 0 ? end + 0 : s + every }
# split: whether the run of rl lasts min to e: its frames' time, or, frames
# dropped, its span; section(): it is the section from now on
function long(e) { return (rn * every > e - ra0 ? rn * every : e - ra0) >= min - 0.0005 }
function section() {
  if (cur != "") { if (!starts) emit(ca, ra0, cur); ca = ra0 } else ca = first
  cur = rl; ce = re; if (starts) emit(ca, ca, cur)
}
# live: the frame is answered; delete it, and say how far behind
function answered(p,   cmd, nw, taken, d, waiting, lag, late, now_) {
  cmd = "date -r \047" p "\047 +%s.%N"; cmd | getline taken; close(cmd)
  cmd = "date \"+%s.%N\""; cmd | getline nw; close(cmd)
  system("rm -f \047" p "\047")
  d = p; sub(/\/[^\/]*$/, "", d)
  cmd = "ls \047" d "\047 | grep -c \047[.]jpg$\047"; cmd | getline waiting; close(cmd)
  lag = nw - taken
  late = lag > (every * 2 > 5 ? every * 2 : 5)
  now_ = sprintf("%s.%03d", clock(nw), (nw - int(nw)) * 1000)
  if (late != behind)
    printf "dvid: %s %s: frame %d answered %.1fs after it was taken, %d waiting\n", now_,
      late ? "falling behind" : "caught up", NR, lag, waiting > "/dev/stderr"
  behind = late
}

{
  if (live) answered($1)
  s = at($1)
  if (mode == "series") { print fmt(s) "\t" ($3 == "-" ? $2 : $3); fflush(); found = 1; next }
  if (mode == "split") {
    if (NR == 1) first = s
    if ($2 != rl) {
      # the run before ends here: long enough, it is a section
      if (rl != "" && rl != cur && long(s)) section()
      rl = $2; ra0 = s; rn = 0
    }
    rn++; re = s + every
    if (rl == cur) ce = re
    else if (long(re)) section()
    next
  }
  delete now
  for (i = 2; i < NF; i += 2) if ($(i + 1) == "-") now[$i] = 1; else if ($(i + 1) + 0 > t + 0) now[$i] = $(i + 1)
  for (l in open) if (!(l in now)) close_run(l, s)
  for (l in now) {
    if (!(l in open)) { open[l] = 1; ra[l] = s; best[l] = now[l]; if (starts) emit(s, s, mode == "grep" ? now[l] : l) }
    last[l] = s; if (mode == "grep" && now[l] + 0 > best[l] + 0) best[l] = now[l]
  }
}
END {
  if (mode == "split") {
    if (rl != "" && rl != cur && long(final(re - every))) section()
    if (cur == "" && rl != "") { cur = rl; ca = first; if (starts) emit(ca, ca, cur) }
    if (cur != "" && !starts) emit(ca, final(re - every), cur)
  } else if (mode != "series") for (l in open) close_run(l, final(last[l]))
  exit !found
}
