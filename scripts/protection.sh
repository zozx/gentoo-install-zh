if [[ "$GENTOO_INSTALL_REPO_SCRIPT_ACTIVE" != "true" ]]; then
	echo "[1;31m * ERROR:[m 此腳本不應被直接執行！" >&2
	exit 1
fi
