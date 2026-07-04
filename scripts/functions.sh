# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

function sync_time() {
	einfo "時間同步中"
	if command -v ntpd &> /dev/null; then
		try ntpd -g -q
	elif command -v chrony &> /dev/null; then
		# See https://github.com/oddlama/gentoo-install/pull/122
		try chronyd -q
	else
		# why am I doing this?
		try date -s "$(curl -sI http://example.com | grep -i ^date: | cut -d' ' -f3-)"
	fi

	einfo "現在日期: $(LANG=C date)"
	einfo "正將時間寫至硬件時鐘"
	hwclock --systohc --utc \
		|| die "無法將時間存至硬件時鐘"
}

function check_config() {
	[[ $KEYMAP =~ ^[0-9A-Za-z-]*$ ]] \
		|| die "KEYMAP 包含無效字符"

	if [[ "$SYSTEMD" == "true" ]]; then
		[[ "$STAGE3_BASENAME" == *systemd* ]] \
			|| die "使用 systemd 需要 systemd stage3 檔！"
	else
		[[ "$STAGE3_BASENAME" != *systemd* ]] \
			|| die "使用 OpenRC 需要 non-systemd stage3 檔!"
	fi

	# Check hostname per RFC1123
	local hostname_regex='^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$'
	[[ $HOSTNAME =~ $hostname_regex ]] \
		|| die "'$HOSTNAME' 不是有效主機名"

	[[ -v "DISK_ID_ROOT" && -n $DISK_ID_ROOT ]] \
		|| die "必須分配 DISK_ID_ROOT"
	[[ -v "DISK_ID_EFI" && -n $DISK_ID_EFI ]] || [[ -v "DISK_ID_BIOS" && -n $DISK_ID_BIOS ]] \
		|| die "必須分配 DISK_ID_EFI 或 DISK_ID_BIOS"

	[[ -v "DISK_ID_BIOS" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_BIOS]" ]] \
		&& die "缺少 DISK_ID_BIOS 的 uuid ，是否確認有使用？"
	[[ -v "DISK_ID_EFI" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_EFI]" ]] \
		&& die "缺少 DISK_ID_EFI 的 uuid，是否確定有使用？"
	[[ -v "DISK_ID_SWAP" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_SWAP]" ]] \
		&& die "缺少 DISK_ID_SWAP 的 uuid, 是否確定有使用？"
	[[ -v "DISK_ID_ROOT" ]] && [[ ! -v "DISK_ID_TO_UUID[$DISK_ID_ROOT]" ]] \
		&& die "缺少 DISK_ID_ROOT 的 uuid，是否確定有使用？"

	if [[ -v "DISK_ID_EFI" ]]; then
		IS_EFI=true
	else
		IS_EFI=false
	fi
}

function preprocess_config() {
	disk_configuration

	# Check encryption key if used
	[[ $USED_ENCRYPTION == "true" ]] \
		&& check_encryption_key

	check_config
}

function prepare_installation_environment() {
	maybe_exec 'before_prepare_environment'

	einfo "安裝環境準備中"

	local wanted_programs=(
		gpg
		hwclock
		lsblk
		ntpd
		partprobe
		python3
		"?rhash"
		sha512sum
		sgdisk
		uuidgen
		wget
	)

	[[ $USED_BTRFS == "true" ]] \
		&& wanted_programs+=(btrfs)
	[[ $USED_ZFS == "true" ]] \
		&& wanted_programs+=(zfs)
	[[ $USED_RAID == "true" ]] \
		&& wanted_programs+=(mdadm)
	[[ $USED_LUKS == "true" ]] \
		&& wanted_programs+=(cryptsetup)

	# Check for existence of required programs
	check_wanted_programs "${wanted_programs[@]}"

	# Sync time now to prevent issues later
	sync_time

	maybe_exec 'after_prepare_environment'
}

function check_encryption_key() {
	if [[ -z "${GENTOO_INSTALL_ENCRYPTION_KEY+set}" ]]; then
		elog "加密已啟用，而環境變量 GENTOO_INSTALL_ENCRYPTION_KEY 中未有特定金鑰。"
		if ask "是否現在輸入加密金鑰？"; then
			local encryption_key_1
			local encryption_key_2

			while true; do
				flush_stdin
				IFS="" read -s -r -p "輸入加密金鑰 : " encryption_key_1 \
					|| die "讀取過程中出現錯誤。"
				echo

				[[ ${#encryption_key_1} -ge 8 ]] \
					|| { ewarn "加密金鑰長度須不少於8個字符。"; continue; }

				flush_stdin
				IFS="" read -s -r -p "重複加密金鑰: " encryption_key_2 \
					|| die "讀取過程中出現錯誤。"
				echo

				[[ "$encryption_key_1" == "$encryption_key_2" ]] \
					|| { ewarn "兩次輸入不吻合。"; continue; }
				break
			done

			export GENTOO_INSTALL_ENCRYPTION_KEY="$encryption_key_1"
		else
			die "請以所欲使用之金鑰導出 GENTOO_INSTALL_ENCRYPTION_KEY"
		fi
	fi

	[[ ${#GENTOO_INSTALL_ENCRYPTION_KEY} -ge 8 ]] \
		|| die "加密金鑰長度須不少於8個字符。"
}

function add_summary_entry() {
	local parent="$1"
	local id="$2"
	local name="$3"
	local hint="$4"
	local desc="$5"

	local ptr
	case "$id" in
		"${DISK_ID_BIOS-__unused__}")  ptr="[1;32m← bios[m" ;;
		"${DISK_ID_EFI-__unused__}")   ptr="[1;32m← efi[m"  ;;
		"${DISK_ID_SWAP-__unused__}")  ptr="[1;34m← swap[m" ;;
		"${DISK_ID_ROOT-__unused__}")  ptr="[1;33m← root[m" ;;
		# \x1f characters compensate for printf byte count and unicode character count mismatch due to '←'
		*)                             ptr="[1;32m[m$(echo -e "\x1f\x1f")" ;;
	esac

	summary_tree[$parent]+=";$id"
	summary_name[$id]="$name"
	summary_hint[$id]="$hint"
	summary_ptr[$id]="$ptr"
	summary_desc[$id]="$desc"
}

function summary_color_args() {
	for arg in "$@"; do
		if [[ -v "arguments[$arg]" ]]; then
			printf '%-28s ' "[1;34m$arg[2m=[m${arguments[$arg]}"
		fi
	done
}

function disk_existing() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry __root__ "$new_id" "${arguments[device]}" "(no-format, existing)" ""
	fi
	# no-op;
}

function disk_create_gpt() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -v arguments[id] ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "gpt" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(gpt)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -v arguments[id] ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")"
		device_desc="$device ($id)"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local ptuuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "於 $device_desc 創建新 gpt 分區表 ($new_id)"
	wipefs --quiet --all --force "$device" \
		|| die "無法從 '$device' 抹除原文件系統之特徵碼"
	sgdisk -Z -U "$ptuuid" "$device" >/dev/null \
		|| die "無法於 '$device' 創建新 gpt 分區表 ($new_id)"
	partprobe "$device"
}

function disk_create_partition() {
	local new_id="${arguments[new_id]}"
	local id="${arguments[id]}"
	local size="${arguments[size]}"
	local type="${arguments[type]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "$id" "$new_id" "part" "($type)" "$(summary_color_args size)"
		return 0
	fi

	if [[ $size == "remaining" ]]; then
		arg_size=0
	else
		arg_size="+$size"
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "無法以 id=$id 解析設備"
	local partuuid="${DISK_ID_TO_UUID[$new_id]}"
	local extra_args=""
	case "$type" in
		'bios')  type='ef02' extra_args='--attributes=0:set:2';;
		'efi')   type='ef00' ;;
		'swap')  type='8200' ;;
		'raid')  type='fd00' ;;
		'luks')  type='8309' ;;
		'linux') type='8300' ;;
		*) ;;
	esac

	einfo "在 $device 上創建 type=$type, size=$size 的分區"
	# shellcheck disable=SC2086
	sgdisk -n "0:0:$arg_size" -t "0:$type" -u "0:$partuuid" $extra_args "$device" >/dev/null \
		|| die "無法在 '$device' ($id) 上創建新 gpt 分區表 ($new_id)"
	partprobe "$device"

	# On some system, we need to wait a bit for the partition to show up.
	local new_device
	new_device="$(resolve_device_by_id "$new_id")" \
		|| die "無法以 id=$new_id 解析新設備"
	for i in {1..10}; do
		[[ -e "$new_device" ]] && break
		[[ "$i" -eq 1 ]] && printf "等待分區 (%s) 出現..." "$new_device"
		printf " %s" "$((10 - i + 1))"
		sleep 1
		[[ "$i" -eq 10 ]] && echo
	done
}

