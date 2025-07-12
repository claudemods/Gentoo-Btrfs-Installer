#!/bin/bash
# Gentoo UEFI-only BTRFS Installation with Multiple Init Systems
set -e

# Install dialog if missing
if ! command -v dialog >/dev/null; then
    emerge --quiet app-misc/dialog >/dev/null 2>&1
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
    echo -e "${CYAN}Gentoo Btrfs Installer v1.0 12-07-2025${NC}"
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
            emerge --sync >/dev/null 2>&1
            mirrorselect -i -o >> /etc/portage/make.conf
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
    echo "Compression Level: $COMPRESSION_LEVEL${NC}"
    echo -ne "${CYAN}Continue? (y/n): ${NC}"
    read confirm
    if [ "$confirm" != "y" ]; then
        echo -e "${CYAN}Installation cancelled.${NC}"
        exit 1
    fi

    # Install required tools
    cyan_output emerge --quiet sys-fs/btrfs-progs sys-block/parted sys-boot/efibootmgr dosfstools

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

    # Install base system
    cyan_output emerge-webrsync >/dev/null 2>&1
    cyan_output emerge --quiet sys-apps/baselayout sys-kernel/gentoo-sources sys-apps/openrc

    # Generate fstab
    ROOT_UUID=$(blkid -s UUID -o value "${TARGET_DISK}2")
    {
        echo ""
        echo "# Btrfs subvolumes (auto-added)"
        echo "UUID=$ROOT_UUID /              btrfs   rw,noatime,compress=zstd:$COMPRESSION_LEVEL,discard=async,space_cache=v2,subvol=/@ 0 0"
        echo "UUID=$ROOT_UUID /root          btrfs   rw,noatime,compress=zstd:$COMPRESSION_LEVEL,discard=async,space_cache=v2,subvol=/@root 0 0"
        echo "UUID=$ROOT_UUID /home          btrfs   rw,noatime,compress=zstd:$COMPRESSION_LEVEL,discard=async,space_cache=v2,subvol=/@home 0 0"
        echo "UUID=$ROOT_UUID /srv           btrfs   rw,noatime,compress=zstd:$COMPRESSION_LEVEL,discard=async,space_cache=v2,subvol=/@srv 0 0"
        echo "UUID=$ROOT_UUID /var/cache     btrfs   rw,noatime,compress=zstd:$COMPRESSION_LEVEL,discard=async,space_cache=v2,subvol=/@cache 0 0"
        echo "UUID=$ROOT_UUID /var/tmp       btrfs   rw,noatime,compress=zstd:$COMPRESSION_LEVEL,discard=async,space_cache=v2,subvol=/@tmp 0 0"
        echo "UUID=$ROOT_UUID /var/log       btrfs   rw,noatime,compress=zstd:$COMPRESSION_LEVEL,discard=async,space_cache=v2,subvol=/@log 0 0"
    } > /mnt/etc/fstab

    # Chroot setup
    cat << CHROOT | tee /mnt/setup-chroot.sh >/dev/null
#!/bin/bash
# Basic system configuration
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
# Users and passwords
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,storage,optical -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASSWORD" | chpasswd
# Configure sudo
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
# Handle bootloader installation
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
    "OpenRC")
        # OpenRC is Gentoo's default
        rc-update add dbus
        rc-update add NetworkManager
        [ "$LOGIN_MANAGER" != "none" ] && rc-update add $LOGIN_MANAGER
        ;;
    "systemd")
        emerge --quiet sys-apps/systemd
        ln -sf /usr/lib/systemd/systemd /sbin/init
        systemctl enable dbus
        systemctl enable NetworkManager
        [ "$LOGIN_MANAGER" != "none" ] && systemctl enable $LOGIN_MANAGER
        ;;
    "runit")
        emerge --quiet sys-process/runit
        ln -sf /usr/bin/runit-init /sbin/init
        # Set up runit services
        mkdir -p /etc/runit/runsvdir/default
        for service in dbus NetworkManager $LOGIN_MANAGER; do
            if [ -f "/etc/init.d/$service" ]; then
                ln -s /etc/init.d/$service /etc/runit/runsvdir/default/
            fi
        done
        ;;
    "s6")
        emerge --quiet sys-process/s6
        ln -sf /usr/bin/s6-init /sbin/init
        # Set up s6 services
        mkdir -p /etc/s6/sv
        for service in dbus NetworkManager $LOGIN_MANAGER; do
            if [ -f "/etc/init.d/$service" ]; then
                mkdir -p /etc/s6/sv/$service
                echo '#!/bin/sh' > /etc/s6/sv/$service/run
                echo 'exec /etc/init.d/$service start' >> /etc/s6/sv/$service/run
                chmod +x /etc/s6/sv/$service/run
            fi
        done
        ;;
esac
# Clean up
rm /setup-chroot.sh
CHROOT
    chmod +x /mnt/setup-chroot.sh
    chroot /mnt /setup-chroot.sh
    umount -R /mnt
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
                umount -R /mnt
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
        "OpenRC" "Gentoo's default init system" \
        "systemd" "Systemd init system" \
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
        choice=$(dialog --clear --title "Gentoo Btrfs Installer v1.0 12-07-2025" \
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
