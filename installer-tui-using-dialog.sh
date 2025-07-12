#!/bin/bash

# Gentoo Linux UEFI-only BTRFS Installation with Multiple Init Systems
set -e

# Install dialog if missing
if ! command -v dialog >/dev/null; then
    emerge --quiet dialog >/dev/null 2>&1
fi

# Colors
RED='\033[38;2;255;0;0m'
CYAN='\033[38;2;0;255;255m'
NC='\033[0m'

show_ascii() {
    clear
    echo -e "${RED}░█████╗░██╗░░░░░░█████╗░██║░░░██╗██████╗░███████╗███╗░░░███╗░█████╗░██████╗░░██████╗
██╔══██╗██║░░░░░██╔══██╗██║░░░██║██╔══██╗██╔════╝████╗░████║██╔══██╗██╔══██╗██╔════╝
██║░░╚═╝██║░░░░░███████║██║░░░██║██║░░██║█████╗░░██╔████╔██║██║░░██║██║░░██║╚█████╗░
██║░░██╗██║░░░░░██╔══██║██║░░░██║██║░░██║██╔══╝░░██║╚██╔╝██║██║░░██║██║░░██║░╚═══██╗
╚█████╔╝███████╗██║░░██║╚██████╔╝██████╔╝███████╗██║░╚═╝░██║╚█████╔╝██████╔╝██████╔╝
░╚════╝░╚══════╝╚═╝░░╚═╝░╚═════╝░╚═════╝░╚══════╝╚═╝░░░░░╚═╝░╚════╝░╚═════╝░╚═════╝░${NC}"
    echo -e "${CYAN}Gentoo Btrfs Installer v1.02 12-07-2025${NC}"
    echo
}

cyan_output() {
    "$@" | while IFS= read -r line; do echo -e "${CYAN}$line${NC}"; done
}

configure_fastest_mirrors() {
    show_ascii
    dialog --title "Fastest Mirrors" --yesno "Would you like to find and use the fastest mirrors?" 7 50
    response=$?
    case $response in
        0) 
            echo -e "${CYAN}Finding fastest mirrors...${NC}"
            emerge --quiet app-portage/mirrorselect >/dev/null 2>&1
            mirrorselect -s4 -D -o >> /etc/portage/make.conf
            echo -e "${CYAN}Mirrorlist updated with fastest mirrors${NC}"
            ;;
        1) 
            echo -e "${CYAN}Using default mirrors${NC}"
            ;;
        255) 
            echo -e "${CYAN}Using default mirrors${NC}"
            ;;
    esac
}

select_kernel() {
    KERNEL_CHOICE=$(dialog --title "Kernel Selection" --menu "Select kernel:" 15 45 5 \
        "gentoo-kernel-bin" "Pre-built generic kernel" \
        "gentoo-sources" "Gentoo kernel with custom config" \
        "vanilla-sources" "Latest stable upstream kernel" \
        "hardened-sources" "Hardened kernel with security features" \
        "linux-zen-sources" "Zen kernel tuned for performance" 3>&1 1>&2 2>&3)
    
    # Additional kernel parameters
    KERNEL_PARAMS=$(dialog --title "Kernel Parameters" --inputbox "Enter additional kernel parameters (leave empty for default):" 8 70 3>&1 1>&2 2>&3)
}

install_kernel() {
    if [ "$KERNEL_CHOICE" = "gentoo-kernel-bin" ]; then
        # Install binary kernel
        cyan_output emerge --quiet sys-kernel/gentoo-kernel-bin
    else
        # Install kernel sources
        cyan_output emerge --quiet sys-kernel/${KERNEL_CHOICE}
        cyan_output emerge --quiet sys-kernel/linux-firmware
        
        # Configure kernel
        cd /usr/src/linux
        if [ ! -f .config ]; then
            if [ -f /proc/config.gz ]; then
                zcat /proc/config.gz > .config
            else
                make defconfig
            fi
        fi
        
        # Make kernel configuration more user-friendly
        if command -v nconfig >/dev/null; then
            make nconfig
        elif command -v menuconfig >/dev/null; then
            make menuconfig
        else
            echo -e "${CYAN}No kernel configurator found, using default config${NC}"
        fi
        
        # Compile and install kernel
        cyan_output make -j$(nproc)
        cyan_output make modules_install
        cyan_output make install
        
        # Generate initramfs
        cyan_output emerge --quiet sys-kernel/dracut
        dracut --hostonly --kver $(ls /lib/modules | sort -V | tail -n 1)
    fi
    
    # Update bootloader configuration
    if [ "$BOOTLOADER" = "GRUB" ]; then
        grub-mkconfig -o /boot/grub/grub.cfg
    elif [ "$BOOTLOADER" = "rEFInd" ]; then
        refind-install
    fi
}

