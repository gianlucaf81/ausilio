#!/bin/bash

#=================================================
# SCRIPT: Create empty VM on Proxmox + Download ARC ISO from https://github.com/AuxXxilium/arc + assign the ISO as an IDE disk
# AUTHOR: Gianluca (gianlucaf81)
# Version 0.2 - Added OVFM UEFI Bios - Added selezione scheda controller PCI
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
# Costanti
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
    # Check whiptail (for interface)
    if ! command -v whiptail &>/dev/null; then
        print_info "Installing whiptail..."
        if command -v apt &>/dev/null; then apt-get update -qq && apt-get install -y whiptail >/dev/null 2>&1
        elif command -v yum &>/dev/null; then yum install -y newt >/dev/null 2>&1
        elif command -v dnf &>/dev/null; then dnf install -y newt >/dev/null 2>&1
        else print_error "Cannot install whiptail: no supported package manager found" && exit 1
        fi
        command -v whiptail &>/dev/null || { print_error "Failed to install whiptail."; exit 1; }
    fi
    
    # Controlla unzip
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
# GUI Function
#=================================================

# Get a list of available bridges
get_available_bridges() {
    ip link show | grep -oP '(?<=: )vmbr\d+' | sort
}

# Displays a message and a progress bar
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

# Check if user is root
if [[ $(id -u) -ne 0 ]]; then
    whiptail --title "$TITLE" --msgbox "This script must be run as root!" 8 60
    exit 1
fi

# Welcom screen
if ! whiptail --title "$TITLE" --yesno "This script will create a new Proxmox VM with the AuxXxilium ARC image.\n\nContinue?" 10 60; then
    exit 0
fi

# Get VMID 
NEXT_VMID=$(pvesh get /cluster/nextid)
VMID=$(whiptail --title "$TITLE" --inputbox "Select VM ID (e.g., 100):" 8 60 "$NEXT_VMID" --title "VM ID" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 ]]; then
    exit 1
fi

# If user leaves blank, use the suggested value
if [[ -z "$VMID" ]]; then
    VMID="$NEXT_VMID"
fi

# Chek if VMID already exist
if qm list | awk '{print $1}' | grep -q "^$VMID$"; then
    whiptail --title "$TITLE" --msgbox "VM ID $VMID already exists. Choose another ID." 8 60
    exit 1
fi

# Get VM name
VMNAME=$(whiptail --title "$TITLE" --inputbox "Enter the VM name:" 8 60 --title "VM Name" 3>&1 1>&2 2>&3)
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

# Selection Bridge
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

# Single choice: disk, passthrough PCI o nothing
ADD_DISKS=false
ADD_PCI_DEVICE=false
PCI_ID=""

DISK_CTRL_CHOICE=$(whiptail --title "$TITLE" --menu \
  "Do you want to add physical disks or a PCI device (e.g., SATA/SAS controller) to the VM?" 12 70 4 \
  "DISCS" "Add physical disks to the VM" \
  "PCI" "Add a PCI device (passthrough)" \
  "NONE" "Do not add anything" \
  3>&1 1>&2 2>&3)

exitstatus=$?
if [[ $exitstatus -ne 0 ]]; then
    ADD_DISKS=false
    ADD_PCI_DEVICE=false
else
    if [[ "$DISK_CTRL_CHOICE" == "DISCHI" ]]; then
        ADD_DISKS=true
    elif [[ "$DISK_CTRL_CHOICE" == "PCI" ]]; then
        ADD_PCI_DEVICE=true
    fi
fi

