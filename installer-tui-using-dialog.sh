#!/bin/bash

# Gentoo UEFI-only BTRFS Installation with Full Init System Support
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
    echo -e "${RED}░██████╗░███████╗███╗░░██╗████████╗░█████╗░
██╔════╝░██╔════╝████╗░██║╚══██╔══╝██╔══██╗
██║░░██╗░█████╗░░██╔██╗██║░░░██║░░░██║░░██║
██║░░╚██╗██╔══╝░░██║╚████║░░░██║░░░██║░░██║
╚██████╔╝███████╗██║░╚███║░░░██║░░░╚█████╔╝
░╚═════╝░╚══════╝╚═╝░░╚══╝░░░╚═╝░░░░╚════╝░${NC}"
    echo -e "${CYAN}Gentoo Btrfs Installer v1.1 12-07-2025${NC}"
    echo -e "${CYAN}Supports OpenRC, systemd, runit, and s6${NC}"
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
            emerge --quiet mirrorselect >/dev/null 2>&1
            mirrorselect -s4 -D -o > /etc/portage/make.conf
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
    cyan_output emerge --quiet sys-fs/btrfs-progs sys-block/parted dosfstools sys-boot/efibootmgr

    # Partitioning
    cyan_output parted -s "$TARGET_DISK" mklabel gpt
    cyan_output parted -s "$TARGET_DISK" mkpart primary 1MiB 513MiB
    cyan_output parted -s "$TARGET_DISK" set 1 esp on
    cyan_output parted -s "$TARGET_DISK" mkpart primary 513MiB 100%

    # Formatting
    cyan_output mkfs.vfat -F32 "${TARGET_DISK}1"
    cyan_output mkfs.btrfs -f "${TARGET_DISK}2"

    # Mounting and subvolumes
    cyan_output mount "${TARGET_DISK}2" /mnt/gentoo
    cyan_output btrfs subvolume create /mnt/gentoo/@
    cyan_output btrfs subvolume create /mnt/gentoo/@home
    cyan_output btrfs subvolume create /mnt/gentoo/@root
    cyan_output btrfs subvolume create /mnt/gentoo/@srv
    cyan_output btrfs subvolume create /mnt/gentoo/@tmp
    cyan_output btrfs subvolume create /mnt/gentoo/@var_log
    cyan_output btrfs subvolume create /mnt/gentoo/@var_cache
    cyan_output umount /mnt/gentoo

    # Remount with compression
    cyan_output mount -o subvol=@,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/gentoo
    cyan_output mkdir -p /mnt/gentoo/boot/efi
    cyan_output mount "${TARGET_DISK}1" /mnt/gentoo/boot/efi
    cyan_output mkdir -p /mnt/gentoo/home
    cyan_output mkdir -p /mnt/gentoo/root
    cyan_output mkdir -p /mnt/gentoo/srv
    cyan_output mkdir -p /mnt/gentoo/tmp
    cyan_output mkdir -p /mnt/gentoo/var/cache
    cyan_output mkdir -p /mnt/gentoo/var/log
    cyan_output mount -o subvol=@home,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/gentoo/home
    cyan_output mount -o subvol=@root,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/gentoo/root
    cyan_output mount -o subvol=@srv,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/gentoo/srv
    cyan_output mount -o subvol=@tmp,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/gentoo/tmp
    cyan_output mount -o subvol=@var_log,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/gentoo/var/log
    cyan_output mount -o subvol=@var_cache,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL "${TARGET_DISK}2" /mnt/gentoo/var/cache

    # Determine stage3 URL based on init system
    case $INIT_SYSTEM in
        "systemd") 
            STAGE3_TYPE="stage3-amd64-systemd"
            ;;
        *) 
            STAGE3_TYPE="stage3-amd64-openrc"
            ;;
    esac

    # Download and extract stage3 tarball
    cd /mnt/gentoo
    cyan_output wget https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-${STAGE3_TYPE}.txt
    STAGE3_URL=$(grep -v '^#' latest-${STAGE3_TYPE}.txt | awk '{print $1}')
    cyan_output wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_URL}"
    cyan_output tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

    # Mount required filesystems for chroot
    cyan_output mount --types proc /proc /mnt/gentoo/proc
    cyan_output mount --rbind /sys /mnt/gentoo/sys
    cyan_output mount --make-rslave /mnt/gentoo/sys
    cyan_output mount --rbind /dev /mnt/gentoo/dev
    cyan_output mount --make-rslave /mnt/gentoo/dev
    cyan_output mount --bind /run /mnt/gentoo/run
    cyan_output mount --make-slave /mnt/gentoo/run

    # Determine login manager based on desktop environment
    case $DESKTOP_ENV in
        "KDE Plasma") LOGIN_MANAGER="sddm" ;;
        "GNOME") LOGIN_MANAGER="gdm" ;;
        "XFCE"|"MATE"|"LXQt") LOGIN_MANAGER="lightdm" ;;
        *) LOGIN_MANAGER="none" ;;
    esac

    # Chroot setup script
    cat << CHROOT | tee /mnt/gentoo/setup-chroot.sh >/dev/null