perform_installation() {
    show_ascii

    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${CYAN}This script must be run as root or with sudo${NC}"
        exit 1
    fi

    if [ ! -d /sys/firmware/efi ]; then
        echo -e "${CYAN}ERROR: This script requires UEFI boot mode${NC}"
        exit 1
    fi

    echo -e "${CYAN}About to install to $TARGET_DISK with these settings:"
    echo "Hostname: $HOSTNAME"
    echo "Timezone: $TIMEZONE"
    echo "Keymap: $KEYMAP"
    echo "Username: $USER_NAME"
    echo "Desktop: $DESKTOP_ENV"
    echo "Bootloader: $BOOTLOADER"
    echo "Init System: $INIT_SYSTEM"
    echo "Kernel: $KERNEL_CHOICE"
    echo "Compression Level: $COMPRESSION_LEVEL${NC}"
    echo -ne "${CYAN}Continue? (y/n): ${NC}"
    read confirm
    if [ "$confirm" != "y" ]; then
        echo -e "${CYAN}Installation cancelled.${NC}"
        exit 1
    fi

    # Install required tools
    cyan_output emerge --quiet sys-fs/btrfs-progs sys-block/parted sys-fs/dosfstools sys-boot/efibootmgr

    # Partitioning
    cyan_output parted -s "$TARGET_DISK" mklabel gpt
    cyan_output parted -s "$TARGET_DISK" mkpart primary 1MiB 513MiB
    cyan_output parted -s "$TARGET_DISK" set 1 esp on
    cyan_output parted -s "$TARGET_DISK" mkpart primary 513MiB 100%

    # Formatting
    cyan_output mkfs.vfat -F32 "${TARGET_DISK}1"
    cyan_output mkfs.btrfs -f "${TARGET_DISK}2"

    # Mounting and subvolumes
    cyan_output mount "${TARGET_DISK}2" /mnt
    cyan_output btrfs subvolume create /mnt/@
    cyan_output btrfs subvolume create /mnt/@home
    cyan_output btrfs subvolume create /mnt/@root
    cyan_output btrfs subvolume create /mnt/@srv
    cyan_output btrfs subvolume create /mnt/@tmp
    cyan_output btrfs subvolume create /mnt/@log
    cyan_output btrfs subvolume create /mnt/@cache
    cyan_output umount /mnt

    # Remount with compression
    cyan_output mount -o subvol=@,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt
    cyan_output mkdir -p /mnt/boot/efi
    cyan_output mount "${TARGET_DISK}1" /mnt/boot/efi
    cyan_output mkdir -p /mnt/home
    cyan_output mkdir -p /mnt/root
    cyan_output mkdir -p /mnt/srv
    cyan_output mkdir -p /mnt/tmp
    cyan_output mkdir -p /mnt/var/cache
    cyan_output mkdir -p /mnt/var/log
    cyan_output mount -o subvol=@home,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/home
    cyan_output mount -o subvol=@root,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/root
    cyan_output mount -o subvol=@srv,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/srv
    cyan_output mount -o subvol=@tmp,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/tmp
    cyan_output mount -o subvol=@log,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/var/log
    cyan_output mount -o subvol=@cache,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/var/cache

    # Determine correct stage3 tarball based on init system
    case $INIT_SYSTEM in
        "systemd")
            STAGE3_TYPE="stage3-amd64-systemd"
            ;;
        "OpenRC")
            STAGE3_TYPE="stage3-amd64-openrc"
            ;;
        *)
            STAGE3_TYPE="stage3-amd64-openrc"
            ;;
    esac

    # Stage 3 tarball installation
    echo -e "${CYAN}Downloading and extracting $STAGE3_TYPE tarball...${NC}"
    LATEST_STAGE3=$(curl -s "https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-${STAGE3_TYPE}.txt" | grep -v '#' | awk '{print $1}')
    wget -q "https://distfiles.gentoo.org/releases/amd64/autobuilds/$LATEST_STAGE3" -O /tmp/stage3.tar.xz
    tar xpf /tmp/stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt
    rm /tmp/stage3.tar.xz

    # Mount required filesystems for chroot
    cyan_output mount -t proc none /mnt/proc
    cyan_output mount --rbind /dev /mnt/dev
    cyan_output mount --rbind /sys /mnt/sys

    # Determine login manager based on desktop environment
    case $DESKTOP_ENV in
        "KDE Plasma") LOGIN_MANAGER="sddm" ;;
        "GNOME") LOGIN_MANAGER="gdm" ;;
        "XFCE"|"MATE"|"LXQt") LOGIN_MANAGER="lightdm" ;;
        *) LOGIN_MANAGER="none" ;;
    esac

    # Chroot setup script
    cat << CHROOT | tee /mnt/setup-chroot.sh >/dev/null