# If the user has chosen a PCI device
if [[ "$ADD_PCI_DEVICE" == "true" ]]; then
    PCI_LIST=$(lspci | grep -i -E "sata|sas|raid|storage|controller|AHCI" | awk '{print $1 " " substr($0, index($0,$2))}')
    if [[ -z "$PCI_LIST" ]]; then
        whiptail --title "$TITLE" --msgbox "No eligible PCI device found for passthrough.." 8 60
        ADD_PCI_DEVICE=false
    else
        PCI_OPTIONS=()
        while IFS= read -r line; do
            PCI_ID_LINE=$(echo "$line" | awk '{print $1}')
            PCI_DESC=$(echo "$line" | cut -d' ' -f2-)
            PCI_OPTIONS+=("$PCI_ID_LINE" "$PCI_DESC")
        done <<< "$PCI_LIST"

        SELECTED_PCI=$(whiptail --title "$TITLE" --menu \
            "Select the PCI device to assign to the VM:" \
            20 80 10 "${PCI_OPTIONS[@]}" 3>&1 1>&2 2>&3)

        exitstatus=$?
        if [[ $exitstatus -ne 0 || -z "$SELECTED_PCI" ]]; then
            ADD_PCI_DEVICE=false
        else
            PCI_ID="$SELECTED_PCI"
        fi
    fi
fi

# Variable to store disk information
DISK_INFO=""
DISK_COUNT=0
SATA_PORTS=()

# If the user wants to add physical disks
if [[ "$ADD_DISKS" == "true" ]]; then
    # Get the list of available disks
    AVAILABLE_DISKS=$(ls -la /dev/disk/by-id/ | grep -v "wwn\|part\|^$" | grep "ata\|scsi" | awk '{print $9,$11}' | sed 's/\.\.\/\.\.\//\/dev\//g' | sort)

    if [[ -z "$AVAILABLE_DISKS" ]]; then
        whiptail --title "$TITLE" --msgbox "No physical disks found." 8 60
        ADD_DISKS=false
    else
        # Prepare the array for the checklist
        disk_checklist_options=()
        while IFS= read -r line; do
            disk_id=$(echo "$line" | awk '{print $1}')
            disk_device=$(echo "$line" | awk '{print $2}')

            if command -v lsblk &>/dev/null; then
                disk_size=$(lsblk -d -n -o SIZE "$disk_device" 2>/dev/null || echo "Unknown")
                disk_model=$(lsblk -d -n -o MODEL "$disk_device" 2>/dev/null || echo "Unknown")
                disk_info="${disk_size} ${disk_model} (${disk_device})"
            else
                disk_info="$disk_device"
            fi

            disk_checklist_options+=("$disk_id" "$disk_info" "OFF")
        done <<< "$AVAILABLE_DISKS"

        SELECTED_DISKS_IDS=$(whiptail --title "$TITLE" --checklist \
            "Select the disks to add (Spacebar to select/deselect, Enter to confirm):" \
            20 80 10 "${disk_checklist_options[@]}" 3>&1 1>&2 2>&3)

        exitstatus=$?
        if [[ $exitstatus -ne 0 ]]; then
            ADD_DISKS=false
        else
            SELECTED_DISKS=()
            SATA_PORTS=()
            DISK_INFO=""
            DISK_COUNT=0

            SELECTED_ARRAY=()
            for id in $SELECTED_DISKS_IDS; do
                id_clean=$(echo "$id" | sed 's/"//g')
                SELECTED_ARRAY+=("$id_clean")
            done

            for disk_id in "${SELECTED_ARRAY[@]}"; do
                PORT=$((DISK_COUNT + 1))
                SELECTED_DISKS+=("/dev/disk/by-id/$disk_id")
                SATA_PORTS+=("$PORT")
                DISK_INFO="${DISK_INFO}SATA${PORT}: /dev/disk/by-id/$disk_id\n"
                DISK_COUNT=$((DISK_COUNT + 1))
            done

            if [[ $DISK_COUNT -gt 0 ]]; then
                whiptail --title "$TITLE" --msgbox "Selected discs:\n\n$DISK_INFO" 20 70
            else
                ADD_DISKS=false
            fi
        fi
    fi
fi


# Settings summary with included disks
DISKS_SUMMARY=""
if [[ -n "$DISK_INFO" ]]; then
    DISKS_SUMMARY="\n\nPhysical disks:\n$DISK_INFO"
fi

if ! whiptail --title "$TITLE" --yesno "Settings Summary:\n\nVM ID: $VMID\nName: $VMNAME\nMemory: $MEMORY MB\nCPU Cores: $CORES\nBridge: $BRIDGE$DISKS_SUMMARY\n\nProceed with creation?" 20 70; then
    exit 0