function disk_create_raid() {
	local new_id="${arguments[new_id]}"
	local level="${arguments[level]}"
	local name="${arguments[name]}"
	local ids="${arguments[ids]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "_$new_id" "raid$level" "" "$(summary_color_args name)"
		done

		add_summary_entry __root__ "$new_id" "raid$level" "" "$(summary_color_args name)"
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "無法以 id=$id 解析設備"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	local mddevice="/dev/md/$name"
	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	extra_args=()
	if [[ "$level" == 1 && "$name" == "efi" ]]; then
		extra_args+=("--metadata=1.0")
	else
		extra_args+=("--metadata=1.2")
	fi

# See https://serverfault.com/questions/1163715/mdadm-value-arch12021-cannot-be-set-as-devname-reason-not-posix-compatible
	einfo "在 $devices_desc 上創建 raid$level ($new_id)"
	mdadm \
			--create "$mddevice" \
			--verbose \
			--level="$level" \
			--raid-devices="${#devices[@]}" \
			--uuid="$uuid" \
			--homehost="$HOSTNAME" \
			"${extra_args[@]}" \
			"${devices[@]}" \
		|| die "無法在 $device_desc 上創建 raid$level 陣列 '$mddevice' ($new_id)"
}

function disk_create_luks() {
	local new_id="${arguments[new_id]}"
	local name="${arguments[name]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -v arguments[id] ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "luks" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(luks)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -v arguments[id] ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")"
		device_desc="$device ($id)"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "在 $device_desc 上創建 luks ($new_id)"
	cryptsetup luksFormat \
			--type luks2 \
			--uuid "$uuid" \
			--key-file <(echo -n "$GENTOO_INSTALL_ENCRYPTION_KEY") \
			--cipher aes-xts-plain64 \
			--hash sha512 \
			--pbkdf argon2id \
			--iter-time 4000 \
			--key-size 512 \
			--batch-mode \
			"$device" \
		|| die "無法在 $device_desc 創建 luks"
	mkdir -p "$LUKS_HEADER_BACKUP_DIR" \
		|| die "無法創建 luks 頭備份目錄 '$LUKS_HEADER_BACKUP_DIR'"
	local header_file="$LUKS_HEADER_BACKUP_DIR/luks-header-$id-${uuid,,}.img"
	[[ ! -e $header_file ]] \
		|| rm "$header_file" \
		|| die "無法移除舊 luks 頭備份文件 '$header_file'"
	cryptsetup luksHeaderBackup "$device" \
			--header-backup-file "$header_file" \
		|| die "無法在 $device_desc 備份 luks 頭"
	cryptsetup open --type luks2 \
			--key-file <(echo -n "$GENTOO_INSTALL_ENCRYPTION_KEY") \
			"$device" "$name" \
		|| die "無法打開 luks 加密設備 $device_desc"
}

