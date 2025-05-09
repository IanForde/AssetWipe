#!/bin/bash

# If called with --do-restore, skip dialogs and do the restore
if [[ "$1" == "--do-restore" ]]; then
  echo "Starting restore of all connected devices..."
  echo "---------------------------------------------"
  date

  /usr/local/bin/cfgutil -f restore

  echo "---------------------------------------------"
  echo "Restore complete for all connected devices."
  date
  read -n 1 -s -r -p "Press any key to close this window..."
  exit 0
fi

# --- Normal dialog/confirmation workflow ---

device_info=$(/usr/local/bin/cfgutil list | grep -v "^$")

if [ -z "$device_info" ]; then
  osascript -e 'display dialog "No devices detected. Please connect devices via USB-C and try again." buttons {"OK"} default button 1'
  exit 0
fi

# Show the user what is connected and get button result
button=$(osascript <<EOF
set theDialogText to "The following devices are currently connected:

$device_info

ALL of these devices will be RESTORED (ERASED). Are you sure you want to continue?"
display dialog theDialogText buttons {"Cancel", "Restore All"} default button "Cancel" with icon caution
return button returned of result
EOF
)

if [[ "$button" != "Restore All" ]]; then
  osascript -e 'display dialog "Operation cancelled." buttons {"OK"} default button 1'
  exit 0
fi

osascript -e 'display dialog "Restoring all connected devices. This may take several minutes. Please do not disconnect any devices.

A new Terminal window will open to show progress." buttons {"OK"} default button 1'

# Get the full path to this script
SCRIPT_PATH="$(cd "$(dirname "$0")"; pwd)/$(basename "$0")"

# Open a new Terminal window and run this script with the --do-restore flag
osascript <<EOF
tell application "Terminal"
    activate
    do script "bash $(printf %q "$SCRIPT_PATH") --do-restore"
end tell
EOF
