# Check comparison

Windows cells stay `to fill in` until the PowerShell script exists.

| Check | macOS | Windows |
| --- | --- | --- |
| macOS / OS version | `sw_vers` (product name, version, and build). No warning. | to fill in |
| Free disk space | `df -Pk` on `/System/Volumes/Data`, falling back to `/` if that mount is missing. Percent free is `100` minus the Capacity column. Warning when free space is under `DISK_WARN_PCT` (default 15). | to fill in |
| Encryption | `fdesetup status` with no volume argument. Warning when FileVault is Off. | to fill in |
| Uptime | Days since `sysctl kern.boottime`. Warning when uptime is over `UPTIME_WARN_DAYS` (default 14). | to fill in |
| Load average | `sysctl vm.loadavg` compared with `hw.ncpu`, or with `LOAD_CPU_LIMIT` when that variable is set. Warning when the 1-minute load is above that CPU limit. | to fill in |
| Pending updates | `softwareupdate -l` with stdout and stderr combined, stopped after 180 seconds. Warning only when an update-label line (`* Label:`) is present. | to fill in |