function disk_create_dummy() {
	local new_id="${arguments[new_id]}"
	local device="${arguments[device]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry __root__ "$new_id" "$device" "" ""
		return 0
	fi
}

function init_btrfs() {
	local device="$1"
	local desc="$2"
	mkdir -p /btrfs \
		|| die "無法創建 /btrfs 目錄"
	mount "$device" /btrfs \
		|| die "無法將 $desc 掛載至 /btrfs"
	btrfs subvolume create /btrfs/root \
		|| die "無法在 $desc 創建 btrfs 子卷 /root"
	btrfs subvolume set-default /btrfs/root \
		|| die "無法在 $desc 將預設子卷設定為 /root"
	umount /btrfs \
		|| die "無法在 $desc 解除掛載 btrfs"
}

function disk_format() {
	local id="${arguments[id]}"
	local type="${arguments[type]}"
	local label="${arguments[label]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "${arguments[id]}" "__fs__${arguments[id]}" "${arguments[type]}" "(fs)" "$(summary_color_args label)"
		return 0
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "無法以 id=$id 解析設備"

	einfo "Formatting $device ($id) with $type"
	wipefs --quiet --all --force "$device" \
		|| die "無法從 '$device' ($id) 抹除原文件系統之特徵碼"

	case "$type" in
		'bios'|'efi')
			if [[ -v "arguments[label]" ]]; then
				mkfs.fat -F 32 -n "$label" "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			else
				mkfs.fat -F 32 "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			fi
			;;
		'swap')
			if [[ -v "arguments[label]" ]]; then
				mkswap -L "$label" "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			else
				mkswap "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			fi

			# Try to swapoff in case the system enabled swap automatically
			swapoff "$device" &>/dev/null
			;;
		'ext4')
			if [[ -v "arguments[label]" ]]; then
				mkfs.ext4 -q -L "$label" "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			else
				mkfs.ext4 -q "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			fi
			;;
		'btrfs')
			if [[ -v "arguments[label]" ]]; then
				mkfs.btrfs -q -L "$label" "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			else
				mkfs.btrfs -q "$device" \
					|| die "無法格式化設備 '$device' ($id)"
			fi

			init_btrfs "$device" "'$device' ($id)"
			;;
		*) die "未知的文件系統類型" ;;
	esac
}

