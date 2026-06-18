#!/system/bin/sh
# ============================================================
# MiMo Code Android Installer
# Usage: su -c "sh mimo-android.sh"
# ============================================================
set -eu

trap 'echo ""; echo "[!] Cancelled"; rm -rf "$CACHE" 2>/dev/null; exit 130' INT

# ---------- Config ----------
MIMO_REPO="XiaomiMiMo/MiMo-Code"
MIMO_VER=""
INSTALL_DIR="/data/local/tmp/mimocode"
BIN_DIR="${INSTALL_DIR}/bin"
LIB_DIR="${INSTALL_DIR}/lib"
HOME_DIR="${INSTALL_DIR}/home"
CACHE="/data/local/.mimo-cache"
STATE="${INSTALL_DIR}/.state"
DEBIAN_MIRROR="http://mirrors.ustc.edu.cn/debian/pool/main"
BB="/data/adb/ksu/bin/busybox"

detect_root_method() {
    [ -d /data/adb/ksu ] && echo "ksu" && return
    [ -d /data/adb/magisk ] && echo "magisk" && return
    [ -d /data/adb/ap ] && echo "apatch" && return
    echo "unknown"
}
ROOT_METHOD=$(detect_root_method)

case "$ROOT_METHOD" in
    ksu|magisk|apatch)
        MOD_DIR="/data/adb/modules/mimo/system/bin"
        mkdir -p "$MOD_DIR" 2>/dev/null
        WRAPPER="$MOD_DIR/mimo"
        ;;
    *)
        WRAPPER="/data/local/tmp/mimo"
        ;;
esac

TOOL_DIR="/data/local/tmp"

# ---------- Helpers ----------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; C='\033[0;36m'; O='\033[38;5;208m'; NC='\033[0m'
ok()   { printf "${G}[OK]${NC} %s\n" "$1"; }
warn() { printf "${Y}[!]${NC} %s\n" "$1"; }
err()  { printf "${R}[X]${NC} %s\n" "$1"; exit 1; }
info() { printf "${C}>${NC} %s\n" "$1"; }

detect_proxy() {
    local proxy_info=$(dumpsys connectivity 2>/dev/null | grep -o 'HttpProxy: \[[^]]*\] [0-9]*' | head -1)
    if [ -n "$proxy_info" ]; then
        local host=$(echo "$proxy_info" | grep -o '\[[^]]*\]' | tr -d '[]')
        local port=$(echo "$proxy_info" | grep -o '[0-9]*$')
        if [ -n "$host" ] && [ -n "$port" ]; then
            echo "${host}:${port}"
            return 0
        fi
    fi
    [ -n "$http_proxy" ] && echo "$http_proxy" && return 0
    [ -n "$https_proxy" ] && echo "$https_proxy" && return 0
    [ -n "$HTTP_PROXY" ] && echo "$HTTP_PROXY" && return 0
    [ -n "$HTTPS_PROXY" ] && echo "$HTTPS_PROXY" && return 0
    return 1
}

CURL_PROXY=""
PROXY_INFO=$(detect_proxy 2>/dev/null) && CURL_PROXY="-x $PROXY_INFO"

dl() {
    local url="$1" out="$2" label="$3"
    local tmperr=$(mktemp)
    printf "  ${O}%-20s${NC}" "$label"
    curl -L $CURL_PROXY --connect-timeout 20 --max-time 600 --retry 2 -# -o "$out" "$url" 2>"$tmperr" &
    local cpid=$!
    while kill -0 $cpid 2>/dev/null; do
        local pct=$(tail -1 "$tmperr" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1)
        [ -n "$pct" ] && printf "\r  ${O}%-20s %7s${NC}" "$label" "$pct"
        sleep 1
    done
    wait $cpid
    local ret=$?
    rm -f "$tmperr"
    if [ $ret -ne 0 ] || [ ! -s "$out" ]; then
        printf "\r  ${O}%-20s${NC}  ${R}X${NC}\n" "$label"
        return 1
    fi
    printf "\r  ${O}%-20s${NC}  ${G}OK${NC}\n" "$label"
    return 0
}

