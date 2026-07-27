#!/usr/bin/env bash
set -uo pipefail

# ---------- Settings ----------
CONN=8                                           # parallel connections per region (default; override with -c/--connections)
CHUNK_MB=16                                      # MiB per connection => CONN x CHUNK_MB fetched per region
UL_MB=500                                        # upload payload size in MiB
DL_TIMEOUT=90                                    # seconds cap per download connection
TMPBASE="/dev/shm"                               # scratch for the upload payload; falls back to /tmp
UPLOAD_URL="https://speed.cloudflare.com/__up"   # only reliable public upload sink (NEAREST edge, not per-region)
BW_DEBUG="${BW_DEBUG:-0}"                        # BW_DEBUG=1 prints the raw curl errors under each failed row

# ---------- Command-line arguments ----------
usage() {
  cat >&2 <<EOF
Usage: ${0##*/} [-c N] [-h]

  -c, --connections N   parallel connections per region (default: $CONN, max: 64)
  -h, --help            show this help and exit

Environment:
  BW_DEBUG=1            print the raw curl errors under each failed row
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--connections)
      [ "$#" -ge 2 ] || { echo "Error: $1 needs a value." >&2; usage; exit 2; }
      CONN="$2"; shift 2 ;;
    -c=*|--connections=*)
      CONN="${1#*=}"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "Error: unexpected argument '$1'." >&2; usage; exit 2 ;;
  esac
done

# Each connection pulls CHUNK_MB, so CONN x CHUNK_MB must fit inside the smallest
# test file (1 GiB). 64 x 16 MiB fills exactly that, which is the hard ceiling.
case "$CONN" in
  ''|*[!0-9]*) echo "Error: --connections must be a positive integer (got '$CONN')." >&2; exit 2 ;;
esac
[ "$CONN" -ge 1 ]  || { echo "Error: --connections must be at least 1 (got '$CONN')." >&2; exit 2; }
[ "$CONN" -le 64 ] || { echo "Error: --connections capped at 64 (got '$CONN'); each pulls ${CHUNK_MB} MiB." >&2; exit 2; }

# Downloads are streamed to /dev/null, so they need no scratch space at all.
# Only the upload payload is written to disk, and it is the sole size requirement.
NEED_KB=$(( UL_MB * 1024 + 16384 ))

# ---------- Targets: "Region|download URL" ----------
TARGETS=(
  "North America (Ashburn US)|https://ash-speed.hetzner.com/1GB.bin"
  "Europe (Falkenstein DE)|https://fsn1-speed.hetzner.com/1GB.bin"
  "Asia (Singapore)|https://sin-speed.hetzner.com/1GB.bin"
  "Japan (Tokyo)|https://speedtest.tokyo2.linode.com/1GB-tokyo2.bin"
  "India (Mumbai)|https://speedtest.mumbai1.linode.com/1GB-mumbai1.bin"
  "Middle East (Fujairah AE)|https://fjr.download.datapacket.com/1000mb.bin"
  "Oceania (Melbourne AU)|https://mel.download.datapacket.com/1000mb.bin"
  "Iran (Asiatech, best-effort)|http://at.tadserver.com/1GB.bin"
)
# ------------------------------

command -v curl >/dev/null 2>&1 || { echo "curl is required. Install it and re-run." >&2; exit 1; }

# Scratch dir: try each candidate for real. df alone is not enough -- on tmpfs it
# reports the mount's size limit rather than free memory, and a directory can be
# unwritable while showing plenty of space. So each candidate is also test-written.
SCRATCH=""
for base in "$TMPBASE" /tmp "${TMPDIR:-/tmp}" "$PWD" "$HOME"; do
  [ -d "$base" ] || continue
  kb=$(df -Pk "$base" 2>/dev/null | awk 'NR==2{print $4}')
  [ -n "${kb:-}" ] && [ "$kb" -ge "$NEED_KB" ] || continue
  d=$(mktemp -d "${base%/}/spd.XXXXXX" 2>/dev/null) || continue
  if : >"$d/.probe" 2>/dev/null; then rm -f "$d/.probe"; SCRATCH="$d"; break; fi
  rmdir "$d" 2>/dev/null
done
if [ -z "$SCRATCH" ]; then
  echo "Error: found no writable scratch directory with $(( NEED_KB / 1024 )) MiB free." >&2
  echo "       Tried: $TMPBASE /tmp $PWD $HOME" >&2
  echo "       Lower UL_MB, free some space, or point TMPBASE somewhere roomier." >&2
  exit 1