# This function will be called when a custom zfs pool type has been chosen.
# $1: either 'true' or 'false' determining if the datasets should be encrypted
# $2: either 'false' or a value determining the dataset compression algorithm
# $3: a string describing all device paths (for error messages)
# $@: device paths
function format_zfs_standard() {
	local encrypt="$1"
	local compress="$2"
	local device_desc="$3"
	shift 3
	local devices=("$@")
	local extra_args=()

	einfo "正在 $devices_desc 上創建 zfs 池"

	local zfs_stdin=""
	if [[ "$encrypt" == true ]]; then
		extra_args+=(
			"-O" "encryption=aes-256-gcm"
			"-O" "keyformat=passphrase"
			"-O" "keylocation=prompt"
			)

		zfs_stdin="$GENTOO_INSTALL_ENCRYPTION_KEY"
	fi

	# dnodesize=legacy might be needed for GRUB2, but auto is preferred for xattr=sa.
	zpool create \
		-R "$ROOT_MOUNTPOINT" \
		-o ashift=12          \
		-O acltype=posix      \
		-O atime=off          \
		-O xattr=sa           \
		-O dnodesize=auto     \
		-O mountpoint=none    \
		-O canmount=noauto    \
		-O devices=off        \
		"${extra_args[@]}"    \
		rpool                 \
		"${devices[@]}"       \
			<<< "$zfs_stdin"  \
		|| die "無法在 $devices_desc 上創建 zfs 池"

	if [[ "$compress" != false ]]; then
		zfs set "compression=$compress" rpool \
			|| die "無法在數據集 'rpool' 上啟用壓縮"
	fi
	zfs create rpool/ROOT \
		|| die "無法創建 zfs 數據集 'rpool/ROOT'"
	zfs create -o mountpoint=/ rpool/ROOT/default \
		|| die "無法創建 zfs 數據集 'rpool/ROOT/default'"
	zpool set bootfs=rpool/ROOT/default rpool \
		|| die "無法在 rpool 上設定 zfs 屬性 bootfs"
}

function disk_format_zfs() {
	local ids="${arguments[ids]}"
	local pool_type="${arguments[pool_type]}"
	local encrypt="${arguments[encrypt]-false}"
	local compress="${arguments[compress]-false}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "zfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "無法以 id=$id 解析設備"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	wipefs --quiet --all --force "${devices[@]}" \
		|| die "無法從 $devices_desc 抹除原文件系統之特徵碼"

	if [[ "$pool_type" == "custom" ]]; then
		format_zfs_custom "$devices_desc" "${devices[@]}"
	else
		format_zfs_standard "$encrypt" "$compress" "$devices_desc" "${devices[@]}"
	fi
}

