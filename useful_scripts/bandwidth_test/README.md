# Multi-Region Bandwidth Test (`bandwidth_test.sh`)

A small Bash script that measures your server's **download throughput from eight
world regions** and its **upload throughput to the nearest Cloudflare edge**, shows a
live progress bar for each step, and prints one summary table at the end.

It is meant for a fresh VPS or workstation, to answer *"how well does this box talk
to the rest of the world?"* rather than *"how fast is my line to the nearest
speed-test server?"*

---

## What it does

- For each region, opens **8 parallel connections** by default (set with `-c`),
  spread round-robin across **several distinct-host mirrors** near that region, and
  reports the aggregate as MiB/s. Each region is measured for **up to 10 seconds** by
  default (`--time-box`); pass `--file-size` to cap by bytes downloaded instead.
  Multiple connections matter here: a single TCP stream to Melbourne or Mumbai is
  limited by latency and window size long before it is limited by your actual link.
  Multiple *hosts* matter too: some providers (e.g. Hetzner) cap concurrent
  downloads per IP, so spreading a region across mirrors keeps one host's limit from
  throttling the whole measurement.
- **Streams every download to `/dev/null`.** Nothing is written to disk, so the test
  cannot fail for want of scratch space no matter how small `/tmp` or `/dev/shm` is.
- **Probes each target with a 1 KB range request first**, so a dead URL, a bad
  certificate or a DNS failure is reported in a second instead of after a long stall.
- Reports, per region, the **min and max TCP round-trip latency** across that
  region's mirrors as two extra columns, and can print all rates in **Mbps** instead
  of MiB/s with `--mbps`.
- Uploads a payload to `speed.cloudflare.com` **once**, and reports it separately
  from the regional table.
- Draws a **progress bar per action** while it runs; each successful bar fills to
  100% on its own line, then the summary table is printed below.
- Prints a short **failure reason in red** for anything that did not complete.

---

## Requirements

`curl` and a Bash 4+ shell. That is all — there is no `aria2c` dependency.

```bash
sudo apt install curl        # Debian / Ubuntu / Mint
sudo dnf install curl        # Fedora / RHEL / Rocky / Alma
sudo pacman -S curl          # Arch / Manjaro
sudo zypper install curl     # openSUSE
```

Scratch space is needed **only for the upload payload** (`UL_MB`, 500 MiB by
default). The script tries `/dev/shm`, then `/tmp`, then `$PWD` and `$HOME`, and
**test-writes each candidate** before committing to it — `df` alone is not
trustworthy, because on a tmpfs mount like `/dev/shm` it reports the mount's size
limit rather than free memory, and a directory can be unwritable while still showing
plenty of space.

The live progress bar reads `/proc/<pid>/io` to count bytes. Where that is not
readable, it falls back to a spinner with elapsed time; the measurement itself is
unaffected.

---

## Usage

```bash
chmod +x bandwidth_test.sh
./bandwidth_test.sh
```

By default each region is measured for **up to 10 seconds** and its progress bar
fills toward that time-box — unless a fast link empties the whole file first, in
which case the bar races ahead and completes early. Change the cap with
`--time-box`, or switch to a byte cap with `--file-size`:

```bash
./bandwidth_test.sh                    # default: time-box, 10s per region
./bandwidth_test.sh --time-box=30s     # measure each region for up to 30s
./bandwidth_test.sh --file-size=1GiB   # download up to 1 GiB per region instead
./bandwidth_test.sh --file-size        # a bare flag uses its default (512 MiB)
```

Set the number of parallel connections per region with `-c` / `--connections`
(default `8`, max `64`):

```bash
./bandwidth_test.sh -c 16
```

Report speeds in **Mbps** (megabits/s) instead of the default **MiB/s** with
`--mbps` (this changes the download column, the live bar, and the upload line):

```bash
./bandwidth_test.sh --mbps
```

To print the raw `curl` errors underneath each failed row:

```bash
BW_DEBUG=1 ./bandwidth_test.sh
```

Both `--time-box` and `--file-size` are **caps**: a region stops as soon as its
limit is reached (a fast link may finish sooner), and its bar still completes to
100%. Mind the traffic — a full 10 s time-box on a fast link can pull most of a
~1 GiB file per region (up to ~8 GiB across all eight regions), and `--file-size`
downloads its cap on purpose; lower the cap on metered links. The units for
`--file-size` are `KiB`/`MiB`/`GiB` or `KB`/`MB`/`GB`, and a bare number is MiB.

---

## Reading the output

While it works, one line updates in place:

```text
  Asia (Singapore)             [##############..........]  58%    149 MiB   62.41 MiB/s
```

When everything has finished, each bar is left filled at 100% and the summary is
printed below:

```text
Region                           Download (MiB/s)   Min ms   Max ms
------------------------------ ------------------ -------- --------
North America (US East)                    112.40       14      132
Europe (Germany/central)                    98.75       21       30
Asia (Singapore)                            41.02      168      190
Japan (Tokyo/Osaka)                         63.17      110      140
Oceania (AU/NZ)                                   could not connect

Upload (500 MiB to nearest Cloudflare edge): 47.66 MiB/s
```