extract_deb_libs() {
    local deb="$1" label="$2" out="$3"
    local tmpdir="$out/_tmp_$label"
    rm -rf "$tmpdir" 2>/dev/null
    mkdir -p "$tmpdir"
    ( cd "$tmpdir" || exit 1
      $BB ar x "$deb" || exit 1
      if [ -f data.tar.xz ]; then
          $BB xz -d data.tar.xz && $BB tar xf data.tar
      elif [ -f data.tar.gz ]; then
          gunzip -f data.tar.gz && $BB tar xf data.tar
      fi
      rm -f data.tar data.tar.xz data.tar.gz debian-binary control.tar.* 2>/dev/null
    ) || return 1
    return 0
}

# ---------- State ----------
is_installed() {
    [ -f "$STATE" ] && [ -f "$BIN_DIR/mimo.real" ] && [ -f "$LIB_DIR/ld-linux-aarch64.so.1" ]
}
get_version()  { [ -f "$STATE" ] && cat "$STATE" 2>/dev/null || echo ""; }

check_integrity() {
    local missing=""
    [ -f "$BIN_DIR/mimo.real" ] || missing="$missing mimo.real"
    [ -f "$LIB_DIR/ld-linux-aarch64.so.1" ] || missing="$missing glibc"
    [ -f "$LIB_DIR/bash" ] || missing="$missing bash"
    [ -f "$LIB_DIR/python3.13.bin" ] || missing="$missing python3"
    [ -f "$WRAPPER" ] || missing="$missing wrapper"
    [ -z "$missing" ]
}

do_uninstall() {
    echo ""
    info "Uninstalling..."
    rm -rf "$INSTALL_DIR" "$WRAPPER" "$CACHE" 2>/dev/null
    rm -rf "$TOOL_DIR/mimo" "$TOOL_DIR/bash" "$TOOL_DIR/python3" 2>/dev/null
    rm -rf /data/local/.mimo-cache /data/local/.mimo-proot-cache 2>/dev/null
    rm -rf /data/adb/modules/mimo /data/adb/mimocode 2>/dev/null
    rm -f /data/adb/ksu/bin/mimo /data/adb/ksu/bin/bash /data/adb/ksu/bin/python3 2>/dev/null
    ok "Uninstalled. Reboot to clear KSU mounts."
    echo ""
    exit 0
}

do_menu() {
    VER=$(get_version)
    echo ""
    printf "${C}============================================${NC}\n"
    printf "${C}  MiMo Code installed v%-17s${NC}\n" "${VER:-?}"
    printf "${C}============================================${NC}\n"
    echo ""
    if ! check_integrity; then
        printf "  ${Y}[!]${NC} Missing components detected\n"
        echo ""
    fi
    printf "  ${G}[1]${NC} Update/Repair to latest\n"
    printf "  ${R}[2]${NC} Uninstall\n"
    printf "  ${C}[3]${NC} Exit\n"
    echo ""
    printf "  Select: "
    read CHOICE
    case "$CHOICE" in
        2) do_uninstall ;;
        *) exit 0 ;;
    esac
}

# ============================================================
# Main
# ============================================================
echo ""
printf "${G}"
echo "---------------------------------------------------------------------------------"
echo "     ___      _______      _______        __    __         ______    __  ___  __"
echo "    /   \    |   _   \   |   ____|      |  |  |  |        /  __  \  |  |/  / |  |"
echo "   /  ^  \   |  |_)  |   |  |__         |  |  |  |       |  |  |  | |  '  /  |  |"
echo "  /  /_\  \  |      /    |   __|        |  |  |  |       |  |  |  | |    <   |  |"
echo " /  _____  \ |  |\  \--. |  |____       |  \--'  |       |  \--'  | |  .  \  |__|"
echo "/__/     \__\| _| \____| |_______|       \______/         \______/  |__|\__\ (__)"
echo "---------------------------------------------------------------------------------"
printf "${NC}"
echo "  MiMo Code for Android Installer"
echo ""

START_TIME=$(date +%s)

# ---------- Pre-checks ----------
[ "$(id -u)" = "0" ] || err "ROOT required"
is_installed && do_menu
[ -x "$BB" ] || err "KernelSU busybox required"

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || err "ARM64 only"
ok "Architecture: ARM64"
[ -f /system/build.prop ] && ok "Android $(getprop ro.build.version.release 2>/dev/null || echo '?')"