#!/bin/bash

# Basic system configuration
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,users,audio,video,usb,cdrom,portage,plugdev -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASSWORD" | chpasswd

# Generate fstab
cat << EOF > /etc/fstab
${TARGET_DISK}1 /boot/efi vfat defaults 0 2
${TARGET_DISK}2 / btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@ 0 1
${TARGET_DISK}2 /home btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@home 0 2
${TARGET_DISK}2 /root btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@root 0 2
${TARGET_DISK}2 /srv btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@srv 0 2
${TARGET_DISK}2 /tmp btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@tmp 0 2
${TARGET_DISK}2 /var/log btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@var_log 0 2
${TARGET_DISK}2 /var/cache btrfs rw,noatime,compress=zstd:$COMPRESSION_LEVEL,compress-force=zstd:$COMPRESSION_LEVEL,subvol=@var_cache 0 2
EOF

# Configure Portage
echo 'MAKEOPTS="-j$(nproc)"' >> /etc/portage/make.conf
echo 'EMERGE_DEFAULT_OPTS="--quiet-build"' >> /etc/portage/make.conf
mkdir -p /etc/portage/repos.conf
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf
emerge-webrsync

# Select profile based on init system
case "$INIT_SYSTEM" in
    "systemd")
        eselect profile set default/linux/amd64/17.1/systemd
        ;;
    *)
        eselect profile set default/linux/amd64/17.1
        ;;
esac

# Update @world set
emerge --update --deep --newuse @world

# Configure locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

# Install kernel
case "$KERNEL_CHOICE" in
    "gentoo-sources")
        emerge sys-kernel/gentoo-sources
        emerge sys-kernel/genkernel
        cd /usr/src/linux
        make defconfig
        genkernel --install --kernel-config=/usr/src/linux/.config all
        ;;
    "vanilla-sources")
        emerge sys-kernel/vanilla-sources
        emerge sys-kernel/genkernel
        cd /usr/src/linux
        make defconfig
        genkernel --install --kernel-config=/usr/src/linux/.config all
        ;;
    "linux-next")
        emerge sys-kernel/linux-next
        emerge sys-kernel/genkernel
        cd /usr/src/linux
        make defconfig
        genkernel --install --kernel-config=/usr/src/linux/.config all
        ;;
    "binary")
        emerge sys-kernel/gentoo-kernel-bin
        ;;
esac

# Install bootloader
case "$BOOTLOADER" in
    "GRUB")
        emerge sys-boot/grub
        case "$INIT_SYSTEM" in
            "systemd")
                echo 'GRUB_CMDLINE_LINUX="init=/usr/lib/systemd/systemd"' >> /etc/default/grub
                ;;
        esac
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=gentoo
        grub-mkconfig -o /boot/grub/grub.cfg
        ;;
    "rEFInd")
        emerge sys-boot/refind
        refind-install
        ;;