fi

# Creazione VM
whiptail --title "$TITLE" --infobox "VM creation $VMNAME with ID $VMID..." 8 60

if ! qm create "$VMID" \
    --name "$VMNAME" \
    --ostype l26 \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "virtio,bridge=$BRIDGE" \
    --boot 'order=sata0' \
    --scsihw virtio-scsi-pci \
    --bios ovmf \
    --machine q35 \
    --agent enabled=1 \
    --onboot 0 \
    --ide2 none,media=cdrom \
    --serial0 socket; then
    
    whiptail --title "$TITLE" --msgbox "Error creating VM." 8 60
    exit 1
fi

# Wait for the .conf file to actually be written
for i in {1..5}; do
    if [[ -f "/etc/pve/qemu-server/${VMID}.conf" ]]; then
        break
    fi
    sleep 1
done

# Now you can run qm set safely
qm set "$VMID" --efidisk0 local-lvm:4,efitype=4m,format=raw


# Add PCI passthrough device if selected
if [[ "$ADD_PCI_DEVICE" == "true" && -n "$PCI_ID" ]]; then
    qm set "$VMID" --hostpci0 "$PCI_ID"
    print_info "PCI device $PCI_ID added to VM."
fi


# Remove default SCSI disk if it exists
whiptail --title "$TITLE" --infobox "Remove SCSI0 disk if present..." 8 60
qm set "$VMID" --delete scsi0 2>/dev/null

# Download ISO
URL_DOWNLOAD=$(curl -s https://api.github.com/repos/AuxXxilium/arc/releases/latest | grep "browser_download_url" | head -1 | cut -d '"' -f 4)

if [[ -z "$URL_DOWNLOAD" ]]; then
    whiptail --title "$TITLE" --msgbox "Unable to get download URL from GitHub API." 8 60
    exit 1
fi

ZIP_NAME="$(basename "$URL_DOWNLOAD")"

# Download con barra di progresso
(
    echo "10"
    echo "# Download preparation..."
    sleep 1
    
    echo "20"
    echo "# Download the image from GitHub..."
    if ! wget -q -O "$ISO_STORAGE/$ZIP_NAME" "$URL_DOWNLOAD"; then
        echo "100"
        exit 1
    fi
    
    echo "50"
    echo "# Extracting ZIP files..."
    if ! unzip -o -d "$ISO_STORAGE" "$ISO_STORAGE/$ZIP_NAME" >/dev/null; then
        echo "100"
        exit 1
    fi
    
    echo "75"
    echo "# Setting permissions..."
    chmod 644 "$ISO_STORAGE"/*
    
    echo "90"
    echo "# Importing disk into local-lvm..."
    if ! qm importdisk "$VMID" "$ISO_STORAGE/arc.img" local-lvm; then
        echo "100"
        exit 1
    fi
    
    sleep 2
    
    echo "95"
    echo "# Configuring disk as IDE0..."
    if ! qm set "$VMID" --sata0 "local-lvm:vm-${VMID}-disk-1,cache=writeback"; then
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
            
            echo "# Attaching physical disk to SATA${sata_port}..."
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
) | whiptail --title "$TITLE" --gauge "Initialization..." 10 70 0

# Controlla se l'operazione è terminata con successo
if [[ $? -ne 0 ]]; then
    whiptail --title "$TITLE" --msgbox "An error occurred while downloading or importing." 8 60
    cleanup
fi

# Messaggio finale
DISK_MSG=""
if [[ ${#SELECTED_DISKS[@]} -gt 0 ]]; then
    DISK_MSG="\n\nAttached physical disks:"
    for i in "${!SELECTED_DISKS[@]}"; do
        DISK_MSG="${DISK_MSG}\nSATA${SATA_PORTS[i]}: ${SELECTED_DISKS[i]}"
    done
fi

whiptail --title "$TITLE" --msgbox "VM '$VMNAME' (ID: $VMID) created successfully!\n\nThe ARC image has been imported and configured as IDE0 with writeback cache.${DISK_MSG}\n\nYou can boot the VM from the Proxmox web interface." 16 76

exit 0
