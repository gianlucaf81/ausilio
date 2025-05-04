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
    # Controlla whiptail (per l'interfaccia)
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
# Funzioni GUI
#=================================================

# Ottieni una lista di bridge disponibili
get_available_bridges() {
    ip link show | grep -oP '(?<=: )vmbr\d+' | sort
}

# Mostra un messaggio e un progress bar
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

# Controlla dipendenze
check_dependencies

# Verifica se l'utente è root
if [[ $(id -u) -ne 0 ]]; then
    whiptail --title "$TITLE" --msgbox "Questo script deve essere eseguito come root!" 8 60
    exit 1
fi

# Schermata di benvenuto
if ! whiptail --title "$TITLE" --yesno "Questo script creerà una nuova VM Proxmox con l'immagine ARC di AuxXxilium.\n\nContinuare?" 10 60; then
    exit 0
fi

# Ottieni VMID 
NEXT_VMID=$(pvesh get /cluster/nextid)
VMID=$(whiptail --title "$TITLE" --inputbox "Scegli VM ID (e.g., 100):" 8 60 "$NEXT_VMID" --title "VM ID" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 ]]; then
    exit 1
fi

# Se l'utente lascia vuoto, usa il valore suggerito
if [[ -z "$VMID" ]]; then
    VMID="$NEXT_VMID"
fi

# Verifica se VMID esiste già
if qm list | awk '{print $1}' | grep -q "^$VMID$"; then
    whiptail --title "$TITLE" --msgbox "VM ID $VMID già esistente. Scegli un altro ID." 8 60
    exit 1
fi

# Ottieni Nome VM
VMNAME=$(whiptail --title "$TITLE" --inputbox "Inserisci il nome della VM:" 8 60 --title "VM Name" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 || -z "$VMNAME" ]]; then
    exit 1
fi

# Impostazioni hardware
MEMORY=$(whiptail --title "$TITLE" --inputbox "Memoria (MB):" 8 60 "$DEFAULT_MEMORY" --title "Memoria" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 || -z "$MEMORY" ]]; then
    MEMORY="$DEFAULT_MEMORY"
fi

CORES=$(whiptail --title "$TITLE" --inputbox "Numero di core CPU:" 8 60 "$DEFAULT_CORES" --title "CPU Cores" 3>&1 1>&2 2>&3)
exitstatus=$?
if [[ $exitstatus -ne 0 || -z "$CORES" ]]; then
    CORES="$DEFAULT_CORES"
fi

# Selezione Bridge
BRIDGES=$(get_available_bridges)
if [[ -z "$BRIDGES" ]]; then
    BRIDGE="vmbr0"  # Default
else
    BRIDGE=$(whiptail --title "$TITLE" --menu "Seleziona il bridge di rete:" 15 60 6 $(echo "$BRIDGES" | awk '{print $0, "Bridge"}') 3>&1 1>&2 2>&3)
    exitstatus=$?
    if [[ $exitstatus -ne 0 || -z "$BRIDGE" ]]; then
        BRIDGE="vmbr0"  # Default
    fi
fi

# Opzione per aggiungere dischi fisici
ADD_DISKS=false
if whiptail --title "$TITLE" --yesno "Vuoi aggiungere dischi fisici alla VM?" 8 60; then
    ADD_DISKS=true
fi

# Variabile per memorizzare le informazioni dei dischi
DISK_INFO=""
DISK_COUNT=0
SATA_PORTS=()

# Se l'utente vuole aggiungere dischi fisici
if [[ "$ADD_DISKS" == "true" ]]; then
    # Ottieni la lista dei dischi disponibili
    AVAILABLE_DISKS=$(ls -la /dev/disk/by-id/ | grep -v "wwn\|part\|^$" | grep "ata\|scsi" | awk '{print $9,$11}' | sed 's/\.\.\/\.\.\//\/dev\//g' | sort)
    
    if [[ -z "$AVAILABLE_DISKS" ]]; then
        whiptail --title "$TITLE" --msgbox "Nessun disco fisico trovato" 8 60
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
            "Seleziona i dischi da aggiungere (Barra spaziatrice per selez./deselez., Enter per confermare):" \
            20 80 10 "${disk_checklist_options[@]}" 3>&1 1>&2 2>&3)
        
        exitstatus=$?
        if [[ $exitstatus -ne 0 ]]; then
            print_info "Selezione dischi annullata."
            ADD_DISKS=false
        else
            # Processa i dischi selezionati
            SELECTED_DISKS=()
            SATA_PORTS=()
            DISK_INFO=""
            DISK_COUNT=0
            
            # Converti lista selezionata in array
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