esac

# Install desktop environment
case "$DESKTOP_ENV" in
    "KDE Plasma") 
        echo ">=kde-plasma/plasma-meta-5.27.9 ~amd64" >> /etc/portage/package.accept_keywords
        emerge kde-plasma/plasma-meta
        ;;
    "GNOME") 
        emerge gnome-base/gnome
        ;;
    "XFCE") 
        emerge xfce-base/xfce4-meta
        ;;
    "MATE") 
        emerge mate-base/mate
        ;;
    "LXQt") 
        emerge lxqt-base/lxqt-meta
        ;;
esac

# Configure network
emerge --noreplace net-misc/netifrc
echo 'hostname="'"$HOSTNAME"'"' > /etc/conf.d/hostname
echo 'config_eth0="dhcp"' > /etc/conf.d/net
ln -s /etc/init.d/net.lo /etc/init.d/net.eth0

# Configure init system
case "$INIT_SYSTEM" in
    "OpenRC")
        rc-update add net.eth0 default
        rc-update add dbus default
        rc-update add sshd default
        [ "$LOGIN_MANAGER" != "none" ] && rc-update add $LOGIN_MANAGER default
        ;;
    "systemd")
        systemctl enable systemd-networkd
        systemctl enable systemd-resolved
        systemctl enable dbus
        systemctl enable sshd
        [ "$LOGIN_MANAGER" != "none" ] && systemctl enable $LOGIN_MANAGER
        ;;
    "runit")
        emerge --quiet sys-process/runit-rc
        rc-update del net.eth0 default
        mkdir -p /etc/runit/runsvdir/default
        # Network service
        mkdir -p /etc/runit/sv/net.eth0
        echo '#!/bin/sh' > /etc/runit/sv/net.eth0/run
        echo 'exec /etc/init.d/net.eth0 start' >> /etc/runit/sv/net.eth0/run
        chmod +x /etc/runit/sv/net.eth0/run
        ln -s /etc/runit/sv/net.eth0 /etc/runit/runsvdir/default/
        # DBus service
        mkdir -p /etc/runit/sv/dbus
        echo '#!/bin/sh' > /etc/runit/sv/dbus/run
        echo 'exec /etc/init.d/dbus start' >> /etc/runit/sv/dbus/run
        chmod +x /etc/runit/sv/dbus/run
        ln -s /etc/runit/sv/dbus /etc/runit/runsvdir/default/
        # SSHD service
        mkdir -p /etc/runit/sv/sshd
        echo '#!/bin/sh' > /etc/runit/sv/sshd/run
        echo 'exec /etc/init.d/sshd start' >> /etc/runit/sv/sshd/run
        chmod +x /etc/runit/sv/sshd/run
        ln -s /etc/runit/sv/sshd /etc/runit/runsvdir/default/
        # Login manager service if selected
        if [ "$LOGIN_MANAGER" != "none" ]; then
            mkdir -p /etc/runit/sv/$LOGIN_MANAGER
            echo '#!/bin/sh' > /etc/runit/sv/$LOGIN_MANAGER/run
            echo 'exec /etc/init.d/$LOGIN_MANAGER start' >> /etc/runit/sv/$LOGIN_MANAGER/run
            chmod +x /etc/runit/sv/$LOGIN_MANAGER/run
            ln -s /etc/runit/sv/$LOGIN_MANAGER /etc/runit/runsvdir/default/
        fi
        ;;
    "s6")
        emerge --quiet sys-apps/s6
        emerge --quiet sys-apps/s6-rc
        rc-update del net.eth0 default
        # Create service directories
        mkdir -p /etc/s6/sv/net.eth0
        echo '#!/bin/sh' > /etc/s6/sv/net.eth0/run
        echo 'exec /etc/init.d/net.eth0 start' >> /etc/s6/sv/net.eth0/run
        chmod +x /etc/s6/sv/net.eth0/run
        mkdir -p /etc/s6/sv/dbus
        echo '#!/bin/sh' > /etc/s6/sv/dbus/run
        echo 'exec /etc/init.d/dbus start' >> /etc/s6/sv/dbus/run
        chmod +x /etc/s6/sv/dbus/run
        mkdir -p /etc/s6/sv/sshd
        echo '#!/bin/sh' > /etc/s6/sv/sshd/run
        echo 'exec /etc/init.d/sshd start' >> /etc/s6/sv/sshd/run
        chmod +x /etc/s6/sv/sshd/run
        # Login manager service if selected
        if [ "$LOGIN_MANAGER" != "none" ]; then
            mkdir -p /etc/s6/sv/$LOGIN_MANAGER
            echo '#!/bin/sh' > /etc/s6/sv/$LOGIN_MANAGER/run
            echo 'exec /etc/init.d/$LOGIN_MANAGER start' >> /etc/s6/sv/$LOGIN_MANAGER/run
            chmod +x /etc/s6/sv/$LOGIN_MANAGER/run
        fi
        # Create the scan directory
        mkdir -p /etc/s6/scan
        # Create the dependencies directory
        mkdir -p /etc/s6/rc/compiled
        # Create the compilation directory
        mkdir -p /etc/s6/rc/source
        ;;