printf "  Network check... "
curl -s $CURL_PROXY --connect-timeout 8 --max-time 10 https://github.com >/dev/null 2>&1 && echo "OK" || \
curl -s --connect-timeout 8 --max-time 10 https://www.baidu.com >/dev/null 2>&1 && echo "OK" || \
err "No network"
ok "Network OK"
[ -n "$PROXY_INFO" ] && ok "Proxy: $PROXY_INFO"

# ---------- Get version ----------
if [ -z "$MIMO_VER" ]; then
    MIMO_VER=$(curl -s $CURL_PROXY --connect-timeout 10 --max-time 15 "https://api.github.com/repos/${MIMO_REPO}/releases/latest" 2>/dev/null | grep -o '"tag_name":"v[^"]*"' | head -1 | sed 's/"tag_name":"v//;s/"//')
    [ -z "$MIMO_VER" ] && MIMO_VER="0.1.1"
fi

# ---------- Config summary ----------
echo ""
printf "${C}==============================================${NC}\n"
printf "${C}           Install Configuration              ${NC}\n"
printf "${C}==============================================${NC}\n"
echo ""
echo "  Device:   $(getprop ro.product.model 2>/dev/null || echo '?') (Android $(getprop ro.build.version.release 2>/dev/null || echo '?'))"
echo "  Arch:     ARM64 (aarch64)"
echo "  Kernel:   $(uname -r)"
echo ""
echo "  Install:  ${INSTALL_DIR}"
echo "  Data:     ${HOME_DIR}"
echo "  Command:  ${WRAPPER}"
echo ""
echo "  Packages:"
echo "    - MiMo Code v${MIMO_VER:-latest}"
echo "    - glibc (libc6/libstdc++/libgcc)"
echo "    - bash (glibc)"
echo "    - python3 + pip (glibc)"
echo ""
printf "  ${C}Auto-installing in %2d sec (press n to cancel)...${NC}\r" 10
WAIT=10
while [ $WAIT -gt 0 ]; do
    read -t 1 KEY 2>/dev/null && {
        case "$KEY" in
            n|N) echo ""; echo "Cancelled"; exit 0 ;;
        esac
    }
    WAIT=$((WAIT - 1))
    printf "  ${C}Auto-installing in %2d sec (press n to cancel)...${NC}\r" $WAIT
done
echo ""
echo ""

# ---------- Cleanup ----------
info "Cleaning old files..."
rm -rf "$INSTALL_DIR" "$WRAPPER" "$TOOL_DIR/mimo" "$TOOL_DIR/bash" "$TOOL_DIR/python3" "$CACHE" /data/adb/mimocode /data/local/.mimo-cache /data/local/.mimo-proot-cache 2>/dev/null
mkdir -p "$BIN_DIR" "$LIB_DIR" "$CACHE" "$HOME_DIR/.local/share/mimocode" "$HOME_DIR/.config/mimocode" "$HOME_DIR/.cache/mimocode"
ok "Ready"

# ============================================================
# 1. Download glibc
# ============================================================
echo ""
info "[1/5] Downloading glibc..."

GLIBC_VER="2.42-16"
GCC_VER="14.2.0-19"

for pkg in \
    "libc6|g/glibc/libc6_${GLIBC_VER}_arm64.deb|libc6" \
    "libstdc++|g/gcc-14/libstdc++6_${GCC_VER}_arm64.deb|libstdcpp" \
    "libgcc|g/gcc-14/libgcc-s1_${GCC_VER}_arm64.deb|libgcc"; do
    IFS='|' read -r name path file <<< "$pkg"
    if [ -f "$CACHE/${file}.deb" ] && [ -s "$CACHE/${file}.deb" ]; then
        ok "  $name (cached)"
    else
        dl "${DEBIAN_MIRROR}/${path}" "$CACHE/${file}.deb" "$name" || {
            warn "  $name download failed"
        }
    fi
done

# ============================================================
# 2. Download bash + python3 + deps
# ============================================================
echo ""
info "[2/5] Downloading bash + python3..."

