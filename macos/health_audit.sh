#!/usr/bin/env bash
# macOS endpoint health audit.
#
# Read-only: this script does not change system settings and does not use sudo.
# Written for bash 3.2, the bash shipped with macOS. Avoid bash 4+ features.
#
# The report lists the checks only. It does not include hostname or serial number.
#
# Threshold overrides (defaults shown):
#   DISK_WARN_PCT=15        warn when free space is under this percent
#   UPTIME_WARN_DAYS=14     warn when uptime is over this many days
#   LOAD_CPU_LIMIT=         empty uses the logical CPU count (hw.ncpu)

# A failed check must not abort the report, so this script does not use set -e.
set -u
set -o pipefail

DISK_WARN_PCT="${DISK_WARN_PCT:-15}"
UPTIME_WARN_DAYS="${UPTIME_WARN_DAYS:-14}"
LOAD_CPU_LIMIT="${LOAD_CPU_LIMIT:-}"
SOFTWAREUPDATE_TIMEOUT_SECONDS=180

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
REPORT_DIR="${REPO_ROOT}/reports"
REPORT_FILE="${REPORT_DIR}/audit-$(date +%Y-%m-%d).txt"

warning_count=0
error_count=0
report_text=""
updates_pid=""
updates_tmp=""

# Called from the EXIT trap, which ShellCheck does not treat as a direct call.
# shellcheck disable=SC2329
cleanup() {
  if [ -n "${updates_pid}" ]; then
    kill "${updates_pid}" 2>/dev/null || true
    wait "${updates_pid}" 2>/dev/null || true
    updates_pid=""
  fi
  if [ -n "${updates_tmp}" ]; then
    rm -f "${updates_tmp}"
    updates_tmp=""
  fi
}
# Called from the INT and TERM traps.
# shellcheck disable=SC2329
on_signal() {
  cleanup
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

append_line() {
  report_text="${report_text}${1}"$'\n'
}

record_ok() {
  append_line "[OK]      ${1}"
}

record_warning() {
  warning_count=$((warning_count + 1))
  append_line "[WARNING] ${1}"
}

record_error() {
  error_count=$((error_count + 1))
  append_line "[ERROR]   ${1}"
}

is_uint() {
  case "${1}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Product, version, and build. No warning: this identifies the OS, not a fault.
check_macos_version() {
  local name version build
  name=$(sw_vers -productName 2>/dev/null) || {
    record_error "macOS version: sw_vers failed"
    return
  }
  version=$(sw_vers -productVersion 2>/dev/null) || {
    record_error "macOS version: sw_vers failed"
    return
  }
  build=$(sw_vers -buildVersion 2>/dev/null) || {
    record_error "macOS version: sw_vers failed"
    return
  }
  if [ -z "${name}" ] || [ -z "${version}" ] || [ -z "${build}" ]; then
    record_error "macOS version: sw_vers returned an empty value"
    return
  fi
  record_ok "macOS version: ${name} ${version} (${build})"
}

# Free space on the APFS data volume. The sealed system volume at / can look
# almost empty or almost full for reasons that do not describe user data.
check_disk_space() {
  local mount df_line available_kb capacity used_pct free_pct human detail

  if ! is_uint "${DISK_WARN_PCT}"; then
    record_error "Disk space: DISK_WARN_PCT must be a whole number (got '${DISK_WARN_PCT}')"
    return
  fi

  mount="/System/Volumes/Data"
  if [ ! -d "${mount}" ]; then
    mount="/"
  fi

  df_line=$(df -Pk "${mount}" 2>/dev/null | awk 'NR==2 { print $4, $5 }') || df_line=""
  if [ -z "${df_line}" ]; then
    record_error "Disk space: could not read free space on ${mount}"
    return
  fi

  available_kb=$(printf '%s\n' "${df_line}" | awk '{ print $1 }')
  capacity=$(printf '%s\n' "${df_line}" | awk '{ print $2 }')
  used_pct=${capacity%%%}
  if ! is_uint "${used_pct}" || ! is_uint "${available_kb}"; then
    record_error "Disk space: unexpected df output on ${mount}"
    return
  fi

  # 10# forces decimal so values like 08 are not treated as octal.
  free_pct=$((100 - 10#${used_pct}))
  human=$(df -h "${mount}" 2>/dev/null | awk 'NR==2 { print $4 }') || human=""
  if [ -n "${human}" ]; then
    detail="${human} available (${free_pct}% free) on ${mount}"
  else
    detail="${free_pct}% free on ${mount}"
  fi
  detail="${detail} (warning under ${DISK_WARN_PCT}% free)"

  if [ "$((10#${free_pct}))" -lt "$((10#${DISK_WARN_PCT}))" ]; then
    record_warning "Disk space: ${detail}"
  else
    record_ok "Disk space: ${detail}"
  fi
}

# FileVault Off is a warning because disk encryption is a baseline endpoint control.
check_filevault() {
  local status
  status=$(fdesetup status 2>&1) || {
    record_error "FileVault: fdesetup failed (${status})"
    return
  }
  case "${status}" in
    *"FileVault is On."*)
      record_ok "FileVault: On"
      ;;
    *"FileVault is Off."*)
      record_warning "FileVault: Off"
      ;;
    *)
      record_error "FileVault: unexpected status (${status})"
      ;;
  esac
}

# Days since boot, from kern.boottime. The uptime command's wording changes
# ("9 days" vs "14:03") and is a poor thing to parse.
check_uptime() {
  local boot_raw boot_sec now_sec uptime_sec uptime_days detail
  local day_label threshold_label warn_days

  if ! is_uint "${UPTIME_WARN_DAYS}"; then
    record_error "Uptime: UPTIME_WARN_DAYS must be a whole number (got '${UPTIME_WARN_DAYS}')"
    return
  fi

  boot_raw=$(sysctl -n kern.boottime 2>/dev/null) || {
    record_error "Uptime: could not read kern.boottime"
    return
  }
  # Match "{ sec = N" only. A pattern of "sec =" also matches the "sec" in "usec".
  boot_sec=$(printf '%s\n' "${boot_raw}" | sed -n 's/.*{ sec = \([0-9][0-9]*\).*/\1/p')
  if ! is_uint "${boot_sec}"; then
    record_error "Uptime: could not parse boot time"
    return
  fi

  # Convert each value on its own so a leading zero is not treated as octal.
  now_sec=$((10#$(date +%s)))
  boot_sec=$((10#${boot_sec}))
  if [ "${now_sec}" -lt "${boot_sec}" ]; then
    record_error "Uptime: boot time is in the future"
    return
  fi

  uptime_sec=$((now_sec - boot_sec))
  uptime_days=$((uptime_sec / 86400))
  warn_days=$((10#${UPTIME_WARN_DAYS}))
  if [ "${uptime_days}" -eq 1 ]; then
    day_label="day"
  else
    day_label="days"
  fi
  if [ "${warn_days}" -eq 1 ]; then
    threshold_label="day"
  else
    threshold_label="days"
  fi
  detail="${uptime_days} ${day_label} (warning over ${warn_days} ${threshold_label})"
  if [ "${uptime_days}" -gt "${warn_days}" ]; then
    record_warning "Uptime: ${detail}"
  else
    record_ok "Uptime: ${detail}"
  fi
}

# 1-minute load above the logical CPU count is the usual "saturated" rule of thumb.
check_load() {
  local load_raw load1 load5 load15 ncpu limit_note compare_status cpu_label

  load_raw=$(sysctl -n vm.loadavg 2>/dev/null) || {
    record_error "Load average: could not read vm.loadavg"
    return
  }
  load1=$(printf '%s\n' "${load_raw}" | awk '{ gsub(/[{}]/, ""); print $1 }')
  load5=$(printf '%s\n' "${load_raw}" | awk '{ gsub(/[{}]/, ""); print $2 }')
  load15=$(printf '%s\n' "${load_raw}" | awk '{ gsub(/[{}]/, ""); print $3 }')

  if [ -n "${LOAD_CPU_LIMIT}" ]; then
    if ! is_uint "${LOAD_CPU_LIMIT}"; then
      record_error "Load average: LOAD_CPU_LIMIT must be a whole number (got '${LOAD_CPU_LIMIT}')"
      return
    fi
    ncpu="${LOAD_CPU_LIMIT}"
  else
    ncpu=$(sysctl -n hw.ncpu 2>/dev/null) || {
      record_error "Load average: could not read hw.ncpu"
      return
    }
    if ! is_uint "${ncpu}"; then
      record_error "Load average: unexpected CPU count (${ncpu})"
      return
    fi
  fi

  if [ "${ncpu}" -eq 1 ]; then
    cpu_label="CPU"
  else
    cpu_label="CPUs"
  fi
  if [ -n "${LOAD_CPU_LIMIT}" ]; then
    limit_note="limit ${ncpu} ${cpu_label} (LOAD_CPU_LIMIT)"
  else
    limit_note="limit ${ncpu} ${cpu_label}"
  fi

  if [ -z "${load1}" ] || [ -z "${load5}" ] || [ -z "${load15}" ]; then
    record_error "Load average: could not parse vm.loadavg (${load_raw})"
    return
  fi

  compare_status=0
  awk -v load="${load1}" -v ncpu="${ncpu}" 'BEGIN {
    if (load !~ /^[0-9]+([.][0-9]+)?$/ || ncpu !~ /^[0-9]+$/) exit 2
    if ((load + 0) > (ncpu + 0)) exit 0
    exit 1
  }' || compare_status=$?

  case "${compare_status}" in
    0)
      record_warning "Load average: ${load1}, ${load5}, ${load15} (${limit_note})"
      ;;
    1)
      record_ok "Load average: ${load1}, ${load5}, ${load15} (${limit_note})"
      ;;
    *)
      record_error "Load average: could not compare '${load1}' with CPU limit '${ncpu}'"
      ;;
  esac
}

# Pending updates are a warning because an available update is the finding.
# macOS has no timeout(1). Run softwareupdate in the background and kill it
# after 180 seconds. Combine stdout and stderr: "No new software available."
# is written to stderr, and the banner is non-empty even when nothing is pending.
check_pending_updates() {
  local waited timed_out update_exit count labels label_line

  if ! command -v softwareupdate >/dev/null 2>&1; then
    record_error "Pending updates: softwareupdate not found"
    return
  fi

  updates_tmp=$(mktemp "${TMPDIR:-/tmp}/health-audit-updates.XXXXXX") || {
    record_error "Pending updates: could not create a temp file"
    return
  }

  softwareupdate -l >"${updates_tmp}" 2>&1 &
  updates_pid=$!
  waited=0
  timed_out=0

  while kill -0 "${updates_pid}" 2>/dev/null; do
    if [ "${waited}" -ge "${SOFTWAREUPDATE_TIMEOUT_SECONDS}" ]; then
      kill "${updates_pid}" 2>/dev/null || true
      sleep 1
      if kill -0 "${updates_pid}" 2>/dev/null; then
        kill -9 "${updates_pid}" 2>/dev/null || true
      fi
      wait "${updates_pid}" 2>/dev/null || true
      updates_pid=""
      timed_out=1
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  if [ "${timed_out}" -eq 1 ]; then
    rm -f "${updates_tmp}"
    updates_tmp=""
    record_error "Pending updates: softwareupdate timed out after ${SOFTWAREUPDATE_TIMEOUT_SECONDS}s"
    return
  fi

  update_exit=0
  wait "${updates_pid}" 2>/dev/null || update_exit=$?
  updates_pid=""

  count=$(grep -E -c '^[[:space:]]*\* Label:' "${updates_tmp}" 2>/dev/null) || true
  if ! is_uint "${count}"; then
    count=0
  fi

  if [ "${count}" -gt 0 ]; then
    record_warning "Pending updates: ${count} available"
    labels=$(grep -E '^[[:space:]]*\* Label:' "${updates_tmp}" || true)
    while IFS= read -r label_line; do
      if [ -n "${label_line}" ]; then
        append_line "          ${label_line}"
      fi
    done <<EOF
$(printf '%s\n' "${labels}")
EOF
  elif grep -F -q "No new software available" "${updates_tmp}"; then
    record_ok "Pending updates: none"
  elif [ "${update_exit}" -eq 0 ]; then
    record_ok "Pending updates: none"
  else
    record_error "Pending updates: softwareupdate failed (exit ${update_exit})"
  fi

  rm -f "${updates_tmp}"
  updates_tmp=""
}

write_report() {
  local header generated

  if ! mkdir -p "${REPORT_DIR}"; then
    printf 'Could not create %s\n' "${REPORT_DIR}" >&2
    exit 1
  fi

  generated=$(date '+%Y-%m-%d %H:%M:%S')
  header="Endpoint Health Audit"$'\n'"Generated: ${generated}"$'\n'
  if ! printf '%s\n%s\nSummary: %s warning(s), %s error(s)\n' \
    "${header}" \
    "${report_text}" \
    "${warning_count}" \
    "${error_count}" | tee "${REPORT_FILE}"; then
    printf 'Could not write %s\n' "${REPORT_FILE}" >&2
    exit 1
  fi
}

check_macos_version
check_disk_space
check_filevault
check_uptime
check_load
check_pending_updates
write_report
exit 0