fi
trap 'rm -rf "$SCRATCH"' EXIT
case "$SCRATCH" in
  "${TMPBASE%/}"/*) : ;;
  *) echo "Note: ${TMPBASE} was unusable; using ${SCRATCH%/*} for the upload payload." >&2 ;;
esac

if [ -t 1 ]; then
  TTY=1; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  TTY=0; RED=''; DIM=''; RST=''
fi
# The measurement functions are called inside $(...), so their stdout is captured.
# Progress therefore goes to stderr, and is only drawn when stderr is a terminal.
BAR=0; [ -t 2 ] && BAR=1
HAVE_PROC=0; [ -d /proc/self ] && HAVE_PROC=1

# ---------- Progress bar ----------
T_US=0
set_now() {   # microseconds since epoch, without forking
  local t="${EPOCHREALTIME:-}"; t="${t/,/.}"
  if [ -n "$t" ]; then T_US="${t/./}"; else T_US=$(( $(date +%s%N) / 1000 )); fi
}

IO_VAL=0
read_io() {   # $1=pid $2=field -> sets IO_VAL, returns 1 if unreadable
  local k v; IO_VAL=0
  [ -r "/proc/$1/io" ] || return 1
  while IFS=': ' read -r k v; do
    if [ "$k" = "$2" ]; then IO_VAL="$v"; return 0; fi
  done < "/proc/$1/io"
  return 1
}

proc_alive() {  # $1=pid -> 0 while running. A reaped-but-unwaited child is a
  local line                     # zombie, and kill -0 still succeeds on those,
  if [ "$HAVE_PROC" -eq 1 ]; then   # so the state field is what actually decides.
    [ -r "/proc/$1/stat" ] || return 1
    read -r line < "/proc/$1/stat" 2>/dev/null || return 1
    line="${line##*) }"
    case "${line%% *}" in Z|X|x) return 1 ;; esac
    return 0
  fi
  kill -0 "$1" 2>/dev/null
}

SPIN='|/-\'
bar_render() {  # $1=label $2=bytes $3=total $4=elapsed us
  [ "$BAR" -eq 1 ] || return 0
  local pct=0 filled i bar='' sp100=0
  [ "$3" -gt 0 ] && pct=$(( $2 * 100 / $3 ))
  [ "$pct" -gt 100 ] && pct=100
  filled=$(( pct * 24 / 100 ))
  for ((i = 0; i < 24; i++)); do
    if [ "$i" -lt "$filled" ]; then bar+='#'; else bar+='.'; fi
  done
  [ "$4" -gt 0 ] && sp100=$(( $2 * 100000000 / 1048576 / $4 ))
  printf '\r  %-28.28s [%s] %3d%%  %5d MiB  %d.%02d MiB/s\033[K' \
         "$1" "$bar" "$pct" "$(( $2 / 1048576 ))" "$(( sp100 / 100 ))" "$(( sp100 % 100 ))" >&2
}

bar_spin() {    # used when /proc/<pid>/io is not readable, so bytes are unknown
  [ "$BAR" -eq 1 ] || return 0
  local n=$(( $2 / 1000000 ))
  printf '\r  %-28.28s [%s] working, %ds elapsed\033[K' \
         "$1" "${SPIN:$(( n % 4 )):1}" "$n" >&2
}

bar_clear() { [ "$BAR" -eq 1 ] && printf '\r\033[K' >&2; return 0; }

watch_pids() {  # $1=label $2=expected bytes $3=io field $4=out prefix ("" disables) $5..=pids
  local label="$1" total="$2" field="$3" outpre="$4"; shift 4
  local pids=("$@") n=$# i alive sum io_ok s_us el fb b
  local -a last
  for ((i = 0; i < n; i++)); do last[i]=0; done
  set_now; s_us="$T_US"
  while :; do
    alive=0; sum=0; io_ok=0
    for ((i = 0; i < n; i++)); do
      if proc_alive "${pids[i]}"; then
        alive=1
        # While the connection is live, /proc/<pid>/io gives smooth progress.
        # Hold the max per connection so the bar cannot count backwards.
        if read_io "${pids[i]}" "$field"; then
          io_ok=1
          [ "$IO_VAL" -gt "${last[i]}" ] && last[i]="$IO_VAL"
        fi
      elif [ -n "$outpre" ]; then
        # The process has exited: /proc/<pid>/io is gone and its last live reading
        # was only a partial, setup-era count. curl wrote the authoritative byte
        # total (field 2 of its -w output) on exit, so read that instead -- without
        # it, a transfer that finishes inside one 0.2s poll freezes the bar near 1%.
        # curl's -w output has no trailing newline, so read exits non-zero while
        # still assigning the fields: never gate the assignment on its exit status.
        b=0; read -r _ b <"$outpre$i.out" 2>/dev/null
        fb="${b%%.*}"; [ -n "$fb" ] || fb=0
        [ "$fb" -gt "${last[i]}" ] && last[i]="$fb"
      fi
      sum=$(( sum + last[i] ))
    done
    set_now; el=$(( T_US - s_us ))
    if [ "$io_ok" -eq 1 ] || [ "$sum" -gt 0 ]; then
      bar_render "$label" "$sum" "$total" "$el"
    else
      bar_spin "$label" "$el"
    fi
    [ "$alive" -eq 1 ] || break
    # Never outlive the connections themselves, whatever /proc reports.
    [ "$el" -gt $(( (DL_TIMEOUT + 60) * 1000000 )) ] && break
    sleep 0.2
  done
}

# ---------- Failure reasons ----------
curl_reason() {  # $1=exit code [$2=stderr file] -> short human reason
  if [ -n "${2:-}" ] && [ -s "$2" ]; then
    grep -qi 'certificate'            "$2" && { echo "TLS certificate rejected"; return; }
    grep -qi 'resolve host'           "$2" && { echo "DNS lookup failed"; return; }
    grep -qi 'connection refused'     "$2" && { echo "connection refused"; return; }
    grep -qi 'network is unreachable' "$2" && { echo "network unreachable"; return; }
    grep -qi 'no route to host'       "$2" && { echo "no route to host"; return; }
  fi
  case "$1" in
    5)  echo "proxy could not be resolved" ;;
    6)  echo "DNS lookup failed" ;;
    7)  echo "could not connect" ;;
    18) echo "transfer ended early" ;;
    22) echo "server returned an error" ;;
    23) echo "local write error" ;;
    28) echo "timed out with no data" ;;
    35|53|59) echo "TLS handshake failed" ;;
    52) echo "server sent an empty reply" ;;
    56) echo "connection reset by peer" ;;
    60) echo "TLS certificate rejected" ;;
    77) echo "CA bundle unreadable" ;;
    *)  echo "curl error code $1" ;;
  esac
}

# ---------- Measurement ----------
probe() {  # $1=url -> "206|" (ranges work) | "200|" (no ranges) | "FAILED|reason"
  local code rc err="$SCRATCH/probe.err"
  code=$(curl -sS --location --range 0-1023 -o /dev/null -w '%{http_code}' \
              --connect-timeout 15 --max-time 30 "$1" 2>"$err")
  rc=$?
  [ "$rc" -ne 0 ] && { echo "FAILED|$(curl_reason "$rc" "$err")"; return; }
  case "$code" in
    206)     echo "206|" ;;
    200)     echo "200|" ;;
    404|410) echo "FAILED|file missing on server ($code)" ;;
    401|403) echo "FAILED|server refused request ($code)" ;;
    5??)     echo "FAILED|server error ($code)" ;;
    000)     echo "FAILED|no response from server" ;;
    *)       echo "FAILED|unexpected HTTP $code" ;;
  esac
}

dl_speed() {  # $1=label $2=url -> "MiB/s|" or "FAILED|reason"
  local label="$1" url="$2" p mode nconn chunk total i start end
  local rc=0 w sum=0 b s_us e_us el code code0=000

  # Clear before probing, so a probe failure cannot leave the previous region's
  # connection logs lying around for the debug dump to pick up.
  rm -f "$SCRATCH"/c*.out "$SCRATCH"/c*.err
  p=$(probe "$url"); mode="${p%%|*}"
  [ "$mode" = "FAILED" ] && { echo "$p"; return; }

  chunk=$(( CHUNK_MB * 1048576 ))
  nconn="$CONN"
  # A server that ignores Range would hand every connection the same bytes from
  # offset 0, so fall back to a single time-boxed stream instead.
  [ "$mode" = "200" ] && nconn=1
  total=$(( chunk * nconn ))

  local -a pids=()
  set_now; s_us="$T_US"
  for ((i = 0; i < nconn; i++)); do
    start=$(( i * chunk )); end=$(( start + chunk - 1 ))
    # --fail makes curl abort with exit 22 on any 4xx/5xx instead of streaming
    # the error page: a 503 "Service Unavailable" body would otherwise be counted
    # as download bytes and reported as a spurious near-zero speed. %{http_code}
    # is captured alongside the byte count so the failure reason can name the code.
    if [ "$mode" = "206" ]; then
      curl -sS --fail --location --range "$start-$end" -o /dev/null -w '%{http_code} %{size_download}' \
           --connect-timeout 15 --max-time "$DL_TIMEOUT" \
           "$url" >"$SCRATCH/c$i.out" 2>"$SCRATCH/c$i.err" &
    else
      curl -sS --fail --location -o /dev/null -w '%{http_code} %{size_download}' \
           --connect-timeout 15 --max-time "$DL_TIMEOUT" \
           "$url" >"$SCRATCH/c$i.out" 2>"$SCRATCH/c$i.err" &
    fi
    pids+=("$!")
  done

  watch_pids "$label" "$total" rchar "$SCRATCH/c" "${pids[@]}"
  for ((i = 0; i < nconn; i++)); do
    wait "${pids[i]}"; w=$?
    [ "$w" -ne 0 ] && [ "$rc" -eq 0 ] && rc="$w"
  done
  set_now; e_us="$T_US"
  bar_clear

  for ((i = 0; i < nconn; i++)); do
    code=000 b=0; read -r code b <"$SCRATCH/c$i.out" 2>/dev/null
    [ "$i" -eq 0 ] && code0="${code:-000}"
    b="${b%%.*}"; [ -n "$b" ] || b=0
    sum=$(( sum + b ))
  done

  # A timeout that still moved bytes is a valid measurement, not a failure. With
  # --fail a positive sum can only be real payload now, never a counted error page.
  if [ "$sum" -le 0 ]; then
    if [ "${code0:-000}" -ge 400 ] 2>/dev/null; then
      echo "FAILED|server error ($code0)"
    else
      echo "FAILED|$(curl_reason "$rc" "$SCRATCH/c0.err")"
    fi
    return
  fi
  el=$(( e_us - s_us )); [ "$el" -le 0 ] && el=1
  awk -v b="$sum" -v us="$el" 'BEGIN{ printf "%.2f|", b / (us / 1000000) / 1048576 }'
}

ul_speed() {  # -> "MiB/s|" or "FAILED|reason", to the nearest Cloudflare edge
  local pid rc code bps out="$SCRATCH/ul.out" err="$SCRATCH/ul.err"

  # --upload-file streams from disk; --data-binary would slurp the whole payload
  # into RAM first, which is exactly what a small box cannot afford.
  curl -sS -X POST -o /dev/null -w '%{http_code} %{speed_upload}' \
       --connect-timeout 20 --max-time 900 \
       --header 'Content-Type: application/octet-stream' \
       --upload-file "$UPFILE" "$UPLOAD_URL" >"$out" 2>"$err" &
  pid=$!
  watch_pids "upload to nearest edge" $(( UL_MB * 1048576 )) wchar "" "$pid"
  wait "$pid"; rc=$?
  bar_clear

  code=""; bps=""; read -r code bps <"$out" 2>/dev/null
  # Some endpoints only accept a plain POST body; retry that way before giving up.
  if [ "$rc" -eq 0 ] && [ "${code:-0}" -ge 400 ] 2>/dev/null; then
    curl -sS -o /dev/null -w '%{http_code} %{speed_upload}' \
         --connect-timeout 20 --max-time 900 \
         --data-binary @"$UPFILE" "$UPLOAD_URL" >"$out" 2>"$err" &
    pid=$!
    watch_pids "upload to nearest edge (retry)" $(( UL_MB * 1048576 )) wchar "" "$pid"
    wait "$pid"; rc=$?
    bar_clear
    code=""; bps=""; read -r code bps <"$out" 2>/dev/null
  fi

  if [ "$rc" -ne 0 ]; then
    echo "FAILED|$(curl_reason "$rc" "$err")"
  elif [ "${code:-0}" -ge 400 ] 2>/dev/null; then
    echo "FAILED|upload rejected (HTTP $code)"
  elif [ -z "${bps:-}" ] || [ "${bps%%.*}" -le 0 ] 2>/dev/null; then
    echo "FAILED|no bytes accepted"
  else
    awk -v b="$bps" 'BEGIN{ printf "%.2f|", b / 1048576 }'
  fi
}

# ---------- Run ----------
UPFILE="$SCRATCH/up.bin"
if ! dd if=/dev/zero of="$UPFILE" bs=1M count="$UL_MB" status=none 2>"$SCRATCH/dd.err"; then
  echo "Error: could not write the ${UL_MB} MiB upload payload to $SCRATCH" >&2
  sed -e 's/^/       /' "$SCRATCH/dd.err" >&2
  exit 1
fi

[ "$TTY" -eq 1 ] && printf '%sMeasuring %d regions (%d x %d MiB each), then one %d MiB upload...%s\n\n' \
  "$DIM" "${#TARGETS[@]}" "$CONN" "$CHUNK_MB" "$UL_MB" "$RST"

declare -a R_LABEL=() R_VAL=() R_REASON=()
failures=0

for entry in "${TARGETS[@]}"; do
  label="${entry%%|*}"; url="${entry##*|}"
  idx=${#R_LABEL[@]}
  raw=$(dl_speed "$label" "$url")
  R_LABEL+=("$label"); R_VAL+=("${raw%%|*}"); R_REASON+=("${raw#*|}")
  [ "${raw%%|*}" = "FAILED" ] && failures=$(( failures + 1 ))
  # Keep this region's errors: the shared c*.err files are reused by the next one.
  cat "$SCRATCH/probe.err" "$SCRATCH/c0.err" 2>/dev/null | head -n 4 >"$SCRATCH/row$idx.err"
done

ul_raw=$(ul_speed); ul="${ul_raw%%|*}"; ul_reason="${ul_raw#*|}"
[ "$ul" = "FAILED" ] && failures=$(( failures + 1 ))
rm -f "$UPFILE"

# ---------- Summary ----------
# One measurement column: a failed region shows its reason where the number would
# have been, so the table stays two columns wide.
DLW=30
DASH=$(printf '%*s' "$DLW" ''); DASH="${DASH// /-}"

cell() {  # $1=text $2=1 when this is a failure -> right-aligned in DLW, red if failed
  local padded; printf -v padded "%${DLW}.${DLW}s" "$1"
  if [ "$2" = "1" ]; then printf '%s' "${RED}${padded}${RST}"; else printf '%s' "$padded"; fi
}

printf "%-30s %${DLW}s\n" "Region" "Download (MiB/s)"
printf '%-30s %s\n' "------------------------------" "$DASH"
for i in "${!R_LABEL[@]}"; do
  if [ "${R_VAL[i]}" = "FAILED" ]; then
    printf '%-30s %s\n' "${R_LABEL[i]}" "$(cell "${R_REASON[i]}" 1)"
  else
    printf '%-30s %s\n' "${R_LABEL[i]}" "$(cell "${R_VAL[i]}" 0)"
  fi
  if [ "$BW_DEBUG" = "1" ] && [ "${R_VAL[i]}" = "FAILED" ] && [ -s "$SCRATCH/row$i.err" ]; then
    sed -e 's/^/    /' "$SCRATCH/row$i.err"
  fi
done

echo
if [ "$ul" = "FAILED" ]; then
  printf 'Upload (%s MiB to nearest Cloudflare edge): %s%s%s\n' \
         "$UL_MB" "$RED" "$ul_reason" "$RST"
  [ "$BW_DEBUG" = "1" ] && [ -s "$SCRATCH/ul.err" ] && head -n 4 "$SCRATCH/ul.err" | sed -e 's/^/    /'
else
  printf 'Upload (%s MiB to nearest Cloudflare edge): %s MiB/s\n' "$UL_MB" "$ul"
fi

echo
echo "Downloads are streamed to /dev/null over ${CONN} connections, so nothing is written"
echo "to disk. Upload is measured once, against the nearest Cloudflare edge rather than"
echo "against each region: it describes your server's uplink, not the path to any row."
if [ "$failures" -gt 0 ] && [ "$BW_DEBUG" != "1" ]; then
  echo
  printf '%s\n' "${DIM}Re-run with BW_DEBUG=1 ./bandwidth_test.sh to see the raw curl errors.${RST}"
fi