- **Four columns: region, download rate, and Min/Max latency.** `Min ms` and
  `Max ms` are the fastest and slowest **TCP round-trip** (the connect handshake)
  among that region's mirrors, so they show the spread of your connectivity to the
  region — a low min with a high max means one mirror is much closer than another.
- **The download column's unit follows `--mbps`** — it reads `Download (MiB/s)` by
  default, or `Download (Mbps)` when that flag is set.
- **A region that failed shows its reason in red**, spanning the three data columns
  where the numbers would have been. The reason comes from the HTTP status or
  `curl`'s exit code and error text, so a failure tells you *why*, not just *that*.
- **The table is downloads only.** Upload is a single measurement against the
  nearest Cloudflare edge, so it belongs to the machine rather than to any region —
  it is reported on its own line under the table instead of being repeated across
  eight rows.
- **A connection that times out with bytes already received still counts.** Speed is
  measured as bytes actually transferred over wall-clock time, so a slow region
  yields a real number rather than a `FAILED`.

### Failure reasons you may see

| Reason                         | What it usually means                                                       |
| ------------------------------ | --------------------------------------------------------------------------- |
| `file missing on server (404)` | the provider retired or renamed the test file — update the URL in `TARGETS` |
| `server refused request (403)` | the provider blocks your IP range or requires a referrer                    |
| `server error (503)`           | the test host is overloaded or rate-limiting you; try again later           |
| `DNS lookup failed`            | no resolver, or that region's host no longer exists                         |
| `TLS certificate rejected`     | missing or stale CA bundle on this machine                                  |
| `could not connect`            | the host is unreachable, or a firewall is dropping the traffic              |
| `connection reset by peer`     | the far end dropped the transfer mid-flight                                 |
| `timed out with no data`       | the connection opened but nothing ever arrived                              |
| `upload rejected (HTTP ...)`   | the upload sink refused the request; check `UPLOAD_URL`                     |

If **every** row fails with the same reason, suspect this machine — its resolver, its
CA bundle, or its egress firewall — rather than eight unrelated providers.

---

## Customizing

Everything tunable sits at the top of the script:

| Variable     | Default                     | Meaning                                             |
| ------------ | --------------------------- | --------------------------------------------------- |
| `CONN`       | `8`                         | parallel connections per region (or `-c N` on the CLI)             |
| `MODE`       | `time`                      | `time` or `size`; set on the CLI by `--time-box` / `--file-size`   |
| `TIMEBOX_S`  | `10`                        | time-box seconds (or `--time-box=DUR`)                             |
| `SIZE_BYTES` | `512 MiB`                   | size-mode byte cap (or `--file-size=SZ`)                           |
| `UNIT`       | `mib`                       | rate unit `mib` (MiB/s) or `mbps` (Mbps); `--mbps` sets `mbps`     |
| `UL_MB`      | `500`                       | upload payload size in MiB                                         |
| `DL_TIMEOUT` | `90`                        | hard per-connection cap in size mode (time mode uses the time-box) |
| `TMPBASE`    | `/dev/shm`                  | preferred scratch location for the upload payload                 |
| `UPLOAD_URL` | `speed.cloudflare.com/__up` | upload sink                                                        |
| `TARGETS`    | eight `Region\|url1\|url2\|...` rows | each region lists several distinct-host mirrors        |

Each `TARGETS` row is `Region|url1|url2|...`: the region label followed by one or
more mirror URLs on **distinct hosts** near that region. The connections are spread
round-robin across whichever mirrors respond, so a region keeps working even if one
mirror is down, and no single host's per-IP concurrency cap throttles it. Regions
with fewer good public mirrors (Middle East, Iran) simply list fewer.

Test-file URLs go stale. If a mirror reports a 404, check the provider's speed-test
page (Hetzner, Linode, DataPacket and OVH all publish them) and edit or drop that
URL in `TARGETS`.

A mirror's size and whether it honours `Range` are read from the probe. Connections
that share a range-capable host are given staggered byte offsets so they don't fetch
the same bytes; a host that ignores `Range` is requested without one (its connections
can't seek), so prefer range-capable mirrors when editing `TARGETS`.

---

## A caveat worth reading

**Speed-test tools do not always show the real bandwidth capability of your server or
workstation.** A speed test measures one path, at one moment, through infrastructure
you do not control, and any of the following can cap the result well below what your
machine can actually do:

- The **test server** is busy, rate-limited, or peered badly with your provider.
- The **route** in between is congested, even though your own link is idle.
- **Per-connection limits** on the far end throttle you no matter how fast your line is.
- The measurement window is **too short** for TCP to reach full speed — especially on
  high-latency, long-distance paths.
- CDN-backed tests may serve you from a **nearby cache**, flattering the number, or
  from a distant origin, depressing it.

Because of this, a single speed-test figure is best read as a *lower bound for that
particular path*, not as your machine's capability.

**A direct upload/download between two machines you control is usually the better
measure of real bandwidth.** Copy a large file — a few GB, big enough that ramp-up
stops mattering — between your server and another host on a known-good link, and time
it: `scp`, `rsync --progress`, `iperf3` against your own endpoint, or plain HTTP from
your own web server. You control both ends, so you can tell a slow *link* apart from a
slow *test server*, repeat the run, and measure both directions honestly. That is what
this script's per-region download figures approximate, and it is why they use many
parallel connections rather than one.
