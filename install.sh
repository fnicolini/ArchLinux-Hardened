#!/bin/bash
#
# Arch Linux installation
#
# Heavily inspired by https://github.com/maximbaz/dotfiles/blob/master/install.sh
#
# Before you run this script from your Arch ISO:
#
# - Set boot mode to UEFI, disable Legacy mode entirely.
# - Temporarily disable Secure Boot.
# - Make sure a strong UEFI administrator password is set.
# - Delete preloaded OEM keys for Secure Boot, allow custom ones.
#
# Run installation:
#
# - Connect to wifi via: `# iwctl station wlan0 connect WIFI-NETWORK`
# - Run: `# git clone https://github.com/ShellCode33/TiredOfLinuxSetup`
# - Run: `# bash install_archlinux.sh`

set -euo pipefail
cd "$(dirname "$0")"
trap on_error ERR

# Redirect outputs to files for easier debugging
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log" >&2)

# Dialog
BACKTITLE="Arch Linux installation"

on_error() {
	ret=$?
	echo "[$0] Error on line $LINENO: $BASH_COMMAND"
	exit $ret
}

get_input() {
	title="$1"
	description="$2"

	input=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --inputbox "$description" 0 0)
	echo "$input"
}

get_password() {
	title="$1"
	description="$2"

	init_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description" 0 0)
	test -z "$init_pass" && echo >&2 "password cannot be empty" && exit 1

	test_pass=$(dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --passwordbox "$description again" 0 0)
	if [[ "$init_pass" != "$test_pass" ]]; then
		echo "Passwords did not match" >&2
		exit 1
	fi
	echo "$init_pass"
}

get_choice() {
	title="$1"
	description="$2"
	shift 2
	options=("$@")
	dialog --clear --stdout --backtitle "$BACKTITLE" --title "$title" --menu "$description" 0 0 0 "${options[@]}"
}

if [ ! -d /sys/firmware/efi ]; then
	echo >&2 "legacy BIOS boot detected, this install script only works with UEFI."
	exit 1
fi

# Unmount previously mounted devices in case the install script is run multiple times
swapoff -a || true
umount -R /mnt 2>/dev/null || true
cryptsetup luksClose archlinux 2>/dev/null || true

# Basic settings
timedatectl set-ntp true
hwclock --systohc --utc

# Keyring from ISO might be outdated, upgrading it just in case
pacman -Sy --noconfirm --needed archlinux-keyring

# Make sure some basic tools that will be used in this script are installed
pacman -Sy --noconfirm --needed git reflector terminus-font dialog wget

# Adjust the font size in case the screen is hard to read
noyes=("Yes" "The font is too small" "No" "The font size is just fine")
hidpi=$(get_choice "Font size" "Is your screen HiDPI?" "${noyes[@]}") || exit 1
clear
[[ "$hidpi" == "Yes" ]] && font="ter-132n" || font="ter-716n"
setfont "$font"

# Ask which device to install ArchLinux on
devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac | tr '\n' ' ')
read -r -a devicelist <<<"$devicelist"
device=$(get_choice "Installation" "Select installation disk" "${devicelist[@]}") || exit 1
clear

noyes=("Yes" "I want to remove everything on $device" "No" "GOD NO !! ABORT MISSION")
lets_go=$(get_choice "Are you absolutely sure ?" "YOU ARE ABOUT TO ERASE EVERYTHING ON $device" "${noyes[@]}") || exit 1
clear
[[ "$lets_go" == "No" ]] && exit 1

hostname=$(get_input "Hostname" "Enter hostname") || exit 1
clear
test -z "$hostname" && echo >&2 "hostname cannot be empty" && exit 1

user=$(get_input "User" "Enter username") || exit 1
clear
test -z "$user" && echo >&2 "user cannot be empty" && exit 1

password=$(get_password "User" "Enter password") || exit 1
clear
test -z "$password" && echo >&2 "password cannot be empty" && exit 1

echo "Setting up fastest mirrors..."
reflector --country France,Germany --latest 30 --sort rate --save /etc/pacman.d/mirrorlist
clear

echo "Writing random bytes to $device, go grab some coffee it might take a while"
dd bs=1M if=/dev/urandom of="$device" status=progress || true

# Setting up partitions
lsblk -plnx size -o name "${device}" | xargs -n1 wipefs --all
sgdisk --clear "${device}" --new 1::-551MiB "${device}" --new 2::0 --typecode 2:ef00 "${device}"
sgdisk --change-name=1:primary --change-name=2:ESP "${device}"

# shellcheck disable=SC2086,SC2010
{
	part_root="$(ls ${device}* | grep -E "^${device}p?1$")"
	part_boot="$(ls ${device}* | grep -E "^${device}p?2$")"
}

