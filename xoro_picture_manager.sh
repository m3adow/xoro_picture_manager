#!/bin/bash
set -Eeuo pipefail
set -x

# Source the env file
source ${1}

XORO_PROTOCOL="ftp"
XORO_PORT="${XORO_PORT:-"2121"}"

# Full prefix will be '$PREFIX_$RANDOM__' (two underscores)
PREFIX="${PREFIX:-"XPM"}"
# Everything not being "sd" or "SD" is handled the same
STORAGE="${STORAGE:-internal}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-10}"

# Copy this amount of pics
MAX_PICS="${MAX_PICS:-"100"}"
# Show this percentage of all available pictures before allowing repeats
# e.g., 80 means 80% of collection must be shown before oldest pictures can be re-uploaded
COVERAGE_PERCENTAGE="${COVERAGE_PERCENTAGE:-"80"}"
# File to save uploaded file paths to prevent repeats until COVERAGE_PERCENTAGE met
STATE_FILE="${STATE_FILE:-"/var/tmp/xoro_pictures.state"}"

# Validate COVERAGE_PERCENTAGE is between 1 and 100
if (( COVERAGE_PERCENTAGE < 1 || COVERAGE_PERCENTAGE > 100 ))
then
  echo "ERROR: COVERAGE_PERCENTAGE must be between 1 and 100, got ${COVERAGE_PERCENTAGE}."
  exit 1
fi

date_echo() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}"
}

discover_pictures() {
  # Run expensive find command once and cache results in temp file
  # This avoids multiple traversals of potentially large directory trees
  local PICTURE_DIR="${1}"
  local CACHE_FILE="${2}"

  # Send logs to stderr to avoid polluting stdout (which is captured)
  date_echo "Discovering pictures in ${PICTURE_DIR} (this may take a while for large collections)" >&2

  # Find all images and save to cache file
  find "${PICTURE_DIR}" -type f -exec file --mime-type {} \+ \
    | awk -F: '{if ($2 ~/image\//) print $1}' \
    > "${CACHE_FILE}"

  local TOTAL=$(wc -l < "${CACHE_FILE}")
  date_echo "Found ${TOTAL} total pictures" >&2

  # Only output the count to stdout (this is what gets captured)
  echo "${TOTAL}"
}

delete_all_ftp_files() {
  local CURL_FILES="$(curl --ftp-method nocwd --silent --list-only "${XORO_URL}")"
  # Set IFS to newline only due to spaces in file names
  IFS=$'\n'
  for FTP_FILE in ${CURL_FILES}
  do
    date_echo "Deleting '${FTP_FILE}'"
    # Reroute STDOUT to null due to excessive outputs
    curl --silent --ftp-method nocwd "${XORO_URL}" -Q "-DELE ${FTP_FILE}" > /dev/null
  done
}

upload_new_files_to_ftp() {
  local PICTURE_CACHE="${1}"

  # Make sure the state file exists
  touch "${STATE_FILE}"

  # Use cached picture list, filter by state file, randomize and limit
  local IMAGES="$(grep -vf ${STATE_FILE} "${PICTURE_CACHE}" | shuf -n ${MAX_PICS})"

  # Check if any pictures available
  if [[ -z "${IMAGES}" ]]
  then
    date_echo "WARNING: No new pictures available (all in state file). Resetting state to start fresh cycle."
    > "${STATE_FILE}"  # Empty the state file
    # Retry using cached list now that state is clear
    IMAGES="$(cat "${PICTURE_CACHE}" | sort --random-sort | head -n ${MAX_PICS})"

    if [[ -z "${IMAGES}" ]]
    then
      date_echo "ERROR: No pictures found in directory at all"
      return
    fi
  fi

  local FAILURE_COUNT=0
  local SUCCESS_COUNT=0
  IFS=$'\n'
  for MYFILE in ${IMAGES}
  do
    # Create a new file name to randomise order
    NEW_FILENAME="${PREFIX}_${RANDOM}_$(basename "${MYFILE}")"

    date_echo "Uploading '${MYFILE}' as '${NEW_FILENAME}'"
    # This command may fail when space is running low
    if curl --silent --ftp-method nocwd -T "${MYFILE}" "${XORO_URL}/${NEW_FILENAME}"
    then
      # Only add to state file if upload succeeded
      echo "${MYFILE}" >> "${STATE_FILE}"
      ((SUCCESS_COUNT++))
    else
      ((FAILURE_COUNT++))
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
  done

  date_echo "Upload complete: ${SUCCESS_COUNT} succeeded, ${FAILURE_COUNT} failed"
}

