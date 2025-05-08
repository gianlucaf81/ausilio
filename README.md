# 🛠️ Ausilio

**VM per Arc Loader** (Redpill Loader personalizzato per DSM 7.x / Xpenology) **per Proxmox**   `community-scripts` / `tteck` style

## 🇮🇹 Descrizione (Italiano)
Script per la creazione di un NAS Synology virtuale.
Questo script crea automaticamente una macchina virtuale su Proxmox, scaricando l’ISO del progetto Arc Loader da github.com/AuxXxilium/arc.
Chiede all'utente che dischi fisici assegnare alla VM nei quali verranno scritti i dati utente e la configurazione del NAS.
Una volta creata la VM avviarla e seguire le indicazioni dalla shell della VM stessa, per la scelta del modello del NAS.
Per entrare nell'interfaccia del NAS usare l'ip suggerito dall'interfaccia stessa oppure cercarlo con Advanced Ip Scanner oppure con find.synology.com
L'ip sarà di tipo 192.168.1.123:5000

**⚠️ ATTENZIONE:** DSM non è in grado di rilevare i dati smart dei dischi passati direttamente così, per questa funzionalità serve passare alla VM l'intero controller SATA.

📥 **Per eseguire lo script in italiano**, usare questo comando nella shell principale di Proxmox:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/ausilio/refs/heads/main/ausilio_it_v0.1.sh)"
```



## 🇬🇧 Description (English)
Script for creating a virtual Synology NAS.
This script automatically creates a virtual machine on Proxmox by downloading the ISO from the Arc Loader project at github.com/AuxXxilium/arc.
It prompts the user to assign physical disks to the VM, which will be used to store user data and NAS configuration.
Once the VM is created, start it and follow the instructions shown in the VM shell to select the NAS model.
To access the NAS interface, use the IP address suggested by the VM interface, or find it using Advanced IP Scanner or via find.synology.com.
The IP address will typically look like 192.168.1.123:5000.

**⚠️ WARNING:** DSM is not able to read S.M.A.R.T. data from disks passed through directly this way. To enable this functionality, you need to passthrough the entire SATA controller to the VM.

📥 **To run the script in English**, use this command from the main Proxmox shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/gianlucaf81/ausilio/refs/heads/main/ausilio_en_v0.1.sh)"
```

![](https://github.com/gianlucaf81/ausilio/blob/d4b7211e7fd1f07bf15d09831dfe85e0a6192a45/media/ausilio_en.gif)



