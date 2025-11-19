#!/bin/bash
# 1-proot.sh
# Konversi dari 1-chroot.sh -> versi PRoot
# REQUIRE: proot binary tersedia (./proot atau di PATH)
# Place this alongside your other sfbootstrap scripts.

module_name=proot

SFB_ARC="$SFB_ROOT/archives"
SFB_SDK_URL="${SFB_SDK_URL:-http://releases.sailfishos.org/sdk}"
PROOT_BIN="${PROOT_BIN:-$PWD/proot}"
SUDO="${SUDO:-sudo}"

# ---------------------------
# helper: logging / die
# ---------------------------
sfb_error(){ printf "ERROR: %s\n" "$*" >&2; exit 1; }
sfb_warn(){ printf "WARN: %s\n" "$*" >&2; }
sfb_log(){ printf "LOG: %s\n" "$*"; }
sfb_dbg(){ if [ "${SFB_DEBUG:-0}" -ne 0 ]; then printf "DBG: %s\n" "$*"; fi; }

# ---------------------------
# copy of your sfb_fetch (unchanged)
# ---------------------------
sfb_fetch() {
	local arg url file hashtype error=false fail_on_error=true dir filename \
	      hashcmd checksum_remote checksum_local fetch=1
	for arg in "$@"; do
		case "$1" in
			-u) url="$2"; shift ;;
			-o) file="$2"; shift ;;
			-c) hashtype="$2"; shift ;;
			-F) fail_on_error=false ;;
		esac
		shift
	done
	if [[ -z "$url" || -z "$file" ]]; then
		sfb_error "A specified URL and output file are required to fetch web content!"
	fi
	dir="$(readlink -f "$(dirname "$file")")"
	[ -d "$dir" ] || mkdir -p "$dir"
	filename="$(basename "$file")"
	if [[ -f "$file" && "$hashtype" ]]; then
		checksum_remote="$(wget "$url.$hashtype" -t 3 -qO - | awk '{print $1}')"
		if [ -z "$checksum_remote" ]; then
			sfb_dbg "missing remote checksum for $filename, skipping redownload"
			return
		fi
		hashcmd=${hashtype%sum}sum
		checksum_local="$($hashcmd "$file" | awk '{print $1}')"
		if [ "$checksum_local" = "$checksum_remote" ]; then
			sfb_dbg "$hashcmd ok for $filename, skipping redownload"
			return
		fi
		sfb_warn "Local $hashcmd for $filename didn't match remote, redownloading..."
		rm "$file"
	elif [ -f "$file" ]; then
		fetch=0 # no need if already exists with no checksum to compare
	fi
	if [ $fetch -eq 1 ]; then
		sfb_dbg "downloading $url..."
		wget "$url" -t 3 --show-progress -qO "$file" || error=true
		if $error; then
			rm "$file" # remove residue 0 byte output file on dl errors
			$fail_on_error && sfb_error "Failed to download $url!"
		fi
	fi
}

sfb_ver() { echo "$*" | awk -F. '{ printf("%d%02d%02d%02d\n", $1,$2,$3,$4); }'; }

# ---------------------------
# PRoot wrapper utilities
# ---------------------------

# basic proot invoker; $1 = rootfs path, rest = args (if first arg = -c then will pass -c "..." to bash)
sfb_proot() {
	#local rootfs="$1"; shift
	local rootfs=`pwd`; shift
	if [ -z "$rootfs" ]; then sfb_error "sfb_proot: no rootfs specified"; fi
	if [ ! -d "$rootfs" ]; then sfb_error "sfb_proot: rootfs not found: $rootfs"; fi
	if [ ! -x "$PROOT_BIN" ]; then
		# try plain 'proot' in PATH
		if command -v proot >/dev/null 2>&1; then
			PROOT_BIN="$(command -v proot)"
		else
			sfb_error "proot binary not found. Set PROOT_BIN or place ./proot in project."
		fi
	fi

	# Bind host home into the guest as /parentroot/home/$USER so scripts that expect /parentroot continue to work
	# Also bind project dir so caller scripts can access tarballs, etc.
	local bind_opts
	# detect -b support
	if "$PROOT_BIN" -h 2>&1 | grep -q '\-b'; then
		bind_opts="-b /dev -b /proc -b /sys -b /tmp -b /run -b $SFB_ROOT:/parentroot$SFB_ROOT -b $PWD:/parentroot$PWD"
	else
		bind_opts="--bind=/dev --bind=/proc --bind=/sys --bind=/tmp --bind=/run --bind=$SFB_ROOT:/parentroot$SFB_ROOT --bind=$PWD:/parentroot$PWD"
	fi

	# default working dir inside guest: /home/$USER if exists else /root
	local workdir="/home/${USER:-$USERNAME}"
	if [ ! -d "$rootfs$workdir" ]; then
		workdir="/root"
	fi

	# If first arg begins with -c or user passed commands, run as non-interactive -c
	exec "$PROOT_BIN" -R "$rootfs" -0 $bind_opts -w "$workdir" /bin/bash -c "$*"
}

