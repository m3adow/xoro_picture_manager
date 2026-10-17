#!/bin/bash
set -Eeuo pipefail

if (( $# < 1 || $# > 2 ))
then
  echo "Usage: ${0} <values.env> [picture directory]" >&2
  exit 1
fi

# Source the env file
# shellcheck source=/dev/null
source "${1}"

if [[ "${DEBUG:-false}" == "true" ]]
then
  set -x
fi

XORO_PROTOCOL="ftp"
XORO_PORT="${XORO_PORT:-"2121"}"

# Uploaded files are named '<PREFIX>_<counter>_<original name>'
PREFIX="${PREFIX:-"XPM"}"
# Space-separated MIME types to upload; the Xoro manual only documents JPEG
ALLOWED_MIME_TYPES="${ALLOWED_MIME_TYPES:-"image/jpeg"}"
# Anything but "sd" (any case) means internal storage
STORAGE="${STORAGE:-internal}"
# Max seconds to wait for the frame after a reboot
BOOT_TIMEOUT="${BOOT_TIMEOUT:-"300"}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-10}"

# Copy this amount of pics
MAX_PICS="${MAX_PICS:-"100"}"
# Show this percentage of all available pictures before allowing repeats
# e.g., 80 means 80% of collection must be shown before oldest pictures can be re-uploaded
COVERAGE_PERCENTAGE="${COVERAGE_PERCENTAGE:-"80"}"
# File to save uploaded file paths to prevent repeats until COVERAGE_PERCENTAGE met
STATE_FILE="${STATE_FILE:-"/var/tmp/xoro_pictures.state"}"
LOCK_FILE="${LOCK_FILE:-"${STATE_FILE}.lock"}"
CURL_OPTS=(--silent --show-error --globoff --ftp-method nocwd --connect-timeout 10 --max-time 300)

for VAR in XORO_PORT BOOT_TIMEOUT UPLOAD_RETRIES MAX_PICS COVERAGE_PERCENTAGE
do
  if [[ ! "${!VAR}" =~ ^[1-9][0-9]*$ ]]
  then
    echo "ERROR: ${VAR} must be a positive integer, got '${!VAR}'." >&2
    exit 1
  fi
done

# Validate COVERAGE_PERCENTAGE is between 1 and 100
if (( COVERAGE_PERCENTAGE < 1 || COVERAGE_PERCENTAGE > 100 ))
then
  echo "ERROR: COVERAGE_PERCENTAGE must be between 1 and 100, got ${COVERAGE_PERCENTAGE}." >&2
  exit 1
fi

PICTURE_DIR=""
if (( $# == 2 ))
then
  if [[ ! -d "${2}" ]]
  then
    echo "ERROR: Picture directory '${2}' does not exist." >&2
    exit 1
  fi
  PICTURE_DIR="$(realpath "${2}")"
fi

date_echo() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}"
}

trap 'RC=$?; date_echo "ERROR: \"${BASH_COMMAND}\" failed with exit code ${RC} at line ${LINENO}" >&2' ERR

# Keep the lock fd away from the daemonized adb server
adb() {
  command adb "$@" 9>&-
}

discover_pictures() {
  # Run expensive find command once and cache results in temp file
  # This avoids multiple traversals of potentially large directory trees
  local PICTURE_DIR="${1}"
  local CACHE_FILE="${2}"

  # Send logs to stderr to avoid polluting stdout (which is captured)
  date_echo "Discovering pictures in ${PICTURE_DIR} (this may take a while for large collections)" >&2

  # Find all displayable images and save to cache file
  find "${PICTURE_DIR}" -type f -exec file --mime-type --no-pad --separator $'\t' {} \+ \
    | awk -F'\t' -v allowed="${ALLOWED_MIME_TYPES}" '
        BEGIN { split(allowed, types, " "); for (i in types) ok[types[i]] = 1 }
        { sub(/^ /, "", $2); if ($2 in ok) print $1 }' \
    > "${CACHE_FILE}"

  local TOTAL=$(wc -l < "${CACHE_FILE}")
  date_echo "Found ${TOTAL} total pictures" >&2

  # Only output the count to stdout (this is what gets captured)
  echo "${TOTAL}"
}

delete_uploaded_ftp_files() {
  local CURL_FILES
  CURL_FILES="$(curl "${CURL_OPTS[@]}" --list-only "${XORO_URL}")"
  local FTP_FILE
  while IFS= read -r FTP_FILE
  do
    if [[ "${FTP_FILE}" != "${PREFIX}_"* ]]
    then
      continue
    fi
    date_echo "Deleting '${FTP_FILE}'"
    # Reroute STDOUT to null due to excessive outputs
    if ! curl "${CURL_OPTS[@]}" "${XORO_URL}" -Q "-DELE ${FTP_FILE}" > /dev/null
    then
      date_echo "WARNING: Failed to delete '${FTP_FILE}'"
    fi
  done <<< "${CURL_FILES}"
}

upload_new_files_to_ftp() {
  local PICTURE_CACHE="${1}"

  # Make sure the state file exists
  touch "${STATE_FILE}"

  # Use cached picture list, filter by state file, randomize and limit
  # grep exits 1 when every picture is already in the state file
  local IMAGES
  IMAGES="$( { grep -vxFf "${STATE_FILE}" "${PICTURE_CACHE}" || (( $? == 1 )); } | shuf -n "${MAX_PICS}")"

  # Check if any pictures available
  if [[ -z "${IMAGES}" ]]
  then
    date_echo "WARNING: No new pictures available (all in state file). Resetting state to start fresh cycle."
    : > "${STATE_FILE}"  # Empty the state file
    # Retry using cached list now that state is clear
    IMAGES="$(shuf -n "${MAX_PICS}" "${PICTURE_CACHE}")"

    if [[ -z "${IMAGES}" ]]
    then
      date_echo "ERROR: No pictures found in directory at all"
      return
    fi
  fi

  local FAILURE_COUNT=0
  local SUCCESS_COUNT=0
  local COUNTER=0
  local MYFILE SAFE_NAME NEW_FILENAME
  while IFS= read -r MYFILE
  do
    # Frame sorts by name: counter keeps shuffle order; names must be URL-safe
    COUNTER=$((COUNTER + 1))
    SAFE_NAME="$(basename "${MYFILE}")"
    SAFE_NAME="${SAFE_NAME//[^A-Za-z0-9._-]/_}"
    printf -v NEW_FILENAME '%s_%0*d_%s' "${PREFIX}" "${#MAX_PICS}" "${COUNTER}" "${SAFE_NAME}"

    date_echo "Uploading '${MYFILE}' as '${NEW_FILENAME}'"
    # This command may fail when space is running low
    if curl "${CURL_OPTS[@]}" -T "${MYFILE}" "${XORO_URL}/${NEW_FILENAME}"
    then
      # Only add to state file if upload succeeded
      echo "${MYFILE}" >> "${STATE_FILE}"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      FAILURE_COUNT=$((FAILURE_COUNT + 1))
      date_echo "ERROR: Failed to upload '${MYFILE}'"
    fi

    # Try the next file until retries are reached
    if (( $FAILURE_COUNT < $UPLOAD_RETRIES ))
    then
      continue
    else
      date_echo "Upload retry limit reached (${UPLOAD_RETRIES} failures)"
      break
    fi
  done <<< "${IMAGES}"

  date_echo "Upload complete: ${SUCCESS_COUNT} succeeded, ${FAILURE_COUNT} failed"
}

reactivate_xoro() {
  date_echo "Reactivating Xoro"

  local ADB_SERIAL="${XORO_HOST}:5555"
  local GALLERY_ACTIVITY="com.allwinner.theatreplayer.album/.ui.GalleryActivity"

  # Connect to Xoro
  if ! adb connect "${XORO_HOST}"
  then
    date_echo "ERROR: Failed to connect to device via ADB at ${XORO_HOST}"
    return 1
  fi
  # Give ADB time to REALLY connect
  sleep 2

  # Restart the device (couldn't figure out how to reindex files after rename)
  # Has to be OR'd with true due to -e
  adb -s "${ADB_SERIAL}" shell reboot || true
  # Sometimes reboot returns too fast, so wait 5 secs to be sure device is offline
  sleep 5
  adb kill-server

  # Wait for the device to become responsive again
  local WAITED=0
  until nc -z -w 5 "${XORO_HOST}" 5555
  do
    if (( WAITED >= BOOT_TIMEOUT ))
    then
      date_echo "ERROR: ${XORO_HOST} did not come back within ${BOOT_TIMEOUT} seconds"
      return 1
    fi
    sleep 5
    WAITED=$((WAITED + 5))
  done
  # Sleep additional time afterwards to be safe
  sleep 5

  adb connect "${XORO_HOST}"
  # Start the Gallery activity, no idea why it fails sometimes
  adb -s "${ADB_SERIAL}" shell "am start ${GALLERY_ACTIVITY}" || {
    sleep 5
    adb -s "${ADB_SERIAL}" shell "am start ${GALLERY_ACTIVITY}"
  }
  # The app takes some time to start
  sleep 5
  # Send three "RIGHT" key strokes, going to internal storage
  # More than two in a row don't get detected properly sometimes
  adb -s "${ADB_SERIAL}" shell "input keyevent 22 22"
  sleep 1
  adb -s "${ADB_SERIAL}" shell "input keyevent 22"
  # If SD is used, send one additional stroke
  if [[ "${STORAGE,,}" == "sd" ]]
  then
    sleep 1
    adb -s "${ADB_SERIAL}" shell "input keyevent 22"
  fi
  # Stop adb again
  adb kill-server
}

cleanup_state_file() {
    # Remove entries from state file for pictures that no longer exist
    # This prevents state file from growing with stale entries

    if [[ ! -f "${STATE_FILE}" ]]
    then
      return
    fi

    local TEMP_STATE=$(mktemp)
    local REMOVED_COUNT=0

    while IFS= read -r PICTURE_PATH
    do
      if [[ -f "${PICTURE_PATH}" ]]
      then
        echo "${PICTURE_PATH}" >> "${TEMP_STATE}"
      else
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
      fi
    done < "${STATE_FILE}"

    if (( REMOVED_COUNT > 0 ))
    then
      date_echo "Cleaned ${REMOVED_COUNT} stale entries from state file"
      mv "${TEMP_STATE}" "${STATE_FILE}"
    else
      rm "${TEMP_STATE}"
    fi
}

update_state_file() {
    local TOTAL_PICS="${1}"
    local STATE_COUNT=$(wc -l "${STATE_FILE}" | cut -d ' ' -f1)

    # Calculate coverage threshold based on total available pictures
    local THRESHOLD=$(( TOTAL_PICS * COVERAGE_PERCENTAGE / 100 ))

    # Ensure threshold is at least MAX_PICS to prevent immediate cycling
    if (( THRESHOLD < MAX_PICS ))
    then
      THRESHOLD=${MAX_PICS}
    fi

    # Don't let threshold exceed total available pictures
    if (( THRESHOLD > TOTAL_PICS ))
    then
      THRESHOLD=${TOTAL_PICS}
    fi

    date_echo "State tracking: ${STATE_COUNT} uploaded, ${TOTAL_PICS} total available, threshold ${THRESHOLD} (${COVERAGE_PERCENTAGE}%)"

    # Calculate how many to actually remove (may be less than MAX_PICS)
    local ENTRIES_TO_REMOVE=${MAX_PICS}
    if (( STATE_COUNT < MAX_PICS ))
    then
      ENTRIES_TO_REMOVE=${STATE_COUNT}
    fi

    # Only remove oldest entries if we've met the coverage threshold
    if (( STATE_COUNT >= THRESHOLD && ENTRIES_TO_REMOVE > 0 ))
    then
      date_echo "Coverage threshold met, releasing oldest ${ENTRIES_TO_REMOVE} pictures back to pool"
      sed -i "1,${ENTRIES_TO_REMOVE}d" "${STATE_FILE}"
    else
      local REMAINING=$(( THRESHOLD - STATE_COUNT ))
      date_echo "Building coverage: ${REMAINING} more unique pictures until threshold"
    fi
}


exec 9> "${LOCK_FILE}"
if ! flock --nonblock 9
then
  date_echo "ERROR: Another instance holds ${LOCK_FILE}, exiting."
  exit 1
fi

# Survive SSH disconnects; INT/TERM exit via the EXIT trap
trap '' SIGHUP
trap 'exit 130' SIGINT
trap 'exit 143' SIGTERM

date_echo "Started"

# Check initial online status first
if ! ping -c 1 -w 5 "${XORO_HOST}"
then
  date_echo "Device ${XORO_HOST} offline. Trying IP."
  if ping -c 1 -w 5 "${XORO_IP}"
  then
    date_echo "Using IP ${XORO_IP} instead of hostname."
    XORO_HOST="${XORO_IP}"
  else
    date_echo "IP ${XORO_IP} offline as well. Ending script."
    exit 1
  fi
fi
XORO_URL="${XORO_PROTOCOL}://${XORO_HOST}:${XORO_PORT}"

if [[ -n "${PICTURE_DIR}" ]]
then
  # Create temp file for caching picture list (avoids multiple expensive find operations)
  PICTURE_CACHE="$(mktemp)"
  trap 'rm -f "${PICTURE_CACHE}"' EXIT

  # Discover all pictures once and cache results
  TOTAL_AVAILABLE_PICS="$(discover_pictures "${PICTURE_DIR}" "${PICTURE_CACHE}")"

  # Handle edge case: no pictures found
  if (( TOTAL_AVAILABLE_PICS == 0 ))
  then
    date_echo "WARNING: No pictures found in ${PICTURE_DIR}, skipping upload"
  else
    delete_uploaded_ftp_files
    upload_new_files_to_ftp "${PICTURE_CACHE}"
    cleanup_state_file
    update_state_file "${TOTAL_AVAILABLE_PICS}"
  fi
fi

#rename_ftp_files
reactivate_xoro
date_echo "Ended"