function disk_format_btrfs() {
	local ids="${arguments[ids]}"
	local label="${arguments[label]}"
	local raid_type="${arguments[raid_type]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "btrfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "無法以 id=$id 解析設備"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	wipefs --quiet --all --force "${devices[@]}" \
		|| die "無法從 $devices_desc 抹除原文件系統之特徵碼"

	# Collect extra arguments
	extra_args=()
	if [[ "${#devices}" -gt 1 ]] && [[ -v "arguments[raid_type]" ]]; then
		extra_args+=("-d" "$raid_type")
	fi

	if [[ -v "arguments[label]" ]]; then
		extra_args+=("-L" "$label")
	fi

	einfo "在 $devices_desc 上創建 btrfs"
	mkfs.btrfs -q "${extra_args[@]}" "${devices[@]}" \
		|| die "無法在 $devices_desc 上創建 btrfs"

	init_btrfs "${devices[0]}" "btrfs array ($devices_desc)"
}

function apply_disk_action() {
	unset known_arguments
	unset arguments; declare -A arguments; parse_arguments "$@"
	case "${arguments[action]}" in
		'existing')          disk_existing         ;;
		'create_gpt')        disk_create_gpt       ;;
		'create_partition')  disk_create_partition ;;
		'create_raid')       disk_create_raid      ;;
		'create_luks')       disk_create_luks      ;;
		'create_dummy')      disk_create_dummy     ;;
		'format')            disk_format           ;;
		'format_zfs')        disk_format_zfs       ;;
		'format_btrfs')      disk_format_btrfs     ;;
		*) echo "忽略無效操作: ${arguments[action]}" ;;
	esac
}