#!/bin/bash

# Basic system configuration
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,usb,cdrom,portage "$USER_NAME"
echo "$USER_NAME:$USER_PASSWORD" | chpasswd
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
echo "$HOSTNAME" > /etc/hostname
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

# Generate fstab
cat << EOF > /etc/fstab
${TARGET_DISK}1 /boot/efi vfat defaults 0 2
${TARGET_DISK}2 / btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@ 0 1
${TARGET_DISK}2 /home btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@home 0 2
${TARGET_DISK}2 /root btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@root 0 2
${TARGET_DISK}2 /srv btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@srv 0 2
${TARGET_DISK}2 /tmp btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@tmp 0 2
${TARGET_DISK}2 /var/log btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@log 0 2
${TARGET_DISK}2 /var/cache btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@cache 0 2
EOF

# Configure portage
mkdir -p /etc/portage/repos.conf
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf
emerge-webrsync

# Set make.conf options
echo 'USE="X wayland pulseaudio dbus networkmanager"' >> /etc/portage/make.conf
echo "MAKEOPTS=\"-j$(nproc)\"" >> /etc/portage/make.conf

# Install kernel and related tools
emerge --quiet sys-kernel/installkernel-gentoo
$(declare -f install_kernel)
install_kernel

# Install desktop environment
case "$DESKTOP_ENV" in
    "KDE Plasma") 
        echo "kde-plasma/plasma-meta wayland" >> /etc/portage/package.use/plasma
        emerge --quiet kde-plasma/plasma-meta
        ;;
    "GNOME") 
        echo "gnome-base/gnome wayland" >> /etc/portage/package.use/gnome
        emerge --quiet gnome-base/gnome
        ;;
    "XFCE") 
        emerge --quiet xfce-base/xfce4-meta
        ;;
    "MATE") 
        emerge --quiet mate-base/mate-desktop
        ;;
    "LXQt") 
        emerge --quiet lxqt-base/lxqt-meta
        ;;
esac

# Install bootloader
case "$BOOTLOADER" in
    "GRUB")
        emerge --quiet sys-boot/grub
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GENTOO
        grub-mkconfig -o /boot/grub/grub.cfg
        ;;
    "rEFInd")
        emerge --quiet sys-boot/refind
        refind-install
        ;;
esac

# Configure init system
case "$INIT_SYSTEM" in
    "systemd")
        # systemd is already set up in systemd stage3
        systemctl enable NetworkManager
        [ "$LOGIN_MANAGER" != "none" ] && systemctl enable $LOGIN_MANAGER
        ;;
    "OpenRC")
        # OpenRC is already set up in OpenRC stage3
        rc-update add dbus default
        rc-update add NetworkManager default
        [ "$LOGIN_MANAGER" != "none" ] && rc-update add $LOGIN_MANAGER default
        ;;
    "runit")
        emerge --quiet sys-process/runit-rc
        echo "sys-process/runit-rc -openrc" >> /etc/portage/package.use/runit
        emerge --quiet --config sys-process/runit-rc
        mkdir -p /etc/runit/runlevels/default
        ln -s /etc/init.d/NetworkManager /etc/runit/runlevels/default/
        [ "$LOGIN_MANAGER" != "none" ] && ln -s /etc/init.d/$LOGIN_MANAGER /etc/runit/runlevels/default/
        ;;
    "s6")
        emerge --quiet sys-apps/s6 sys-apps/s6-rc
        mkdir -p /etc/s6/rc/compiled
        s6-rc-compile /etc/s6/rc/compiled /etc/s6/rc/source
        # Basic service setup would need to be expanded
        ;;
esac