mkfs.vfat -n "EFI" -F 32 "${part_boot}"
echo -n "$password" | cryptsetup luksFormat --label archlinux "${part_root}"
echo -n "$password" | cryptsetup luksOpen "${part_root}" archlinux
mkfs.btrfs --label archlinux /dev/mapper/archlinux

# Create btrfs subvolumes
mount /dev/mapper/archlinux /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@libvirt
btrfs subvolume create /mnt/@docker
btrfs subvolume create /mnt/@cache-pacman-pkgs
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@var-log
btrfs subvolume create /mnt/@var-tmp
umount /mnt

#
# Great btrfs documentations:
# https://en.opensuse.org/SDB:BTRFS
# https://wiki.debian.org/Btrfs
# https://wiki.archlinux.org/title/btrfs
#

mount_opt="defaults,noatime,nodiratime,compress=zstd,space_cache=v2"
mount -o subvol=@,$mount_opt /dev/mapper/archlinux /mnt
mount --mkdir -o umask=0077 "${part_boot}" /mnt/efi
mount --mkdir -o subvol=@home,$mount_opt /dev/mapper/archlinux /mnt/home
mount --mkdir -o subvol=@swap,$mount_opt /dev/mapper/archlinux /mnt/.swap
mount --mkdir -o subvol=@snapshots,umask=0077,$mount_opt /dev/mapper/archlinux /mnt/.snapshots
mount --mkdir -o subvol=@var,$mount_opt,nodatacow /dev/mapper/archlinux /mnt/var
mount --mkdir -o subvol=@var-log,$mount_opt,nodatacow /dev/mapper/archlinux /mnt/var/log
mount --mkdir -o subvol=@libvirt,$mount_opt,nodatacow /dev/mapper/archlinux /mnt/var/lib/libvirt
mount --mkdir -o subvol=@docker,$mount_opt,nodatacow /dev/mapper/archlinux /mnt/var/lib/docker # I feel like using the btrfs storage driver of Docker is not safe yet (nocow for now)

# Not worth snapshoting, creating subvolumes for them so that they're not included
# Be careful not to break a potential future rollback of /@ !!
mount --mkdir -o subvol=@cache-pacman-pkgs,$mount_opt /dev/mapper/archlinux /mnt/var/cache/pacman/pkg
mount --mkdir -o subvol=@var-tmp,$mount_opt /dev/mapper/archlinux /mnt/var/tmp

# Create swapfile for btrfs main system
btrfs filesystem mkswapfile /mnt/.swap/swapfile
mkswap /mnt/.swap/swapfile # according to btrfs doc it shouldn't be needed, it's a bug
swapon /mnt/.swap/swapfile # we use the swap so that genfstab detects it

# Install all packages listed in packages/regular
grep -o '^[^ *#]*' packages/regular | pacstrap -K /mnt -

# Copy custom files to the new installation
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/
find rootfs -type f -exec bash -c 'file="$1"; dest="/mnt/${file#rootfs/}"; mkdir -p "$(dirname "$dest")"; cp "$file" "$dest"' shell {} \;

# Patch pacman config
sed -i "s/#Color/Color/g" /mnt/etc/pacman.conf

# Patch placeholders from config files
sed -i "s/username_placeholder/$user/g" /mnt/etc/systemd/system/getty@tty1.service.d/autologin.conf
sed -i "s/username_placeholder/$user/g" /mnt/etc/libvirt/qemu.conf

# Set the very fast dash in place of sh
ln -sfT dash /mnt/usr/bin/sh

{
	# Customize Linux Security Modules to include AppArmor
	echo -n "lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

	# Put kernel in integrity lockdown mode
	echo -n " lockdown=integrity"

	# The LUKS device to decrypt
	echo -n " cryptdevice=${part_root}:archlinux"

	# The decrypted device to mount as the root
	echo -n " root=/dev/mapper/archlinux"

	# Mount the @ btrfs subvolume inside the decrypted device as the root
	echo -n " rootflags=subvol=@"

	# Allow suspend state (puts device into sleep but keeps powering the RAM for fast sleep mode recovery)
	echo -n " mem_sleep_default=deep"

	# Ensure that all processes that run before the audit daemon starts are marked as auditable by the kernel
	echo -n " audit=1"

	# Increase default log size
	echo -n " audit_backlog_limit=16384"

	# Completely quiet the boot process to display some eye candy using plymouth instead :)
	echo -n " quiet splash rd.udev.log_level=3"
} >/mnt/etc/kernel/cmdline

echo "FONT=$font" >/mnt/etc/vconsole.conf
echo "KEYMAP=fr-latin1" >>/mnt/etc/vconsole.conf