# bash (glibc)
BASH_DEB="bash_5.3-3_arm64.deb"
[ -f "$CACHE/bash.deb" ] && [ -s "$CACHE/bash.deb" ] && ok "  bash (cached)" || \
    dl "${DEBIAN_MIRROR}/b/bash/${BASH_DEB}" "$CACHE/bash.deb" "bash"

# libtinfo (bash dep)
TINFO_DEB="libtinfo6_6.6+20260608-1_arm64.deb"
[ -f "$CACHE/libtinfo.deb" ] && [ -s "$CACHE/libtinfo.deb" ] && ok "  libtinfo (cached)" || \
    dl "${DEBIAN_MIRROR}/n/ncurses/${TINFO_DEB}" "$CACHE/libtinfo.deb" "libtinfo"

# python3.13-minimal
PY3_DEB="python3.13-minimal_3.13.14-1_arm64.deb"
[ -f "$CACHE/python3.deb" ] && [ -s "$CACHE/python3.deb" ] && ok "  python3 (cached)" || \
    dl "${DEBIAN_MIRROR}/p/python3.13/${PY3_DEB}" "$CACHE/python3.deb" "python3"

# libpython3.13-minimal (core stdlib: encodings etc)
LIBPY_MIN_DEB="libpython3.13-minimal_3.13.14-1_arm64.deb"
[ -f "$CACHE/libpython-min.deb" ] && [ -s "$CACHE/libpython-min.deb" ] && ok "  libpython-min (cached)" || \
    dl "${DEBIAN_MIRROR}/p/python3.13/${LIBPY_MIN_DEB}" "$CACHE/libpython-min.deb" "libpython-min"

# libpython3.13-stdlib (full stdlib: shutil etc)
LIBPY_STD_DEB="libpython3.13-stdlib_3.13.14-1_arm64.deb"
[ -f "$CACHE/libpython-std.deb" ] && [ -s "$CACHE/libpython-std.deb" ] && ok "  libpython-std (cached)" || \
    dl "${DEBIAN_MIRROR}/p/python3.13/${LIBPY_STD_DEB}" "$CACHE/libpython-std.deb" "libpython-std"

# zlib (python dep)
ZLIB_DEB="zlib1g_1.3.dfsg+really1.3.1-1+b1_arm64.deb"
[ -f "$CACHE/zlib.deb" ] && [ -s "$CACHE/zlib.deb" ] && ok "  zlib (cached)" || \
    dl "${DEBIAN_MIRROR}/z/zlib/${ZLIB_DEB}" "$CACHE/zlib.deb" "zlib"

# libexpat (python dep)
EXPAT_DEB="libexpat1_2.7.1-2_arm64.deb"
[ -f "$CACHE/expat.deb" ] && [ -s "$CACHE/expat.deb" ] && ok "  libexpat (cached)" || \
    dl "${DEBIAN_MIRROR}/e/expat/${EXPAT_DEB}" "$CACHE/expat.deb" "libexpat"

# pip wheel
PIP_DEB="python3-pip-whl_26.1.2+dfsg-1_all.deb"
[ -f "$CACHE/pip.deb" ] && [ -s "$CACHE/pip.deb" ] && ok "  pip (cached)" || \
    dl "${DEBIAN_MIRROR}/p/python-pip/${PIP_DEB}" "$CACHE/pip.deb" "pip"

# ============================================================
# 3. Extract & install
# ============================================================
echo ""
info "[3/5] Extracting..."

# --- glibc ---
for file in "libc6" "libstdcpp" "libgcc"; do
    [ -f "$CACHE/${file}.deb" ] && extract_deb_libs "$CACHE/${file}.deb" "$file" "$CACHE" && ok "  $file" || warn "  $file failed"
done

SRC=""
for p in "$CACHE"/_tmp_libc6/usr/lib/aarch64-linux-gnu "$CACHE"/_tmp_libc6/usr/lib; do
    [ -d "$p" ] && [ -f "$p/ld-linux-aarch64.so.1" ] && SRC="$p" && break
