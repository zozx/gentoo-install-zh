# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

function install_stage3() {
	prepare_installation_environment
	apply_disk_configuration
	download_stage3
	extract_stage3
}

function configure_base_system() {
	if [[ $MUSL == "true" ]]; then
		einfo "正在安裝 musl-locales"
		try emerge --verbose sys-apps/musl-locales
		echo 'MUSL_LOCPATH="/usr/share/i18n/locales/musl"' >> /etc/env.d/00local \
			|| die "無法寫入 /etc/env.d/00local"
	else
		einfo "地區設定生成中"
		echo "$LOCALES" > /etc/locale.gen \
			|| die "無法寫入 /etc/locale.gen"
		locale-gen \
			|| die "無法生成地區設定"
	fi

	if [[ $SYSTEMD == "true" ]]; then
		einfo "Setting machine-id"
		systemd-machine-id-setup \
			|| die "無法設定 systemd 機器 ID"

		# Set hostname
		einfo "主機名設定中"
		echo "$HOSTNAME" > /etc/hostname \
			|| die "無法寫入 /etc/hostname"

		# Set keymap
		einfo "鍵盤佈局設定中"
		echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf \
			|| die "無法寫入 /etc/vconsole.conf"

		# Set locale
		einfo "地區設定中"
		echo "LANG=$LOCALE" > /etc/locale.conf \
			|| die "無法寫入 /etc/locale.conf"

		einfo "時區設定中"
		ln -sfn "../usr/share/zoneinfo/$TIMEZONE" /etc/localtime \
			|| die "無法變更 /etc/localtime 連結"
	else
		# Set hostname
		einfo "主機名設定中"
		sed -i "/hostname=/c\\hostname=\"$HOSTNAME\"" /etc/conf.d/hostname \
			|| die "無法用 sed 在 /etc/conf.d/hostname 中進行替換"

		# Set timezone
		if [[ $MUSL == "true" ]]; then
			try emerge -v sys-libs/timezone-data
			einfo "時區設定中"
			echo -e "TZ=\"$TIMEZONE\"" >> /etc/env.d/00local \
				|| die "無法寫入 /etc/env.d/00local"
		else
			einfo "時區設定中"
			echo "$TIMEZONE" > /etc/timezone \
				|| die "無法寫入 /etc/timezone"
			chmod 644 /etc/timezone \
				|| die "無法為 /etc/timezone 設定正確權限"
			try emerge -v --config sys-libs/timezone-data
		fi

		# Set keymap
		einfo "鍵盤佈局設定中"
		sed -i "/keymap=/c\\keymap=\"$KEYMAP\"" /etc/conf.d/keymaps \
			|| die "無法用 sed 在 /etc/conf.d/keymaps 中進行替換"

		# Set locale
		einfo "地區選擇中"
		try eselect locale set "$LOCALE"
	fi

	# Update environment
	env_update
}

function configure_portage() {
	# Prepare /etc/portage for autounmask
	mkdir_or_die 0755 "/etc/portage/package.use"
	touch_or_die 0644 "/etc/portage/package.use/zz-autounmask"
	mkdir_or_die 0755 "/etc/portage/package.keywords"
	touch_or_die 0644 "/etc/portage/package.keywords/zz-autounmask"
	touch_or_die 0644 "/etc/portage/package.license"

	if [[ $SELECT_MIRRORS == "true" ]]; then
		einfo "正在臨時安裝 mirrorselect"
		try emerge --verbose --oneshot app-portage/mirrorselect

		einfo "正在選擇最快的 portage 鏡像"
		mirrorselect_params=("-s" "4" "-b" "10")
		[[ $SELECT_MIRRORS_LARGE_FILE == "true" ]] \
			&& mirrorselect_params+=("-D")
		try mirrorselect "${mirrorselect_params[@]}"
	fi

	if [[ $ENABLE_BINPKG == "true" ]]; then
		echo 'FEATURES="getbinpkg binpkg-request-signature"' >> /etc/portage/make.conf
		getuto
		chmod 644 /etc/portage/gnupg/pubring.kbx
	fi

	chmod 644 /etc/portage/make.conf \
		|| die "無法 chmod 644 /etc/portage/make.conf"
}

