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
ROOTFS="${INSTALL_DIR}/rootfs"
CACHE="/data/local/.mimo-cache"
STATE="${INSTALL_DIR}/.state"
DEBIAN_MIRROR="http://mirrors.ustc.edu.cn/debian/pool/main"
DEBIAN_DEB="http://deb.debian.org/debian/pool/main"
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
UPDATE_MODE=0

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
    # Validate .deb files — proxy may return HTML instead of binary
    case "$out" in
        *.deb)
            local magic=$(dd if="$out" bs=8 count=1 2>/dev/null)
            if [ "$magic" != "!<arch>" ]; then
                printf "\r  ${O}%-20s${NC}  ${Y}!${NC} (non-deb content)\n" "$label"
                rm -f "$out" 2>/dev/null
                return 1
            fi
            ;;
    esac
    printf "\r  ${O}%-20s${NC}  ${G}OK${NC}\n" "$label"
    return 0
}

extract_deb_libs() {
    local deb="$1" label="$2" out="$3"
    # Validate deb archive (dd is more portable than head -c)
    local magic=$(dd if="$deb" bs=8 count=1 2>/dev/null)
    if [ "$magic" != "!<arch>" ]; then
        warn "  $label: corrupt/invalid deb (magic=$magic)"
        return 1
    fi
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
has_git() { [ -f "$LIB_DIR/git" ] && [ -f "$LIB_DIR/git-core/git" ]; }

check_integrity() {
    local missing=""
    [ -f "$BIN_DIR/mimo.real" ] || missing="$missing mimo.real"
    [ -f "$LIB_DIR/ld-linux-aarch64.so.1" ] || missing="$missing glibc"
    [ -f "$LIB_DIR/bash" ] || missing="$missing bash"
    [ -f "$LIB_DIR/python3.13.bin" ] || missing="$missing python3"
    [ -f "$LIB_DIR/libssl.so.3" ] || missing="$missing libssl"
    [ -f "$LIB_DIR/libcrypto.so.3" ] || missing="$missing libcrypto"
    [ -f "$LIB_DIR/libzstd.so.1" ] || missing="$missing libzstd"
    [ -f "$LIB_DIR/libffi.so.8" ] || missing="$missing libffi"
    [ -f "$LIB_DIR/libsqlite3.so.0" ] || missing="$missing libsqlite3"
    [ -f "$LIB_DIR/libbz2.so.1.0" ] || missing="$missing libbz2"
    [ -f "$LIB_DIR/liblzma.so.5" ] || missing="$missing liblzma"
    [ -f "$LIB_DIR/libreadline.so.8" ] || missing="$missing libreadline"
    [ -f "$LIB_DIR/libncursesw.so.6" ] || missing="$missing libncursesw"
    [ -f "$LIB_DIR/libgdbm.so.6" ] || missing="$missing libgdbm"
    [ -f "$LIB_DIR/libgdbm_compat.so.4" ] || missing="$missing libgdbm-compat"
    [ -f "$LIB_DIR/libmagic.so.1" ] || missing="$missing libmagic"
    [ -f "$LIB_DIR/nano" ] || missing="$missing nano"
    [ -f "$LIB_DIR/less" ] || missing="$missing less"
    [ -f "$LIB_DIR/file" ] || missing="$missing file"
    [ -f "$LIB_DIR/tree" ] || missing="$missing tree"
    has_git || missing="$missing git"
    [ -f "$WRAPPER" ] || missing="$missing wrapper"
    [ -z "$missing" ]
}

do_uninstall() {
    echo ""
    printf "  ${Y}Keep user data (memory/config/pip packages)?${NC}\n"
    printf "  ${G}[1]${NC} Yes — keep data in ${HOME_DIR}\n"
    printf "  ${R}[2]${NC} No — delete everything\n"
    printf "  ${C}[3]${NC} Cancel\n"
    printf "  Select: "
    read KEEP
    case "$KEEP" in
        1) info "Uninstalling (keeping data)..."
           rm -rf "$BIN_DIR" "$LIB_DIR" "$ROOTFS" "$WRAPPER" "$CACHE" 2>/dev/null
           rm -f "$STATE" 2>/dev/null
           rm -rf "$TOOL_DIR/mimo" "$TOOL_DIR/bash" "$TOOL_DIR/python3" "$TOOL_DIR/git" 2>/dev/null
           rm -rf "$TOOL_DIR/nano" "$TOOL_DIR/less" "$TOOL_DIR/file" "$TOOL_DIR/tree" 2>/dev/null
           rm -rf /data/local/.mimo-cache /data/local/.mimo-proot-cache 2>/dev/null
           rm -rf /data/adb/modules/mimo /data/adb/mimocode 2>/dev/null
           rm -f /data/adb/ksu/bin/mimo /data/adb/ksu/bin/bash /data/adb/ksu/bin/python3 /data/adb/ksu/bin/git 2>/dev/null
           ok "Uninstalled (data preserved in ${HOME_DIR})"
           ;;
        2) info "Uninstalling (deleting everything)..."
           rm -rf "$INSTALL_DIR" "$WRAPPER" "$CACHE" 2>/dev/null
           rm -rf "$TOOL_DIR/mimo" "$TOOL_DIR/bash" "$TOOL_DIR/python3" "$TOOL_DIR/git" 2>/dev/null
           rm -rf "$TOOL_DIR/nano" "$TOOL_DIR/less" "$TOOL_DIR/file" "$TOOL_DIR/tree" 2>/dev/null
           rm -rf /data/local/.mimo-cache /data/local/.mimo-proot-cache 2>/dev/null
           rm -rf /data/adb/modules/mimo /data/adb/mimocode 2>/dev/null
           rm -f /data/adb/ksu/bin/mimo /data/adb/ksu/bin/bash /data/adb/ksu/bin/python3 /data/adb/ksu/bin/git 2>/dev/null
           ok "Uninstalled. Reboot to clear KSU mounts."
           ;;
        *) echo "Cancelled"; exit 0 ;;
    esac
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
    printf "  ${G}[1]${NC} Update/Repair to latest (preserves data)\n"
    printf "  ${C}[2]${NC} Install/Repair git only\n"
    printf "  ${R}[3]${NC} Uninstall\n"
    printf "  ${C}[4]${NC} Exit\n"
    echo ""
    printf "  Select: "
    read CHOICE
    case "$CHOICE" in
        1) UPDATE_MODE=1; has_git || do_fix_git; return 1 ;;
        2) do_fix_git; exit 0 ;;
        3) do_uninstall ;;
        *) exit 0 ;;
    esac
}