# convenience wrappers
sfb_proot_sfossdk() {
	# run command inside SFOS SDK rootfs
	# usage: sfb_proot_sfossdk "some command"
	[ -z "$SFOSSDK_ROOT" ] && sfb_error "SFOSSDK_ROOT not set"
	sfb_proot "$SFOSSDK_ROOT" "$*"
}

sfb_proot_habuild() {
	[ -z "$HABUILD_ROOT" ] && sfb_error "HABUILD_ROOT not set"
	sfb_proot "$HABUILD_ROOT" "$*"
}

# ---------------------------
# conversions of existence checks (unchanged)
# ---------------------------
sfb_chroot_exists_sfossdk() { [ -f "$SFOSSDK_ROOT/bin/sh" ]; }
sfb_chroot_exists_habuild() { [ -f "$HABUILD_ROOT/bin/sh" ]; }
sfb_chroot_exists_sb2_target() { [ -f "$SB2_TARGET_ROOT/bin/sh" ]; }
sfb_chroot_exists_sb2_tooling() { [ -f "$SB2_TOOLING_ROOT/bin/sh" ]; }

# ---------------------------
# chroot setup -> proot setup replacements
# ---------------------------

# Ensure no 'nosuid' style mount problem (less relevant for proot but keep check)
sfb_chroot_check_suid() {
	local mnt
	if command -v findmnt >/dev/null 2>&1; then
		mnt="$(findmnt -nT "$PLATFORM_SDK_ROOT" 2>/dev/null || true)"
		if echo "$mnt" | grep -q 'nosuid'; then
			local mntdir="$(echo "$mnt" | awk '{print $1}')"
			sfb_error "PLATFORM_SDK_ROOT appears to be on a mount ($mntdir) with 'nosuid' option set!"
		fi
	fi
}

# Setup SFOS SDK rootfs (extract tarball) — converted: no mount, no mknod required
sfb_proot_setup_sfossdk() {
	local sdk_tarball="$1"
	[ -z "$sdk_tarball" ] && sfb_error "sfb_proot_setup_sfossdk: no tarball specified"
	[ -f "$SFOSSDK_ROOT" ] && $SUDO rm -rf "$SFOSSDK_ROOT"
	mkdir -p "$SFOSSDK_ROOT"
	sfb_log "Extracting $sdk_tarball -> $SFOSSDK_ROOT (PRoot-friendly)"
	# avoid attempting mknod; allow missing device nodes (proot will handle)
	tar --numeric-owner --no-same-owner --no-same-permissions -xpf "$sdk_tarball" -C "$SFOSSDK_ROOT" || { sfb_error "Failed extracting sdk tarball"; }
	# remove/ignore device nodes that failed to be created
	# (no-op: tar will already have skipped mknod where not permitted)
	sfb_log "SFOS SDK rootfs extracted."
	# prepare a minimal mersdk profile so non-interactive shells in proot behave
	sfb_fix_env_proot
}