function print_summary_tree_entry() {
	local indent_chars=""
	local indent="0"
	local d="1"
	local maxd="$((depth - 1))"
	while [[ $d -lt $maxd ]]; do
		if [[ ${summary_depth_continues[$d]} == "true" ]]; then
			indent_chars+='│ '
		else
			indent_chars+='  '
		fi
		indent=$((indent + 2))
		d="$((d + 1))"
	done
	if [[ $maxd -gt 0 ]]; then
		if [[ ${summary_depth_continues[$maxd]} == "true" ]]; then
			indent_chars+='├─'
		else
			indent_chars+='└─'
		fi
		indent=$((indent + 2))
	fi

	local name="${summary_name[$root]}"
	local hint="${summary_hint[$root]}"
	local desc="${summary_desc[$root]}"
	local ptr="${summary_ptr[$root]}"
	local id_name="[2m[m"
	if [[ $root != __* ]]; then
		if [[ $root == _* ]]; then
			id_name="[2m${root:1}[m"
		else
			id_name="[2m${root}[m"
		fi
	fi

	local align=0
	if [[ $indent -lt 33 ]]; then
		align="$((33 - indent))"
	fi

	elog "$indent_chars$(printf "%-${align}s %-47s %s" \
		"$name [2m$hint[m" \
		"$id_name $ptr" \
		"$desc")"
}

function print_summary_tree() {
	local root="$1"
	local depth="$((depth + 1))"
	local has_children=false

	if [[ -v "summary_tree[$root]" ]]; then
		local children="${summary_tree[$root]}"
		has_children=true
		summary_depth_continues[$depth]=true
	else
		summary_depth_continues[$depth]=false
	fi

	if [[ $root != __root__ ]]; then
		print_summary_tree_entry "$root"
	fi

	if [[ $has_children == "true" ]]; then
		local count
		count="$(tr ';' '\n' <<< "$children" | grep -c '\S')" \
			|| count=0
		local idx=0
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${children//';'/ }; do
			idx="$((idx + 1))"
			[[ $idx == "$count" ]] \
				&& summary_depth_continues[$depth]=false
			print_summary_tree "$id"
			# separate blocks by newline
			[[ ${summary_depth_continues[0]} == "true" ]] && [[ $depth == 1 ]] && [[ $idx == "$count" ]] \
				&& elog
		done
	fi
}

function apply_disk_actions() {
	local param
	local current_params=()
	for param in "${DISK_ACTIONS[@]}"; do
		if [[ $param == ';' ]]; then
			apply_disk_action "${current_params[@]}"
			current_params=()
		else
			current_params+=("$param")
		fi
	done
}

function summarize_disk_actions() {
	elog "[1m現時 lsblk 之輸出:[m"
	for_line_in <(lsblk \
		|| die "於 lsblk 發生錯誤") elog

	local disk_action_summarize_only=true
	declare -A summary_tree
	declare -A summary_name
	declare -A summary_hint
	declare -A summary_ptr
	declare -A summary_desc
	declare -A summary_depth_continues
	apply_disk_actions

	local depth=-1
	elog
	elog "[1m已配置之磁碟佈局:[m"
	elog ────────────────────────────────────────────────────────────────────────────────
	elog "$(printf '%-26s %-28s %s' NODE ID OPTIONS)"
	elog ────────────────────────────────────────────────────────────────────────────────
	print_summary_tree __root__
	elog ────────────────────────────────────────────────────────────────────────────────
}

function apply_disk_configuration() {
	summarize_disk_actions

	if [[ $NO_PARTITIONING_OR_FORMATTING == true ]]; then
		elog "閣下已選擇一現存磁碟配置。設備不會真正被重新分區或格式化"
		elog "請確保全部設備均已被格式化"
	else
		ewarn "請確保所有被選中之設備均已解除掛載"
		ewarn "且未以其他形式被系統佔用。"
		ewarn "mdadm陣列應被停下，而已打開的 luks 卷應應被關閉。"
		ewarn "否則，自動分區或會失敗。"
	fi
	ask "是否確定要應用此磁碟配置？" \
		|| die "中止"
	countdown "即將應用 " 5

	maybe_exec 'before_disk_configuration'

	einfo "應用磁碟配置"
	apply_disk_actions

	einfo "磁碟配置已成功應用"
	elog "[1m新的 lsblk 輸出:[m"
	for_line_in <(lsblk \
		|| die "在 lsblk 發生錯誤") elog

	maybe_exec 'after_disk_configuration'
}

function mount_efivars() {
	# Skip if already mounted
	mountpoint -q -- "/sys/firmware/efi/efivars" \
		&& return

	# Mount efivars
	einfo "正在掛載 efivars"
	mount -t efivarfs efivarfs "/sys/firmware/efi/efivars" \
		|| die "無法掛載 efivarfs"
}

function mount_by_id() {
	local dev
	local id="$1"
	local mountpoint="$2"

	# Skip if already mounted
	mountpoint -q -- "$mountpoint" \
		&& return

	# Mount device
	einfo "正將 id=$id 之設備掛載至 '$mountpoint'"
	mkdir -p "$mountpoint" \
		|| die "無法創建掛載點目錄 '$mountpoint'"
	dev="$(resolve_device_by_id "$id")" \
		|| die "無法以 id=$id 解析設備"
	mount "$dev" "$mountpoint" \
		|| die "無法掛載設備 '$dev'"
}

function mount_root() {
	if [[ $USED_ZFS == "true" ]] && ! mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		die "錯誤: zfs 應被掛載於 '$ROOT_MOUNTPOINT', 而事實並非如此。"
	else
		mount_by_id "$DISK_ID_ROOT" "$ROOT_MOUNTPOINT"
	fi
}

function bind_repo_dir() {
	# Use new location by default
	export GENTOO_INSTALL_REPO_DIR="$GENTOO_INSTALL_REPO_BIND"

	# Bind the repo dir to a location in /tmp,
	# so it can be accessed from within the chroot
	mountpoint -q -- "$GENTOO_INSTALL_REPO_BIND" \
		&& return

	# Mount root device
	einfo "綁定掛載倉庫目錄"
	mkdir -p "$GENTOO_INSTALL_REPO_BIND" \
		|| die "無法創建掛載點目錄 '$GENTOO_INSTALL_REPO_BIND'"
	mount --bind "$GENTOO_INSTALL_REPO_DIR_ORIGINAL" "$GENTOO_INSTALL_REPO_BIND" \
		|| die "無法將 '$GENTOO_INSTALL_REPO_DIR_ORIGINAL' 綁定掛載至 '$GENTOO_INSTALL_REPO_BIND'"
}

function download_stage3() {
	cd "$TMP_DIR" \
		|| die "無法進入目錄 '$TMP_DIR'"

	local STAGE3_BASENAME_FINAL
	if [[ ("$GENTOO_ARCH" == "amd64" && "$STAGE3_VARIANT" == *x32*) || ("$GENTOO_ARCH" == "x86" && -n "$GENTOO_SUBARCH") ]]; then
		STAGE3_BASENAME_FINAL="$STAGE3_BASENAME_CUSTOM"
	else
		STAGE3_BASENAME_FINAL="$STAGE3_BASENAME"
	fi

	local STAGE3_RELEASES="$GENTOO_MIRROR/releases/$GENTOO_ARCH/autobuilds/current-$STAGE3_BASENAME_FINAL/"

	# Download upstream list of files
	CURRENT_STAGE3="$(download_stdout "$STAGE3_RELEASES")" \
		|| die "Could not retrieve list of tarballs"
	# Decode urlencoded strings
	CURRENT_STAGE3=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))' <<< "$CURRENT_STAGE3")
	# Parse output for correct filename
	CURRENT_STAGE3="$(grep -o "\"${STAGE3_BASENAME_FINAL}-[0-9A-Z]*.tar.xz\"" <<< "$CURRENT_STAGE3" \
		| sort -u | head -1)" \
		|| die "無法解析 tar 包列表"
	# Strip quotes
	CURRENT_STAGE3="${CURRENT_STAGE3:1:-1}"
	# File to indiciate successful verification
	CURRENT_STAGE3_VERIFIED="${CURRENT_STAGE3}.verified"

	maybe_exec 'before_download_stage3' "$STAGE3_BASENAME_FINAL"

	# Download file if not already downloaded
	if [[ -e $CURRENT_STAGE3_VERIFIED ]]; then
		einfo "$STAGE3_BASENAME_FINAL tar 包已下載並通過驗證"
	else
		einfo "正在下載 $STAGE3_BASENAME_FINAL tar 包"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}" "${CURRENT_STAGE3}"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}.DIGESTS" "${CURRENT_STAGE3}.DIGESTS"

		# Import gentoo keys
		einfo "正在導入 gentoo gpg 金鑰"
		local GENTOO_GPG_KEY="$TMP_DIR/gentoo-keys.gpg"
		download "https://gentoo.org/.well-known/openpgpkey/hu/wtktzo4gyuhzu8a4z5fdj3fgmr1u6tob?l=releng" "$GENTOO_GPG_KEY" \
			|| die "無法取得 gentoo gpg 金鑰"
		gpg --quiet --import < "$GENTOO_GPG_KEY" \
			|| die "無法導入 gentoo gpg 金鑰"

		# Verify DIGESTS signature
		einfo "正在驗證 tar 包簽名"
		gpg --quiet --verify "${CURRENT_STAGE3}.DIGESTS" \
			|| die "'${CURRENT_STAGE3}.DIGESTS' 簽名無效！"

		# Check hashes
		einfo "正在驗證 tar 包完整性"
		# Replace any absolute paths in the digest file with just the stage3 basename, so it will be found by rhash
		digest_line=$(grep 'tar.xz$' "${CURRENT_STAGE3}.DIGESTS" | sed -e 's/  .*stage3-/  stage3-/')
		if type rhash &>/dev/null; then
			rhash -P --check <(echo "# SHA512"; echo "$digest_line") \
				|| die "Checksum 不吻合！"
		else
			sha512sum --check <<< "$digest_line" \
				|| die "Checksum 不吻合！"
		fi

		# Create verification file in case the script is restarted
		touch_or_die 0644 "$CURRENT_STAGE3_VERIFIED"
	fi

	maybe_exec 'after_download_stage3' "${CURRENT_STAGE3}"
}

