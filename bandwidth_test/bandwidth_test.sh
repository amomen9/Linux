#!/usr/bin/env bash
set -uo pipefail

# ---------- Settings ----------
CONN=16                                          # download connections per file (aria2c cap = 16)
UL_MB=100                                         # upload payload size in MiB (uplinks are slow; keep modest)
TMPBASE="/dev/shm"                                # RAM scratch; falls back to /tmp if too small
NEED_KB=1153434                                   # ~1.1 GiB headroom for the 1 GB download file
UPLOAD_URL="https://speed.cloudflare.com/__up"    # only reliable public upload sink (NEAREST edge, not per-region)

# ---------- Targets: "Region|download URL" ----------
TARGETS=(
  "North America (Ashburn US)|https://ash-speed.hetzner.com/1GB.bin"
  "Europe (Falkenstein DE)|https://fsn1-speed.hetzner.com/1GB.bin"
  "Asia (Singapore)|https://sin-speed.hetzner.com/1GB.bin"
  "Japan (Tokyo)|https://hnd-jp-ping.vultr.com/vultr.com.1000MB.bin"
  "India (Mumbai)|https://bom-in-ping.vultr.com/vultr.com.1000MB.bin"
  "Middle East (Fujairah AE)|https://fjr.download.datapacket.com/1000mb.bin"
  "Oceania (Melbourne AU)|https://mel.download.datapacket.com/1000mb.bin"
  "Iran (Asiatech, best-effort)|http://at.tadserver.com/1GB.bin"
)
# ------------------------------

for t in aria2c curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t is required. Install it and re-run."; exit 1; }
done

# Scratch dir: prefer RAM, fall back to disk if it can't hold the download.
avail_kb=$(df -Pk "$TMPBASE" 2>/dev/null | awk 'NR==2{print $4}')
if [ -z "${avail_kb:-}" ] || [ "$avail_kb" -lt "$NEED_KB" ]; then
  echo "Note: ${TMPBASE} lacks ~1.1 GiB free -- falling back to /tmp." >&2
  TMPBASE="/tmp"
fi
SCRATCH="$(mktemp -d "${TMPBASE%/}/spd.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# Build the upload payload once and reuse it for every row.
UPFILE="$SCRATCH/up.bin"
dd if=/dev/zero of="$UPFILE" bs=1M count="$UL_MB" status=none

dl_speed() {  # $1=url -> MiB/s (avg) or FAILED
  local url="$1" out="$SCRATCH/dl.bin" s e b
  rm -f "$out"
  s=$(date +%s.%N)
  if aria2c -x"$CONN" -s"$CONN" -k1M --file-allocation=none --allow-overwrite=true \
            --console-log-level=error --summary-interval=0 \
            --timeout=30 --connect-timeout=20 --max-tries=2 \
            --dir="$SCRATCH" --out="dl.bin" "$url" >/dev/null 2>&1; then
    e=$(date +%s.%N); b=$(stat -c%s "$out" 2>/dev/null || echo 0); rm -f "$out"
    awk -v b="$b" -v s="$s" -v e="$e" 'BEGIN{d=e-s; if(d<=0)d=1; printf "%.2f", b/d/1048576}'
  else
    rm -f "$out"; echo "FAILED"
  fi
}

ul_speed() {  # -> MiB/s to nearest Cloudflare edge
  local bps
  bps=$(curl -s -o /dev/null -w '%{speed_upload}' --connect-timeout 20 --max-time 900 \
        --data-binary @"$UPFILE" "$UPLOAD_URL" 2>/dev/null)
  awk -v b="${bps:-0}" 'BEGIN{printf "%.2f", b/1048576}'
}

printf '%-30s %16s %16s\n' "Region" "Download (MiB/s)" "Upload* (MiB/s)"
printf '%-30s %16s %16s\n' "------------------------------" "----------------" "----------------"
for entry in "${TARGETS[@]}"; do
  label="${entry%%|*}"; url="${entry##*|}"
  dl=$(dl_speed "$url")
  ul=$(ul_speed)
  printf '%-30s %16s %16s\n' "$label" "$dl" "$ul"
done
echo
echo "* Upload is measured to the nearest Cloudflare edge, not to each region;"
echo "  it reflects your server's uplink and will read ~the same across rows."