do_fix_git() {
    echo ""
    if has_git; then
        ok "git already installed: $(cd "$LIB_DIR" && ./ld-linux-aarch64.so.1 --library-path . ./git --version 2>/dev/null)"
        return 0
    fi
    info "Installing git..."
    mkdir -p "$CACHE"

    # Download git + all deps
    GIT_DEBS="
git|g/git/git_2.39.5-0+deb12u3_arm64.deb|git
libcurl3|c/curl/libcurl3-gnutls_7.88.1-10+deb12u14_arm64.deb|libcurl3
libssh2|l/libssh2/libssh2-1_1.10.0-3+b1_arm64.deb|libssh2
libpsl|l/libpsl/libpsl5_0.21.2-1_arm64.deb|libpsl
libpcre2|p/pcre2/libpcre2-8-0_10.42-1_arm64.deb|libpcre2
libnghttp2|n/nghttp2/libnghttp2-14_1.52.0-1+deb12u3_arm64.deb|libnghttp2
librtmp|r/rtmpdump/librtmp1_2.4+20151223.gitfa8646d.1-2+b2_arm64.deb|librtmp
libbrotli|b/brotli/libbrotli1_1.0.9-2+b2_arm64.deb|libbrotli
libgnutls|g/gnutls/libgnutls30_3.7.9-2+deb12u3_arm64.deb|libgnutls
libtasn1|l/libtasn1-6/libtasn1-6_4.19.0-3+deb12u1_arm64.deb|libtasn1
libp11kit|p/p11-kit/libp11-kit0_0.24.1-2_arm64.deb|libp11kit
libidn2|l/libidn2/libidn2-0_2.3.7-2+deb12u1_arm64.deb|libidn2
libunistring|l/libunistring/libunistring2_1.0-2_arm64.deb|libunistring
libgmp|g/gmp/libgmp10_6.2.1+dfsg-2+deb12u1_arm64.deb|libgmp
libnettle|n/nettle/libnettle8_3.8.1-2_arm64.deb|libnettle
libhogweed|n/nettle/libhogweed6_3.8.1-2_arm64.deb|libhogweed
libgssapi|k/krb5/libgssapi-krb5-2_1.20.1-2+deb12u4_arm64.deb|libgssapi
libkrb5|k/krb5/libkrb5-3_1.20.1-2+deb12u4_arm64.deb|libkrb5
libk5crypto|k/krb5/libk5crypto3_1.20.1-2+deb12u4_arm64.deb|libk5crypto
libkrb5support|k/krb5/libkrb5support0_1.20.1-2+deb12u4_arm64.deb|libkrb5support
libcomerr|e/e2fsprogs/libcom-err2_1.46.2-2_arm64.deb|libcomerr
libsasl2|c/cyrus-sasl2/libsasl2-2_2.1.28+dfsg-10_arm64.deb|libsasl2
libldap|o/openldap/libldap-2.5-0_2.5.13+dfsg-5_arm64.deb|libldap
libkeyutils|k/keyutils/libkeyutils1_1.6.3-2_arm64.deb|libkeyutils"
    echo "$GIT_DEBS" | while IFS='|' read -r name path file; do
        [ -z "$name" ] && continue
        if [ -f "$CACHE/${file}.deb" ] && [ -s "$CACHE/${file}.deb" ]; then
            local magic=$(dd if="$CACHE/${file}.deb" bs=8 count=1 2>/dev/null)
            if [ "$magic" = "!<arch>" ]; then
                ok "  $name (cached)"
                continue
            fi
            warn "  $name cached deb corrupt, re-downloading..."
        fi
        dl "${DEBIAN_MIRROR}/${path}" "$CACHE/${file}.deb" "$name" || \
            dl "${DEBIAN_DEB}/${path}" "$CACHE/${file}.deb" "$name (alt)" || \
            warn "  $name download failed"
    done

    # Extract git
    extract_deb_libs "$CACHE/git.deb" "git" "$CACHE"
    GIT_BIN=$(find "$CACHE/_tmp_git" -path "*/bin/git" -type f 2>/dev/null | head -1)
    [ -n "$GIT_BIN" ] && [ -s "$GIT_BIN" ] && {
        cp -f "$GIT_BIN" "$LIB_DIR/git"; chmod 755 "$LIB_DIR/git"
        mkdir -p "$LIB_DIR/git-core"
        cp -f "$CACHE/_tmp_git/usr/lib/git-core/"* "$LIB_DIR/git-core/" 2>/dev/null
        chmod 755 "$LIB_DIR/git-core/"* 2>/dev/null
        ok "  git binary"
    } || { warn "  git binary not found"; return 1; }

    # Extract git deps
    echo "$GIT_DEBS" | while IFS='|' read -r name path file; do
        [ "$file" = "git" ] && continue
        [ -f "$CACHE/${file}.deb" ] || continue
        extract_deb_libs "$CACHE/${file}.deb" "$file" "$CACHE"
        find "$CACHE/_tmp_${file}" -name "*.so*" -type f 2>/dev/null | while read -r f; do
            cp -f "$f" "$LIB_DIR/" 2>/dev/null
            chmod 755 "$LIB_DIR/$(basename "$f")"
        done
    done

    # Fix symlinks
    cd "$LIB_DIR" 2>/dev/null
    for f in *.so.*; do
        [ -L "$f" ] && continue; [ ! -f "$f" ] && continue
        echo "$f" | grep -qE '\.so\.[0-9]+\.[0-9]+(\.[0-9]+)?$' || continue
        MAJOR=$(echo "$f" | sed 's/\.so\.\([0-9]*\).*/\.so.\1/')
        [ ! -e "$MAJOR" ] && ln -sf "$f" "$MAJOR" 2>/dev/null
    done
    [ ! -e "$LIB_DIR/libresolv.so.2" ] && ln -sf libc.so.6 "$LIB_DIR/libresolv.so.2" 2>/dev/null
    ok "  git deps"

    # Proot wrapper
    cat > "$BIN_DIR/git" << WEOF
#!/system/bin/sh
D=${INSTALL_DIR}
R=\$D/rootfs
export HOME=\$D/home
export GIT_EXEC_PATH=/lib/git-core
export GIT_TEMPLATE_DIR=/lib/git-templates
export SSL_CERT_FILE=\$R/etc/ssl/certs/ca-certificates.crt
cd "\$(pwd 2>/dev/null || echo \$D)" 2>/dev/null || cd \$D
exec "\$D/lib/proot" \\
  -b "\$D/lib:/lib" \\
  -b "\$R/etc/resolv.conf:/etc/resolv.conf" \\
  -b "\$R/etc/hosts:/etc/hosts" \\
  -b "\$R/etc/nsswitch.conf:/etc/nsswitch.conf" \\
  -b "\$R/etc/ssl:/etc/ssl" \\
  -w "\$(pwd)" \\
  "\$D/lib/ld-linux-aarch64.so.1" --library-path "\$D/lib" "\$D/lib/git" "\$@"
WEOF
    chmod 755 "$BIN_DIR/git"

    # KSU bin + module shortcuts
    if [ -d /data/adb/ksu/bin ]; then
        cat > /data/adb/ksu/bin/git << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/git "\$@"
WEOF
        chmod 755 /data/adb/ksu/bin/git 2>/dev/null
    fi
    if [ "$ROOT_METHOD" != "unknown" ] && [ -d /data/adb/modules/mimo/system/bin ]; then
        cat > /data/adb/modules/mimo/system/bin/git << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/git "\$@"
WEOF
        chmod 755 /data/adb/modules/mimo/system/bin/git 2>/dev/null
    fi

    rm -rf "$CACHE"
    ok "git installed: $(cd "$LIB_DIR" && ./ld-linux-aarch64.so.1 --library-path . ./git --version 2>/dev/null)"
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
echo " /  _____  \ |  |\  \__. |  |____       |  '--'  |       |  '--'  | |  .  \  |__|"
echo "/__/     \__\| _| \____| |_______|       \______/         \______/  |__|\__\ (__)"
echo "---------------------------------------------------------------------------------"
printf "${NC}"
echo "  MiMo Code for Android Installer"
echo ""

START_TIME=$(date +%s)

# ---------- Pre-checks ----------
[ "$(id -u)" = "0" ] || err "ROOT required"
is_installed && do_menu || true
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
    # 使用更稳健的方式获取最新版本（|| true 防止 set -e 下 curl 失败导致脚本退出）
    RESPONSE=$(curl -s $CURL_PROXY --connect-timeout 10 --max-time 15 "https://api.github.com/repos/${MIMO_REPO}/releases/latest" 2>/dev/null || true)
    
    # 尝试多种方式解析tag_name
    if [ -n "$RESPONSE" ]; then
        # 方法1: 使用grep提取tag_name字段
        MIMO_VER=$(echo "$RESPONSE" | grep -o '"tag_name":"v[^"]*"' | head -1 | sed 's/"tag_name":"v//;s/"//')
        
        # 方法2: 如果方法1失败，尝试直接grep v版本号
        if [ -z "$MIMO_VER" ]; then
            MIMO_VER=$(echo "$RESPONSE" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/v//')
        fi
    fi
    
    # 调试输出：显示获取的版本
    if [ -n "$MIMO_VER" ]; then
        ok "Latest version detected: v${MIMO_VER}"
    else
        warn "Failed to fetch latest version, using default 0.1.1"
        MIMO_VER="0.1.1"
    fi
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
echo "    - git (glibc + proot)"
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
if [ "$UPDATE_MODE" = "1" ]; then
    info "Updating MiMo binary (preserving runtime & data)..."
    rm -rf "$BIN_DIR/mimo.real" "$CACHE" 2>/dev/null
else
    info "Cleaning old files..."
    rm -rf "$INSTALL_DIR" "$WRAPPER" "$TOOL_DIR/mimo" "$TOOL_DIR/bash" "$TOOL_DIR/python3" "$CACHE" /data/adb/mimocode /data/local/.mimo-cache /data/local/.mimo-proot-cache 2>/dev/null
fi
mkdir -p "$BIN_DIR" "$LIB_DIR" "$CACHE" "$HOME_DIR/.local/share/mimocode" "$HOME_DIR/.config/mimocode" "$HOME_DIR/.cache/mimocode"
ok "Ready"

# In update mode, skip steps 1-4 (glibc/bash/python3/tools/proot unchanged)
if [ "$UPDATE_MODE" != "1" ]; then








# ============================================================
# Parallel Download Dependencies
# ============================================================
echo ""
info "Downloading dependencies (parallel + auto-resolve)..."

download_deps_parallel() {
    local pids=""
    local count=0

    while IFS=',' read -r name path_prefix regex file_out; do
        [ -z "$name" ] && continue
        
        if [ -s "$CACHE/${file_out}.deb" ] && [ "$(dd if="$CACHE/${file_out}.deb" bs=8 count=1 2>/dev/null)" = "!<arch>" ]; then
            ok "  $name (cached)"
            continue
        fi
        
        (
            # Resolve latest version
            local url_base="$DEBIAN_MIRROR"
            local html=$(curl -sL $CURL_PROXY --connect-timeout 10 --max-time 15 --retry 3 "$url_base/$path_prefix/" 2>/dev/null)
            local deb=$(echo "$html" | grep -oE "$regex" | grep -v "\-dbg" | grep -v "\-dev" | grep -v "udeb" | sort -V | tail -1)
            deb="${deb%%.deb*}.deb"
            
            if [ -z "$deb" ] || [ "$deb" = ".deb" ]; then
                url_base="$DEBIAN_DEB"
                html=$(curl -sL $CURL_PROXY --connect-timeout 10 --max-time 15 --retry 3 "$url_base/$path_prefix/" 2>/dev/null)
                deb=$(echo "$html" | grep -oE "$regex" | grep -v "\-dbg" | grep -v "\-dev" | grep -v "udeb" | sort -V | tail -1)
                deb="${deb%%.deb*}.deb"
            fi
            
            if [ -z "$deb" ] || [ "$deb" = ".deb" ]; then
                exit 1
            fi
            
            local url="$url_base/$path_prefix/$deb"
            curl -sL $CURL_PROXY --connect-timeout 20 --max-time 600 --retry 3 -o "$CACHE/${file_out}.deb" "$url" 2>/dev/null
            if [ $? -ne 0 ] || [ ! -s "$CACHE/${file_out}.deb" ]; then
                if [ "$url_base" != "$DEBIAN_DEB" ]; then
                    url="$DEBIAN_DEB/$path_prefix/$deb"
                    curl -sL $CURL_PROXY --connect-timeout 20 --max-time 600 --retry 3 -o "$CACHE/${file_out}.deb" "$url" 2>/dev/null
                fi
            fi
            
            local magic=$(dd if="$CACHE/${file_out}.deb" bs=8 count=1 2>/dev/null)
            if [ "$magic" != "!<arch>" ]; then
                rm -f "$CACHE/${file_out}.deb" 2>/dev/null
                exit 1
            fi
            exit 0
        ) &
        
        local cpid=$!
        pids="$pids $cpid"
        echo "$name" > "$CACHE/.pid_$cpid"
        count=$((count+1))
        
        sleep 0.05
    done << 'EOF_DEPS'
libc6,g/glibc,libc6_[^"]+_arm64\.deb,libc6
libstdc++,g/gcc-14,libstdc\+\+6_[^"]+_arm64\.deb,libstdcpp
libgcc,g/gcc-14,libgcc-s1_[^"]+_arm64\.deb,libgcc
bash,b/bash,bash_[^"]+_arm64\.deb,bash
libtinfo,n/ncurses,libtinfo6_[^"]+_arm64\.deb,libtinfo
python3,p/python3.13,python3.13-minimal_[^"]+_arm64\.deb,python3
libpython-min,p/python3.13,libpython3.13-minimal_[^"]+_arm64\.deb,libpython-min
libpython-std,p/python3.13,libpython3.13-stdlib_[^"]+_arm64\.deb,libpython-std
zlib,z/zlib,zlib1g_[^"]+_arm64\.deb,zlib
libexpat,e/expat,libexpat1_[^"]+_arm64\.deb,expat
libssl,o/openssl,libssl3t64_[^"]+_arm64\.deb,libssl
libzstd,libz/libzstd,libzstd1_[^"]+_arm64\.deb,libzstd
libffi,libf/libffi,libffi8_[^"]+_arm64\.deb,libffi
libsqlite3,s/sqlite3,libsqlite3-0_[^"]+_arm64\.deb,libsqlite3
libbz2,b/bzip2,libbz2-1.0_[^"]+_arm64\.deb,libbz2
liblzma,x/xz-utils,liblzma5_[^"]+_arm64\.deb,liblzma
libreadline,r/readline,libreadline8t64_[^"]+_arm64\.deb,libreadline
libncursesw,n/ncurses,libncursesw6_[^"]+_arm64\.deb,libncursesw
libgdbm,g/gdbm,libgdbm6_[^"]+_arm64\.deb,libgdbm
libgdbm-compat,g/gdbm,libgdbm-compat4t64_[^"]+_arm64\.deb,libgdbmc
libmagic,f/file,libmagic1t64_[^"]+_arm64\.deb,libmagic
libmagic-mgc,f/file,libmagic-mgc_[^"]+_(arm64|all)\.deb,libmagic-mgc
pip,p/python-pip,python3-pip_[^"]+_all\.deb,pip
nano,n/nano,nano_[^"]+_arm64\.deb,nano
less,l/less,less_[^"]+_arm64\.deb,less
file,f/file,file_[^"]+_arm64\.deb,file
tree,t/tree,tree_[^"]+_arm64\.deb,tree
git,g/git,git_[^"]+_arm64\.deb,git
libcurl3,c/curl,libcurl3t64-gnutls_[^"]+_arm64\.deb,libcurl3
libssh2,libs/libssh2,libssh2-1[^"]*_arm64\.deb,libssh2
libpsl,libp/libpsl,libpsl5[^"]*_arm64\.deb,libpsl
libpcre2,p/pcre2,libpcre2-8-0_[^"]+_arm64\.deb,libpcre2
libnghttp2,n/nghttp2,libnghttp2-14_[^"]+_arm64\.deb,libnghttp2
librtmp,r/rtmpdump,librtmp1_[^"]+_arm64\.deb,librtmp
libbrotli,b/brotli,libbrotli1_[^"]+_arm64\.deb,libbrotli
libgnutls,g/gnutls28,libgnutls30[^"]*_arm64\.deb,libgnutls
libtasn1,libt/libtasn1-6,libtasn1-6_[^"]+_arm64\.deb,libtasn1
libp11kit,p/p11-kit,libp11-kit0_[^"]+_arm64\.deb,libp11kit
libidn2,libi/libidn2,libidn2-0_[^"]+_arm64\.deb,libidn2
libunistring,libu/libunistring,libunistring[0-9]+_[^"]+_arm64\.deb,libunistring
libgmp,g/gmp,libgmp10_[^"]+_arm64\.deb,libgmp
libnettle,n/nettle,libnettle[0-9]+[^"]*_arm64\.deb,libnettle
libhogweed,n/nettle,libhogweed[0-9]+[^"]*_arm64\.deb,libhogweed
libgssapi,k/krb5,libgssapi-krb5-2_[^"]+_arm64\.deb,libgssapi
libkrb5,k/krb5,libkrb5-3_[^"]+_arm64\.deb,libkrb5
libk5crypto,k/krb5,libk5crypto3_[^"]+_arm64\.deb,libk5crypto
libkrb5support,k/krb5,libkrb5support0_[^"]+_arm64\.deb,libkrb5support
libcomerr,e/e2fsprogs,libcom-err2_[^"]+_arm64\.deb,libcomerr
libsasl2,c/cyrus-sasl2,libsasl2-2_[^"]+_arm64\.deb,libsasl2
libldap,o/openldap,libldap-2.5-0_[^"]+_arm64\.deb,libldap
libkeyutils,k/keyutils,libkeyutils1_[^"]+_arm64\.deb,libkeyutils
EOF_DEPS
    
    if [ $count -gt 0 ]; then
        info "  Waiting for $count downloads to complete..."
        local has_err=0
        for pid in $pids; do
            local name=$(cat "$CACHE/.pid_$pid" 2>/dev/null)
            if wait $pid; then
                ok "  $name"
            else
                warn "  $name (failed to resolve or download)"
                has_err=1
            fi
            rm -f "$CACHE/.pid_$pid"
        done
        if [ $has_err -ne 0 ]; then
            error "Some dependencies failed to download."
            exit 1
        fi
    fi
}

download_deps_parallel

# ============================================================
# 3. Extract & install
# ============================================================
echo ""
info "[3/5] Extracting..."

# --- glibc ---
for file in "libc6" "libstdcpp" "libgcc"; do
    if [ -f "$CACHE/${file}.deb" ]; then
        if extract_deb_libs "$CACHE/${file}.deb" "$file" "$CACHE"; then
            ok "  $file"
        else
            # Retry from official Debian mirror
            case "$file" in
                libc6)   retry_path="g/glibc/libc6_${GLIBC_VER}_arm64.deb" ;;
                libstdcpp) retry_path="g/gcc-14/libstdc++6_${GCC_VER}_arm64.deb" ;;
                libgcc)  retry_path="g/gcc-14/libgcc-s1_${GCC_VER}_arm64.deb" ;;
            esac
            warn "  $file: retrying from Debian official..."
            dl "${DEBIAN_DEB}/${retry_path}" "$CACHE/${file}.deb" "$file (retry)" && \
                extract_deb_libs "$CACHE/${file}.deb" "$file" "$CACHE" && ok "  $file" || warn "  $file failed"
        fi
    else
        warn "  $file deb not found"
    fi
done

SRC=""
LD_FILE=$(find "$CACHE/_tmp_libc6" -name "ld-linux-aarch64.so.1" 2>/dev/null | head -1)
if [ -n "$LD_FILE" ]; then
    SRC=$(dirname "$LD_FILE")
fi
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
    err "glibc not found (download or extraction failed) - aborting."
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

# --- libssl (OpenSSL - required for Python HTTPS/pip) ---
if [ -f "$CACHE/libssl.deb" ]; then
    extract_deb_libs "$CACHE/libssl.deb" "libssl" "$CACHE"
    f=$(find "$CACHE/_tmp_libssl" -name "libssl.so.3*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libssl.so.3"; chmod 755 "$LIB_DIR/libssl.so.3"; }
    f=$(find "$CACHE/_tmp_libssl" -name "libcrypto.so.3*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libcrypto.so.3"; chmod 755 "$LIB_DIR/libcrypto.so.3"; }
    ok "  libssl (OpenSSL)"
fi

# --- libzstd (OpenSSL compression dependency) ---
if [ -f "$CACHE/libzstd.deb" ]; then
    extract_deb_libs "$CACHE/libzstd.deb" "libzstd" "$CACHE"
    f=$(find "$CACHE/_tmp_libzstd" -name "libzstd.so.1*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libzstd.so.1"; chmod 755 "$LIB_DIR/libzstd.so.1"; ok "  libzstd"; } || warn "  libzstd not found"
fi

# --- libffi (ctypes dependency) ---
if [ -f "$CACHE/libffi.deb" ]; then
    extract_deb_libs "$CACHE/libffi.deb" "libffi" "$CACHE"
    f=$(find "$CACHE/_tmp_libffi" -name "libffi.so.8*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libffi.so.8"; chmod 755 "$LIB_DIR/libffi.so.8"; ok "  libffi"; } || warn "  libffi not found"
fi

# --- libsqlite3 (sqlite3 dependency) ---
if [ -f "$CACHE/libsqlite3.deb" ]; then
    extract_deb_libs "$CACHE/libsqlite3.deb" "libsqlite3" "$CACHE"
    f=$(find "$CACHE/_tmp_libsqlite3" -name "libsqlite3.so.3*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libsqlite3.so.0"; chmod 755 "$LIB_DIR/libsqlite3.so.0"; ok "  libsqlite3"; } || warn "  libsqlite3 not found"
fi

# --- libbz2 (bz2 module) ---
if [ -f "$CACHE/libbz2.deb" ]; then
    extract_deb_libs "$CACHE/libbz2.deb" "libbz2" "$CACHE"
    f=$(find "$CACHE/_tmp_libbz2" -name "libbz2.so.1.0*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libbz2.so.1.0"; chmod 755 "$LIB_DIR/libbz2.so.1.0"; ok "  libbz2"; } || warn "  libbz2 not found"
fi

# --- liblzma (lzma module) ---
if [ -f "$CACHE/liblzma.deb" ]; then
    extract_deb_libs "$CACHE/liblzma.deb" "liblzma" "$CACHE"
    f=$(find "$CACHE/_tmp_liblzma" -name "liblzma.so.5*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/liblzma.so.5"; chmod 755 "$LIB_DIR/liblzma.so.5"; ok "  liblzma"; } || warn "  liblzma not found"
fi

# --- libreadline (readline module) ---
if [ -f "$CACHE/libreadline.deb" ]; then
    extract_deb_libs "$CACHE/libreadline.deb" "libreadline" "$CACHE"
    f=$(find "$CACHE/_tmp_libreadline" -name "libreadline.so.8*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libreadline.so.8"; chmod 755 "$LIB_DIR/libreadline.so.8"; ok "  libreadline"; } || warn "  libreadline not found"
fi

# --- libncursesw (curses module / readline dep) ---
if [ -f "$CACHE/libncursesw.deb" ]; then
    extract_deb_libs "$CACHE/libncursesw.deb" "libncursesw" "$CACHE"
    f=$(find "$CACHE/_tmp_libncursesw" -name "libncursesw.so.6*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libncursesw.so.6"; chmod 755 "$LIB_DIR/libncursesw.so.6"; ok "  libncursesw"; } || warn "  libncursesw not found"
fi

# --- libgdbm (dbm module) ---
if [ -f "$CACHE/libgdbm.deb" ]; then
    extract_deb_libs "$CACHE/libgdbm.deb" "libgdbm" "$CACHE"
    f=$(find "$CACHE/_tmp_libgdbm" -name "libgdbm.so.6*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libgdbm.so.6"; chmod 755 "$LIB_DIR/libgdbm.so.6"; ok "  libgdbm"; } || warn "  libgdbm not found"
fi

# --- libgdbm-compat (dbm.gnu / gdbm module) ---
if [ -f "$CACHE/libgdbmc.deb" ]; then
    extract_deb_libs "$CACHE/libgdbmc.deb" "libgdbmc" "$CACHE"
    f=$(find "$CACHE/_tmp_libgdbmc" -name "libgdbm_compat.so.4*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libgdbm_compat.so.4"; chmod 755 "$LIB_DIR/libgdbm_compat.so.4"; ok "  libgdbm-compat"; } || warn "  libgdbm-compat not found"
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

# --- tools (nano, less, file, tree) ---
for tool in nano less file tree; do
    if [ -f "$CACHE/${tool}.deb" ]; then
        extract_deb_libs "$CACHE/${tool}.deb" "$tool" "$CACHE"
        BIN=$(find "$CACHE/_tmp_${tool}" -name "$tool" -type f 2>/dev/null | head -1)
        [ -n "$BIN" ] && [ -s "$BIN" ] && { cp -f "$BIN" "$LIB_DIR/${tool}"; chmod 755 "$LIB_DIR/${tool}"; ok "  $tool"; } || warn "  $tool not found"
    fi
done

# libmagic (file command dependency)
if [ -f "$CACHE/libmagic.deb" ]; then
    extract_deb_libs "$CACHE/libmagic.deb" "libmagic" "$CACHE"
    f=$(find "$CACHE/_tmp_libmagic" -name "libmagic.so.1*" -type f 2>/dev/null | head -1)
    [ -n "$f" ] && [ -s "$f" ] && { cp -f "$f" "$LIB_DIR/libmagic.so.1"; chmod 755 "$LIB_DIR/libmagic.so.1"; ok "  libmagic"; } || warn "  libmagic not found"
fi

# file magic database
if [ -f "$CACHE/libmagic-mgc.deb" ]; then
    extract_deb_libs "$CACHE/libmagic-mgc.deb" "magic-mgc" "$CACHE"
    MAGIC=$(find "$CACHE/_tmp_magic-mgc" -name "magic.mgc" -type f 2>/dev/null | head -1)
    [ -n "$MAGIC" ] && { cp -f "$MAGIC" "$LIB_DIR/magic.mgc"; ok "  magic.mgc"; } || warn "  magic.mgc not found"
fi

# --- git ---
if [ -f "$CACHE/git.deb" ]; then
    extract_deb_libs "$CACHE/git.deb" "git" "$CACHE"
    GIT_BIN=$(find "$CACHE/_tmp_git" -path "*/bin/git" -type f 2>/dev/null | head -1)
    [ -n "$GIT_BIN" ] && [ -s "$GIT_BIN" ] && {
        cp -f "$GIT_BIN" "$LIB_DIR/git"; chmod 755 "$LIB_DIR/git"
        mkdir -p "$LIB_DIR/git-core"
        cp -f "$CACHE/_tmp_git/usr/lib/git-core/"* "$LIB_DIR/git-core/" 2>/dev/null
        chmod 755 "$LIB_DIR/git-core/"* 2>/dev/null
        ok "  git (glibc)"
    } || warn "  git not found"
fi

# --- git deps (bulk extract) ---
for dep in libcurl3 libssh2 libpsl libpcre2 libnghttp2 librtmp libbrotli \
           libgnutls libtasn1 libp11kit libidn2 libunistring libgmp \
           libnettle libhogweed libgssapi libkrb5 libk5crypto libkrb5support \
           libcomerr libsasl2 libldap libkeyutils; do
    [ -f "$CACHE/${dep}.deb" ] || continue
    extract_deb_libs "$CACHE/${dep}.deb" "$dep" "$CACHE"
    find "$CACHE/_tmp_${dep}" -name "*.so*" -type f 2>/dev/null | while read -r f; do
        cp -f "$f" "$LIB_DIR/" 2>/dev/null
        chmod 755 "$LIB_DIR/$(basename "$f")"
    done
done
# fix symlinks
cd "$LIB_DIR" 2>/dev/null
for f in *.so.*; do
    [ -L "$f" ] && continue; [ ! -f "$f" ] && continue
    echo "$f" | grep -qE '\.so\.[0-9]+\.[0-9]+(\.[0-9]+)?$' || continue
    MAJOR=$(echo "$f" | sed 's/\.so\.\([0-9]*\).*/\.so.\1/')
    [ ! -e "$MAJOR" ] && ln -sf "$f" "$MAJOR" 2>/dev/null
done
[ ! -e "$LIB_DIR/libresolv.so.2" ] && ln -sf libc.so.6 "$LIB_DIR/libresolv.so.2" 2>/dev/null

# ============================================================
# 4. proot + rootfs (DNS / SSL / NSS for glibc)
# ============================================================
echo ""
info "[4/6] proot + minimal rootfs..."

PROOT_VER="5.3.0"
PROOT_URL="https://github.com/proot-me/proot/releases/download/v${PROOT_VER}/proot-v${PROOT_VER}-aarch64-static"

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

fi  # end of update-mode skip (steps 1-4)

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
export SSL_CERT_FILE=\$R/etc/ssl/certs/ca-certificates.crt
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
rm -rf /data/local/tmp/mimo /data/local/tmp/bash /data/local/tmp/python3 /data/local/tmp/git
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
export SSL_CERT_FILE="${ROOTFS}/etc/ssl/certs/ca-certificates.crt"
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/python3.13 "\$@"
WEOF
    chmod 755 "/data/adb/modules/mimo/system/bin/python3"
    # git wrapper in module
    if has_git; then
        cat > "/data/adb/modules/mimo/system/bin/git" << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/git "\$@"
WEOF
        chmod 755 "/data/adb/modules/mimo/system/bin/git"
    fi
    restorecon -R /data/adb/modules/mimo 2>/dev/null || true
    ok "  systemless module (mimo/bash/python3/git after reboot)"
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
export SSL_CERT_FILE="${ROOTFS}/etc/ssl/certs/ca-certificates.crt"
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/python3.13 "\$@"
WEOF
chmod 755 "$TOOL_DIR/python3"

# Tool wrappers (nano, less, file, tree)
for tool in nano less tree; do
    cat > "$TOOL_DIR/${tool}" << WEOF
#!/system/bin/sh
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/${tool} "\$@"
WEOF
    chmod 755 "$TOOL_DIR/${tool}"
done

# file needs MAGIC path
cat > "$TOOL_DIR/file" << WEOF
#!/system/bin/sh
export MAGIC=${LIB_DIR}/magic.mgc
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/file "\$@"
WEOF
chmod 755 "$TOOL_DIR/file"

# git proot wrapper (needs proot for deep deps)
if has_git; then
    cat > "$BIN_DIR/git" << WEOF
#!/system/bin/sh
D=${INSTALL_DIR}
R=\$D/rootfs
export HOME=\$D/home
export GIT_EXEC_PATH=/lib/git-core
export GIT_TEMPLATE_DIR=/lib/git-templates
export SSL_CERT_FILE=\$R/etc/ssl/certs/ca-certificates.crt
cd "\$(pwd 2>/dev/null || echo \$D)" 2>/dev/null || cd \$D
exec "\$D/lib/proot" \\
  -b "\$D/lib:/lib" \\
  -b "\$R/etc/resolv.conf:/etc/resolv.conf" \\
  -b "\$R/etc/hosts:/etc/hosts" \\
  -b "\$R/etc/nsswitch.conf:/etc/nsswitch.conf" \\
  -b "\$R/etc/ssl:/etc/ssl" \\
  -w "\$(pwd)" \\
  "\$D/lib/ld-linux-aarch64.so.1" --library-path "\$D/lib" "\$D/lib/git" "\$@"
WEOF
    chmod 755 "$BIN_DIR/git"
fi

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
export SSL_CERT_FILE="${ROOTFS}/etc/ssl/certs/ca-certificates.crt"
exec ${LIB_DIR}/ld-linux-aarch64.so.1 --library-path ${LIB_DIR} ${LIB_DIR}/python3.13 "\$@"
WEOF
    chmod 755 /data/adb/ksu/bin/python3 2>/dev/null
    for tool in nano less file tree; do
        cat > "/data/adb/ksu/bin/${tool}" << WEOF
#!/system/bin/sh
exec ${TOOL_DIR}/${tool} "\$@"
WEOF
        chmod 755 "/data/adb/ksu/bin/${tool}" 2>/dev/null
    done
    if has_git; then
        cat > /data/adb/ksu/bin/git << WEOF
#!/system/bin/sh
exec ${INSTALL_DIR}/bin/git "\$@"
WEOF
        chmod 755 /data/adb/ksu/bin/git 2>/dev/null
    fi
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
if [ "$UPDATE_MODE" = "1" ]; then
    echo "           Update Complete! (data preserved)"
else
    echo "           Installation Complete!"
fi
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
if has_git; then
    GIT_VER=$("$LIB_DIR/ld-linux-aarch64.so.1" --library-path "$LIB_DIR" "$LIB_DIR/git" --version 2>/dev/null | awk '{print $3}')
    printf "  %-12s  %-35s  %s\n" "git" "$LIB_DIR/git" "${GIT_VER:-?}"
fi
TOTAL_SIZE=$(du -sh "$INSTALL_DIR" 2>/dev/null | awk '{print $1}')
echo "  ----------------------------------------"
printf "  %-12s  %-35s  %s\n" "Total" "$INSTALL_DIR" "${TOTAL_SIZE:-?}"
echo ""
echo "  ${G}Usage:${NC}"
echo ""
if [ "$ROOT_METHOD" != "unknown" ]; then
    echo "  ${C}After reboot:${NC} mimo / bash / python3 / git available globally"
    echo ""
    echo "  ${C}Without reboot:${NC}"
fi
echo "    su -c '/data/local/tmp/mimo'"
echo ""
echo "  ${C}Tools:${NC}"
echo "    /data/local/tmp/bash --version"
echo "    /data/local/tmp/python3 --version"
echo "    /data/local/tmp/python3 -m pip --version"
echo "    /data/local/tmp/git --version"
echo ""
echo "  Re-run this script to update/uninstall"
echo ""