done
if [ -n "$SRC" ]; then
    for lib in ld-linux-aarch64.so.1 libc.so.6 libstdc++.so.6.0.33 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1; do
        [ -f "$SRC/$lib" ] && [ -s "$SRC/$lib" ] && { cp -f "$SRC/$lib" "$LIB_DIR/"; chmod 755 "$LIB_DIR/$lib"; }
    done
    cd "$LIB_DIR" 2>/dev/null; ln -sf libstdc++.so.6.0.33 libstdc++.so.6 2>/dev/null; ln -sf libc.so.6 libc.so 2>/dev/null
    # libgcc_s.so.1 lives in libgcc deb, not libc6
    GCC_SRC=$(find "$CACHE/_tmp_libgcc" -name "libgcc_s.so.1" -type f 2>/dev/null | head -1)
    [ -n "$GCC_SRC" ] && { cp -f "$GCC_SRC" "$LIB_DIR/libgcc_s.so.1"; chmod 755 "$LIB_DIR/libgcc_s.so.1"; }
    ok "  glibc runtime"
else
    warn "  glibc not found"
fi

# --- bash ---
if [ -f "$CACHE/bash.deb" ]; then
    extract_deb_libs "$CACHE/bash.deb" "bash" "$CACHE"
    BASH_BIN=$(find "$CACHE/_tmp_bash" -name "bash" -type f 2>/dev/null | head -1)
    [ -n "$BASH_BIN" ] && [ -s "$BASH_BIN" ] && { cp -f "$BASH_BIN" "$LIB_DIR/bash"; chmod 755 "$LIB_DIR/bash"; ok "  bash (glibc)"; } || warn "  bash not found"
fi