function extract_stage3() {
	mount_root

	[[ -n $CURRENT_STAGE3 ]] \
		|| die "CURRENT_STAGE3 未設定"
	[[ -e "$TMP_DIR/$CURRENT_STAGE3" ]] \
		|| die "stage3 文件不存在"

	maybe_exec 'before_extract_stage3' "$TMP_DIR/$CURRENT_STAGE3" "$ROOT_MOUNTPOINT"

	# Go to root directory
	cd "$ROOT_MOUNTPOINT" \
		|| die "無法移動至 '$ROOT_MOUNTPOINT'"
	# Ensure the directory is empty
	find . -mindepth 1 -maxdepth 1 -not -name 'lost+found' \
		| grep -q . \
		&& die "根目錄 '$ROOT_MOUNTPOINT' 非空"

	# Extract tarball
	einfo "stage3 tar 包解壓中"
	tar xpf "$TMP_DIR/$CURRENT_STAGE3" --xattrs --numeric-owner \
		|| die "解壓 tar 包過程中出錯"
	cd "$TMP_DIR" \
		|| die "無法進入 '$TMP_DIR'"

	maybe_exec 'after_extract_stage3' "$TMP_DIR/$CURRENT_STAGE3" "$ROOT_MOUNTPOINT"
}

function gentoo_umount() {
	if mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		einfo "正在解除掛載根文件系統"
		umount -R -l "$ROOT_MOUNTPOINT" \
			|| die "無法解除掛載文件系統"
	fi
}