echo "${hostname}" >/mnt/etc/hostname
echo "en_US.UTF-8 UTF-8" >>/mnt/etc/locale.gen
echo "fr_FR.UTF-8 UTF-8" >>/mnt/etc/locale.gen
ln -sf /usr/share/zoneinfo/Europe/Paris /mnt/etc/localtime
arch-chroot /mnt locale-gen

genfstab -U /mnt >>/mnt/etc/fstab

# Creating user
arch-chroot /mnt useradd -m -s /bin/sh "$user" # keep a real POSIX shell as default, not zsh, that will come later
for group in wheel audit libvirt; do
	arch-chroot /mnt groupadd -rf "$group"
	arch-chroot /mnt gpasswd -a "$user" "$group"
done
echo "$user:$password" | arch-chroot /mnt chpasswd
touch /mnt/etc/hushlogins # for a smoother transition between Plymouth and Sway
sed -i 's/HUSHLOGIN_FILE.*/#\0/g' /etc/login.defs

# Temporarly give sudo NOPASSWD rights to user for yay
echo "$user ALL=(ALL) NOPASSWD:ALL" >>"/mnt/etc/sudoers"

# Temporarly disable pacman wrapper so that no warning is issued
mv /mnt/usr/local/bin/pacman /mnt/usr/local/bin/pacman.disable

# Install AUR helper
arch-chroot -u "$user" /mnt /bin/bash -c 'mkdir /tmp/yay.$$ && \
                                          cd /tmp/yay.$$ && \
                                          curl "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=yay-bin" -o PKGBUILD && \
                                          makepkg -si --noconfirm'

# Install AUR packages
grep -o '^[^ *#]*' packages/aur | HOME="/home/$user" arch-chroot -u "$user" /mnt /usr/bin/yay --noconfirm -Sy -

# Restore pacman wrapper
mv /mnt/usr/local/bin/pacman.disable /mnt/usr/local/bin/pacman

# Remove sudo NOPASSWD rights from user
sed -i '$ d' /mnt/etc/sudoers

# WARNING: using plymouth is not ideal since its code run early at boot
#          and can be the source of high privilege vulnerabilities.
#          But hey, security is always a matter of compromise. And I like some
#          eye candy, so I made my choice :)
#
# You can choose your own theme from there: https://github.com/adi1090x/plymouth-themes
arch-chroot /mnt plymouth-set-default-theme colorful_loop

cat <<EOF >/mnt/etc/mkinitcpio.conf
MODULES=(i915)
BINARIES=(setfont)
FILES=()
HOOKS=(base consolefont keymap udev autodetect modconf block plymouth encrypt filesystems keyboard)
EOF

# This must be done after plymouth is installed from the AUR
arch-chroot /mnt mkinitcpio -p linux-hardened

# Generate UEFI keys, sign kernels, enroll keys, etc.
echo 'KERNEL=linux-hardened' >/mnt/etc/arch-secure-boot/config
arch-chroot /mnt arch-secure-boot initial-setup

# Hardenning
arch-chroot /mnt chmod 700 /boot
arch-chroot /mnt passwd -dl root

# Configure systemd services
arch-chroot /mnt systemctl enable getty@tty1
arch-chroot /mnt systemctl enable btrfs-scrub@-.timer
arch-chroot /mnt systemctl enable btrfs-balance.timer
arch-chroot /mnt systemctl enable pacman-sync.timer
arch-chroot /mnt systemctl enable pacman-notify.timer
arch-chroot /mnt systemctl enable pacnew-notify.timer
arch-chroot /mnt systemctl enable dbus-broker
arch-chroot /mnt systemctl enable dhcpcd
arch-chroot /mnt systemctl enable iwd
arch-chroot /mnt systemctl enable auditd
arch-chroot /mnt systemctl enable nftables
arch-chroot /mnt systemctl enable docker
arch-chroot /mnt systemctl enable libvirtd
arch-chroot /mnt systemctl enable check-secure-boot
arch-chroot /mnt systemctl enable apparmor
arch-chroot /mnt systemctl enable auditor.timer
arch-chroot /mnt systemctl enable auditd-notify

# Configure systemd user services
arch-chroot /mnt systemctl --global enable dbus-broker
arch-chroot /mnt systemctl --global enable journalctl-notify
arch-chroot /mnt systemctl --global enable pipewire
arch-chroot /mnt systemctl --global enable wireplumber

# Run userspace configuration
HOME="/home/$user" arch-chroot -u "$user" /mnt /bin/bash -c 'cd && \
                                                             git clone https://github.com/ShellCode33/.dotfiles && \
                                                             .dotfiles/install.sh'