function enable_sshd() {
	einfo "正在安裝並啟用 sshd"
	install -m0600 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/sshd_config" /etc/ssh/sshd_config \
		|| die "無法安裝 /etc/ssh/sshd_config"
	enable_service sshd
}

function install_authorized_keys() {
	mkdir_or_die 0700 "/root/"
	mkdir_or_die 0700 "/root/.ssh"

	if [[ -n "$ROOT_SSH_AUTHORIZED_KEYS" ]]; then
		einfo "正在為 root 添加獲授權的金鑰"
		touch_or_die 0600 "/root/.ssh/authorized_keys"
		echo "$ROOT_SSH_AUTHORIZED_KEYS" > "/root/.ssh/authorized_keys" \
			|| die "無法添加 ssh 金鑰至 /root/.ssh/authorized_keys"
	fi
}

function generate_initramfs() {
	local output="$1"

	# Generate initramfs
	einfo "正在生成 initramfs"

	local modules=()
	[[ $USED_RAID == "true" ]] \
		&& modules+=("mdraid")
	[[ $USED_LUKS == "true" ]] \
		&& modules+=("crypt crypt-gpg")
	[[ $USED_BTRFS == "true" ]] \
		&& modules+=("btrfs")
	[[ $USED_ZFS == "true" ]] \
		&& modules+=("zfs")

	local kver
	kver="$(readlink /usr/src/linux)" \
		|| die "無法從 /usr/src/linux 符號連結確定內核版本"
	kver="${kver#linux-}"

	dracut_opts=()
	if [[ $SYSTEMD == "true" && $SYSTEMD_INITRAMFS_SSHD == "true" ]]; then
		cd /tmp || die "無法進入 /tmp"
		try git clone https://github.com/gsauthof/dracut-sshd
		try cp -r dracut-sshd/46sshd /usr/lib/dracut/modules.d
		sed -e 's/^Type=notify/Type=simple/' \
			-e 's@^\(ExecStart=/usr/sbin/sshd\) -D@\1 -e -D@' \
			-i /usr/lib/dracut/modules.d/46sshd/sshd.service \
			|| die "無法在 service 文件中替換 sshd 選項"
		dracut_opts+=("--install" "/etc/systemd/network/20-wired.network")
		modules+=("systemd-networkd")
	fi

	# Generate initramfs
	# TODO --conf          "/dev/null" \
	# TODO --confdir       "/dev/null" \
	try dracut \
		--kver          "$kver" \
		--zstd \
		--no-hostonly \
		--ro-mnt \
		--add           "bash ${modules[*]}" \
		"${dracut_opts[@]}" \
		--force \
		"$output"

	# Create script to repeat initramfs generation
	cat > "$(dirname "$output")/generate_initramfs.sh" <<EOF
#!/bin/bash
kver="\$1"
output="\$2" # At setup time, this was "$output"
[[ -n "\$kver" ]] || { echo "usage \$0 <kernel_version> <output>" >&2; exit 1; }
dracut \\
	--kver          "\$kver" \\
	--zstd \\
	--no-hostonly \\
	--ro-mnt \\
	--add           "bash ${modules[*]}" \\
	${dracut_opts[@]@Q} \\
	--force \\
	"\$output"
EOF
}

function get_cmdline() {
	local cmdline=("rd.vconsole.keymap=$KEYMAP_INITRAMFS")
	cmdline+=("${DISK_DRACUT_CMDLINE[@]}")

	if [[ $USED_ZFS != "true" ]]; then
		cmdline+=("root=UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")")
	fi

	echo -n "${cmdline[*]}"
}

