# Multi-Region Bandwidth Test (`bandwidth_test.sh`)

A small Bash script that measures your server's **download throughput from eight
world regions** and its **upload throughput to the nearest Cloudflare edge**, shows a
live progress bar for each step, and prints one summary table at the end.

It is meant for a fresh VPS or workstation, to answer *"how well does this box talk
to the rest of the world?"* rather than *"how fast is my line to the nearest
speed-test server?"*

---

## What it does

- For each region, opens **16 parallel connections**, each fetching a different byte
  range of a large test file with `curl`, and reports the aggregate as MiB/s.
  Multiple connections matter here: a single TCP stream to Melbourne or Mumbai is
  limited by latency and window size long before it is limited by your actual link.
- **Streams every download to `/dev/null`.** Nothing is written to disk, so the test
  cannot fail for want of scratch space no matter how small `/tmp` or `/dev/shm` is.
- **Probes each target with a 1 KB range request first**, so a dead URL, a bad
  certificate or a DNS failure is reported in a second instead of after a long stall.
- Uploads a payload to `speed.cloudflare.com` **once**, and reports it separately
  from the regional table.
- Draws a **progress bar per action** while it runs, then clears it and prints the
  summary table.
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

To print the raw `curl` errors underneath each failed row:

```bash
BW_DEBUG=1 ./bandwidth_test.sh
```

By default the run transfers `CONN x CHUNK_MB` = 256 MiB per region (~2 GiB in
total) plus one `UL_MB` upload, so watch out for metered links or a monthly traffic
quota. Lower `CHUNK_MB` for a lighter run.

---

## Reading the output

While it works, one line updates in place:

```text
  Asia (Singapore)             [##############..........]  58%    149 MiB   62.41 MiB/s
```

When everything has finished, that line is cleared and the summary is printed:

```text
Region                         Download (MiB/s)  Failure reason
------------------------------ ----------------  --------------------------
North America (Ashburn US)               112.40
Europe (Falkenstein DE)                   98.75
Asia (Singapore)                          41.02
Japan (Tokyo)                             FAILED  file missing on server (404)

Upload (500 MiB to nearest Cloudflare edge): 47.66 MiB/s
```

- **The table is downloads only.** Upload is a single measurement against the
  nearest Cloudflare edge, so it belongs to the machine rather than to any region —
  it is reported on its own line under the table instead of being repeated across
  eight rows.
- **`FAILED` and its reason are printed in red.** The reason comes from the HTTP
  status or `curl`'s exit code and error text, so a failure tells you *why* rather
  than just *that*.
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
| `CONN`       | `16`                        | parallel connections per region                     |
| `CHUNK_MB`   | `16`                        | MiB per connection, so `CONN x CHUNK_MB` per region |
| `UL_MB`      | `500`                       | upload payload size in MiB                          |
| `DL_TIMEOUT` | `90`                        | seconds cap per download connection                 |
| `TMPBASE`    | `/dev/shm`                  | preferred scratch location for the upload payload   |
| `UPLOAD_URL` | `speed.cloudflare.com/__up` | upload sink                                         |
| `TARGETS`    | eight `Region\|URL` pairs   | add, remove or re-point regions here                |

Test-file URLs go stale. If a row reports a 404, check the provider's speed-test page
(Hetzner, Vultr and DataPacket all publish them) and edit the matching line in
`TARGETS`.

Targets that ignore `Range` and return the whole file are detected by the probe and
measured with a single time-boxed stream instead of 16 partial ones, so the number
stays honest rather than being inflated by 16 copies of the same bytes.

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
