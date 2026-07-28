#!/usr/bin/env bash
set -uo pipefail

# ---------- Settings ----------
CONN=8                                           # parallel connections per region (default; override with -c/--connections)
DEF_TIMEBOX_S=10                                 # default --time-box, in seconds
DEF_SIZE_BYTES=$(( 512 * 1048576 ))              # default --file-size, in bytes (512 MiB)
UL_MB=500                                        # upload payload size in MiB
DL_TIMEOUT=90                                    # hard per-connection cap in size mode (time mode uses --time-box)
TMPBASE="/dev/shm"                               # scratch for the upload payload; falls back to /tmp
UPLOAD_URL="https://speed.cloudflare.com/__up"   # only reliable public upload sink (NEAREST edge, not per-region)
BW_DEBUG="${BW_DEBUG:-0}"                        # BW_DEBUG=1 prints the raw curl errors under each failed row

# Measurement mode: "time" (download for up to TIMEBOX_S) or "size" (download up
# to SIZE_BYTES). Time is the default; a --file-size / --time-box flag switches it.
MODE=time
TIMEBOX_S="$DEF_TIMEBOX_S"
SIZE_BYTES="$DEF_SIZE_BYTES"

# ---------- Command-line arguments ----------
usage() {
  cat >&2 <<EOF
Usage: ${0##*/} [options]

  -c, --connections N   parallel connections per region (default: $CONN, max: 64)
      --time-box[=DUR]  measure each region for up to DUR (default: ${DEF_TIMEBOX_S}s); the
                        default mode. Its bar fills to 100% over DUR.
      --file-size[=SZ]  instead, download up to SZ per region (default: 512MiB). Its
                        bar fills to 100% at SZ. Units: KiB/MiB/GiB or KB/MB/GB; a
                        bare number is MiB.
  -h, --help            show this help and exit

Both limits are caps: a region may finish sooner (a fast link empties the file),
and its bar still completes to 100% -- the file's own size does not matter. Pass a
value with '=' (--time-box=30s, --file-size=1GiB); the bare flag uses its default.
The last of --time-box / --file-size on the command line wins.

Environment:
  BW_DEBUG=1            print the raw curl errors under each failed row
EOF
}

parse_size() {  # $1 human size (512MiB, 1G, 256) -> bytes on stdout; error+return 1 on bad input
  local s="$1" num unit mult
  num="${s%%[!0-9]*}"; unit="${s:${#num}}"; unit="${unit,,}"
  [ -n "$num" ] || { echo "Error: --file-size needs a number (got '$s')." >&2; return 1; }
  case "$unit" in
    ''|mib|m) mult=1048576 ;;
    b)        mult=1 ;;
    kib|k)    mult=1024 ;;
    kb)       mult=1000 ;;
    mb)       mult=1000000 ;;
    gib|g)    mult=1073741824 ;;
    gb)       mult=1000000000 ;;
    *) echo "Error: unknown size unit in '$s' (use B, KiB, MiB, GiB, KB, MB, GB)." >&2; return 1 ;;
  esac
  echo $(( num * mult ))
}

parse_time() {  # $1 like 10s, 10, 2m -> seconds on stdout; error+return 1 on bad input
  local s="$1" num unit
  num="${s%%[!0-9]*}"; unit="${s:${#num}}"; unit="${unit,,}"
  [ -n "$num" ] || { echo "Error: --time-box needs a number (got '$s')." >&2; return 1; }
  case "$unit" in
    ''|s|sec) echo "$num" ;;
    m|min)    echo $(( num * 60 )) ;;
    *) echo "Error: unknown time unit in '$s' (use s or m)." >&2; return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--connections)
      [ "$#" -ge 2 ] || { echo "Error: $1 needs a value." >&2; usage; exit 2; }
      CONN="$2"; shift 2 ;;
    -c=*|--connections=*)
      CONN="${1#*=}"; shift ;;
    --time-box)    MODE=time; shift ;;
    --time-box=*)  MODE=time; TIMEBOX_S=$(parse_time "${1#*=}") || exit 2; shift ;;
    --file-size)   MODE=size; shift ;;
    --file-size=*) MODE=size; SIZE_BYTES=$(parse_size "${1#*=}") || exit 2; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      echo "Error: unexpected argument '$1'." >&2; usage; exit 2 ;;
  esac
done

# Each connection is a separate curl process; 64 keeps a run from forking a swarm.
case "$CONN" in
  ''|*[!0-9]*) echo "Error: --connections must be a positive integer (got '$CONN')." >&2; exit 2 ;;