# Setup HABUILD rootfs: extract ubuntu rootfs tarball into HABUILD_ROOT
sfb_proot_setup_habuild() {
	local ubu_tarball="$1"
	[ -z "$ubu_tarball" ] && sfb_error "sfb_proot_setup_habuild: no tarball specified"
	$SUDO rm -rf "$HABUILD_ROOT"
	mkdir -p "$HABUILD_ROOT"
	sfb_log "Extracting $ubu_tarball -> $HABUILD_ROOT"
	tar --numeric-owner --no-same-owner --no-same-permissions -xpf "$ubu_tarball" -C "$HABUILD_ROOT" || { sfb_error "Failed extracting ubuntu tarball"; }
	# small fixes similar to original script but adapted for proot:
	# - ensure home dir exists
	mkdir -p "$HABUILD_ROOT/home/$USER"
	$SUDO chown -R "$USER:" "$HABUILD_ROOT/home/$USER" 2>/dev/null || true
	# link host mersdk profile if present (use /parentroot path inside guest)
	ln -sf /parentroot/home/$USER/.mersdk.profile "$HABUILD_ROOT/home/$USER/.mersdkubu.profile" 2>/dev/null || true
	sfb_log "HABUILD rootfs prepared."
}

# small helper to write .hadk.env / .mersdk.profile inside SFOSSDK_ROOT
sfb_fix_env_proot() {
	[ -z "$SFOSSDK_ROOT" ] && return 0
	mkdir -p "$SFOSSDK_ROOT/home/$USER"
	cat > "$SFOSSDK_ROOT/home/$USER/.mersdk.profile" <<'EOF'
export PATH=$PATH:/sbin
. ~/.hadk.env 2>/dev/null || true
# stop if not interactive
[[ $- != *i* ]] && return
EOF
	# hadk env
	cat > "$SFOSSDK_ROOT/home/$USER/.hadk.env" <<EOF
export SFB_ROOT="/parentroot$SFB_ROOT"
export ANDROID_ROOT="/parentroot$ANDROID_ROOT"
EOF
}

# ---------------------------
# sb2/tooling/target setup conversions
# ---------------------------
sfb_chroot_sb2_setup() {
	local ans tooling tooling_url target target_url
	if sfb_array_contains "^\-(y|\-yes)$" "$@"; then
		ans="y"
	fi
	if sfb_chroot_exists_sb2_target; then
		sfb_prompt "Remove existing target chroot for $VENDOR-$DEVICE-$PORT_ARCH (y/N)?" ans "$SFB_YESNO_REGEX" "$ans"
		[[ "${ans^^}" != "Y"* ]] && return
		# original used sb2 inside sfossdk to remove target
		sfb_proot_sfossdk "sdk-assistant target remove -y $VENDOR-$DEVICE-$PORT_ARCH"
	fi
	tooling="Sailfish_OS-$TOOLING_RELEASE-Sailfish_SDK_Tooling-i486.tar.7z"
	tooling_url="$SFB_SDK_URL/targets/$tooling"
	target="Sailfish_OS-$TOOLING_RELEASE-Sailfish_SDK_Target-$PORT_ARCH.tar.7z"
	target_url="$SFB_SDK_URL/targets/$target"

	sfb_log "Fetching Scratchbox2 tooling & target chroot tarballs..."
	sfb_fetch -u "$tooling_url" -o "$SFB_ARC"/$tooling -c "md5sum"
	sfb_fetch -u "$target_url" -o "$SFB_ARC"/$target -c "md5sum"

	sfb_log "Setting up Scratchbox2 tooling & target $VENDOR-$DEVICE-$PORT_ARCH..."
	$SUDO rm -rf "$SB2_TARGET_ROOT"*
	if ! sfb_chroot_exists_sb2_tooling; then
		# create tooling inside sfossdk rootfs
		sfb_proot_sfossdk "sdk-assistant tooling create SailfishOS-$TOOLING_RELEASE /parentroot$SFB_ARC/$tooling --no-snapshot -y" || return 1
	fi
	sfb_proot_sfossdk "sdk-assistant target create $VENDOR-$DEVICE-$PORT_ARCH /parentroot$SFB_ARC/$target --tooling SailfishOS-$TOOLING_RELEASE --no-snapshot -y && sdk-assistant list" || return 1

	# run the same zypper installs inside sfossdk
	sfb_proot_sfossdk 'sudo zypper ref -f && sudo zypper --non-interactive in android-tools-hadk kmod && sb2 -t $VENDOR-$DEVICE-$PORT_ARCH -m sdk-install -R zypper --non-interactive rm ofono-configs-binder bluez5-configs-mer jolla-devicelock-daemon-encpartition' || return 1

	sfb_log "Running Scratchbox2 self-test for $VENDOR-$DEVICE-$PORT_ARCH..."
	# compile and run test inside sb2 target (via sfossdk)
	sfb_proot_sfossdk 'cd;
cat > test.c <<EOF
#include <stdlib.h>
#include <stdio.h>
int main(void) {
printf("Hello, '"$PORT_ARCH"'!\n");
return EXIT_SUCCESS;
}
EOF
sb2 -t '"$VENDOR"'-'"$DEVICE"'-'"$PORT_ARCH"' gcc test.c -o test &&
sb2 -t '"$VENDOR"'-'"$DEVICE"'-'"$PORT_ARCH"' ./test;
ret=$?
rm test*;
exit $ret' || sfb_error "Failed sb2 self-test"
}