# Riepilogo impostazioni con dischi inclusi
DISKS_SUMMARY=""
if [[ -n "$DISK_INFO" ]]; then
    DISKS_SUMMARY="\n\nDischi fisici:\n$DISK_INFO"
fi

if ! whiptail --title "$TITLE" --yesno "Riepilogo impostazioni:\n\nVM ID: $VMID\nNome: $VMNAME\nMemoria: $MEMORY MB\nCPU Cores: $CORES\nBridge: $BRIDGE$DISKS_SUMMARY\n\nProcedere con la creazione?" 20 70; then
    exit 0
fi

# Creazione VM
whiptail --title "$TITLE" --infobox "Creazione VM $VMNAME con ID $VMID..." 8 60

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
    
    whiptail --title "$TITLE" --msgbox "Errore nella creazione della VM." 8 60
    exit 1
fi

# Rimuovi disco SCSI predefinito se esiste
whiptail --title "$TITLE" --infobox "Rimozione disco SCSI0 se presente..." 8 60
qm set "$VMID" --delete scsi0 2>/dev/null

# Download ISO
URL_DOWNLOAD=$(curl -s https://api.github.com/repos/AuxXxilium/arc/releases/latest | grep "browser_download_url" | head -1 | cut -d '"' -f 4)

if [[ -z "$URL_DOWNLOAD" ]]; then
    whiptail --title "$TITLE" --msgbox "Impossibile ottenere l'URL di download dalla GitHub API." 8 60
    exit 1
fi

ZIP_NAME="$(basename "$URL_DOWNLOAD")"

# Download con barra di progresso
(
    echo "10"
    echo "# Preparazione download..."
    sleep 1
    
    echo "20"
    echo "# Download dell'immagine da GitHub..."
    if ! wget -q -O "$ISO_STORAGE/$ZIP_NAME" "$URL_DOWNLOAD"; then
        echo "100"
        exit 1
    fi
    
    echo "50"
    echo "# Estrazione file ZIP..."
    if ! unzip -o -d "$ISO_STORAGE" "$ISO_STORAGE/$ZIP_NAME" >/dev/null; then
        echo "100"
        exit 1
    fi
    
    echo "75"
    echo "# Impostazione permessi..."
    chmod 644 "$ISO_STORAGE"/*
    
    echo "90"
    echo "# Importazione disco in local-lvm..."
    if ! qm importdisk "$VMID" "$ISO_STORAGE/arc.img" local-lvm; then
        echo "100"
        exit 1
    fi
    
    sleep 2
    
    echo "95"
    echo "# Configurazione disco come IDE0..."
    if ! qm set "$VMID" --sata0 "local-lvm:vm-${VMID}-disk-0,cache=writeback"; then
        echo "100"
        exit 1
    fi
    
    # Aggiungi i dischi fisici selezionati
    if [[ ${#SELECTED_DISKS[@]} -gt 0 ]]; then
        echo "96"
        echo "# Aggiunta dei dischi fisici..."
        
        for i in "${!SELECTED_DISKS[@]}"; do
            disk_path="${SELECTED_DISKS[i]}"
            sata_port="${SATA_PORTS[i]}"
            
            echo "# Collegamento disco fisico a SATA${sata_port}..."
            if ! qm set "$VMID" --"sata${sata_port}" "$disk_path"; then
                echo "100"
                exit 1
            fi
            
            sleep 1
        done
    fi
    
    echo "100"
    echo "# Completato!"
    sleep 1
) | whiptail --title "$TITLE" --gauge "Inizializzazione..." 10 70 0

# Controlla se l'operazione è terminata con successo
if [[ $? -ne 0 ]]; then
    whiptail --title "$TITLE" --msgbox "Si è verificato un errore durante il download o l'importazione." 8 60
    cleanup
fi

# Messaggio finale
DISK_MSG=""
if [[ ${#SELECTED_DISKS[@]} -gt 0 ]]; then
    DISK_MSG="\n\nDischi fisici collegati:"
    for i in "${!SELECTED_DISKS[@]}"; do
        DISK_MSG="${DISK_MSG}\nSATA${SATA_PORTS[i]}: ${SELECTED_DISKS[i]}"
    done
fi

whiptail --title "$TITLE" --msgbox "VM '$VMNAME' (ID: $VMID) creata con successo!\n\nL'immagine ARC è stata importata e configurata come IDE0 con cache writeback.${DISK_MSG}\n\nPuoi avviare la VM dall'interfaccia web di Proxmox." 16 76

exit 0