esac
[ "$CONN" -ge 1 ]  || { echo "Error: --connections must be at least 1 (got '$CONN')." >&2; exit 2; }
[ "$CONN" -le 64 ] || { echo "Error: --connections capped at 64 (got '$CONN')." >&2; exit 2; }
[ "$SIZE_BYTES" -ge 1048576 ] || { echo "Error: --file-size must be at least 1 MiB." >&2; exit 2; }
[ "$TIMEBOX_S" -ge 1 ]        || { echo "Error: --time-box must be at least 1 second." >&2; exit 2; }

# Downloads are streamed to /dev/null, so they need no scratch space at all.
# Only the upload payload is written to disk, and it is the sole size requirement.
NEED_KB=$(( UL_MB * 1024 + 16384 ))

# ---------- Targets: "Region|url1|url2|..." ----------
# Each region lists several distinct-host mirrors near it; the connections are
# spread round-robin across them, so a single host's concurrency cap (e.g. Hetzner
# serves 2 connections per IP) no longer throttles the whole region. Hosts on the
# same provider but in different cities are separate servers with separate limits.
TARGETS=(
  "North America (US East)|https://ash-speed.hetzner.com/1GB.bin|https://speedtest.newark.linode.com/1GB-newark.bin|https://nyc.download.datapacket.com/1000mb.bin|https://speedtest.atlanta.linode.com/1GB-atlanta.bin"
  "Europe (Germany/central)|https://fsn1-speed.hetzner.com/1GB.bin|https://speedtest.frankfurt.linode.com/1GB-frankfurt.bin|https://fra.download.datapacket.com/1000mb.bin|https://proof.ovh.net/files/1Gb.dat"
  "Asia (Singapore)|https://sin-speed.hetzner.com/1GB.bin|https://speedtest.singapore.linode.com/1GB-singapore.bin|https://sin.download.datapacket.com/1000mb.bin|https://speedtest.jakarta.linode.com/1GB-jakarta.bin"
  "Japan (Tokyo/Osaka)|https://speedtest.tokyo2.linode.com/1GB-tokyo2.bin|https://speedtest.osaka.linode.com/1GB-osaka.bin|https://tyo.download.datapacket.com/1000mb.bin"
  "India (Mumbai/Chennai)|https://speedtest.mumbai1.linode.com/1GB-mumbai1.bin|https://speedtest.chennai.linode.com/1GB-chennai.bin|https://blr-in-ping.vultr.com/vultr.com.1000MB.bin|https://del-in-ping.vultr.com/vultr.com.1000MB.bin"
  "Middle East (Fujairah/Tel Aviv)|https://fjr.download.datapacket.com/1000mb.bin|https://tlv.download.datapacket.com/1000mb.bin"
  "Oceania (AU/NZ)|https://mel.download.datapacket.com/1000mb.bin|https://syd.download.datapacket.com/1000mb.bin|https://speedtest.sydney.linode.com/1GB-sydney.bin|https://akl.download.datapacket.com/1000mb.bin"
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
bar_render() {  # $1=label $2=pct $3=bytes $4=elapsed us
  [ "$BAR" -eq 1 ] || return 0
  local pct="$2" filled i bar='' sp100=0
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  filled=$(( pct * 24 / 100 ))
  for ((i = 0; i < 24; i++)); do
    if [ "$i" -lt "$filled" ]; then bar+='#'; else bar+='.'; fi
  done
  [ "$4" -gt 0 ] && sp100=$(( $3 * 100000000 / 1048576 / $4 ))
  printf '\r  %-28.28s [%s] %3d%%  %5d MiB  %d.%02d MiB/s\033[K' \
         "$1" "$bar" "$pct" "$(( $3 / 1048576 ))" "$(( sp100 / 100 ))" "$(( sp100 % 100 ))" >&2
}

bar_finish() {  # $1=label $2=bytes $3=elapsed us -> draw a full 100% bar and keep the line
  [ "$BAR" -eq 1 ] || return 0
  bar_render "$1" 100 "$2" "$3"
  printf '\n' >&2
}

bar_spin() {    # used when /proc/<pid>/io is not readable, so bytes are unknown
  [ "$BAR" -eq 1 ] || return 0
  local n=$(( $2 / 1000000 ))
  printf '\r  %-28.28s [%s] working, %ds elapsed\033[K' \
         "$1" "${SPIN:$(( n % 4 )):1}" "$n" >&2
}

bar_clear() { [ "$BAR" -eq 1 ] && printf '\r\033[K' >&2; return 0; }

watch_pids() {  # $1=label $2=byte total $3=time total us $4=basis(bytes|time) $5=io field $6=out prefix ("" disables) $7..=pids
  local label="$1" btotal="$2" ttotal="$3" basis="$4" field="$5" outpre="$6"; shift 6
  local pids=("$@") n=$# i alive sum io_ok s_us el fb b pct spct
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
    # The bar estimates progress toward whenever the download actually ends. In
    # size mode that is bytes toward the cap. In time mode it is whichever finishes
    # first: the clock reaching the time-box (1/timebox per second), or the bytes
    # reaching the whole file (a fast link empties it early) -- so take the larger
    # of the two. dl_speed then snaps it to a full 100% on success.
    if [ "$basis" = "time" ]; then
      pct=0; [ "$ttotal" -gt 0 ] && pct=$(( el * 100 / ttotal ))
      if [ "$btotal" -gt 0 ]; then
        spct=$(( sum * 100 / btotal ))
        [ "$spct" -gt "$pct" ] && pct="$spct"
      fi
    else
      pct=0; [ "$btotal" -gt 0 ] && pct=$(( sum * 100 / btotal ))
    fi
    if [ "$basis" = "time" ] || [ "$io_ok" -eq 1 ] || [ "$sum" -gt 0 ]; then
      bar_render "$label" "$pct" "$sum" "$el"
    else
      bar_spin "$label" "$el"
    fi
    [ "$alive" -eq 1 ] || break
    # Never outlive the connections themselves, whatever /proc reports.
    [ "$el" -gt $(( (DL_TIMEOUT + TIMEBOX_S + 60) * 1000000 )) ] && break
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
probe() {  # $1=url -> "206|SIZE" (ranges work) | "200|SIZE" (no ranges) | "FAILED|reason"
  local code rc size='' hdr="$SCRATCH/probe.hdr" err="$SCRATCH/probe.err"
  code=$(curl -sS --location --range 0-1023 -D "$hdr" -o /dev/null -w '%{http_code}' \
              --connect-timeout 15 --max-time 30 "$1" 2>"$err")
  rc=$?
  [ "$rc" -ne 0 ] && { echo "FAILED|$(curl_reason "$rc" "$err")"; return; }
  # File size: prefer the total after the slash in a 206 Content-Range header
  # (bytes 0-1023/TOTAL); fall back to Content-Length. Take the last match so a
  # redirect's final hop wins, and match case-insensitively without gawk's
  # IGNORECASE (mawk, the Debian/Ubuntu default, lacks it).
  size=$(awk 'tolower($0) ~ /^content-range:/ { n=split($0,a,"/"); if(n>=2){s=a[n]; gsub(/[^0-9]/,"",s); if(s!="") v=s} } END{ if(v!="") print v }' "$hdr")
  [ -n "$size" ] || size=$(awk 'tolower($0) ~ /^content-length:/ { s=$2; gsub(/[^0-9]/,"",s); if(s!="") v=s } END{ if(v!="") print v }' "$hdr")
  case "$code" in
    206)     echo "206|$size" ;;
    200)     echo "200|$size" ;;
    404|410) echo "FAILED|file missing on server ($code)" ;;
    401|403) echo "FAILED|server refused request ($code)" ;;
    5??)     echo "FAILED|server error ($code)" ;;
    000)     echo "FAILED|no response from server" ;;
    *)       echo "FAILED|unexpected HTTP $code" ;;
  esac
}