function install_kernel_efi() {
	try emerge --verbose sys-boot/efibootmgr

	# Copy kernel to EFI
	local kernel_file
	kernel_file="$(find "/boot" \( -name "vmlinuz-*" -or -name 'kernel-*' \) -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "無法列出最新的內核文件"

	try cp "/boot/$kernel_file" "/boot/efi/vmlinuz.efi"

	# Generate initramfs
	generate_initramfs "/boot/efi/initramfs.img"

	# Create boot entry
	einfo "正在創建 EFI 引導項"
	local efipartdev
	efipartdev="$(resolve_device_by_id "$DISK_ID_EFI")" \
		|| die "無法以 id=$DISK_ID_EFI 解析設備"
	efipartdev="$(realpath "$efipartdev")" \
		|| die "真路徑 '$efipartdev' 出現錯誤"

	# Get the sysfs path to EFI partition
	local sys_efipart
	sys_efipart="/sys/class/block/$(basename "$efipartdev")" \
		|| die "無法建設至 EFI 分區的 /sys 路徑"

	# Extract partition number, handling both standard and RAID cases
	local efipartnum
	if [[ -e "$sys_efipart/partition" ]]; then
		efipartnum="$(cat "$sys_efipart/partition")" \
			|| die "無法為 EFI 分區 $efipartdev 找到分區編號"
	else
		efipartnum="1" # Assume partition 1 if not found, common for RAID-based EFI
		einfo "將分區1假定為設備 $efipartdev 上基於 RAID 的 EFI"
	fi

	# Identify the parent block device and create EFI boot entry
	local gptdev
	if mdadm --detail --scan "$efipartdev" | grep -qE "^ARRAY $efipartdev " && [[ "$efipartdev" =~ ^/dev/md[0-9]+$ ]]; then
		# RAID 1 case: Create EFI boot entries for each RAID member
		local raid_members
		raid_members=($(mdadm --detail "$efipartdev" | sed -n 's|.*active sync[^/]*\(/dev/[^ ]*\).*|\1|p' | sort))

		if [[ ${#raid_members[@]} -eq 0 ]]; then
			die "檢測到 RAID 設定，但未為 $efipartdev 找到有效的成員磁碟"
		fi

		einfo "檢測到 RAID. RAID 成員: ${raid_members[*]}"

		for disk in "${raid_members[@]}"; do
			gptdev="$disk"
			einfo "為 RAID 成員添加 EFI 引導項: $gptdev"
			try efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "gentoo" --loader '\vmlinuz.efi' --unicode "initrd=\\initramfs.img $(get_cmdline)"
		done
	else
		# Non-RAID case: Create a single EFI boot entry
		gptdev="/dev/$(basename "$(readlink -f "$sys_efipart/..")")" \
			|| die "無法為 EFI 分區 $efipartdev 找到母設備"
		if [[ ! -e "$gptdev" ]] || [[ -z "$gptdev" ]]; then
			gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_EFI]}")" \
				|| die "無法以 id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_EFI]} 解析設備"
		fi
		try efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "gentoo" --loader '\vmlinuz.efi' --unicode 'initrd=\initramfs.img'" $(get_cmdline)"
	fi

	# Create script to repeat adding efibootmgr entry
	cat > "/boot/efi/efibootmgr_add_entry.sh" <<EOF
#!/bin/bash
# This is the command that was used to create the efibootmgr entry when the
# system was installed using gentoo-install.
efibootmgr --verbose --create --disk "$gptdev" --part "$efipartnum" --label "gentoo" --loader '\\vmlinuz.efi' --unicode 'initrd=\\initramfs.img'" $(get_cmdline)"
EOF
}

function generate_syslinux_cfg() {
	cat <<EOF
DEFAULT gentoo
PROMPT 0
TIMEOUT 0

LABEL gentoo
	LINUX ../vmlinuz-current
	APPEND initrd=../initramfs.img $(get_cmdline)
EOF
}

function install_kernel_bios() {
	try emerge --verbose sys-boot/syslinux

	# Link kernel to known name
	local kernel_file
	kernel_file="$(find "/boot" \( -name "vmlinuz-*" -or -name 'kernel-*' \) -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "無法列出最新的內核文件"

	try cp "/boot/$kernel_file" "/boot/bios/vmlinuz-current"

	# Generate initramfs
	generate_initramfs "/boot/bios/initramfs.img"

	# Install syslinux
	einfo "正在安裝 syslinux"
	local biosdev
	biosdev="$(resolve_device_by_id "$DISK_ID_BIOS")" \
		|| die "無法以 id=$DISK_ID_BIOS 解析設備"
	mkdir_or_die 0700 "/boot/bios/syslinux"
	try syslinux --directory syslinux --install "$biosdev"

	# Create syslinux.cfg
	generate_syslinux_cfg > /boot/bios/syslinux/syslinux.cfg \
		|| die "無法儲存生成的 syslinux.cfg"

	# Install syslinux MBR record
	einfo "正在複製 syslinux 主開機紀錄"
	local gptdev
	gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]}")" \
		|| die "無法以 id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]} 解析設備"
	try dd bs=440 conv=notrunc count=1 if=/usr/share/syslinux/gptmbr.bin of="$gptdev"
}