# --- libtinfo ---
if [ -f "$CACHE/libtinfo.deb" ]; then
    extract_deb_libs "$CACHE/libtinfo.deb" "libtinfo" "$CACHE"
    for so in libtinfo.so.6.6 libtic.so.6.6; do
        f=$(find "$CACHE/_tmp_libtinfo" -name "$so" -type f 2>/dev/null | head -1)
        [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/"; chmod 755 "$LIB_DIR/$so"; }
    done
    cd "$LIB_DIR" 2>/dev/null; ln -sf libtinfo.so.6.6 libtinfo.so.6 2>/dev/null; ln -sf libtic.so.6.6 libtic.so.6 2>/dev/null
    ok "  libtinfo"
fi

# --- python3 ---
if [ -f "$CACHE/python3.deb" ]; then
    extract_deb_libs "$CACHE/python3.deb" "python3" "$CACHE"
    PYTHON_BIN=$(find "$CACHE/_tmp_python3" -name "python3.13" -type f 2>/dev/null | head -1)
    [ -n "$PYTHON_BIN" ] && [ -s "$PYTHON_BIN" ] && {
        cp -f "$PYTHON_BIN" "$LIB_DIR/python3.13.bin"; chmod 755 "$LIB_DIR/python3.13.bin"
        ln -sf python3.13.bin "$LIB_DIR/python3.13" 2>/dev/null
        ln -sf python3.13.bin "$LIB_DIR/python3" 2>/dev/null
        ok "  python3 (glibc)"
    } || warn "  python3 not found"
fi

# --- core stdlib (encodings etc) ---
if [ -f "$CACHE/libpython-min.deb" ]; then
    extract_deb_libs "$CACHE/libpython-min.deb" "libpython-min" "$CACHE"
    SRC="$CACHE/_tmp_libpython-min/usr/lib/python3.13"
    if [ -d "$SRC" ]; then
        rm -rf "$LIB_DIR/pyhome/lib/python3.13" 2>/dev/null
        mkdir -p "$LIB_DIR/pyhome/lib/python3.13"
        cp -r "$SRC/." "$LIB_DIR/pyhome/lib/python3.13/" 2>/dev/null
        ok "  python3 core stdlib"
    else
        warn "  libpython-min not found"
    fi
fi

# --- full stdlib (shutil/colorsys etc) ---
if [ -f "$CACHE/libpython-std.deb" ]; then
    extract_deb_libs "$CACHE/libpython-std.deb" "libpython-std" "$CACHE"
    SRC="$CACHE/_tmp_libpython-std/usr/lib/python3.13"
    if [ -d "$SRC" ]; then
        mkdir -p "$LIB_DIR/pyhome/lib/python3.13"
        cp -r "$SRC/." "$LIB_DIR/pyhome/lib/python3.13/" 2>/dev/null
        ok "  python3 full stdlib"
    else
        warn "  libpython-std not found"
    fi
fi

# --- libexpat ---
if [ -f "$CACHE/expat.deb" ]; then
    extract_deb_libs "$CACHE/expat.deb" "expat" "$CACHE"
    f=$(find "$CACHE/_tmp_expat" -name "libexpat.so.1*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libexpat.so.1"; chmod 755 "$LIB_DIR/libexpat.so.1"; ok "  libexpat"; } || warn "  libexpat not found"
fi

# --- zlib ---
if [ -f "$CACHE/zlib.deb" ]; then
    extract_deb_libs "$CACHE/zlib.deb" "zlib" "$CACHE"
    f=$(find "$CACHE/_tmp_zlib" -name "libz.so*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libz.so.1"; chmod 755 "$LIB_DIR/libz.so.1"; ok "  zlib"; } || warn "  zlib not found"
fi

# --- pip ---
if [ -f "$CACHE/pip.deb" ]; then
    extract_deb_libs "$CACHE/pip.deb" "pip" "$CACHE"
    PIP_WHL=$(find "$CACHE/_tmp_pip" -name "pip-*.whl" -type f 2>/dev/null | head -1)
    if [ -n "$PIP_WHL" ]; then
        set +e
        $BB unzip -o "$PIP_WHL" -d "$LIB_DIR/pyhome/lib/python3.13/" 2>/dev/null
        set -e
        [ -f "$LIB_DIR/pyhome/lib/python3.13/pip/__init__.py" ] && ok "  pip" || warn "  pip install failed"
    else
        warn "  pip wheel not found"
    fi
fi

# ============================================================
# 4. proot + rootfs (DNS / SSL / NSS for glibc)
# ============================================================
echo ""
info "[4/6] proot + minimal rootfs..."

PROOT_VER="5.3.0"
PROOT_URL="https://github.com/proot-me/proot/releases/download/v${PROOT_VER}/proot-v${PROOT_VER}-aarch64-static"
ROOTFS="$INSTALL_DIR/rootfs"

# Download proot static binary
dl "$PROOT_URL" "$LIB_DIR/proot" "proot v${PROOT_VER}" || {
    warn "  proot download failed — trying alternative mirror"
    dl "https://github.com/proot-me/proot/releases/download/v${PROOT_VER}/proot-v${PROOT_VER}-aarch64-static" "$LIB_DIR/proot" "proot (alt)" || \
        err "Cannot download proot"
}
chmod 755 "$LIB_DIR/proot"

# Create minimal rootfs
info "  Building rootfs..."
mkdir -p "$ROOTFS/etc/ssl/certs"

cat > "$ROOTFS/etc/resolv.conf" << 'DNSEOF'
nameserver 8.8.8.8
nameserver 114.114.114.114
DNSEOF

cat > "$ROOTFS/etc/hosts" << 'DNSEOF'
127.0.0.1   localhost
::1         localhost
DNSEOF

cat > "$ROOTFS/etc/nsswitch.conf" << 'DNSEOF'
hosts:      files dns
DNSEOF

# Merge Android CA certificates
if [ -d /system/etc/security/cacerts ]; then
    cat /system/etc/security/cacerts/*.0 > "$ROOTFS/etc/ssl/certs/ca-certificates.crt" 2>/dev/null
    ok "  rootfs ready ($(wc -c < "$ROOTFS/etc/ssl/certs/ca-certificates.crt") bytes CA)"
else
    ok "  rootfs ready (no system CA certs)"
fi

chown -R shell:shell "$ROOTFS" 2>/dev/null || true
chmod -R 755 "$ROOTFS"

# ============================================================
# 5. Wrappers
# ============================================================
echo ""
info "[5/6] Configuring wrappers..."

# Main mimo wrapper — proot overlays /etc + /lib for DNS+SSL+subprocess
cat > "$BIN_DIR/mimo" << WEOF
#!/system/bin/sh
D=${INSTALL_DIR}
R=\$D/rootfs
export HOME=\$D/home
export MIMOCODE_HOME=\$D/home
export PYTHONHOME=\$D/lib/pyhome
export PATH=\$D/lib:\$PATH
[ -x "\$D/lib/bash" ] && export SHELL="\$D/lib/bash"
exec "\$D/lib/proot" \
  -b "\$D/lib:/lib" \
  -b "\$R/etc/resolv.conf:/etc/resolv.conf" \
  -b "\$R/etc/hosts:/etc/hosts" \
  -b "\$R/etc/nsswitch.conf:/etc/nsswitch.conf" \
  -b "\$R/etc/ssl:/etc/ssl" \
  "\$D/lib/ld-linux-aarch64.so.1" --library-path "\$D/lib" "\$D/bin/mimo.real" "\$@"
WEOF
chmod 755 "$BIN_DIR/mimo"

# System shortcut
cat > "$WRAPPER" << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/mimo "\$@"
WEOF
chmod 755 "$WRAPPER"

# Systemless module props (KSU/Magisk/APatch)
if [ "$ROOT_METHOD" != "unknown" ]; then
    if mkdir -p "/data/adb/modules/mimo/system/bin" 2>/dev/null && [ -d /data/adb/modules/mimo/system/bin ]; then
    cat > "/data/adb/modules/mimo/module.prop" << EOF
id=mimo
name=MiMo Code
version=${MIMO_VER}
versionCode=1
author=HiTech_NinJa
description=MiMo Code AI Programming Tool ,Run "sh /data/local/tmp/install.sh" to fix,updata or remove.
EOF
    # KSU Manager uninstall hook
    cat > "/data/adb/modules/mimo/uninstall.sh" << UEOF
#!/system/bin/sh
rm -rf /data/local/tmp/mimocode
rm -rf /data/local/tmp/mimo /data/local/tmp/bash /data/local/tmp/python3
rm -rf /data/local/.mimo-cache /data/local/.mimo-proot-cache
UEOF
    chmod 755 "/data/adb/modules/mimo/uninstall.sh"
    # Systemless wrappers
    cat > "/data/adb/modules/mimo/system/bin/mimo" << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/mimo "\$@"
WEOF
    chmod 755 "/data/adb/modules/mimo/system/bin/mimo"
    cat > "/data/adb/modules/mimo/system/bin/bash" << WEOF
#!/system/bin/sh
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/bash "\$@"
WEOF
    chmod 755 "/data/adb/modules/mimo/system/bin/bash"
    cat > "/data/adb/modules/mimo/system/bin/python3" << WEOF
#!/system/bin/sh
export PYTHONHOME="${LIB_DIR}/pyhome"
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/python3.13 "\$@"
WEOF
    chmod 755 "/data/adb/modules/mimo/system/bin/python3"
    restorecon -R /data/adb/modules/mimo 2>/dev/null || true
    ok "  systemless module (mimo/bash/python3 after reboot)"
    else
        warn "  Cannot create KSU module"
    fi
fi

# Tool wrappers (always create)
cat > "$TOOL_DIR/bash" << WEOF
#!/system/bin/sh
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/bash "\$@"
WEOF
chmod 755 "$TOOL_DIR/bash"

cat > "$TOOL_DIR/python3" << WEOF
#!/system/bin/sh
export PYTHONHOME="${LIB_DIR}/pyhome"
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/python3.13 "\$@"
WEOF
chmod 755 "$TOOL_DIR/python3"

# Fallback mimo shortcut
if [ "$WRAPPER" != "/data/local/tmp/mimo" ]; then
    cat > /data/local/tmp/mimo << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/mimo "\$@"
WEOF
    chmod 755 /data/local/tmp/mimo 2>/dev/null
fi

# KSU bin wrappers — reliable global shortcuts, no module/reboot needed
if [ -d /data/adb/ksu/bin ]; then
    cat > /data/adb/ksu/bin/mimo << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/mimo "\$@"
WEOF
    chmod 755 /data/adb/ksu/bin/mimo 2>/dev/null
    cat > /data/adb/ksu/bin/bash << WEOF
#!/system/bin/sh
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/bash "\$@"
WEOF
    chmod 755 /data/adb/ksu/bin/bash 2>/dev/null
    cat > /data/adb/ksu/bin/python3 << WEOF
#!/system/bin/sh
export PYTHONHOME="${LIB_DIR}/pyhome"
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/python3.13 "\$@"
WEOF
    chmod 755 /data/adb/ksu/bin/python3 2>/dev/null
fi

ok "wrappers ready"

# ============================================================
# 6. Download mimo
# ============================================================
echo ""
info "[6/6] Downloading mimo v${MIMO_VER}..."

dl "https://github.com/${MIMO_REPO}/releases/download/v${MIMO_VER}/mimocode-linux-arm64.tar.gz" "$CACHE/mimo.tar.gz" "mimo v${MIMO_VER}" || {
    echo ""
    warn "mimo download failed"
    warn "  bash and python3 are installed and usable"
    warn "  Re-run the script after fixing network"
    exit 1
}

printf "  ${O}Extracting mimo...${NC} "
cd "$CACHE"
tar xzf mimo.tar.gz 2>/dev/null || tar xf mimo.tar.gz 2>/dev/null
if [ ! -f "$CACHE/mimo" ]; then
    echo "FAILED"
    warn "Extraction failed, file may be corrupt"
    exit 1
fi
echo "OK"
cp -f "$CACHE/mimo" "$BIN_DIR/mimo.real"
chmod 755 "$BIN_DIR/mimo.real"
ok "v${MIMO_VER}"

chown -R shell:shell "$HOME_DIR" 2>/dev/null || true
chmod -R 755 "$INSTALL_DIR"
echo "$MIMO_VER" > "$STATE"

ln -sf "$INSTALL_DIR" /data/adb/mimocode 2>/dev/null

rm -rf "$CACHE"

# ============================================================
# Done
# ============================================================
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINS=$((ELAPSED / 60))
SECS=$((ELAPSED % 60))

echo ""
printf "${G}"
echo "=================================================="
echo "           Installation Complete!"
echo "=================================================="
printf "${NC}"
echo ""
echo "  Version:  v${MIMO_VER}"
echo "  Time:     ${MINS}m${SECS}s"
echo ""
echo "  Details:"
echo "  ----------------------------------------"
MIMO_SIZE=$(du -h "$BIN_DIR/mimo.real" 2>/dev/null | awk '{print $1}')
printf "  %-12s  %-35s  %s\n" "mimo" "$BIN_DIR/mimo.real" "${MIMO_SIZE:-?}"
BASH_SIZE=$(du -h "$LIB_DIR/bash" 2>/dev/null | awk '{print $1}')
printf "  %-12s  %-35s  %s\n" "bash" "$LIB_DIR/bash" "${BASH_SIZE:-?}"
PY_SIZE=$(du -h "$LIB_DIR/python3" 2>/dev/null | awk '{print $1}')
printf "  %-12s  %-35s  %s\n" "python3" "$LIB_DIR/python3" "${PY_SIZE:-?}"
LIBC_SIZE=$(du -sh "$LIB_DIR" 2>/dev/null | awk '{print $1}')
printf "  %-12s  %-35s  %s\n" "glibc" "$LIB_DIR" "${LIBC_SIZE:-?}"
if [ -f "$LIB_DIR/proot" ]; then
    PROOT_SIZE=$(du -h "$LIB_DIR/proot" 2>/dev/null | awk '{print $1}')
    printf "  %-12s  %-35s  %s  ${G}proot ready${NC}\n" "proot" "$LIB_DIR/proot" "${PROOT_SIZE:-?}"
else
    printf "  ${Y}%-12s  %-35s  %s  proot missing${NC}\n" "proot" "(missing)" "0"
fi
TOTAL_SIZE=$(du -sh "$INSTALL_DIR" 2>/dev/null | awk '{print $1}')
echo "  ----------------------------------------"
printf "  %-12s  %-35s  %s\n" "Total" "$INSTALL_DIR" "${TOTAL_SIZE:-?}"
echo ""
echo "  ${G}Usage:${NC}"
echo ""
if [ "$ROOT_METHOD" != "unknown" ]; then
    echo "  ${C}After reboot:${NC} mimo / bash / python3 available globally"
    echo ""
    echo "  ${C}Without reboot:${NC}"
fi
echo "    su -c '/data/local/tmp/mimo'"
echo ""
echo "  ${C}Tools:${NC}"
echo "    /data/local/tmp/bash --version"
echo "    /data/local/tmp/python3 --version"
echo "    /data/local/tmp/python3 -m pip --version"
echo ""
echo "  Re-run this script to update/uninstall"
echo ""