dl_speed() {  # $1=label $2..=one or more distinct target URLs -> "MiB/s|" or "FAILED|reason"
  local label="$1"; shift
  local -a urls=("$@")
  local rc=0 w sum=0 b s_us e_us el code code0=000 i u slot Su Cu seg start end range
  local basis btotal ttotal maxt per_conn nconn totsize p m sz first_reason=""

  # Clear before probing, so a probe failure cannot leave the previous region's
  # connection logs lying around for the debug dump to pick up.
  rm -f "$SCRATCH"/c*.out "$SCRATCH"/c*.err

  # Probe every target; keep the ones that answer, with their size and range mode.
  # Spreading a region across several distinct hosts is what defeats a per-host
  # concurrency cap (e.g. Hetzner serves only 2 connections per IP): the other
  # hosts carry the rest instead of the region collapsing to two connections.
  local -a uurl=() umode=() usize=()
  for u in "${urls[@]}"; do
    p=$(probe "$u"); m="${p%%|*}"
    if [ "$m" = "FAILED" ]; then
      [ -z "$first_reason" ] && first_reason="${p#*|}"
      continue
    fi
    sz="${p#*|}"; case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    uurl+=("$u"); umode+=("$m"); usize+=("$sz")
  done
  local nurls=${#uurl[@]}
  if [ "$nurls" -eq 0 ]; then
    echo "FAILED|${first_reason:-no usable target}"
    return
  fi

  # Round-robin the connections over the usable hosts, and count how many land on
  # each so their byte ranges can be staggered within that host's file.
  nconn="$CONN"
  local -a ccount=()
  for ((i = 0; i < nurls; i++)); do ccount[i]=0; done
  for ((i = 0; i < nconn; i++)); do u=$(( i % nurls )); ccount[u]=$(( ${ccount[u]} + 1 )); done

  # Bar totals: time mode fills by the clock toward the time-box or by bytes toward
  # the whole downloadable set (the usable files summed); size mode fills by bytes
  # toward the --file-size cap. Per-connection byte budget in size mode is the cap
  # split evenly across all connections.
  totsize=0
  for ((i = 0; i < nurls; i++)); do totsize=$(( totsize + ${usize[i]} )); done
  if [ "$MODE" = "time" ]; then
    basis=time; ttotal=$(( TIMEBOX_S * 1000000 )); btotal="$totsize"; maxt="$TIMEBOX_S"
  else
    basis=bytes; ttotal=0; maxt="$DL_TIMEOUT"; btotal="$SIZE_BYTES"
  fi
  per_conn=0; [ "$MODE" = "size" ] && [ "$nconn" -gt 0 ] && per_conn=$(( SIZE_BYTES / nconn ))

  local -a pids=()
  set_now; s_us="$T_US"
  for ((i = 0; i < nconn; i++)); do
    u=$(( i % nurls )); slot=$(( i / nurls ))   # which host, and this connection's slot on it
    Su="${usize[u]}"; Cu="${ccount[u]}"
    # --fail makes curl abort with exit 22 on any 4xx/5xx instead of streaming the
    # error page: a 503 body would otherwise be counted as download bytes.
    # %{http_code} is captured with the byte count so a failure reason can name it.
    if [ "${umode[u]}" = "206" ] && [ "$Su" -gt 0 ]; then
      if [ "$MODE" = "size" ]; then
        start=$(( slot * per_conn )); end=$(( start + per_conn - 1 ))
        [ "$start" -ge "$Su" ] && start=0                      # never seek past EOF
        [ "$end" -ge "$Su" ] && end=$(( Su - 1 ))
        range="$start-$end"
      else
        seg=$(( Su / Cu )); range="$(( slot * seg ))-"          # open-ended; time-box is the limiter
      fi
      curl -sS --fail --location --range "$range" -o /dev/null -w '%{http_code} %{size_download}' \
           --connect-timeout 15 --max-time "$maxt" \
           "${uurl[u]}" >"$SCRATCH/c$i.out" 2>"$SCRATCH/c$i.err" &
    else
      curl -sS --fail --location -o /dev/null -w '%{http_code} %{size_download}' \
           --connect-timeout 15 --max-time "$maxt" \
           "${uurl[u]}" >"$SCRATCH/c$i.out" 2>"$SCRATCH/c$i.err" &
    fi
    pids+=("$!")
  done

  watch_pids "$label" "$btotal" "$ttotal" "$basis" rchar "$SCRATCH/c" "${pids[@]}"
  for ((i = 0; i < nconn; i++)); do
    wait "${pids[i]}"; w=$?
    [ "$w" -ne 0 ] && [ "$rc" -eq 0 ] && rc="$w"
  done
  set_now; e_us="$T_US"

  for ((i = 0; i < nconn; i++)); do
    code=000 b=0; read -r code b <"$SCRATCH/c$i.out" 2>/dev/null
    [ "$i" -eq 0 ] && code0="${code:-000}"
    b="${b%%.*}"; [ -n "$b" ] || b=0
    sum=$(( sum + b ))
  done

  # A timeout that still moved bytes is a valid measurement, not a failure. With
  # --fail a positive sum can only be real payload now, never a counted error page.
  if [ "$sum" -le 0 ]; then
    bar_clear
    if [ "${code0:-000}" -ge 400 ] 2>/dev/null; then
      echo "FAILED|server error ($code0)"
    else
      echo "FAILED|$(curl_reason "$rc" "$SCRATCH/c0.err")"
    fi
    return
  fi
  el=$(( e_us - s_us )); [ "$el" -le 0 ] && el=1
  # Snap the bar to a full 100% on success -- an early finish (cap not reached)
  # still shows a completed bar, on its own line.
  bar_finish "$label" "$sum" "$el"
  awk -v b="$sum" -v us="$el" 'BEGIN{ printf "%.2f|", b / (us / 1000000) / 1048576 }'
}

ul_speed() {  # -> "MiB/s|" or "FAILED|reason", to the nearest Cloudflare edge
  local pid rc code bps s_us e_us el out="$SCRATCH/ul.out" err="$SCRATCH/ul.err"
  local payload=$(( UL_MB * 1048576 ))

  # --upload-file streams from disk; --data-binary would slurp the whole payload
  # into RAM first, which is exactly what a small box cannot afford.
  set_now; s_us="$T_US"
  curl -sS -X POST -o /dev/null -w '%{http_code} %{speed_upload}' \
       --connect-timeout 20 --max-time 900 \
       --header 'Content-Type: application/octet-stream' \
       --upload-file "$UPFILE" "$UPLOAD_URL" >"$out" 2>"$err" &
  pid=$!
  watch_pids "upload to nearest edge" "$payload" 0 bytes wchar "" "$pid"
  wait "$pid"; rc=$?

  code=""; bps=""; read -r code bps <"$out" 2>/dev/null
  # Some endpoints only accept a plain POST body; retry that way before giving up.
  if [ "$rc" -eq 0 ] && [ "${code:-0}" -ge 400 ] 2>/dev/null; then
    curl -sS -o /dev/null -w '%{http_code} %{speed_upload}' \
         --connect-timeout 20 --max-time 900 \
         --data-binary @"$UPFILE" "$UPLOAD_URL" >"$out" 2>"$err" &
    pid=$!
    watch_pids "upload to nearest edge (retry)" "$payload" 0 bytes wchar "" "$pid"
    wait "$pid"; rc=$?
    code=""; bps=""; read -r code bps <"$out" 2>/dev/null
  fi
  set_now; e_us="$T_US"

  if [ "$rc" -ne 0 ]; then
    bar_clear; echo "FAILED|$(curl_reason "$rc" "$err")"
  elif [ "${code:-0}" -ge 400 ] 2>/dev/null; then
    bar_clear; echo "FAILED|upload rejected (HTTP $code)"
  elif [ -z "${bps:-}" ] || [ "${bps%%.*}" -le 0 ] 2>/dev/null; then
    bar_clear; echo "FAILED|no bytes accepted"
  else
    el=$(( e_us - s_us )); [ "$el" -le 0 ] && el=1
    bar_finish "upload to nearest edge" "$payload" "$el"
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

if [ "$MODE" = "time" ]; then
  MODE_DESC="up to ${TIMEBOX_S}s each"
else
  MODE_DESC="up to $(( SIZE_BYTES / 1048576 )) MiB each"
fi
[ "$TTY" -eq 1 ] && printf '%sMeasuring %d regions (%s over %d connections), then one %d MiB upload...%s\n\n' \
  "$DIM" "${#TARGETS[@]}" "$MODE_DESC" "$CONN" "$UL_MB" "$RST"

declare -a R_LABEL=() R_VAL=() R_REASON=()
failures=0

for entry in "${TARGETS[@]}"; do
  IFS='|' read -r -a parts <<< "$entry"
  label="${parts[0]}"; urls=("${parts[@]:1}")
  idx=${#R_LABEL[@]}
  raw=$(dl_speed "$label" "${urls[@]}")
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
if [ "$MODE" = "time" ]; then
  echo "Each region was measured for up to ${TIMEBOX_S}s over ${CONN} connections spread across"
  echo "several distinct-host mirrors (a fast link may finish sooner). Downloads are streamed"
  echo "to /dev/null, so nothing is written"
else
  echo "Each region downloaded up to $(( SIZE_BYTES / 1048576 )) MiB over ${CONN} connections spread across several"
  echo "distinct-host mirrors. Downloads are streamed to /dev/null, so nothing is written"
fi
echo "to disk. Upload is measured once, against the nearest Cloudflare edge rather than"
echo "against each region: it describes your server's uplink, not the path to any row."
if [ "$failures" -gt 0 ] && [ "$BW_DEBUG" != "1" ]; then
  echo
  printf '%s\n' "${DIM}Re-run with BW_DEBUG=1 ./bandwidth_test.sh to see the raw curl errors.${RST}"
fi