esac

# Clean up
rm /setup-chroot.sh
CHROOT

    chmod +x /mnt/gentoo/setup-chroot.sh
    chroot /mnt/gentoo /setup-chroot.sh

    umount -R /mnt/gentoo
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
                mount "${TARGET_DISK}1" /mnt/gentoo/boot/efi
                mount -o subvol=@ "${TARGET_DISK}2" /mnt/gentoo
                mount --types proc /proc /mnt/gentoo/proc
                mount --rbind /sys /mnt/gentoo/sys
                mount --make-rslave /mnt/gentoo/sys
                mount --rbind /dev /mnt/gentoo/dev
                mount --make-rslave /mnt/gentoo/dev
                mount --bind /run /mnt/gentoo/run
                mount --make-slave /mnt/gentoo/run
                chroot /mnt/gentoo /bin/bash
                umount -R /mnt/gentoo
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
    TIMEZONE=$(dialog --title "Timezone" --inputbox "Enter timezone (e.g. America/New_York):" 8 40 3>&1 1>&2 2>&3)
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
    
    # Kernel selection
    KERNEL_CHOICE=$(dialog --title "Kernel Selection" --menu "Select kernel:" 15 40 4 \
        "gentoo-sources" "Gentoo patched kernel sources" \
        "vanilla-sources" "Upstream kernel sources" \
        "linux-next" "Linux next development kernel" \
        "binary" "Pre-built binary kernel" 3>&1 1>&2 2>&3)
    
    # Init system selection
    INIT_SYSTEM=$(dialog --title "Init System Selection" --menu "Select init system:" 15 40 4 \
        "OpenRC" "Gentoo's traditional init system" \
        "systemd" "System and service manager" \
        "runit" "Runit init system" \
        "s6" "s6 init system" 3>&1 1>&2 2>&3)
    
    COMPRESSION_LEVEL=$(dialog --title "Compression Level" --inputbox "Enter BTRFS compression level (1-22, default is 22):" 8 40 22 3>&1 1>&2 2>&3)
    
    # Validate compression level
    if ! [[ "$COMPRESSION_LEVEL" =~ ^[0-9]+$ ]] || [ "$COMPRESSION_LEVEL" -lt 1 ] || [ "$COMPRESSION_LEVEL" -gt 22 ]; then
        dialog --msgbox "Invalid compression level. Using default (22)." 6 40
        COMPRESSION_LEVEL=22
    fi
}

main_menu() {
    while true; do
        choice=$(dialog --clear --title "Gentoo Btrfs Installer v1.1 12-07-2025" \
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