function init_bash() {
	source /etc/profile
	umask 0077
	export PS1='(chroot) \[[0;31m\]\u\[[1;31m\]@\h \[[1;34m\]\w \[[m\]\$ \[[m\]'
}; export -f init_bash

function env_update() {
	env-update \
		|| die "env-update 中發生錯誤"
	source /etc/profile \
		|| die "無法 source /etc/profile"
	umask 0077
}

function mkdir_or_die() {
	# shellcheck disable=SC2174
	mkdir -m "$1" -p "$2" \
		|| die "無法創建目錄 '$2'"
}

function touch_or_die() {
	touch "$2" \
		|| die "無法創建 '$2'"
	chmod "$1" "$2"
}

# $1: root directory
# $@: command...
function gentoo_chroot() {
	if [[ $# -eq 1 ]]; then
		einfo "欲在之後解除掛載所有虛擬文件系統，請使用 umount -l ${1@Q}"
		gentoo_chroot "$1" /bin/bash --init-file <(echo 'init_bash')
	fi

	[[ ${EXECUTED_IN_CHROOT-false} == "false" ]] \
		|| die "已處於 chroot 狀態"

	local chroot_dir="$1"
	shift

	# Bind repo directory to tmp
	bind_repo_dir

	# Copy resolv.conf
	einfo "正在準備 chroot 環境"
	install --mode=0644 /etc/resolv.conf "$chroot_dir/etc/resolv.conf" \
		|| die "無法複製 resolv.conf"

	# Mount virtual filesystems
	einfo "正在掛載虛擬文件系統"
	(
		mountpoint -q -- "$chroot_dir/proc" || mount -t proc /proc "$chroot_dir/proc" || exit 1
		mountpoint -q -- "$chroot_dir/run"  || {
			mount --rbind /run  "$chroot_dir/run" &&
			mount --make-rslave "$chroot_dir/run"; } || exit 1
		mountpoint -q -- "$chroot_dir/tmp"  || {
			mount --rbind /tmp  "$chroot_dir/tmp" &&
			mount --make-rslave "$chroot_dir/tmp"; } || exit 1
		mountpoint -q -- "$chroot_dir/sys"  || {
			mount --rbind /sys  "$chroot_dir/sys" &&
			mount --make-rslave "$chroot_dir/sys"; } || exit 1
		mountpoint -q -- "$chroot_dir/dev"  || {
			mount --rbind /dev  "$chroot_dir/dev" &&
			mount --make-rslave "$chroot_dir/dev"; } || exit 1
	) || die "無法掛載虛擬文件系統"

	# Cache lsblk output, because it doesn't work correctly in chroot (returns almost no info for devices, e.g. empty uuids)
	cache_lsblk_output

	# Execute command
	einfo "正在 chroot..."
	EXECUTED_IN_CHROOT=true \
		TMP_DIR="$TMP_DIR" \
		CACHED_LSBLK_OUTPUT="$CACHED_LSBLK_OUTPUT" \
		exec chroot -- "$chroot_dir" "$GENTOO_INSTALL_REPO_DIR/scripts/dispatch_chroot.sh" "$@" \
			|| die "無法 chroot 至 '$chroot_dir'."
}

function enable_service() {
	if [[ $SYSTEMD == "true" ]]; then
		try systemctl enable "$1"
	else
		try rc-update add "$1" default
	fi
}