reactivate_xoro() {
  date_echo "Reactivating Xoro"

  # Connect to Xoro
  if ! adb connect ${XORO_HOST}
  then
    date_echo "ERROR: Failed to connect to device via ADB at ${XORO_HOST}"
    return 1
  fi
  # Give ADB time to REALLY connect
  sleep 2

  # Restart the device (couldn't figure out how to reindex files after rename)
  # Has to be OR'd with true due to -e
  adb shell reboot
  # Sometimes reboot returns too fast, so wait 5 secs to be sure device is offline
  sleep 5
  adb kill-server

  # Wait for the device to become responsive again
  while ! nc -z ${XORO_HOST} 5555; do
      sleep 5 # wait for 1/10 of the second before check again
  done
  # Sleep additional time afterwards to be safe
  sleep 5

  adb connect ${XORO_HOST}
  # Start the Gallery activity, no idea why it fails sometimes
  adb shell "am start com.allwinner.theatreplayer.album/.ui.GalleryActivity" || \
    sleep 5; adb shell "am start com.allwinner.theatreplayer.album/.ui.GalleryActivity"
  # The app takes some time to start
  sleep 5
  # Send three "RIGHT" key strokes, going to internal storage
  # More than two in a row don't get detected properly sometimes
  adb shell "input keyevent 22 / 22"
  sleep 1
  adb shell "input keyevent 22"
  # If SD is used, send one additional stroke
  if [[ "${STORAGE}" =~ "[sS][Dd]" ]]
  then
    sleep 1
    adb shell "input keyevent 22"
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
        ((REMOVED_COUNT++))
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


date_echo "Started"

# Check initial online status first
if ! ping -c 1 -w 5 ${XORO_HOST}
then
  date_echo "Device ${XORO_HOST} offline. Trying IP."
  if ping -c 1 -w 5 ${XORO_IP}
  then
    date_echo "Using IP ${XORO_IP} instead of hostname."
    XORO_HOST="${XORO_IP}"
  else
    date_echo "IP ${XORO_IP} offline as well. Ending script."
    exit
  fi
fi
XORO_URL="${XORO_PROTOCOL}://${XORO_HOST}:${XORO_PORT}"

# Ignore a couple of signals
trap '' SIGINT SIGHUP SIGQUIT SIGTERM SIGSTOP

if [[ -n ${2} && -d ${2} ]]
then
  # Create temp file for caching picture list (avoids multiple expensive find operations)
  PICTURE_CACHE=$(mktemp)
  trap "rm -f ${PICTURE_CACHE}" EXIT

  # Discover all pictures once and cache results
  TOTAL_AVAILABLE_PICS=$(discover_pictures "${2}" "${PICTURE_CACHE}")

  # Handle edge case: no pictures found
  if (( TOTAL_AVAILABLE_PICS == 0 ))
  then
    date_echo "WARNING: No pictures found in ${2}, skipping upload"
  else
    delete_all_ftp_files
    upload_new_files_to_ftp "${PICTURE_CACHE}"
    cleanup_state_file
    update_state_file "${TOTAL_AVAILABLE_PICS}"
  fi

  # Cleanup temp file
  rm -f "${PICTURE_CACHE}"
fi

#rename_ftp_files
reactivate_xoro
date_echo "Ended"