# Clean up
rm /setup-chroot.sh
CHROOT

    chmod +x /mnt/setup-chroot.sh
    chroot /mnt /setup-chroot.sh

    umount -l /mnt
    echo -e "${CYAN}Installation complete!${NC}"

    # Post-install dialog menu
    while true; do
        choice=$(dialog --clear --title "Installation Complete" \
                       --menu "Select post-install action:" 12 45 5 \
                       1 "Reboot now" \
                       2 "Chroot into installed system" \
                       3 "Exit without rebooting" \
                       3>&1 1>&2 2>&3)

        case $choice in
            1) 
                clear
                echo -e "${CYAN}Rebooting system...${NC}"
                reboot
                ;;
            2)
                clear
                echo -e "${CYAN}Entering chroot...${NC}"
                mount "${TARGET_DISK}1" /mnt/boot/efi
                mount -o subvol=@ "${TARGET_DISK}2" /mnt
                mount -t proc none /mnt/proc
                mount --rbind /dev /mnt/dev
                mount --rbind /sys /mnt/sys
                mount --rbind /dev/pts /mnt/dev/pts
                chroot /mnt /bin/bash
                umount -l /mnt
                ;;
            3)
                clear
                exit 0
                ;;
            *)
                echo -e "${CYAN}Invalid option selected${NC}"
                ;;
        esac
    done
}

configure_installation() {
    TARGET_DISK=$(dialog --title "Target Disk" --inputbox "Enter target disk (e.g. /dev/sda):" 8 40 3>&1 1>&2 2>&3)
    HOSTNAME=$(dialog --title "Hostname" --inputbox "Enter hostname:" 8 40 3>&1 1>&2 2>&3)
    TIMEZONE=$(dialog --title "Timezone" --inputbox "Enter timezone (e.g. UTC):" 8 40 3>&1 1>&2 2>&3)
    KEYMAP=$(dialog --title "Keymap" --inputbox "Enter keymap (e.g. us):" 8 40 3>&1 1>&2 2>&3)
    USER_NAME=$(dialog --title "Username" --inputbox "Enter username:" 8 40 3>&1 1>&2 2>&3)
    USER_PASSWORD=$(dialog --title "User Password" --passwordbox "Enter user password:" 8 40 3>&1 1>&2 2>&3)
    ROOT_PASSWORD=$(dialog --title "Root Password" --passwordbox "Enter root password:" 8 40 3>&1 1>&2 2>&3)
    
    # Desktop environment selection
    DESKTOP_ENV=$(dialog --title "Desktop Environment" --menu "Select desktop:" 15 40 6 \
        "KDE Plasma" "KDE Plasma Desktop" \
        "GNOME" "GNOME Desktop" \
        "XFCE" "XFCE Desktop" \
        "MATE" "MATE Desktop" \
        "LXQt" "LXQt Desktop" \
        "None" "No desktop environment" 3>&1 1>&2 2>&3)
    
    # Bootloader selection
    BOOTLOADER=$(dialog --title "Bootloader Selection" --menu "Select bootloader:" 15 40 2 \
        "GRUB" "GRUB (recommended)" \
        "rEFInd" "Graphical boot manager" 3>&1 1>&2 2>&3)
    
    # Init system selection
    INIT_SYSTEM=$(dialog --title "Init System Selection" --menu "Select init system:" 15 40 4 \
        "systemd" "Systemd init system" \
        "OpenRC" "Gentoo's traditional init system" \
        "runit" "Runit init system" \
        "s6" "s6 init system" 3>&1 1>&2 2>&3)
    
    # Kernel selection
    select_kernel
    
    COMPRESSION_LEVEL=$(dialog --title "Compression Level" --inputbox "Enter BTRFS compression level (1-22, default is 22):" 8 40 22 3>&1 1>&2 2>&3)
    
    # Validate compression level
    if ! [[ "$COMPRESSION_LEVEL" =~ ^[0-9]+$ ]] || [ "$COMPRESSION_LEVEL" -lt 1 ] || [ "$COMPRESSION_LEVEL" -gt 22 ]; then
        dialog --msgbox "Invalid compression level. Using default (22)." 6 40
        COMPRESSION_LEVEL=22
    fi
}

main_menu() {
    while true; do
        choice=$(dialog --clear --title "Gentoo Btrfs Installer v1.02 12-07-2025" \
                       --menu "Select option:" 15 45 6 \
                       1 "Configure Installation" \
                       2 "Find Fastest Mirrors" \
                       3 "Start Installation" \
                       4 "Exit" 3>&1 1>&2 2>&3)

        case $choice in
            1) configure_installation ;;
            2) configure_fastest_mirrors ;;
            3)
                if [ -z "$TARGET_DISK" ]; then
                    dialog --msgbox "Please configure installation first!" 6 40
                else
                    perform_installation
                fi
                ;;
            4) clear; exit 0 ;;
        esac
    done
}

show_ascii
main_menu