# ---------------------------
# high-level orchestration converted
# ---------------------------
sfb_chroot_setup_sfossdk() {
	local extra_fetch_args=()
	if sfb_chroot_exists_sfossdk && [[ -d "$PLATFORM_SDK_ROOT/toolings" || -d "$PLATFORM_SDK_ROOT/targets" ]]; then
		sfb_log "Removing potentially existing sb2 targets & toolings..."
		# remove targets inside sfossdk root (if present)
		sfb_proot_sfossdk 'for t in $(sdk-assistant target list); do sdk-assistant target remove -y $t; done'
		sfb_proot_sfossdk 'for t in $(sdk-assistant tooling list); do sdk-assistant tooling remove -y $t; done'
	fi

	sfb_log "Fetching SailfishOS SDK chroot tarball..."
	if [[ "$SDK_RELEASE" != "latest" && "$sdk_tarball_url" != *"/$SDK_RELEASE.deprecated/"* ]]; then
		extra_fetch_args+=(-F)
	fi
	if ! sfb_fetch -u "$sdk_tarball_url" -o "$SFB_ARC"/$sdk_tarball -c "md5" "${extra_fetch_args[@]}"; then
		# only tried when failed to download non-deprecated versioned SDK_RELEASE tarball
		sdk_tarball_url="${sdk_tarball_url/\/$SDK_RELEASE\//\/$SDK_RELEASE.deprecated\/}"
		sfb_fetch -u "$sdk_tarball_url" -o "$SFB_ARC"/$sdk_tarball -c "md5"
		sfb_warn "This port ($SFB_DEVICE) may be unmaintained; please update it or set SDK_RELEASE to '$SDK_RELEASE.deprecated'!"
	fi

	sfb_log "Setting up SailfishOS SDK rootfs for PRoot..."
	$SUDO rm -rf "$SFOSSDK_ROOT"
	mkdir -p "$PLATFORM_SDK_ROOT"/{targets,toolings,sdks/sfossdk} 2>/dev/null || true
	sfb_chroot_check_suid

	# extract tarball into SFOSSDK_ROOT using proot-friendly options
	sfb_proot_setup_sfossdk "$SFB_ARC/$sdk_tarball" || return 1

	# setup proper environment files
	sfb_fix_env_proot

	# disable motd/lastlog similar to original
	[ -f "$SFOSSDK_ROOT"/var/log/lastlog ] && $SUDO chattr -i "$SFOSSDK_ROOT"/var/log/lastlog 2>/dev/null || true
	printf '' > "$SFOSSDK_ROOT"/var/log/lastlog 2>/dev/null || true
	$SUDO chattr +i "$SFOSSDK_ROOT"/var/log/lastlog 2>/dev/null || true
	echo '#!/bin/sh' > "$SFOSSDK_ROOT"/usr/bin/sdk-motd 2>/dev/null || true
	chmod +x "$SFOSSDK_ROOT"/usr/bin/sdk-motd 2>/dev/null || true

	# create home for user
	mkdir -p "$SFOSSDK_ROOT/home/$USER"
	$SUDO chown -R "$USER:" "$SFOSSDK_ROOT/home/$USER" 2>/dev/null || true

	# write .mersdk.profile into SFOSSDK_ROOT/home/$USER
	cat > "$SFOSSDK_ROOT"/home/$USER/.mersdk.profile <<'EOF'
export PATH=$PATH:/sbin
. ~/.hadk.env 2>/dev/null || true
if [ -f "$SFB_ROOT"/.lastdevice ]; then
        SFB_DEVICE="$(<"$SFB_ROOT"/.lastdevice)"
        . "$SFB_ROOT/device/$SFB_DEVICE/env.sh"
        croot() { cd "$ANDROID_ROOT"; }
fi
[[ $- != *i* ]] && return
EOF

	# Reuse host gitconfig if possible
	hostgitconf="$HOME/.gitconfig"
	if [ -f "$hostgitconf" ]; then
		cp "$(readlink -f "$hostgitconf")" "$SFOSSDK_ROOT/home/$USER/.gitconfig" 2>/dev/null || true
		if grep -q 'signingkey' "$SFOSSDK_ROOT/home/$USER/.gitconfig" 2>/dev/null; then
			sed '/signingkey/ s/^/#/' -i "$SFOSSDK_ROOT/home/$USER/.gitconfig" 2>/dev/null || true
		fi
	fi

	# run a zypper install inside proot to install android-tools-hadk if possible
	sfb_proot_sfossdk 'sudo zypper ref -f && sudo zypper --non-interactive in android-tools-hadk kmod' || sfb_warn "zypper install inside proot failed; continue"

	sfb_setup_hadk_env
}

