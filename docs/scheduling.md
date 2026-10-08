# Daily refresh on a Mac

The local runner is ready to invoke explicitly; no recurring job is installed or
activated by this change. It fetches only source registrations that passed their
verification gate and only explicitly configured product/context/channel pairs.
H Mart's validated online reference is available; shelf/pickup integrations remain
unconnected. Never configure the online source as Centreville shelf evidence.

## Configure and inspect

Use `GET /api/staples`, `/api/stores/hmart`, and `/api/stores/hmart/contexts` to
find the actual saved IDs. Create a distinct H Mart online context with no
retailer location ID if needed. Do not substitute the seeded Centreville shelf
context. Select only products you want to inspect against a staple's rules.
The following format contains placeholders for your saved numeric IDs; replace
them before use. The product/SKU identity shown is a real captured rice listing.

```json
{
  "sources": [{
    "source_id": "hmart_online",
    "context_id": 123,
    "channel": "online",
    "requests": [{"staple_id": 456, "retailer_product_id": "8011:8027"}]
  }]
}
```

Save the configuration outside Git if it contains your personal staple choices.
Use absolute paths in these commands, replacing the examples with your checkout,
venv, database and configuration paths:

```sh
/ABS/VENV/bin/python -m staple_scout.scheduler --db /ABS/data/staple-scout.sqlite3 --config /ABS/refresh.json --dry-run
/ABS/VENV/bin/python -m staple_scout.scheduler --db /ABS/data/staple-scout.sqlite3 --config /ABS/refresh.json
/ABS/VENV/bin/python -m staple_scout.scheduler --db /ABS/data/staple-scout.sqlite3 --status
```

Run from the checkout or install the package into that venv. Dry-run validates
structure and counts; source/context/staple existence is checked by ingestion
when invoking the actual refresh. Dry-run performs no HTTP request or day claim.
Limits are five explicit source entries and fifty product requests total; combine
duplicate source/context/channel entries. There is no automatic substitute
selection and imported matches start pending.

## Cache, retries and failures

Manual and scheduled invocations share one durable **UTC calendar-day** claim per
database, including failed runs and configuration changes. A second invocation
returns `already_claimed` and makes no HTTP request. The canonical database
sidecar `.refresh.lock` prevents overlap; it is retained after unlock. Process
exit releases the OS lock. A crashed claim stays visible as `running` and blocks
another attempt that UTC day; the next day can proceed. There is deliberately no
force flag or hidden catch-up loop.

Each source has at most three attempts, with 0.25 then 0.5 second backoff, only
for classified timeouts, transport failures, HTTP429 or HTTP5xx. Other HTTP
failures, malformed evidence and configuration errors are not retried. Each
attempt has a distinct idempotency key so a cached failed attempt cannot masquerade
as a retry. Default source HTTP timeout is ten seconds and registrations cannot
exceed thirty. One source failure does not stop another source. Daily caching
also prevents repeated unavailable-source requests that day.

`GET /api/source-status` (optionally `context_id` and `channel`) separates last
attempt, last success with actual source evidence, and last failure. Source
observation timestamps remain distinct from attempt and retrieval timestamps.
A failed fetch never makes an old price fresh. CLI output contains status, safe
error codes, source/context/channel IDs and run IDs; it excludes credentials,
retailer response bodies, evidence and exception text.

## Optional launchd activation

Create this plist only when you choose to activate daily refresh. Replace every
`/ABS` path, create the log directory, and save it as
`~/Library/LaunchAgents/com.staplescout.refresh.plist`. Nothing here has been
installed or loaded automatically.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.staplescout.refresh</string>
  <key>ProgramArguments</key><array>
    <string>/ABS/VENV/bin/python</string>
    <string>-m</string><string>staple_scout.scheduler</string>
    <string>--db</string><string>/ABS/data/staple-scout.sqlite3</string>
    <string>--config</string><string>/ABS/refresh.json</string>
  </array>
  <key>WorkingDirectory</key><string>/ABS/CHECKOUT</string>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/ABS/logs/refresh.log</string>
  <key>StandardErrorPath</key><string>/ABS/logs/refresh-error.log</string>
</dict></plist>
```

Activate only after reviewing the config and a manual result:

```sh
plutil -lint "$HOME/Library/LaunchAgents/com.staplescout.refresh.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.staplescout.refresh.plist"
```

The example triggers at 06:00 Mac local time; the runner still caches by UTC day.
If the Mac sleeps through its calendar time, launchd runs it on wake. Multiple
missed calendar events coalesce rather than replaying every day. Offline failures
exhaust bounded retries and retain prior price evidence; there is no automatic
same-day retry loop. See [Apple's scheduling guide](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html).

To stop scheduling and remove only this job definition:

```sh
launchctl bootout "gui/$(id -u)/com.staplescout.refresh"
rm "$HOME/Library/LaunchAgents/com.staplescout.refresh.plist"
```

These are operator instructions, not commands this change executes. Removing the
job preserves the database and history. No email, phone or other notification is
sent by the runner.
