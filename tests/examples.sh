#!/usr/bin/env bash
# examples.sh: run every command in the sh blocks of README.md as written,
# from examples/
#
#   tests/examples.sh          against a fake deem, without the API
#   tests/examples.sh --list   print the commands it found, one per line
#   tests/examples.sh --live   against your deem and its API, printing
#                              each command and what it printed
#
# A command passes when it exits 0 or 1 (1 is "nothing found", as with
# grep): it ran, with the flags and files it names. The fake deem says yes
# to everything, so offline this checks that every command runs, not what
# it finds; --live is for reading the answers. Prints one line per failed
# command; exit 1 if any. The live videos play at their own speed, so this
# takes about two minutes either way.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
live=0
list=0
case ${1:-} in --live) live=1 ;; --list) list=1 ;; "") ;; *) echo 'usage: tests/examples.sh [--live | --list]' >&2; exit 2 ;; esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The fake deem reads what deem would (the files it was given, or stdin)
# and answers each record with a yes: 0.9, the first label, a group or a
# root of its own.
cat > "$tmp/deem" <<'EOF'
#!/usr/bin/env bash
files=()
for a; do [ -f "$a" ] && [[ $a != *.deem ]] && files+=("$a"); done
input() { if [ ${#files[@]} -gt 0 ]; then cat "${files[@]}"; else cat; fi; }
case " $* " in
  # cam.deem: a pair for each test
  *" --arg tests "*)
    for ((i = 1; i < $#; i++)); do [ "${!i}" = tests ] && { j=$((i + 1)); tests=${!j}; }; done
    while IFS= read -r path; do
      python3 -I -c '
import json, sys
out = [sys.argv[2]]
for t in json.loads(sys.argv[1]):
    out += [t["labels"][0], "-"] if t["kind"] == "labels" else [t.get("label", ""), "0.9"]
print("\t".join(out))' "$tests" "$path"
    done ;;
  *" run group "* | *"/roots.deem "*) input | awk '{ printf "%d\t%s\n", NR, $0 }' ;;
  *" -s "*) input > /dev/null ;;
  *" -p "*) input | sed 's/^/0.9\t/' ;;
  *" -o "*) input | sed 's/^/label\t/' ;;
  *) input ;;
esac
EOF
chmod +x "$tmp/deem"
if [ "$live" = 1 ]; then export PATH="$root/bin:$PATH"; else export PATH="$root/bin:$tmp:$PATH"; fi

# The commands: each line of the sh blocks, with the lines a \, | or &&
# at its end continues, but for comments, the setup (export, cd) and the
# ffmpeg that made the clips.
python3 -I - "$root/README.md" > "$tmp/commands" <<'EOF'
import re, sys
for block in re.findall(r"^```sh\n(.*?)^```", open(sys.argv[1]).read(), re.S | re.M):
    cmd = ""
    for line in block.splitlines():
        if not cmd and re.match(r"\s*(#|$)", line):
            continue
        cmd += line + "\n"
        if not re.search(r"(\\|\||&&)$", line):
            if not re.match(r"(export|cd|ffmpeg) ", cmd):
                sys.stdout.write(cmd + "\0")
            cmd = ""
EOF

# --list: each command on one line, its continuation lines joined
if [ "$list" = 1 ]; then
  tr '\n\0' '\001\n' < "$tmp/commands" | sed -e 's/\\\x01 */ /g' -e 's/\x01$//' -e 's/\x01/ /g'
  exit 0
fi
found=$(tr -cd '\0' < "$tmp/commands" | wc -c)
[ "$found" -ge 8 ] || { echo "FAIL: found $found commands in README.md, expected at least 8"; exit 1; }
if ! command -v ffmpeg > /dev/null || ! command -v ffprobe > /dev/null; then
  echo 'skipped: the examples need ffmpeg (not installed)' >&2
  exit 0
fi

cd "$root/examples" || exit 2
failed=0 n=0
while IFS= read -r -d '' cmd; do
  n=$((n + 1))
  code=0
  timeout 300 bash -c "$cmd" > "$tmp/out" 2>&1 < /dev/null || code=$?
  if [ "$live" = 1 ]; then
    printf '\n$ %s' "$cmd"
    cat "$tmp/out"
    echo "(exit $code)"
  fi
  if [ "$code" -gt 1 ]; then
    failed=1
    printf 'FAIL (exit %s) %s' "$code" "$cmd"
    sed 's/^/  /' "$tmp/out" | tail -n 5
  fi
done < "$tmp/commands"
[ "$n" -gt 0 ] || { echo 'FAIL: no commands found in README.md'; exit 1; }
if [ "$failed" = 0 ]; then echo "all $n commands ran"; fi
exit "$failed"