# Keep sfb_setup_hadk_env logic with adjusted parentroot usage
sfb_setup_hadk_env() {
	local env_file="$SFOSSDK_ROOT/home/$USER/.hadk.env"
	mkdir -p "$(dirname "$env_file")"
	cat > "$env_file" <<EOF
export SFB_ROOT="/parentroot$SFB_ROOT"
export ANDROID_ROOT="/parentroot$ANDROID_ROOT"
EOF
}

# ---------------------------
# sfb_chroot replacement: dispatch to proot handlers
# ---------------------------
sfb_chroot() {
	local ret=0
	case "$1" in
		setup)
			shift
			sfb_hook_exec pre-chroot-setup 2>/dev/null || true
			sfb_chroot_setup "$@" || sfb_error "Failed to setup build rootfs!"
			sfb_hook_exec post-chroot-setup 2>/dev/null || true
			;;
		sfossdk)
			shift
			sfb_chroot_exists_sfossdk || sfb_error "Rootfs for sfossdk isn't setup yet; run '$0 chroot setup'!"
			sfb_setup_hadk_env
			sfb_hook_exec pre-chroot-enter sfossdk 2>/dev/null || true
			# Run the SFOS SDK chroot-style commands in PRoot
			sfb_proot_sfossdk "$@"
			ret=$?
			sfb_hook_exec post-chroot-enter sfossdk 2>/dev/null || true
			;;
		habuild)
			shift
			sfb_chroot_exists_habuild || sfb_error "Rootfs for habuild isn't setup yet; run '$0 chroot setup'!"
			sfb_setup_hadk_env
			sfb_hook_exec pre-chroot-enter habuild 2>/dev/null || true
			# Run a nested proot into HABUILD root
			sfb_proot_habuild "$@"
			ret=$?
			sfb_hook_exec post-chroot-enter habuild 2>/dev/null || true
			;;
		*)
			sfb_error "Usage: $0 chroot {setup|sfossdk|habuild}";;
	esac
	return $ret
}

# ---------------------------
# entry: if script invoked directly with "chroot ..." emulate original CLI
# ---------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	# naive CLI dispatcher to emulate original script usage: e.g. ./1-proot.sh chroot setup
	if [ "$1" = "chroot" ]; then
		shift
		sfb_chroot "$@"
	else
		echo "Usage: $0 chroot {setup|sfossdk|habuild}"
		exit 1
	fi
fi
