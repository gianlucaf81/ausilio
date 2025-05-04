#!/bin/bash

#=================================================
# SCRIPT: Create empty VM on Proxmox + Download ARC ISO from https://github.com/AuxXxilium/arc
# AUTHOR: Gianluca (gianlucaf81)
#=================================================

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

# Functions
print_success() { echo -e "${GREEN}[✔]${RESET} $1"; }
print_error()   { echo -e "${RED}[✘]${RESET} $1"; }
print_info()    { echo -e "${CYAN}[i]${RESET} $1"; }
print_warn()    { echo -e "${YELLOW}[!]${RESET} $1"; }

#=================================================
# Constants
#=================================================
ISO_STORAGE="/var/lib/vz/template/iso"
REPO_URL="https://github.com/AuxXxilium/arc"
DEFAULT_MEMORY="4096"
DEFAULT_CORES="2"
TITLE="ARC VM Creator"

#=================================================
# Check whiptail
#=================================================
check_dependencies() {
    # Check for whiptail (for the interface)
    if ! command -v whiptail &>/dev/null; then
        print_info "Installing whiptail..."
        if command -v apt &>/dev/null; then apt-get update -qq && apt-get install -y whiptail >/dev/null 2>&1
        elif command -v yum &>/dev/null; then yum install -y newt >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then dnf install -y newt >/dev/null 2>&1
        else print_error "Cannot install whiptail: no supported package manager found" && exit 1
        fi
        command -v whiptail &>/dev/null || { print_error "Failed to install whiptail."; exit 1; }
    fi
    
    # Check for unzip
    if ! command -v unzip &>/dev/null; then
        print_info "Installing unzip..."
        if command -v apt &>/dev/null; then apt-get update -qq && apt-get install -y unzip >/dev/null 2>&1
        elif command -v yum &>/dev/null; then yum install -y unzip >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then dnf install -y unzip >/dev/null 2>&1
        else print_error "Cannot install unzip: no supported package manager found" && exit 1
        fi
        command -v unzip &>/dev/null || { print_error "Failed to install unzip."; exit 1; }
    fi
}

#=================================================
# Cleanup
#=================================================
cleanup() {
    echo -e "${YELLOW}Cleaning temp files...${RESET}"
    rm -rf "$ISO_STORAGE/$(basename "$URL_DOWNLOAD")" "$ISO_STORAGE/${URL_DOWNLOAD##*/%.zip}" 2>/dev/null
    exit 1
}

trap cleanup ERR

#=================================================
# GUI Functions
#=================================================

# Get a list of available bridges
get_available_bridges() {
    ip link show | grep -oP '(?<=: )vmbr\d+' | sort
}

# Show a message with progress bar
show_progress() {
    local message="$1"
    local command="$2"
    local total="$3"
    
    (
        echo "0"
        eval "$command" &>/dev/null
        local exit_code=$?
        echo "100"
        exit $exit_code
    ) | whiptail --gauge "$message" 8 70 0
    
    return $?
}

#=================================================
# MAIN
#=================================================

# Check dependencies
check_dependencies

# Verify if user is root
if [[ $(id -u) -ne 0 ]]; then
    whiptail --title "$TITLE" --msgbox "This script must be run as root!" 8 60
    exit 1
fi

# Welcome screen
if ! whiptail --title "$TITLE" --yesno "This script will create a new Proxmox VM with the AuxXxilium ARC image.\n\nContinue?" 10 60; then
    exit 0
fi

# Get VMID 
NEXT_VMID=$(pvesh get /cluster/nextid)
VMID=$(whiptail --title "$TITLE" --inputbox "Enter VM ID (e.g., 100):" 8 60 "$NEXT_VMID" --title "VM ID" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 ]]; then
    exit 1
fi

# If blank use next free value
if [[ -z "$VMID" ]]; then
    VMID="$NEXT_VMID"
fi

# Check if VMID already exists
if qm list | awk '{print $1}' | grep -q "^$VMID$"; then
    whiptail --title "$TITLE" --msgbox "VM ID $VMID already exists. Choose another ID." 8 60
    exit 1
fi

# Get VM Name
VMNAME=$(whiptail --title "$TITLE" --inputbox "Enter VM name:" 8 60 --title "VM Name" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 || -z "$VMNAME" ]]; then
    exit 1
fi

