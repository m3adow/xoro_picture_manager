#!/bin/bash
set -euo pipefail
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
# Do not copy the same pictures for this amount of days
NO_REPEAT_DAYS="${NO_REPEAT_DAYS:-"28"}"
# File to save the last MAX_PICS * NO_REPEAT_DAYS file names to prevent showing the same files
STATE_FILE="${STATE_FILE:-"/var/tmp/xoro_pictures.state"}"


date_echo() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): ${1}"
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
  # Make sure the state file exists
  touch "${STATE_FILE}"

  # Find all images in given folder, sort randomly
  local IMAGES="$(find ${1} -type f -exec file --mime-type {} \+ | awk -F: '{if ($2 ~/image\//) print $1}' \
    | grep -vf ${STATE_FILE} | sort --random-sort | head -n ${MAX_PICS})"

  local FAILURE_COUNT=0
  IFS=$'\n'
  for MYFILE in ${IMAGES}
  do
    # Create a new file name to randomise order
    NEW_FILENAME="${PREFIX}_${RANDOM}_$(basename "${MYFILE}")"

    date_echo "Uploading '${MYFILE}' as '${NEW_FILENAME}'"
    # This command may fail when space is running low
    curl --silent --ftp-method nocwd -T "${MYFILE}" "${XORO_URL}/${NEW_FILENAME}"
    if [[ $? -ne 0 ]]
    then
      ((FAILURE_COUNT++))
    fi

    # Add the file name to the STATE_FILE to prevent it from being shown the next NO_REPEAT_DAYS
    echo "${MYFILE}" >> "${STATE_FILE}"

    # Try the next file until retries are reached
    if (( $FAILURE_COUNT < $UPLOAD_RETRIES ))
    then
      continue
    else
      break
    fi
  done
}

reactivate_xoro() {
  date_echo "Reactivating Xoro"
  # Connect to Xoro
  adb connect ${XORO_HOST}
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

update_state_file() {
    # Update the state file by cutting MAX_PICS lines from the top
    if (( $(wc -l "${STATE_FILE} | cut -d ' ' -f1") > ${MAX_PICS} * ${NO_REPEAT_DAYS} ))
    then
      sed -i '1,10d' "${STATE_FILE}"
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
  delete_all_ftp_files
  upload_new_files_to_ftp "${2}" "${MAX_PICS}"
  update_state_file
fi

#rename_ftp_files
reactivate_xoro
date_echo "Ended"
