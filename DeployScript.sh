
DFUMode(){
    sudo macvdmtool dfu

}

Restore(){
    cfgutil restore

}

MainGUI(){
    while true; do
        USER_CHOICE=$(osascript <<EOD
            set options to {"DFU Mode", "Restore", "Exit"}
            choose from list options with title "JAMF Commands" with prompt "Select a JAMF command to execute:" default items {"Jamf Recon"}
EOD
)
        if [[ "$USER_CHOICE" == "DFU Mode" ]]; then
            echo "Forcing Mac into DFU Mode"
            Sleep 2
            DFUMode
            continue

        elif [[ "$USER_CHOICE" == "Restore" ]]; then 
            echo "Restoring All connected MacBooks" 
            Sleep 2
            Restore
            continue
        elif [[ "$USER_CHOICE" == "Exit" ]]; then
            echo "Exiting App"
            exit 0
        else
            echo "Invalid Selction"
            continue
        fi
    done
}

macvdmtoolCheck(){
    if ! command -v macvdmtool >/dev/null 2>&1; then 
        decision=$(osascript <<-EOD
            tell application "System Events"
            activate
            display dialog "Would you like to install MACVDMTOOL? (y/n):" default answer "" with title "Missing Require Dependency for DFU"
            set userResponse to text returned of result
            return userResponse
            end tell
EOD
)
    else   
        echo "macvdmtool is installed" 
        
    fi
        if [[ "$decision" == "y" ]]; then
            xcode-select --install
            git clone https://github.com/AsahiLinux/macvdmtool.git
            cd macvdmtool
            make
            sudo cp macvdmtool /usr/local/bin

        elif [[ "$decision" == "n" ]]; then
            exit 0
        
        else    
            echo "invalid command" 
        fi
}

macvdmtoolCheck
MainGUI