# Hardware settings
MEMORY=$(whiptail --title "$TITLE" --inputbox "Memory (MB):" 8 60 "$DEFAULT_MEMORY" --title "Memory" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 || -z "$MEMORY" ]]; then
    MEMORY="$DEFAULT_MEMORY"
fi

CORES=$(whiptail --title "$TITLE" --inputbox "Number of CPU cores:" 8 60 "$DEFAULT_CORES" --title "CPU Cores" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 || -z "$CORES" ]]; then
    CORES="$DEFAULT_CORES"
fi

# Bridge selection
BRIDGES=$(get_available_bridges)
if [[ -z "$BRIDGES" ]]; then
    BRIDGE="vmbr0"  # Default
else
    BRIDGE=$(whiptail --title "$TITLE" --menu "Select network bridge:" 15 60 6 $(echo "$BRIDGES" | awk '{print $0, "Bridge"}') 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [[ $exitstatus -ne 0 || -z "$BRIDGE" ]]; then
        BRIDGE="vmbr0"  # Default
    fi
fi

# Option to add physical disks
ADD_DISKS=false
if whiptail --title "$TITLE" --yesno "Do you want to add physical disks to the VM?" 8 60; then
    ADD_DISKS=true
fi

# Variable to store disk information
DISK_INFO=""
DISK_COUNT=0
SATA_PORTS=()

# If user wants to add physical disks
if [[ "$ADD_DISKS" == "true" ]]; then
    # Ottieni la lista dei dischi disponibili
    AVAILABLE_DISKS=$(ls -la /dev/disk/by-id/ | grep -v "wwn\|part\|^$" | grep "ata\|scsi" | awk '{print $9,$11}' | sed 's/\.\.\/\.\.\//\/dev\//g' | sort)
    
    if [[ -z "$AVAILABLE_DISKS" ]]; then
        whiptail --title "$TITLE" --msgbox "No available physical disks found." 8 60
    else
        # Prepara l'array per la checklist
        disk_checklist_options=()
        while IFS= read -r line; do
            disk_id=$(echo "$line" | awk '{print $1}')
            disk_device=$(echo "$line" | awk '{print $2}')
            
            # Ottieni info disco
            if command -v lsblk &>/dev/null; then
                disk_size=$(lsblk -d -n -o SIZE "$disk_device" 2>/dev/null || echo "Unknown")
                disk_model=$(lsblk -d -n -o MODEL "$disk_device" 2>/dev/null || echo "Unknown")
                disk_info="${disk_size} ${disk_model} (${disk_device})"
            else
                disk_info="$disk_device"
            fi
            
            disk_checklist_options+=("$disk_id" "$disk_info" "OFF")
        done <<< "$AVAILABLE_DISKS"
        
        # Mostra checklist per selezione multipla
        SELECTED_DISKS_IDS=$(whiptail --title "$TITLE" --checklist \
            "Select disks to add (Space to select, Enter to confirm):" \
            20 80 10 "${disk_checklist_options[@]}" 3>&1 1>&2 2>&3)
        
        exitstatus=$?
        if [[ $exitstatus -ne 0 ]]; then
            print_info "Disk selection cancelled."
            ADD_DISKS=false
        else
            # Processa i dischi selezionati
            SELECTED_DISKS=()
            SATA_PORTS=()
            DISK_INFO=""
            DISK_COUNT=0
            
            # Convert selected list to array
            SELECTED_ARRAY=()
            for id in $SELECTED_DISKS_IDS; do
                id_clean=$(echo "$id" | sed 's/"//g')
                SELECTED_ARRAY+=("$id_clean")
            done
            
            # Assegna a ciascun disco una porta SATA
            for disk_id in "${SELECTED_ARRAY[@]}"; do
                PORT=$((DISK_COUNT + 1))
                SELECTED_DISKS+=("/dev/disk/by-id/$disk_id")
                SATA_PORTS+=("$PORT")
                DISK_INFO="${DISK_INFO}SATA${PORT}: /dev/disk/by-id/$disk_id\n"
                DISK_COUNT=$((DISK_COUNT + 1))
            done
            
            # Mostra riepilogo selezione
            if [[ $DISK_COUNT -gt 0 ]]; then
                whiptail --title "$TITLE" --msgbox "Dischi selezionati:\n\n$DISK_INFO" 20 70
            else
                ADD_DISKS=false
            fi
        fi
    fi
fi

# Settings summary including disks

DISKS_SUMMARY=""
if [[ -n "$DISK_INFO" ]]; then
    DISKS_SUMMARY="\n\nPhysical disks:\n$DISK_INFO"
fi

if ! whiptail --title "$TITLE" --yesno "Settings summary:\n\nVM ID: $VMID\nName: $VMNAME\nMemory: $MEMORY MB\nCPU Cores: $CORES\nBridge: $BRIDGE$DISKS_SUMMARY\n\nProceed with creation?" 20 70; then
    exit 0
fi

# Create VM
whiptail --title "$TITLE" --infobox "Creating VM $VMNAME with ID $VMID..." 8 60

if ! qm create "$VMID" \
    --name "$VMNAME" \
    --ostype l26 \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "virtio,bridge=$BRIDGE" \
    --boot 'order=sata0' \
    --scsihw virtio-scsi-pci \
    --machine pc \
    --agent enabled=1 \
    --onboot 0 \
    --ide2 none,media=cdrom \
    --serial0 socket; then
    
    whiptail --title "$TITLE" --msgbox "Error creating VM." 8 60
    exit 1
fi

# Remove default SCSI disk if it exists
whiptail --title "$TITLE" --infobox "Removing SCSI0 disk if present..." 8 60
qm set "$VMID" --delete scsi0 2>/dev/null

# Download ISO
URL_DOWNLOAD=$(curl -s https://api.github.com/repos/AuxXxilium/arc/releases/latest | grep "browser_download_url" | head -1 | cut -d '"' -f 4)

if [[ -z "$URL_DOWNLOAD" ]]; then
    whiptail --title "$TITLE" --msgbox "Unable to get download URL from GitHub API." 8 60
    exit 1
fi

ZIP_NAME="$(basename "$URL_DOWNLOAD")"

# Download with progress bar
(
    echo "10"
    echo "# Preparing download..."
    sleep 1
    
    echo "20"
    echo "# Downloading image from GitHub..."
    if ! wget -q -O "$ISO_STORAGE/$ZIP_NAME" "$URL_DOWNLOAD"; then
        echo "100"
        exit 1
    fi
    
    echo "50"
    echo "# Extracting ZIP file..."
    if ! unzip -o -d "$ISO_STORAGE" "$ISO_STORAGE/$ZIP_NAME" >/dev/null; then
        echo "100"
        exit 1
    fi
    
    echo "75"
    echo "# Setting permissions..."
    chmod 644 "$ISO_STORAGE"/*
    
    echo "90"
    echo "# Importing disk to local-lvm..."
    if ! qm importdisk "$VMID" "$ISO_STORAGE/arc.img" local-lvm; then
        echo "100"
        exit 1
    fi
    
    sleep 2
    
    echo "95"
    echo "# Configuring disk as IDE0..."
    if ! qm set "$VMID" --sata0 "local-lvm:vm-${VMID}-disk-0,cache=writeback"; then
        echo "100"
        exit 1
    fi
    
    # Add selected physical disks
    if [[ ${#SELECTED_DISKS[@]} -gt 0 ]]; then
        echo "96"
        echo "# Adding physical disks..."
        
        for i in "${!SELECTED_DISKS[@]}"; do
            disk_path="${SELECTED_DISKS[i]}"
            sata_port="${SATA_PORTS[i]}"
            
            echo "# Connecting physical disk to SATA${sata_port}..."
            if ! qm set "$VMID" --"sata${sata_port}" "$disk_path"; then
                echo "100"
                exit 1
            fi
            
            sleep 1
        done
    fi
    
    echo "100"
    echo "# Completed!"
    sleep 1
) | whiptail --title "$TITLE" --gauge "Initializing..." 10 70 0

# Check if operation completed successfully
if [[ $? -ne 0 ]]; then
    whiptail --title "$TITLE" --msgbox "An error occurred during download or import." 8 60
    cleanup
fi

# Final message
DISK_MSG=""
if [[ ${#SELECTED_DISKS[@]} -gt 0 ]]; then
    DISK_MSG="\n\nPhysical disks connected:"
    for i in "${!SELECTED_DISKS[@]}"; do
        DISK_MSG="${DISK_MSG}\nSATA${SATA_PORTS[i]}: ${SELECTED_DISKS[i]}"
    done
fi

whiptail --title "$TITLE" --msgbox "VM '$VMNAME' (ID: $VMID) created successfully!\n\nThe ARC image has been imported and configured as IDE0 with writeback cache.${DISK_MSG}\n\nYou can start the VM from the Proxmox web interface." 16 76

exit 0