function install_kernel() {
	# Install vanilla kernel
	einfo "正在安裝原版內核及相關工具"

	if [[ $IS_EFI == "true" ]]; then
		install_kernel_efi
	else
		install_kernel_bios
	fi

	einfo "正在安裝 linux-firmware"
	echo "sys-kernel/linux-firmware linux-fw-redistributable no-source-code" >> /etc/portage/package.license \
		|| die "無法寫入 /etc/portage/package.license"
	try emerge --verbose linux-firmware
}

function add_fstab_entry() {
	printf '%-46s  %-24s  %-6s  %-96s %s\n' "$1" "$2" "$3" "$4" "$5" >> /etc/fstab \
		|| die "無法向 fstab 添加項"
}

function generate_fstab() {
	einfo "正在生成 fstab"
	install -m0644 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/fstab" /etc/fstab \
		|| die "無法覆寫 /etc/fstab"
	if [[ $USED_ZFS != "true" && -n $DISK_ID_ROOT_TYPE ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" "/" "$DISK_ID_ROOT_TYPE" "$DISK_ID_ROOT_MOUNT_OPTS" "0 1"
	fi
	if [[ $IS_EFI == "true" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_EFI")" "/boot/efi" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	else
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_BIOS")" "/boot/bios" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	fi
	if [[ -v "DISK_ID_SWAP" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_SWAP")" "none" "swap" "defaults,discard" "0 0"
	fi
}

function main_install_gentoo_in_chroot() {
	[[ $# == 0 ]] || die "參數過多"

	maybe_exec 'before_install'

	# Remove the root password, making the account accessible for automated
	# tasks during the period of installation.
	einfo "正在清除 root 密碼"
	passwd -d root \
		|| die "無法修改 root 密碼"

	# Sync portage
	einfo "正在同步 portage 樹"
	try emerge-webrsync

	# Install mdadm if we used RAID (needed for UUID resolving)
	if [[ $USED_RAID == "true" ]]; then
		einfo "正在安裝 mdadm"
		try emerge --verbose sys-fs/mdadm
	fi

	if [[ $IS_EFI == "true" ]]; then
		# Mount efi partition
		mount_efivars
		einfo "正在掛載 efi 分區"
		mount_by_id "$DISK_ID_EFI" "/boot/efi"
	else
		# Mount bios partition
		einfo "正在掛載 bios 分區"
		mount_by_id "$DISK_ID_BIOS" "/boot/bios"
	fi

	# Configure basic system things like timezone, locale, ...
	maybe_exec 'before_configure_base_system'
	configure_base_system
	maybe_exec 'after_configure_base_system'

	# Prepare portage environment
	maybe_exec 'before_configure_portage'
	configure_portage

	# Install git (for git portage overlays)
	einfo "正在安裝 git"
	try emerge --verbose dev-vcs/git

	if [[ "$PORTAGE_SYNC_TYPE" == "git" ]]; then
		mkdir_or_die 0755 "/etc/portage/repos.conf"
		cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = $PORTAGE_GIT_MIRROR
auto-sync = yes
sync-depth = $([[ $PORTAGE_GIT_FULL_HISTORY == true ]] && echo -n 0 || echo -n 1)
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
EOF
		chmod 644 /etc/portage/repos.conf/gentoo.conf \
			|| die "無法變更 '/etc/portage/repos.conf/gentoo.conf' 之權限"
		rm -rf /var/db/repos/gentoo \
			|| die "無法刪除過時的 rsync gentoo 倉庫"
		try emerge --sync
	fi
	maybe_exec 'after_configure_portage'

	einfo "正在生成 ssh 主機金鑰"
	try ssh-keygen -A

	# Install authorized_keys before dracut, which might need them for remote unlocking.
	install_authorized_keys

	einfo "正於 sys-kernel/installkernel 啟用 dracut USE 標記"
	echo "sys-kernel/installkernel dracut" > /etc/portage/package.use/installkernel \
		|| die "無法寫入 /etc/portage/package.use/installkernel"

	# Install required programs and kernel now, in order to
	# prevent emerging module before an imminent kernel upgrade
	if [[ "${KERNEL_TYPE:-bin}" == "source" ]]; then
		einfo "正在從原始碼 (sys-kernel/gentoo-kernel) 構建內核"
		try emerge --verbose sys-kernel/dracut sys-kernel/gentoo-kernel app-arch/zstd
	else
		einfo "正在安裝二進制內核 (sys-kernel/gentoo-kernel-bin)"
		try emerge --verbose sys-kernel/dracut sys-kernel/gentoo-kernel-bin app-arch/zstd
	fi

	# Install cryptsetup if we used LUKS
	if [[ $USED_LUKS == "true" ]]; then
		einfo "正在安裝 cryptsetup"
		try emerge --verbose sys-fs/cryptsetup
	fi

	if [[ $SYSTEMD == "true" && $USED_LUKS == "true" ]] ; then
		einfo "正於 sys-apps/systemd 啟用 cryptsetup USE 標記"
		echo "sys-apps/systemd cryptsetup" > /etc/portage/package.use/systemd \
			|| die "無法寫入 /etc/portage/package.use/systemd"
		einfo "正在以變更後的 USE 標記重新構建 systemd"
		try emerge --verbose --changed-use --oneshot sys-apps/systemd
	fi

	# Install btrfs-progs if we used Btrfs
	if [[ $USED_BTRFS == "true" ]]; then
		einfo "正在安裝 btrfs-progs"
		try emerge --verbose sys-fs/btrfs-progs
	fi

	try emerge --verbose dev-vcs/git

	# Install ZFS kernel module and tools if we used ZFS
	if [[ $USED_ZFS == "true" ]]; then
		einfo "正在安裝 zfs"
		try emerge --verbose sys-fs/zfs sys-fs/zfs-kmod

		einfo "正在啟用 zfs 服務"
		if [[ $SYSTEMD == "true" ]]; then
			try systemctl enable zfs.target
			try systemctl enable zfs-import-cache
			try systemctl enable zfs-mount
			try systemctl enable zfs-import.target
		else
			try rc-update add zfs-import boot
			try rc-update add zfs-mount boot
		fi
	fi

	# Install kernel and initramfs
	maybe_exec 'before_install_kernel'
	install_kernel
	maybe_exec 'after_install_kernel'

	# Generate a valid fstab file
	generate_fstab

	# Install gentoolkit
	einfo "Installing gentoolkit"
	try emerge --verbose app-portage/gentoolkit

	if [[ $SYSTEMD == "true" ]]; then
		if [[ $SYSTEMD_NETWORKD == "true" ]]; then
			# Enable systemd networking and dhcp
			enable_service systemd-networkd
			enable_service systemd-resolved
			if [[ $SYSTEMD_NETWORKD_DHCP == "true" ]]; then
				echo -en "[Match]\nName=${SYSTEMD_NETWORKD_INTERFACE_NAME}\n\n[Network]\nDHCP=yes" > /etc/systemd/network/20-wired.network \
					|| die "無法將 DHCP 網絡配置寫入 '/etc/systemd/network/20-wired.network'"
			else
				addresses=""
				for addr in "${SYSTEMD_NETWORKD_ADDRESSES[@]}"; do
					addresses="${addresses}Address=$addr\n"
				done
				echo -en "[Match]\nName=${SYSTEMD_NETWORKD_INTERFACE_NAME}\n\n[Network]\n${addresses}Gateway=$SYSTEMD_NETWORKD_GATEWAY" > /etc/systemd/network/20-wired.network \
					|| die "無法將 DHCP 網絡配置寫入 '/etc/systemd/network/20-wired.network'"
			fi
			chown root:systemd-network /etc/systemd/network/20-wired.network \
				|| die "無法變更 '/etc/systemd/network/20-wired.network' 之所有者"
			chmod 640 /etc/systemd/network/20-wired.network \
				|| die "無法變更 '/etc/systemd/network/20-wired.network' 之權限"
		fi
	else
		# Install and enable dhcpcd
		einfo "正在安裝 dhcpcd"
		try emerge --verbose net-misc/dhcpcd

		enable_service dhcpcd
	fi

	if [[ $ENABLE_SSHD == "true" ]]; then
		enable_sshd
	fi

	# Install additional packages, if any.
	if [[ ${#ADDITIONAL_PACKAGES[@]} -gt 0 ]]; then
		einfo "正在安裝額外包"
		# shellcheck disable=SC2086
		try emerge --verbose --autounmask-continue=y -- "${ADDITIONAL_PACKAGES[@]}"
	fi

	if ask "現在是否要設定 root 密碼？"; then
		try passwd root
		einfo "Root 密碼已設定"
	else
		try passwd -d root
		ewarn "Root 密碼已清除，請盡快設定一個新密碼！"
	fi

	# If configured, change to gentoo testing at the last moment.
	# This is to ensure a smooth installation process. You can deal
	# with the blockers after installation ;)
	if [[ $USE_PORTAGE_TESTING == "true" ]]; then
		einfo "正在將 ~$GENTOO_ARCH 添加至 ACCEPT_KEYWORDS"
		echo "ACCEPT_KEYWORDS=\"~$GENTOO_ARCH\"" >> /etc/portage/make.conf \
			|| die "無法修改 /etc/portage/make.conf"
	fi

	maybe_exec 'after_install'

	einfo "Gentoo 安裝完畢。"
	[[ $USED_LUKS == "true" ]] \
		&& einfo "閣下可於 '$LUKS_HEADER_BACKUP_DIR' 找到 LUKS 頭之備份"
	einfo "現在可以重啟系統或執行 ./install --chroot $ROOT_MOUNTPOINT 以 chroot 形式進入新系統"
	einfo "此方式 (chroot) 總是可用的，以便重啟後修復一些錯誤。"
}

function main_install() {
	[[ $# == 0 ]] || die "參數過多"

	gentoo_umount
	install_stage3

	[[ $IS_EFI == "true" ]] \
		&& mount_efivars
	gentoo_chroot "$ROOT_MOUNTPOINT" "$GENTOO_INSTALL_REPO_BIND/install" __install_gentoo_in_chroot
}

function main_chroot() {
	# Skip if already mounted
	mountpoint -q -- "$1" \
		|| die "'$1' 並非掛載點"

	gentoo_chroot "$@"
}
