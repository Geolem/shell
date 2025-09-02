#!/bin/bash
# 自用修改版脚本，鸣谢：https://github.com/Devmiston/sing-box

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

disable_option=false
enable_ech=false
listen_port=""
override_port=""
start_port=""
end_port=""
ip_v4=""
ip_v6=""
record_content=""
record_type=""
record_name=""
obfs_password=""
domain=""
domain_name=""
up_mbps=""
down_mbps=""
certificate_path=""
private_key_path=""
public_key=""
private_key=""
multiplex_config=""
brutal_config=""
warp_output_file=""
ech_key=()
ech_config=()
user_names=()
user_passwords=()
user_uuids=()
ss_passwords=() 
stls_passwords=()
short_ids=()

# SingBox版本控制 - 留空使用最新版本，指定版本如："1.12.4"
SINGBOX_VERSION=""

# 检查必需依赖并自动安装
function check_dependencies() {
    local missing_deps=()
    
    # 检查wget
    if ! command -v wget >/dev/null 2>&1; then
        missing_deps+=("wget")
    fi
    
    # 检查jq
    if ! command -v jq >/dev/null 2>&1; then
        missing_deps+=("jq")
    fi
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        return 0
    fi
    
    echo "检测到缺少必需依赖: ${missing_deps[*]}"
    echo "正在尝试自动安装..."
    
    # 检测包管理器并安装
    if command -v apt >/dev/null 2>&1; then
        apt update >/dev/null 2>&1
        apt install -y "${missing_deps[@]}" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${missing_deps[@]}" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${missing_deps[@]}" >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --noconfirm "${missing_deps[@]}" >/dev/null 2>&1
    else
        echo -e "${RED}未检测到支持的包管理器，请手动安装: ${missing_deps[*]}${NC}"
        exit 1
    fi
    
    # 验证安装结果
    for dep in "${missing_deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${RED}安装 $dep 失败，请手动安装${NC}"
            exit 1
        fi
    done
    
    echo -e "${GREEN}依赖安装完成${NC}"
}

# 检查防火墙以及放行端口
function check_firewall_configuration() {
    local os_name=$(uname -s)
    local firewall=""
    local ports=("$listen_port" "$override_port" 80)
    local proto_list=("tcp" "udp")

    if [[ $os_name == "Linux" ]]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
            firewall="ufw"
        elif command -v ip6tables >/dev/null 2>&1 && ip6tables -S | grep -q "INPUT -j DROP"; then
            firewall="iptables"
        elif command -v iptables >/dev/null 2>&1 && iptables -S | grep -q "INPUT -j DROP"; then
            firewall="iptables"
        elif systemctl is-active --quiet netfilter-persistent; then
            firewall="iptables"
        elif systemctl is-active --quiet iptables.service; then
            firewall="iptables"
        elif command -v firewalld >/dev/null 2>&1 && firewall-cmd --state | grep -q "running"; then
            firewall="firewalld"
        fi
    fi

    if [[ -z $firewall ]]; then
        echo "No firewall configuration detected or firewall is not enabled, skipping firewall configuration."
        return
    fi

    echo "Checking firewall configuration for: $firewall..."

    case $firewall in
        ufw)
            ufw status | grep -q "Status: active" || ufw enable >/dev/null 2>&1
            for port in "${ports[@]}"; do
                for proto in "${proto_list[@]}"; do
                    ufw status | grep -q " $port/$proto" || ufw allow "$port/$proto" >/dev/null 2>&1
                done
            done
            ;;
        iptables)
            for port in "${ports[@]}"; do
                for proto in "${proto_list[@]}"; do
                    # IPv4
                    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                        || iptables -A INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1
                    # IPv6
                    ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                        || ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1
                done
            done
            [[ -e /etc/iptables/rules.v4 ]] && iptables-save > /etc/iptables/rules.v4
            [[ -e /etc/iptables/rules.v6 ]] && ip6tables-save > /etc/iptables/rules.v6
            [[ -e /etc/sysconfig/iptables ]] && iptables-save > /etc/sysconfig/iptables
            [[ -e /etc/sysconfig/ip6tables ]] && ip6tables-save > /etc/sysconfig/ip6tables
            ;;
        firewalld)
            for port in "${ports[@]}"; do
                for proto in "${proto_list[@]}"; do
                    firewall-cmd --zone=public --list-ports | grep -q "$port/$proto" \
                        || firewall-cmd --zone=public --add-port="$port/$proto" --permanent >/dev/null 2>&1
                done
            done
            firewall-cmd --reload
            ;;
    esac

    echo "Firewall configuration has been updated."
}

# 检查sing-box所需的文件夹及配置文件
function create_sing_box_folders() {
    local folders=("/usr/local/etc/sing-box" "/etc/ssl/private")

    for folder in "${folders[@]}"; do
        if [[ ! -d "$folder" ]]; then
            mkdir -p "$folder"
            [[ "$folder" == "/usr/local/etc/sing-box" ]] && touch "$folder/config.json"
        fi
    done
}

# 检查juicity所需的文件夹及配置文件
function create_juicity_folder() {
    local folders=("/usr/local/etc/juicity" "/etc/ssl/private")

    for folder in "${folders[@]}"; do
        if [[ ! -d "$folder" ]]; then
            mkdir -p "$folder"
            [[ "$folder" == "/usr/local/etc/juicity" ]] && touch "$folder/config.json"
        fi
    done
}

# 检查clash配置文件是否存在
function ensure_clash_yaml() {
    local clash_yaml="/usr/local/etc/sing-box/clash.yaml"

    if [[ ! -e "$clash_yaml" ]]; then
        touch "$clash_yaml"
    fi
}

# 检查sing-box配置文件是否存在
function check_config_file_existence() {
    local config_file="/usr/local/etc/sing-box/config.json"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}sing-box 配置文件不存在，请先搭建节点！${NC}"
        exit 1
    fi
}

# 生成naive客户端随机文件名
function generate_naive_random_filename() {
    local dir="/usr/local/etc/sing-box"
    local filename=""

    while true; do
        random_value=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 5 | head -n 1)
        filename="naive_client_${random_value}.json"
        
        if [[ ! -e "${dir}/${filename}" ]]; then
            touch "${dir}/${filename}"
            naive_client_filename="${dir}/${filename}"
            break
        fi
    done
}

# 安装sing-box
function install_sing_box() {
    if [[ -f "/usr/local/bin/sing-box" && -f "/usr/local/etc/sing-box/config.json" ]]; then
        return 1
    else
        get_local_ip
        configure_dns64
        select_sing_box_install_option
        configure_sing_box_service
        create_sing_box_folders
    fi
}

# 配置DNS64
function configure_dns64() {
    if [[ -n $ip_v4 ]]; then
        return
    fi

    if [[ -n $ip_v6 ]]; then
        echo "Check that the machine is IPv6 single-stack network, configure DNS64..."
        sed -i '/^nameserver /s/^/#/' /etc/resolv.conf 
        echo "nameserver 2a00:1098:2b::1" >> /etc/resolv.conf
        echo "nameserver 2a01:4f9:c010:3f02::1" >> /etc/resolv.conf
        echo "nameserver 2a01:4f8:c2c:123f::1" >> /etc/resolv.conf
        echo "DNS64 configuration is complete."
    fi
}

# 配置BBR
function enable_bbr() {
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "BBR is already enabled, skipping configuration."
        return
    fi

    while true; do
        read -p "是否开启 BBR (Y/N，默认N)? " -i "N" response
        response=${response:-"N"}
        
        if [[ $response == "y" || $response == "Y" ]]; then
            echo "Enable BBR..."
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p > /dev/null
            echo "BBR has been enabled"
            break
        elif [[ $response == "n" || $response == "N" ]]; then
            echo "BBR will not be enabled."
            break
        else
            echo -e "${RED}无效的输入，请重新输入！${NC}"
        fi
    done
}

# 选择sing-box的安装方式
function select_sing_box_install_option() {
    while true; do
        echo "请选择 sing-box 的安装方式（默认1）："
        echo "1). 下载安装 sing-box（Latest 版本）"
        echo "2). 下载安装 sing-box（Beta 版本）"

        read -p "请选择 [1-2]: " install_option
        install_option="${install_option:-1}"

        case $install_option in
            1)
                install_latest_sing_box
                break
                ;;
            2)
                install_Pre_release_sing_box
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入！${NC}"
                ;;
        esac
    done
}



# 获取 sing-box 下载链接（支持版本控制）
function get_singbox_download_url() {
    local arch=$(uname -m)
    local version="$1"
    local download_url
    
    if [[ -z "$version" ]]; then
        # 原有逻辑：获取latest版本
        local url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        case $arch in
            x86_64|amd64)
                download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-amd64.tar.gz")
                ;;
            armv7l)
                download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-armv7.tar.gz")
                ;;
            aarch64|arm64)
                download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-arm64.tar.gz")
                ;;
            amd64v3)
                download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-amd64v3.tar.gz")
                ;;
            s390x)
                download_url=$(curl -s $url | grep -o "https://github.com[^\"']*linux-s390x.tar.gz")
                ;;
            *)
                echo -e "${RED}不支持的架构：$arch${NC}" >&2
                return 1
                ;;
        esac
    else
        # 固定版本逻辑：构造特定版本的下载链接
        case $arch in
            x86_64|amd64)
                download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-amd64.tar.gz"
                ;;
            armv7l)
                download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-armv7.tar.gz"
                ;;
            aarch64|arm64)
                download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-arm64.tar.gz"
                ;;
            amd64v3)
                download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-amd64v3.tar.gz"
                ;;
            s390x)
                download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-s390x.tar.gz"
                ;;
            *)
                echo -e "${RED}不支持的架构：$arch${NC}" >&2
                return 1
                ;;
        esac
    fi
    
    echo "$download_url"
}

# 安装最新版本的 sing-box
function install_latest_sing_box() {
    local download_url=$(get_singbox_download_url "$SINGBOX_VERSION")
    
    if [[ $? -ne 0 ]] || [[ -z "$download_url" ]]; then
        echo -e "${RED}无法获取下载链接${NC}"
        return 1
    fi
    
    # 对于固定版本，验证URL是否存在
    if [[ -n "$SINGBOX_VERSION" ]]; then
        if ! curl --output /dev/null --silent --head --fail "$download_url"; then
            echo -e "${RED}指定版本 $SINGBOX_VERSION 不存在或下载链接无效${NC}"
            return 1
        fi
        echo "Downloading Sing-Box version $SINGBOX_VERSION..."
    else
        echo "Downloading Sing-Box..."
    fi
    
    wget -qO sing-box.tar.gz "$download_url" 2>&1 >/dev/null
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}下载失败${NC}"
        return 1
    fi
    
    tar -xzf sing-box.tar.gz -C /usr/local/bin --strip-components=1
    rm sing-box.tar.gz
    chmod +x /usr/local/bin/sing-box
    echo "Sing-Box installed successfully."
}

# 安装预发布版本的 sing-box
function install_Pre_release_sing_box() {
    local arch=$(uname -m)
    local url="https://api.github.com/repos/SagerNet/sing-box/releases"
    local download_url
    
    case $arch in
        x86_64|amd64)
            download_url=$(curl -s "$url" | jq -r '.[] | select(.prerelease == true) | .assets[] | select(.browser_download_url | contains("linux-amd64.tar.gz")) | .browser_download_url' | head -n 1)
            ;;
        armv7l)
            download_url=$(curl -s "$url" | jq -r '.[] | select(.prerelease == true) | .assets[] | select(.browser_download_url | contains("linux-armv7.tar.gz")) | .browser_download_url' | head -n 1)
            ;;
        aarch64|arm64)
            download_url=$(curl -s "$url" | jq -r '.[] | select(.prerelease == true) | .assets[] | select(.browser_download_url | contains("linux-arm64.tar.gz")) | .browser_download_url' | head -n 1)
            ;;
        amd64v3)
            download_url=$(curl -s "$url" | jq -r '.[] | select(.prerelease == true) | .assets[] | select(.browser_download_url | contains("linux-amd64v3.tar.gz")) | .browser_download_url' | head -n 1)
            ;;
        s390x)
            download_url=$(curl -s "$url" | jq -r '.[] | select(.prerelease == true) | .assets[] | select(.browser_download_url | contains("linux-s390x.tar.gz")) | .browser_download_url' | head -n 1)
            ;;
        *)
            echo -e "${RED}不支持的架构：$arch${NC}"
            return 1
            ;;
    esac
    
    if [[ -n "$download_url" ]]; then
        echo "Downloading Sing-Box..."
        wget -qO sing-box.tar.gz "$download_url" 2>&1 >/dev/null
        tar -xzf sing-box.tar.gz -C /usr/local/bin --strip-components=1
        rm sing-box.tar.gz
        chmod +x /usr/local/bin/sing-box
        
        echo "Sing-Box installed successfully."
    else
        echo -e "${RED}Unable to get pre-release download link for Sing-Box.${NC}"
        return 1
    fi
}

# 安装最新版本的 juicity
function install_latest_juicity() {
    local arch=$(uname -m)

    case $arch in
        "arm64")
            arch_suffix="arm64"
            ;;
        "armv5")
            arch_suffix="armv5"
            ;;
        "armv6")
            arch_suffix="armv6"
            ;;
        "armv7")
            arch_suffix="armv7"
            ;;
        "mips")
            arch_suffix="mips32"
            ;;
        "mipsel")
            arch_suffix="mips32le"
            ;;
        "mips64")
            arch_suffix="mips64"
            ;;
        "mips64el")
            arch_suffix="mips64le"
            ;;
        "riscv64")
            arch_suffix="riscv64"
            ;;
        "i686")
            arch_suffix="x86_32"
            ;;
        "x86_64")
            if [[ -n "$(grep avx2 /proc/cpuinfo)" ]]; then
                arch_suffix="x86_64_v3_avx2"
            else
                arch_suffix="x86_64_v2_sse"
            fi
            ;;
        *)
            echo "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    local github_api_url="https://api.github.com/repos/juicity/juicity/releases/latest"
    local download_url=$(curl -s "$github_api_url" | grep "browser_download_url.*$arch_suffix.zip\"" | cut -d '"' -f 4)
    local temp_dir=$(mktemp -d)
    local install_path="/usr/local/bin/juicity-server"

    echo "Downloading the latest version of juicity-server..."
    wget -P "$temp_dir" "$download_url" >/dev/null 2>&1
    unzip "$temp_dir/*.zip" -d "$temp_dir" >/dev/null 2>&1    
    mv "$temp_dir/juicity-server" "$install_path" >/dev/null 2>&1
    chmod +x /usr/local/bin/juicity-server

    echo "juicity-server has been downloaded."    
    rm -rf "$temp_dir"
}

# 配置 sing-box 启动服务
function configure_sing_box_service() {
    echo "Configuring sing-box startup service..."

    local service_file="/etc/systemd/system/sing-box.service"
    if [[ -f $service_file ]]; then
        rm "$service_file"
    fi

    local service_config='[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target'

    echo "$service_config" >"$service_file"
    echo "sing-box startup service has been configured."
}

# 配置 juicity 启动服务
function configure_juicity_service() {
    echo "Configuring juicity startup service..."

    local service_file="/etc/systemd/system/juicity.service"
    if [[ -f $service_file ]]; then
        rm "$service_file"
    fi

    local service_config='[Unit]
Description=juicity-server Service
Documentation=https://github.com/juicity/juicity
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Environment=QUIC_GO_ENABLE_GSO=true
ExecStart=/usr/local/bin/juicity-server run -c /usr/local/etc/juicity/config.json --disable-timestamp
Restart=on-failure
LimitNPROC=512
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target'

    echo "$service_config" >"$service_file"
    echo "juicity startup service has been configured."
}

# 配置监听端口
function set_listen_port() {
    while true; do
        read -p "请输入监听端口 (默认8443): " new_listen_port
        new_listen_port=${new_listen_port:-8443}

        if [[ $new_listen_port =~ ^[1-9][0-9]{0,4}$ && $new_listen_port -le 65535 ]]; then
            check_result=$(netstat -tulpn | grep -E "\b${new_listen_port}\b")
            if [[ -z "$check_result" ]]; then
                echo "监听端口：$new_listen_port"
                break
            else
                echo -e "${RED}错误：端口已被占用，请选择其他端口！${NC}" >&2
            fi
        else
            echo -e "${RED}错误：端口范围1-65535，请重新输入！${NC}" >&2
        fi
    done

    listen_port="$new_listen_port"
}

# 配置用户名
function set_user_name() {  
    while true; do
        read -p "请输入用户名 (默认随机生成): " new_user_name
        
        if [[ -z "$new_user_name" ]]; then
            new_user_name=$(sing-box generate rand --base64 6 2>/dev/null || openssl rand -base64 5)           
            echo "用户名：$new_user_name"
            break
        elif [[ ! -z "$new_user_name" ]]; then
            break
        fi
    done 
    
    user_names+=("$new_user_name")   
}

# 配置用户密码
function set_user_password() { 
    while true; do
        read -p "请输入密码（默认随机生成）: " new_user_password
        
        if [[ -z "$new_user_password" ]]; then
            new_user_password=$(sing-box generate rand --base64 9 2>/dev/null || openssl rand -base64 9)
            echo "密码：$new_user_password"            
            break
        elif [[ ! -z "$new_user_password" ]]; then
            break
        fi
    done
    
    user_passwords+=("$new_user_password")    
}

# 配置 Shadowsocks 密码
function set_ss_password() {
    while true; do
        read -p "请输入 Shadowsocks 密码（默认随机生成）: " ss_user_password
        
        if [[ -z $ss_user_password ]]; then
            if [[ $encryption_choice == 1 || $encryption_choice == 2 ]]; then
                ss_password=$(sing-box generate rand --base64 32)
                echo "Shadowsocks 密码: $ss_password"
            else
                ss_password=$(sing-box generate rand --base64 16)
                echo "Shadowsocks 密码: $ss_password"
            fi
            
            ss_passwords+=("$ss_password")
            break
        
        elif [[ $encryption_choice == 1 || $encryption_choice == 2 ]] && [[ ${#ss_user_password} -eq 32 ]]; then
            ss_password="$ss_user_password"
            echo "Shadowsocks 密码: $ss_password"
            ss_passwords+=("$ss_password")
            break
        
        elif [[ $encryption_choice != 1 && $encryption_choice != 2 ]] && [[ ${#ss_user_password} -eq 16 ]]; then
            ss_password="$ss_user_password"
            echo "Shadowsocks 密码: $ss_password"
            ss_passwords+=("$ss_password")
            break
        
        else
            echo -e "${RED}错误：密码长度不符合要求，请重新输入！${NC}"
        fi
    done
}

# 配置 ShadowTLS 密码
function set_stls_password() {
    while true; do
        read -p "请输入 ShadowTLS 密码（默认随机生成）: " stls_user_password
        
        if [[ -z $stls_user_password ]]; then
            if [[ $encryption_choice == 1 || $encryption_choice == 2 ]]; then
                stls_password=$(sing-box generate rand --base64 32)
                echo "ShadowTLS 密码: $stls_password"
            else
                stls_password=$(sing-box generate rand --base64 16)
                echo "ShadowTLS 密码: $stls_password"
            fi
            
            stls_passwords+=("$stls_password")
            break
        
        elif [[ $encryption_choice == 1 || $encryption_choice == 2 ]] && [[ ${#stls_user_password} -eq 32 ]]; then
            stls_password="$stls_user_password"
            echo "ShadowTLS 密码: $stls_password"
            stls_passwords+=("$stls_password")
            break
        
        elif [[ $encryption_choice != 1 && $encryption_choice != 2 ]] && [[ ${#stls_user_password} -eq 16 ]]; then
            stls_password="$stls_user_password"
            echo "ShadowTLS 密码: $stls_password"
            stls_passwords+=("$stls_password")
            break
        
        else
            echo -e "${RED}错误：密码长度不符合要求，请重新输入！${NC}"
        fi
    done
}

# 配置上行速率
function set_up_speed() { 
    while true; do
        read -p "请输入上行速率 (默认50): " new_up_mbps
        new_up_mbps=${new_up_mbps:-50}
        
        if [[ $new_up_mbps =~ ^[0-9]+$ ]]; then            
            echo "上行速率：$new_up_mbps Mbps"
            break
        else
            echo -e "${RED}错误：请输入数字作为上行速率！${NC}"
        fi
    done
    
    up_mbps="$new_up_mbps"
}

# 配置下行速率
function set_down_speed() {
    while true; do
        read -p "请输入下行速率 (默认100): " new_down_mbps
        new_down_mbps=${new_down_mbps:-100}
        
        if [[ $new_down_mbps =~ ^[0-9]+$ ]]; then            
            echo "下行速率：$new_down_mbps Mbps"
            break
        else
            echo -e "${RED}错误：请输入数字作为下行速率！${NC}"
        fi
    done
    
    down_mbps="$new_down_mbps"
}

# 配置 UUID
function set_uuid() {
    while true; do
        read -p "请输入UUID（默认随机生成）: " new_user_uuid
        
        if [[ -z "$new_user_uuid" ]]; then
            new_user_uuid=$(sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        fi
        
        if [[ $new_user_uuid =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then           
            echo "UUID：$new_user_uuid"
            break
        else
            echo -e "${RED}无效的UUID格式，请重新输入！${NC}"
        fi
    done
    
    user_uuids+=("$new_user_uuid")
}

# 配置目标端口
function set_override_port() {
    while true; do
        read -p "请输入目标端口 (默认8443): " new_override_port
        new_override_port=${new_override_port:-8443}
        
        if [[ $new_override_port =~ ^[1-9][0-9]{0,4}$ && $new_override_port -le 65535 ]]; then            
            echo "目标端口: $new_override_port"
            break
        else
            echo -e "${RED}错误：端口范围1-65535，请重新输入！${NC}"
        fi
    done
    
    override_port="$new_override_port"
}

# 生成 tag
function generate_unique_tag() {
    local config_file="/usr/local/etc/sing-box/config.json"
    
    while true; do
        random_tag=$(head /dev/urandom | tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
        tag_label="${random_tag}-in"
        
        if ! grep -qE "\"tag\":\\s*\"$tag_label\"(,|$)" "$config_file"; then
            break
        fi
    done
}

# 配置目标地址
function set_override_address() {
    while true; do
        read -p "请输入目标地址（IP或域名）: " target_address
        
        if [[ -z "$target_address" ]]; then
            echo -e "${RED}错误：目标地址不能为空！${NC}"
            continue
        fi
        
        if ( [[ $target_address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ $(grep -o '\.' <<< "$target_address" | wc -l) -eq 3 ]] ) || 
            ( [[ $target_address =~ ^[a-fA-F0-9:]+$ ]] && [[ $(grep -o ':' <<< "$target_address" | wc -l) -ge 2 ]] ); then
            break
        else
            resolved_ips=$(host -t A "$target_address" | awk '/has address/ { print $4 }')

            if [[ -n "$resolved_ips" ]] && ( [[ "$resolved_ips" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$resolved_ips" =~ ^[a-fA-F0-9:]+$ ]] ); then
                break
            else
                echo -e "${RED}错误：请输入有效的 IP 地址或域名！${NC}"
            fi
        fi
    done
}

# 配置 ServerName 列表
function set_server_name() {
    while true; do
        read -p "请输入可用的 ServerName 列表 (默认为 nijigen-works.jp): " user_input
        
        if [[ -z "$user_input" ]]; then
            server_name="nijigen-works.jp"
            echo "ServerName：$server_name"
            break
        else
            server_name="$user_input"
            echo "ServerName：$server_name"
            echo "Verifying server's TLS version support..."
            
            if command -v openssl >/dev/null 2>&1; then
                local openssl_output=$(timeout 10s openssl s_client -connect "$server_name:443" -tls1_3 2>&1)
                
                if [[ $openssl_output == *"TLS_AES_256_GCM_SHA384"* || \
                      $openssl_output == *"TLS_AES_128_GCM_SHA256"* || \
                      $openssl_output == *"TLS_CHACHA20_POLY1305_SHA256"* || \
                      $openssl_output == *"TLS_AES_128_CCM_SHA256"* || \
                      $openssl_output == *"TLS_AES_128_CCM_8_SHA256"* ]]; then
                    break
                else
                    echo -e "${RED}该网址不支持 TLS 1.3，请重新输入！${NC}"
                fi
            else
                echo "OpenSSL is not installed, cannot verify TLS support."
                break
            fi
        fi
    done
}

# 配置目标网站地址
function set_target_server() {
    while true; do
        read -p "请输入目标网站地址(默认为 nijigen-works.jp): " user_input
        
        if [[ -z "$user_input" ]]; then
            target_server="nijigen-works.jp"
            echo "目标网址：$target_server"
            break
        else
            target_server="$user_input"
            echo "目标网址：$target_server"
            echo "Verifying server's TLS version support..."
            
            if command -v openssl >/dev/null 2>&1; then
                local openssl_output=$(timeout 10s openssl s_client -connect "$target_server:443" -tls1_3 2>&1)
                
                if [[ $openssl_output == *"TLS_AES_256_GCM_SHA384"* || \
                      $openssl_output == *"TLS_AES_128_GCM_SHA256"* || \
                      $openssl_output == *"TLS_CHACHA20_POLY1305_SHA256"* || \
                      $openssl_output == *"TLS_AES_128_CCM_SHA256"* || \
                      $openssl_output == *"TLS_AES_128_CCM_8_SHA256"* ]]; then
                    break
                else
                    echo -e "${RED}该目标网站地址不支持 TLS 1.3，请重新输入！${NC}" 
                fi
            else
                echo "OpenSSL is not installed, cannot verify TLS support."
                break
            fi
        fi
    done
}

# 获取本机IP地址
function get_local_ip() {
    local local_ip_v4
    local local_ip_v6

    local_ip_v4=$(curl -s4 https://api.myip.com | grep -o '"ip":"[^"]*' | awk -F ':"' '{print $2}')
    
    if [[ -n "$local_ip_v4" ]]; then
        ip_v4="$local_ip_v4"
    else
        local_ip_v4=$(curl -s4 icanhazip.com)
        
        if [[ -n "$local_ip_v4" ]]; then
            ip_v4="$local_ip_v4"
        fi
    fi
    
    local_ip_v6=$(curl -s6 https://api.myip.com | grep -o '"ip":"[^"]*' | awk -F ':"' '{print $2}')
    
    if [[ -n "$local_ip_v6" ]]; then
        ip_v6="$local_ip_v6"
    else
        local_ip_v6=$(curl -s6 icanhazip.com)
        
        if [[ -n "$local_ip_v6" ]]; then
            ip_v6="$local_ip_v6"
        fi
    fi
    
    if [[ -z "$ip_v4" && -z "$ip_v6" ]]; then
        echo -e "${RED}无法获取本机IP地址！${NC}"
    fi
}

# 获取ECH密钥
function get_ech_keys() {
    local input_file="/etc/ssl/private/ech.tmp"
    local output_file="/etc/ssl/private/ech.pem"
    
    sing-box generate ech-keypair [--pq-signature-schemes-enabled] > "$input_file"
    
    IFS=$'\n' read -d '' -ra lines < "$input_file"
    
    exec 3>"$output_file"
    in_ech_keys_section=false
    in_ech_configs_section=false
    
    for line in "${lines[@]}"; do
        if [[ "$line" == *"BEGIN ECH KEYS"* ]]; then
            in_ech_keys_section=true
            ech_key+="            \"$line\",\n"
        elif [[ "$line" == *"END ECH KEYS"* ]]; then
            in_ech_keys_section=false
            ech_key+="            \"$line\""
        elif [[ "$line" == *"BEGIN ECH CONFIGS"* ]]; then
            in_ech_configs_section=true
            ech_config+="            \"$line\",\n"
        elif [[ "$line" == *"END ECH CONFIGS"* ]]; then
            in_ech_configs_section=false
            ech_config+="            \"$line\""
        elif [[ "$in_ech_keys_section" == true ]]; then
            ech_key+="            \"$line\",\n"
        elif [[ "$in_ech_configs_section" == true ]]; then
            ech_config+="            \"$line\",\n"
        else
            echo "\"$line\"," >&3
        fi
    done
    
    exec 3>&-
    rm "$input_file"
}

# 配置域名，并验证其是否绑定本机IP
function get_domain() {
    while true; do
        read -p "请输入域名（关闭Cloudflare代理）： " user_domain
        
        resolved_ipv4=$(dig +short A "$user_domain" 2>/dev/null)
        resolved_ipv6=$(dig +short AAAA "$user_domain" 2>/dev/null)
        
        if [[ -z $user_domain ]]; then
            echo -e "${RED}错误：域名不能为空，请重新输入！${NC}"
        else
            if [[ ("$resolved_ipv4" == "$ip_v4" && ! -z "$resolved_ipv4") || ("$resolved_ipv6" == "$ip_v6" && ! -z "$resolved_ipv6") ]]; then
                break
            else
                if [[ -z "$resolved_ipv4" && -n "$ip_v4" ]]; then
                    resolved_ip_v4=$(ping -4 "$user_domain" -c 1 2>/dev/null | sed '1{s/[^(]*(//;s/).*//;q}')
                    if [[ ("$resolved_ip_v4" == "$ip_v4" && ! -z "$resolved_ip_v4") ]]; then
                        break
                    fi
                fi
                
                if [[ -z "$resolved_ipv6" && -n "$ip_v6" ]]; then
                    resolved_ip_v6=$(ping -6 "$user_domain" -c 1 2>/dev/null | sed '1{s/[^(]*(//;s/).*//;q}')
                    if [[ ("$resolved_ip_v6" == "$ip_v6" && ! -z "$resolved_ip_v6") ]]; then
                        break
                    fi
                fi
                
                echo -e "${RED}错误：域名未绑定本机IP，请重新输入！${NC}"
            fi
        fi
    done
    
    domain="$user_domain"
}

# 验证域名是否支持通过 CloudFlare 的 API 申请证书
function verify_domain() {
    new_domain=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id" \
    -H "Authorization: Bearer $api_token" | jq -r '.result.name')

    if [[ $new_domain =~ \.(tk|ml|ga|gq|cf)$ ]]; then
        echo -e "${RED}您的域名为$new_domain，该域名不支持使用 CloudFlare 的 API 申请证书，请选择其他方式申请证书！${NC}"
        domain_supported=false
    else
        while true; do
            read -p "请输入主域名前缀（若为空则使用主域名申请证书，不需要在 CloudFlare 添加 DNS 解析记录）： " domain_prefix
            
            if [[ -z "$domain_prefix" ]]; then
                domain="$new_domain"
                record_name="$domain_prefix"
                break
            else
                domain="$domain_prefix.$new_domain"
                record_name="$domain_prefix"
                break
            fi
        done
        domain_supported=true
    fi
}

# 配置 DNS 记录
function set_dns_record() {
    if [[ -z "$record_name" ]]; then
        name_value="@"
    else
        name_value="$record_name"
    fi
    
    if [[ -n "$ip_v4" ]]; then
        record_content="$ip_v4"
        record_type="A"
    elif [[ -z "$ip_v4" && -n "$ip_v6" ]]; then
        record_content="$ip_v6"
        record_type="AAAA"
    fi
    
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_Zone_ID/dns_records" \
      -H "Authorization: Bearer $CF_Token" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"$record_type\",\"name\":\"$name_value\",\"content\":\"$record_content\",\"ttl\":120,\"proxied\":false}" >/dev/null
}

# 获取 CloudFlare 的限制性 API 令牌
function get_api_token() {
    while true; do
        read -p "请输入 CloudFlare 的限制性 API 令牌: " api_token
        
        if [[ ! $api_token =~ ^[A-Za-z0-9_-]{40}$ ]]; then
            echo -e "${RED}API令牌格式不正确，请重新输入！${NC}"
        else
            export CF_Token="$api_token"
            break
        fi
    done
}

# 获取 CloudFlare 的区域 ID
function get_zone_id() {
    while true; do
        read -p "请输入 CloudFlare 的区域 ID: " zone_id
        
        if [[ ! $zone_id =~ ^[a-z0-9]{32}$ ]]; then
            echo -e "${RED}CloudFlare 的区域 ID 格式不正确，请重新输入！${NC}"
        else
            export CF_Zone_ID="$zone_id"
            break
        fi
    done
}

# 获取 CloudFlare 的登录邮箱
function get_api_email() {
    while true; do
        read -p "请输入 CloudFlare 的登录邮箱: " api_email
        
        if [[ ! $api_email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$ ]]; then
            echo -e "${RED}邮箱格式不正确，请重新输入！${NC}"
        else
            export CF_Email="$api_email"
            break
        fi
    done
}

# 配置伪装网址
function set_fake_domain() {
    while true; do
        read -p "请输入伪装网址（默认: www.zcloudisk.com）: " fake_domain
        fake_domain=${fake_domain:-"www.zcloudisk.com"}
        
        if curl --output /dev/null --silent --head --fail "$fake_domain"; then
            echo "伪装网址: $fake_domain"
            break
        else
            echo -e "${RED}伪装网址无效或不可用，请重新输入！${NC}"
        fi
    done
}

# 设置 PEM 证书位置
function set_certificate_path() {
    while true; do
        read -p "请输入 PEM 证书位置: " certificate_path_input
        
        if [[ ! -f "$certificate_path_input" ]]; then
            echo -e "${RED}错误：证书文件不存在，请重新输入！${NC}"
            continue
        fi
        
        certificate_file=$(basename "$certificate_path_input")
        allowed_extensions=("crt" "pem")
        
        if [[ ! "${allowed_extensions[@]}" =~ "${certificate_file##*.}" ]]; then
            echo -e "${RED}错误：不支持的证书格式，请配置.crt或.pem格式的证书文件！${NC}"
            continue
        fi
        
        certificate_path="$certificate_path_input"
        break
    done
}

# 设置 PEM 私钥位置
function set_private_key_path() {
    while true; do
        read -p "请输入 PEM 私钥位置: " private_key_path_input
        
        if [[ ! -f "$private_key_path_input" ]]; then
            echo -e "${RED}错误：私钥文件不存在，请重新输入！${NC}"
            continue
        fi
        
        private_key_file=$(basename "$private_key_path_input")
        allowed_extensions=("key" "pem")
        
        if [[ ! "${allowed_extensions[@]}" =~ "${private_key_file##*.}" ]]; then
            echo -e "${RED}错误：不支持的私钥格式，请配置.key或.pem格式的私钥文件！${NC}"
            continue
        fi
        
        private_key_path="$private_key_path_input"
        break
    done
}

# 申请 SSL 证书
function apply_certificate() {
    certificate_path="/etc/ssl/private/"$domain".crt"
    private_key_path="/etc/ssl/private/"$domain".key"
    local has_ipv4=false
    local ca_servers=("letsencrypt" "zerossl")
    local return_to_menu=false

    if [[ -n "$ip_v4" ]]; then
        has_ipv4=true
    fi

    echo "Requesting a certificate..."        
    curl -s https://get.acme.sh | sh -s email=example@gmail.com 2>&1 | tail -n 1
    alias acme.sh=~/.acme.sh/acme.sh

    for ca_server in "${ca_servers[@]}"; do
        echo "Requesting a certificate from $ca_server..."
        ~/.acme.sh/acme.sh --set-default-ca --server "$ca_server"

        if $has_ipv4; then
            result=$(~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 2>&1)
        else
            result=$(~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --listen-v6 2>&1)
        fi

        if [[ $result == *"force"* ]]; then
            if $has_ipv4; then
                result=$(~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --force 2>&1)
            else
                result=$(~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --listen-v6 --force 2>&1)
            fi
        fi

        if [[ $result == *"log"* || $result == *"debug"* || $result == *"error"* ]]; then
            echo -e "${RED}$result ${NC}" 
            continue  
        fi

        if [[ $? -eq 0 ]]; then
            echo "Installing the certificate..."
            ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc --key-file "$private_key_path" --fullchain-file "$certificate_path"
            break 
        else
            echo -e "${RED}Failed to obtain a certificate from $ca_server！${NC}"
            return_to_menu=true
        fi
    done

    if [[ "$return_to_menu" == true ]]; then
        echo -e "${RED}证书申请失败，请使用其它方法申请证书！${NC}"
        return 1
    fi
}

# 申请 API 证书
function Apply_api_certificate() {
    certificate_path="/etc/ssl/private/"$domain".crt"
    private_key_path="/etc/ssl/private/"$domain".key"
    local has_ipv4=false
    local ca_servers=("letsencrypt" "zerossl")
    
    if [[ -n "$ip_v4" ]]; then
        has_ipv4=true
    fi
    
    echo "Requesting a certificate..."        
    curl -s https://get.acme.sh | sh -s email=example@gmail.com 2>&1 | tail -n 1
    alias acme.sh=~/.acme.sh/acme.sh
    
    for ca_server in "${ca_servers[@]}"; do
        echo "Requesting a certificate from $ca_server..."
        ~/.acme.sh/acme.sh --set-default-ca --server "$ca_server"
        
        if $has_ipv4; then
            result=$(~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" -k ec-256 2>&1)
        else
            result=$(~/.acme.sh/acme.sh --issue --dns dns_cf -d "$domain" -k ec-256 --listen-v6 2>&1)
        fi
        
        if [[ $result == *"log"* || $result == *"debug"* || $result == *"error"* || $result == *"force"* ]]; then
            echo -e "${RED}$result ${NC}"
            return_to_menu=true  
            continue  
        fi
        
        if [[ $? -eq 0 ]]; then
            echo "Installing the certificate..."
            ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc --key-file "$private_key_path" --fullchain-file "$certificate_path"
            break 
        else
            echo -e "${RED}Failed to obtain a certificate from $ca_server！${NC}"
            return_to_menu=true
        fi
    done
    
    if [[ "$return_to_menu" == true ]]; then
        echo -e "${RED}证书申请失败，请使用其它方法申请证书！${NC}"
        return 1
    fi
}

# 重新申请证书
function Reapply_certificates() {
    local tls_info_file="/usr/local/etc/sing-box/tls_info.json"
    local has_ipv4=false
    
    if [[ -n "$ip_v4" ]]; then
        has_ipv4=true
    fi
    
    if ! command -v acme.sh &>/dev/null; then
        curl -s https://get.acme.sh | sh -s email=example@gmail.com
    fi
    
    alias acme.sh=~/.acme.sh/acme.sh
    echo "Setting CA server to Let's Encrypt..."
    ~/.acme.sh/acme.sh --set-default-ca --server "letsencrypt"
    
    jq -c '.[]' "$tls_info_file" | while read -r tls_info; do
        server_name=$(echo "$tls_info" | jq -r '.server_name')
        key_path=$(echo "$tls_info" | jq -r '.key_path')
        certificate_path=$(echo "$tls_info" | jq -r '.certificate_path')
        
        echo "Requesting certificate for $server_name..."
        result=$(
            if $has_ipv4; then
                ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$server_name" -k ec-256 --force
            else
                ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$server_name" -k ec-256 --listen-v6 --force
            fi
        )
        
        if [[ "$result" =~ "Cert success." ]]; then
            echo "Certificate for $server_name has been applied using Cloudflare DNS verification."
        else
            echo "Cloudflare DNS verification failed for $server_name. Trying standalone verification..."
            result=$(
                if $has_ipv4; then
                    ~/.acme.sh/acme.sh --issue -d "$server_name" --standalone --force
                else
                    ~/.acme.sh/acme.sh --issue -d "$server_name" --standalone --listen-v6 --force
                fi
            )
            if [[ "$result" =~ "BEGIN CERTIFICATE" && "$result" =~ "END CERTIFICATE" ]]; then
                echo "Certificate for $server_name has been applied using Let's Encrypt CA."
            else
                echo "Failed to obtain certificate for $server_name using standalone verification as well."
                return 1
            fi
        fi      
        
        ~/.acme.sh/acme.sh --install-cert -d "$server_name" --ecc --key-file "$key_path" --fullchain-file "$certificate_path"
        echo "Certificate for $server_name has been installed."
    done
    
    rm -f "$tls_info_file"
}

# 生成公私钥
function generate_private_key() {
    while true; do
        read -p "请输入私钥 (默认随机生成私钥): " local_private_key
        
        if [[ -z "$local_private_key" ]]; then
            local keypair_output=$(sing-box generate reality-keypair)
            local_private_key=$(echo "$keypair_output" | awk -F: '/PrivateKey/{gsub(/ /, "", $2); print $2}')
            local_public_key=$(echo "$keypair_output" | awk -F: '/PublicKey/{gsub(/ /, "", $2); print $2}')
            echo "private_key：$local_private_key"
            echo "public_key：$local_public_key"
            break
        else
            if [[ "$local_private_key" =~ ^[A-Za-z0-9_\-]{43}$ ]]; then
                read -p "请输入公钥: " local_public_key
                
                if ! [[ "$local_public_key" =~ ^[A-Za-z0-9_\-]{43}$ ]]; then
                    echo -e "${RED}无效的公钥，请重新输入！${NC}" 
                else
                    break
                fi
            else
                echo -e "${RED}无效的私钥，请重新输入！${NC}"
            fi
        fi
    done
    
    public_key="$local_public_key"
    private_key="$local_private_key"
}

# 配置自签名证书
function create_self_signed_cert() {
    while true; do
        read -p "请输入要用于自签名证书的域名（默认为 bing.com）: " user_domain
        domain_name=${user_domain:-"bing.com"}
        
        if curl --output /dev/null --silent --head --fail "$domain_name"; then
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout /etc/ssl/private/$domain_name.key \
                -out /etc/ssl/private/$domain_name.crt \
                -subj "/CN=$domain_name" -days 36500
            
            chmod 777 /etc/ssl/private/$domain_name.key
            chmod 777 /etc/ssl/private/$domain_name.crt
            break 
        else
            echo -e "${RED}无效的域名或域名不可用，请输入有效的域名！${NC}"
        fi
    done
    
    certificate_path="/etc/ssl/private/$domain_name.crt"
    private_key_path="/etc/ssl/private/$domain_name.key"
}

# 获取 WARP 配置参数
function generate_warp_info() {
    local key priv_key pub_key temp_file ser_v4 ser_v6 ser_port local_v4 local_v6 publ_key res_value

    key=$(openssl genpkey -algorithm X25519 | openssl pkey -text -noout)
    priv_key=$(echo "$key" | grep -A 3 "priv:" | tail -n +2 | tr -d ' \n:' | xxd -r -p | base64)
    pub_key=$(echo "$key" | grep -A 3 "pub:" | tail -n +2 | tr -d ' \n:' | xxd -r -p | base64)

    temp_file=$(mktemp)
    curl -sL --tlsv1.3 -X POST 'https://api.cloudflareclient.com/v0a2158/reg' \
        -H 'CF-Client-Version: a-8.3-1190' \
        -H 'Content-Type: application/json' \
        -d '{
            "key":"'${pub_key}'",
            "tos":"'$(date +"%Y-%m-%dT%H:%M:%S.000Z")'"
        }' > "$temp_file"

    ser_v4=$(jq -r '.config.peers[0].endpoint.v4' < "$temp_file" | sed 's/:0$//')
    ser_v6=$(jq -r '.config.peers[0].endpoint.v6' < "$temp_file" | sed 's/:0$//')
    ser_port=$(jq -r '.config.peers[0].endpoint.ports[0]' < "$temp_file")
    local_v4=$(jq -r '.config.interface.addresses.v4 + "/32"' < "$temp_file")
    local_v6=$(jq -r '.config.interface.addresses.v6 + "/128"' < "$temp_file")
    publ_key=$(jq -r '.config.peers[0].public_key' < "$temp_file")
    res_value=$(jq -r '.config.client_id' < "$temp_file" | base64 -d | xxd -p | tr -d '\n' | sed 's/../& /g' | tr ' ' '\n' | awk '{printf "%d, ", "0x"$1}' | sed 's/, $//' | sed 's/^/[/' | sed 's/$/]/')

    warp_output_file=$(mktemp --suffix=.json)
    awk -v ser_v4="$ser_v4" -v ser_v6="$ser_v6" -v ser_port="$ser_port" -v local_v4="$local_v4" -v local_v6="$local_v6" -v priv_key="$priv_key" -v publ_key="$publ_key" -v res_value="$res_value" 'BEGIN {
        print "{\n    \"server\": {\n        \"v4\": \"" ser_v4 "\",\n        \"v6\": \"" ser_v6 "\"\n    },\n    \"server_port\": " ser_port ",\n    \"local_address\": {\n        \"v4\": \"" local_v4 "\",\n        \"v6\": \"" local_v6 "\"\n    },\n    \"private_key\": \"" priv_key "\",\n    \"public_key\": \"" publ_key "\",\n    \"reserved\": " res_value ",\n    \"mtu\": 1280\n}"
    }' > "$warp_output_file"
    rm "$temp_file"
}

# 检测并安装 iptables 及相关服务
function check_iptables_installed() {
    local os_name=$(uname -s)
    export PATH=$PATH:/usr/sbin:/sbin

    if [[ "$os_name" == "Linux" ]]; then
        if [[ -f /etc/debian_version ]]; then
            if ! command -v iptables &> /dev/null; then
                echo "Installing iptables..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y iptables &> /dev/null
            fi

            if ! command -v netfilter-persistent &> /dev/null; then
                echo "Installing netfilter-persistent..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y netfilter-persistent &> /dev/null
            fi

            if [[ ! -f /etc/init.d/iptables-persistent ]]; then
                echo "Installing iptables-persistent..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent &> /dev/null
            fi

            [[ ! -f /etc/iptables/rules.v4 ]] && touch /etc/iptables/rules.v4
            [[ ! -f /etc/iptables/rules.v6 ]] && touch /etc/iptables/rules.v6
            netfilter-persistent save &> /dev/null
            command -v nft &> /dev/null && echo "System uses nftables backend."
        elif [[ -f /etc/redhat-release ]]; then
            if ! command -v iptables &> /dev/null; then
                echo "Installing iptables-services..."
                if command -v dnf &> /dev/null; then
                    dnf install -y iptables-services
                else
                    yum install -y iptables-services
                fi
            fi

            command -v service &> /dev/null && service iptables save &> /dev/null
            command -v service &> /dev/null && service ip6tables save &> /dev/null
            systemctl enable iptables &> /dev/null
            systemctl enable ip6tables &> /dev/null

            command -v nft &> /dev/null && echo "System uses nftables backend."
        fi

        sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf
        sed -i '/^net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf
        echo -e "net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\nnet.ipv6.conf.default.forwarding = 1" >> /etc/sysctl.conf
        sysctl -p &> /dev/null
    fi
}


# 设置端口范围
function get_port_range() {
    while true; do
        read -p "请输入端口跳跃的起始端口 (默认：2080): " start_port
        start_port=${start_port:-2080}

        if [[ $start_port =~ ^[1-9][0-9]{0,4}$ && $start_port -le 65535 ]]; then
            break
        else
            echo -e "${RED}错误：端口范围 1-65535，请重新输入！${NC}" >&2
        fi
    done

    while true; do
        read -p "请输入端口跳跃的终止端口 (默认：3000): " end_port
        end_port=${end_port:-3000}

        if [[ $end_port =~ ^[1-9][0-9]{0,4}$ && $end_port -le 65535 ]]; then
            if [[ "$end_port" -le "$start_port" ]]; then
                echo -e "${RED}错误：终止端口必须大于起始端口！${NC}" >&2
                return 1
            fi
            break
        else
            echo -e "${RED}错误：端口范围 1-65535，请重新输入！${NC}" >&2
        fi
    done
}

# 是否开启端口跳跃
function ask_enable_port_forwarding() {
    while true; do
        read -p "是否开启端口跳跃功能？(Y/N，默认为Y): " choice

        if [[ -z "$choice" || "$choice" == "y" || "$choice" == "Y" ]]; then
            check_iptables_installed
            get_port_range
            set_port_forwarding
            break
        elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
            break
        else
            echo -e "${RED}无效的输入，请重新输入！${NC}"
        fi
    done
}

# 设置 iptables DNAT 规则
function set_port_forwarding() {
    local wan_iface
    wan_iface=$(ip route | grep '^default' | awk '{print $5}')
    if [[ -z "$wan_iface" ]]; then
        echo "Error: Could not detect WAN interface."
        return 1
    fi

    echo "Setting port forwarding from $start_port:$end_port to $listen_port on interface $wan_iface..."

    if command -v iptables &> /dev/null; then
        iptables -t nat -A PREROUTING -i "$wan_iface" -p udp --dport "$start_port":"$end_port" -j DNAT --to-destination ":$listen_port" &> /dev/null
        iptables -t nat -A POSTROUTING -p udp --dport $listen_port -j MASQUERADE &> /dev/null
    fi

    if command -v ip6tables &> /dev/null; then
        if ip6tables -t nat -L &> /dev/null; then
            ip6tables -t nat -A PREROUTING -i "$wan_iface" -p udp --dport "$start_port":"$end_port" -j DNAT --to-destination ":$listen_port" &> /dev/null
            ip6tables -t nat -A POSTROUTING -p udp --dport $listen_port -j MASQUERADE &> /dev/null
        else
            echo "IPv6 NAT not supported, skipping IPv6 port forwarding."
        fi
    fi

    if command -v nft &> /dev/null; then
        nft list table ip nat &> /dev/null || nft add table ip nat
        nft list table ip6 nat &> /dev/null || nft add table ip6 nat
    fi

    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save &> /dev/null
    elif command -v service &> /dev/null; then
        service iptables save &> /dev/null
        service ip6tables save &> /dev/null
    fi

    echo "Port forwarding setup completed."
}

# 选择加密类型
function select_encryption_method() {
    while true; do
        read -p "请选择加密方式(默认1)：
1). 2022-blake3-chacha20-poly1305
2). 2022-blake3-aes-256-gcm
3). 2022-blake3-aes-128-gcm
4). xchacha20-ietf-poly1305
5). chacha20-ietf-poly1305
6). aes-256-gcm
7). aes-192-gcm
8). aes-128-gcm
请选择[1-8]: " encryption_choice
        
        encryption_choice=${encryption_choice:-1}
        
        case $encryption_choice in
            1)
                ss_method="2022-blake3-chacha20-poly1305"
                ss_password=$(sing-box generate rand --base64 32)
                shadowtls_password=$(sing-box generate rand --base64 32)
                break
                ;;
            2)
                ss_method="2022-blake3-aes-256-gcm"
                ss_password=$(sing-box generate rand --base64 32)
                shadowtls_password=$(sing-box generate rand --base64 32)
                break
                ;;                
            3)
                ss_method="2022-blake3-aes-128-gcm"
                ss_password=$(sing-box generate rand --base64 16)
                shadowtls_password=$(sing-box generate rand --base64 16)
                break
                ;;
            4)
                ss_method="xchacha20-ietf-poly1305"
                ss_password=$(sing-box generate rand --base64 16)
                shadowtls_password=$(sing-box generate rand --base64 16)
                break
                ;;
            5)
                ss_method="chacha20-ietf-poly1305"
                ss_password=$(sing-box generate rand --base64 16)
                shadowtls_password=$(sing-box generate rand --base64 16)
                break
                ;;
            6)
                ss_method="aes-256-gcm"
                ss_password=$(sing-box generate rand --base64 16)
                shadowtls_password=$(sing-box generate rand --base64 16)
                break
                ;;
            7)
                ss_method="aes-192-gcm"
                ss_password=$(sing-box generate rand --base64 16)
                shadowtls_password=$(sing-box generate rand --base64 16)
                break
                ;;
            8)
                ss_method="aes-128-gcm"
                ss_password=$(sing-box generate rand --base64 16)
                shadowtls_password=$(sing-box generate rand --base64 16)
                break
                ;;                                                                
            *)
                echo -e "${RED}错误：无效的选择，请重新输入！${NC}"
                ;;
        esac
    done
}

# 选择要解锁的项目
function select_unlocked_items() {
    while true; do
        read -p "请选择要解锁的项目（支持多选）：
1). ChatGPT
2). Netflix
3). Disney+
4). YouTube
请选择[1-4]: " choices
        
        if [[ "$choices" =~ ^[1234]+$ ]]; then
            selected=($(echo "$choices" | sed 's/./& /g'))
            break
        else
            echo -e "${RED}错误：无效的选择，请重新输入！${NC}"
        fi
    done
}

# 更新规则集
function update_rule_set() {
    for choice in "${selected[@]}"; do
        case $choice in
            1)
                rule_set+=("\"geosite-openai\"")
                ;;
            2)
                rule_set+=("\"geosite-netflix\"")
                ;;
            3)
                rule_set+=("\"geosite-disney\"")
                ;;
            4)
                rule_set+=("\"geosite-youtube\"")
                ;;
            *)
                echo -e "${RED}无效的选择: $choice${NC}"
                ;;
        esac
    done
}

# 配置拥塞控制算法
function select_congestion_control() {
    local default_congestion_control="bbr"
    
    while true; do
        read -p "请选择拥塞控制算法 (默认$default_congestion_control):
1). bbr
2). cubic
3). new_reno
请选择[1-3]: " congestion_control

        case $congestion_control in
            1)
                congestion_control="bbr"
                break
                ;;
            2)
                congestion_control="cubic"
                break
                ;;
            3)
                congestion_control="new_reno"
                break
                ;;
            "")
                congestion_control=$default_congestion_control
                break
                ;;
            *)
                echo -e "${RED}错误：无效的选择，请重新输入！${NC}"
                ;;
        esac
    done
}

# 选择证书来源
function select_certificate_option() {
    local certificate_option
    local domain_supported=false
    local return_to_menu=false

    while true; do
        read -p "请选择证书来源 (默认1)：
1). 自签证书
2). 监听80端口申请证书（standalone模式）
3). cloudflare API 申请证书（DNS API模式）
4). 自定义证书路径
请选择[1-4]: " certificate_option

        certificate_option=${certificate_option:-1}

        case $certificate_option in
            1)
                if $disable_option; then
                    echo -e "${RED}NaiveProxy节点不支持自签证书，请使用acme申请证书！${NC}"
                    continue
                fi
                check_firewall_configuration
                create_self_signed_cert
                break
                ;;
            2)
                get_local_ip
                get_domain
                check_firewall_configuration
                apply_certificate
                if [[ "$return_to_menu" == true ]]; then
                    return_to_menu=false
                    continue
                fi
                break
                ;;
            3)
                get_local_ip
                get_api_token
                get_zone_id
                get_api_email
                verify_domain
                set_dns_record
                check_firewall_configuration
                if [[ "$domain_supported" == false ]]; then
                    continue
                else
                    Apply_api_certificate
                    if [[ "$return_to_menu" == true ]]; then
                        return_to_menu=false
                        continue
                    fi
                    break
                fi
                ;;
            4)
                get_local_ip
                get_domain 
                check_firewall_configuration
                set_certificate_path
                set_private_key_path
                break
                ;;
            *)
                echo -e "${RED}错误：无效的选择，请重新输入！${NC}"
                ;;
        esac
    done
}

# 选择 VMess 节点类型
function select_vmess_type() {
    while true; do
        read -p "请选择节点类型（默认1）：
1). VMess+TCP
2). VMess+WebSocket
3). VMess+gRPC
4). VMess+HTTPUpgrade
5). VMess+TCP+TLS
6). VMess+WebSocket+TLS
7). VMess+H2C+TLS
8). VMess+gRPC+TLS
9). VMess+HTTPUpgrade+TLS
请选择 [1-9]: " node_type

        case $node_type in
            "" | 1)
                tls_enabled=false
                break
                ;;
            2)
                transport_ws=true
                tls_enabled=false
                break
                ;;
            3)
                transport_grpc=true
                tls_enabled=false
                break
                ;;
            4)
                transport_httpupgrade=true
                tls_enabled=false
                break
                ;;
            5)
                tls_enabled=true
                break
                ;; 
            6)
                transport_ws=true
                tls_enabled=true
                break
                ;; 
            7)
                transport_http=true
                tls_enabled=true
                break
                ;;
            8)
                transport_grpc=true
                tls_enabled=true
                break
                ;;
            9)
                transport_httpupgrade=true
                tls_enabled=true
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入！${NC}"
                ;;
        esac
    done
}

# 选择 VLESS 节点类型
function select_vless_type() {
    while true; do
        read -p "请选择节点类型 (默认1)：     
1). VLESS+TCP
2). VLESS+WebSocket
3). VLESS+gRPC
4). VLESS+HTTPUpgrade
5). VLESS+Vision+REALITY
6). VLESS+H2C+REALITY
7). VLESS+gRPC+REALITY
请选择[1-7]: " flow_option

        case $flow_option in
            "" | 1)
                flow_type=""
                break
                ;;
            2)
                flow_type=""
                transport_ws=true
                break
                ;;
            3)
                flow_type=""
                transport_grpc=true
                break
                ;;
            4)
                flow_type=""
                transport_httpupgrade=true
                break
                ;;
            5)
                flow_type="xtls-rprx-vision"
                reality_enabled=true
                break
                ;;
            6)
                flow_type=""
                transport_http=true
                reality_enabled=true
                break
                ;;
            7)
                flow_type=""
                transport_grpc=true
                reality_enabled=true
                break
                ;;            
            *)
                echo -e "${RED}错误的选项，请重新输入！${NC}" >&2
                ;;
        esac
    done
}

# 选择 Trojan 节点类型
function select_trojan_type() {
    while true; do
        read -p "请选择节点类型（默认1）：
1). Trojan+TCP
2). Trojan+WebSocket
3). Trojan+gRPC
4). Trojan+HTTPUpgrade
5). Trojan+TCP+TLS
6). Trojan+WebSocket+TLS
7). Trojan+H2C+TLS
8). Trojan+gRPC+TLS
9). Trojan+HTTPUpgrade+TLS
请选择 [1-9]: " setup_type

        case $setup_type in
            "" | 1)
                tls_enabled=false
                break
                ;;
            2)
                transport_ws=true
                tls_enabled=false
                break
                ;;
            3)
                transport_grpc=true
                tls_enabled=false
                break
                ;;
            4)
                transport_httpupgrade=true
                tls_enabled=false
                break
                ;;
            5)
                tls_enabled=true
                break
                ;;
            6)
                transport_ws=true
                tls_enabled=true
                break
                ;;
            7)
                transport_http=true
                tls_enabled=true
                break
                ;;
            8)
                transport_grpc=true
                tls_enabled=true
                break
                ;;
            9)
                transport_httpupgrade=true
                tls_enabled=true
                break
                ;;
            *)
                echo -e "${RED}无效的选择，请重新输入！${NC}"
                ;;
        esac
    done
}

# 设置 Short_Id
function set_short_id() {
    while true; do
        read -p "请输入 Short_Id (用于区分不同的客户端，默认随机生成): " short_id
        
        if [[ -z "$short_id" ]]; then
            short_id=$(openssl rand -hex 8)
            echo "Short_Id：$short_id"
            break
        elif [[ "$short_id" =~ ^[0-9a-fA-F]{2,16}$ ]]; then
            echo "Short_Id：$short_id"
            break
        else
            echo "错误：请输入两到八位的十六进制字符串！"
        fi
    done

    short_ids+=("$short_id")
}

# 设置多个 Short_Id
function set_short_ids() {
    while true; do
        set_short_id
        
        for ((i=0; i<${#short_ids[@]}; i++)); do
            short_id="${short_ids[$i]}"
        done
        
        while true; do
            read -p "是否继续添加 short id？(Y/N，默认N): " -e choice
            
            if [[ -z "$choice" ]]; then
                choice="N"
            fi
            
            if [[ "$choice" == "N" || "$choice" == "n" ]]; then
                short_Ids+="\n            \"$short_id\""
                return
            elif [[ "$choice" == "Y" || "$choice" == "y" ]]; then
                short_Ids+="\n            \"$short_id\","
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 TUIC 配置
function tuic_multiple_users() {
    while true; do
        set_user_name
        set_user_password
        set_uuid
        
        for ((i=0; i<${#user_names[@]}; i++)); do
            user_name="${user_names[$i]}"
            user_uuid="${user_uuids[$i]}"
            user_password="${user_passwords[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"uuid\": \"$user_uuid\",\n          \"password\": \"$user_password\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"uuid\": \"$user_uuid\",\n          \"password\": \"$user_password\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 VMess 配置
function vmess_multiple_users() {
    while true; do
        set_uuid
        
        for ((i=0; i<${#user_uuids[@]}; i++)); do
            user_uuid="${user_uuids[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"uuid\": \"$user_uuid\",\n          \"alterId\": 0\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"uuid\": \"$user_uuid\",\n          \"alterId\": 0\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 VLESS 配置
function vless_multiple_users() {
    while true; do
        set_uuid
        
        for ((i=0; i<${#user_uuids[@]}; i++)); do
            user_uuid="${user_uuids[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"uuid\": \"$user_uuid\",\n          \"flow\": \"$flow_type\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"uuid\": \"$user_uuid\",\n          \"flow\": \"$flow_type\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 SOCKS、NaiveProxy 配置
function socks_naive_multiple_users() {
    while true; do
        set_user_name
        set_user_password
        
        for ((i=0; i<${#user_names[@]}; i++)); do
            user_name="${user_names[$i]}"
            user_password="${user_passwords[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"username\": \"$user_name\",\n          \"password\": \"$user_password\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"username\": \"$user_name\",\n          \"password\": \"$user_password\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 AnyTLS 配置
function anytls_multiple_users() {
    while true; do
        set_user_name
        set_user_password
        
        for ((i=0; i<${#user_names[@]}; i++)); do
            user_name="${user_names[$i]}"
            user_password="${user_passwords[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"password\": \"$user_password\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"password\": \"$user_password\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 Hysteria 配置
function hysteria_multiple_users() {
    while true; do
        set_user_name
        set_user_password
        
        for ((i=0; i<${#user_names[@]}; i++)); do
            user_name="${user_names[$i]}"
            user_password="${user_passwords[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"auth_str\": \"$user_password\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"auth_str\": \"$user_password\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 Hysteria2 配置
function hy2_multiple_users() {
    while true; do
        set_user_name
        set_user_password
        
        for ((i=0; i<${#user_names[@]}; i++)); do
            user_name="${user_names[$i]}"
            user_password="${user_passwords[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"password\": \"$user_password\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"password\": \"$user_password\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 Trojan 配置
function trojan_multiple_users() {
    while true; do
        set_user_password
        
        for ((i=0; i<${#user_passwords[@]}; i++)); do
            user_password="${user_passwords[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"password\": \"$user_password\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"password\": \"$user_password\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 添加多个用户到 ShadowTLS 配置
function shadowtls_multiple_users() {
    while true; do
        set_user_name
        set_stls_password
        
        for ((i=0; i<${#user_names[@]}; i++)); do
            user_name="${user_names[$i]}"
            stls_password="${stls_passwords[$i]}"
        done
        
        while true; do
            read -p "是否继续添加用户？(Y/N，默认N): " -e add_multiple_users
            
            if [[ -z "$add_multiple_users" ]]; then
                add_multiple_users="N"
            fi
            
            if [[ "$add_multiple_users" == "N" || "$add_multiple_users" == "n" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"password\": \"$stls_password\"\n        }"
                return
            elif [[ "$add_multiple_users" == "Y" || "$add_multiple_users" == "y" ]]; then
                users+="\n        {\n          \"name\": \"$user_name\",\n          \"password\": \"$stls_password\"\n        },"
                break
            else
                echo -e "${RED}无效的输入，请重新输入！${NC}"
            fi
        done
    done
}

# 生成 transport 配置
function generate_transport_config() {    
    if [[ "$transport_ws" = true ]]; then
        read -p "请输入 ws 路径 (默认随机生成): " transport_path_input
        transport_path=${transport_path_input:-/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)}
        
        if [[ ! "$transport_path" =~ ^/ ]]; then
            transport_path="/$transport_path"
        fi
        
        transport_config="\n      \"transport\": {\n        \"type\": \"ws\",\n        \"path\": \"$transport_path\",\n        \"max_early_data\": 2048,\n        \"early_data_header_name\": \"Sec-WebSocket-Protocol\"\n      },"
    
    elif [[ "$transport_httpupgrade" = true ]]; then
        transport_path=${transport_path_input:-/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)}
        
        if [[ ! "$transport_path" =~ ^/ ]]; then
            transport_path="/$transport_path"
        fi
        
        transport_config="\n      \"transport\": {\n        \"type\": \"httpupgrade\",\n        \"path\": \"$transport_path\"\n      },"
    
    elif [[ "$transport_grpc" = true ]]; then
        service_name=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)
        transport_config="\n      \"transport\": {\n        \"type\": \"grpc\",\n        \"service_name\": \"$service_name\"\n      },"
    
    elif [[ "$transport_http" = true ]]; then
        transport_config="\n      \"transport\": {\n        \"type\": \"http\"\n      },"
    
    else
        transport_config=""    
    fi
}

# 生成 TLS 配置
function generate_tls_config() {
    if [[ "$tls_enabled" = true ]]; then
        set_ech_config
        select_certificate_option
    fi

    if [[ -z "$domain_name" ]]; then
        if [[ -n "$domain" ]]; then
            server_name="$domain"
        fi
    else
        server_name="$domain_name"
    fi
    
    if [[ "$tls_enabled" = true ]]; then
        tls_config=",\n      \"tls\": {\n        \"enabled\": true,\n        \"server_name\": \"$server_name\",\n        \"certificate_path\": \"$certificate_path\",\n        \"key_path\": \"$private_key_path\"$ech_server_config\n      }"
    fi
}

# 配置 ECH
function set_ech_config() {
    while true; do
        read -p "是否开启 ECH?(Y/N，默认N):" enable_ech
        enable_ech="${enable_ech:-N}"

        if [[ "$enable_ech" == "y" || "$enable_ech" == "Y" ]]; then
            get_ech_keys
            enable_ech=true
            ech_server_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"key\": [\n$ech_key\n          ]\n        }"
            break
        elif [[ "$enable_ech" == "n" || "$enable_ech" == "N" ]]; then
            enable_ech=false
            ech_server_config=""
            break
        else
            echo -e "${RED}无效的输入，请重新输入！${NC}"
        fi
    done
}

# 生成 Reality 配置
function generate_reality_config() {
    if [[ "$reality_enabled" = true ]]; then
        set_server_name
        set_target_server
        generate_private_key
        set_short_ids

        reality_config=",\n      \"tls\": {\n        \"enabled\": true,\n        \"server_name\": \"$server_name\",\n        \"reality\": {\n          \"enabled\": true,\n          \"handshake\": {\n            \"server\": \"$target_server\",\n            \"server_port\": 443\n          },\n          \"private_key\": \"$private_key\",\n          \"short_id\": [$short_Ids\n          ]\n        }\n      }"
    fi
}

# 配置 QUIC 流量混淆
function configure_quic_obfuscation() {
    while true; do
        read -p "是否开启QUIC流量混淆（如果你的网络屏蔽了 QUIC 或 HTTP/3 流量，请选择开启）？(Y/N，默认为N): " choice
        choice="${choice:-N}"

        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            read -p "请输入混淆密码（默认随机生成）: " new_obfs_password
            if [[ -z "$new_obfs_password" ]]; then
                new_obfs_password=$(sing-box generate rand --base64 9 2>/dev/null || openssl rand -base64 9)
            fi

            obfs_config="\n      \"obfs\": {\n        \"type\": \"salamander\",\n        \"password\": \"$new_obfs_password\"\n      },"
            obfs_password="$new_obfs_password"
            echo "混淆密码：$obfs_password"
            break
        elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
            obfs_config=""
            break
        else
            echo -e "${RED}无效的输入，请重新输入！${NC}"
        fi
    done
}

# 配置 obfs 混淆
function configure_obfuscation() {
    while true; do
        read -p "是否开启 obfs 混淆（用来绕过针对性的 DPI 屏蔽或者 QoS）？(Y/N，默认为N): " choice
        choice="${choice:-N}"

        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            read -p "请输入混淆密码（默认随机生成）: " new_obfs_password
            if [[ -z "$new_obfs_password" ]]; then
                new_obfs_password=$(sing-box generate rand --base64 9 2>/dev/null || openssl rand -base64 9)
            fi

            obfs_config="\n      \"obfs\": \"$new_obfs_password\","
            obfs_password="$new_obfs_password"
            echo "混淆密码：$obfs_password"
            break
        elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
            obfs_config=""
            break
        else
            echo -e "${RED}无效的输入，请重新输入！${NC}"
        fi
    done
}
      
# 配置多路复用
function configure_multiplex() {
    while true; do
        read -p "是否开启多路复用？(Y/N，默认为Y): " choice
        choice="${choice:-Y}"

        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            configure_brutal
            multiplex_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"padding\": false$brutal_config\n      }"
            break
        elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
            multiplex_config=""
            break
        else
            echo -e "${RED}无效的输入，请重新输入！${NC}"
        fi
    done
}

# 配置 TCP Brutal
function configure_brutal() {
    while true; do
        read -p "是否开启 TCP Brutal？(Y/N，默认为N): " choice
        choice="${choice:-N}"

        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            set_up_speed
            set_down_speed
            brutal_config=",\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $up_mbps,\n          \"down_mbps\": $down_mbps\n        }"
            break
        elif [[ "$choice" == "n" || "$choice" == "N" ]]; then
            brutal_config=""
            break
        else
            echo -e "${RED}无效的输入，请重新输入！${NC}"
        fi
    done
}

# 提取 TLS 信息
function extract_tls_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tls_info_file="/usr/local/etc/sing-box/tls_info.json"

    jq '.inbounds[].tls | select(.server_name and .certificate_path and .key_path) | {server_name: .server_name, certificate_path: .certificate_path, key_path: .key_path}' "$config_file" | jq -s 'unique' > "$tls_info_file"
}

# 验证 TLS 信息，并根据 DNS 解析结果更新文件
function validate_tls_info() {
    local tls_info_file="/usr/local/etc/sing-box/tls_info.json"
    local temp_tls_file="/usr/local/etc/sing-box/temp_tls_info.json"
    server_names=($(jq -r '.[].server_name' "$tls_info_file"))

    for server_name in "${server_names[@]}"; do
        local resolved_ipv4=$(dig +short A "$server_name" 2>/dev/null)
        local resolved_ipv6=$(dig +short AAAA "$server_name" 2>/dev/null)

        if [[ (-n "$resolved_ipv4" && "$resolved_ipv4" == "$ip_v4") || (-n "$resolved_ipv6" && "$resolved_ipv6" == "$ip_v6") ]]; then
            continue
        else
            jq 'map(select(.server_name != "'"$server_name"'"))' "$tls_info_file" > "$temp_tls_file"
            mv "$temp_tls_file" "$tls_info_file"
        fi
    done
}

# 修改路由规则
function modify_route_rules() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local temp_config_file="/usr/local/etc/sing-box/temp_config.json"

    if jq -e '.route.rules[] | select(.rule_set != null)' "$config_file" >/dev/null; then
        jq '(.route.rules |= [.[] | select(.rule_set != null)] + [.[] | select(.rule_set == null)])' "$config_file" > "$temp_config_file"
        mv "$temp_config_file" "$config_file"
    fi

    jq '.route.rules |= (map(select(.action == "sniff")) + map(select(.action != "sniff")))' "$config_file" > tmp.json && mv tmp.json "$config_file"
}

# 提取变量并清理临时文件
function extract_variables_and_cleanup() {
    server=$(jq -r '.server.v4' "$warp_output_file")
    server_port=$(jq -r '.server_port' "$warp_output_file")
    local_address_ipv4=$(jq -r '.local_address.v4' "$warp_output_file")
    local_address_ipv6=$(jq -r '.local_address.v6' "$warp_output_file")
    private_key=$(jq -r '.private_key' "$warp_output_file")
    peer_public_key=$(jq -r '.public_key' "$warp_output_file")
    reserved=$(jq -r '.reserved | tostring | gsub(","; ", ")' "$warp_output_file")
    mtu=$(jq -r '.mtu' "$warp_output_file")
    rm "$warp_output_file"
}

# 日志出站配置
function log_outbound_config() {
    local config_file="/usr/local/etc/sing-box/config.json"

    if ! grep -q '"log": {' "$config_file" || ! grep -q '"route": {' "$config_file" || ! grep -q '"inbounds": \[' "$config_file" || ! grep -q '"outbounds": \[' "$config_file"; then
        echo -e '{\n  "log": {\n  },\n  "route": {\n  },\n  "inbounds": [\n  ],\n  "outbounds": [\n  ]\n}' > "$config_file"
        sed -i '/"log": {/!b;n;c\    "disabled": false,\n    "level": "info",\n    "timestamp": true\n  },' "$config_file"
        sed -i '/"route": {/!b;n;c\    "rules": [\n      {\n        "inbound": [\n        ],\n        "action": "sniff",\n        "timeout": "1s"\n      },\n      {\n        "inbound": [\n        ],\n        "action": "route",\n        "outbound": "direct"\n      }\n    ]\n  },' "$config_file"
        sed -i '/"outbounds": \[/!b;n;c\    {\n      "type": "direct",\n      "tag": "direct"\n    }\n  ]' "$config_file"
    fi
}

# 修改JSON格式，去掉多余的逗号
function modify_config_format() {
    file_path="/usr/local/etc/sing-box/config.json"
    start_lines_action=$(grep -n '"action":' "$file_path" | cut -d: -f1)
    start_line_outbounds=$(grep -n '"outbounds": \[' "$file_path" | cut -d: -f1)
    
    for start_line_action in $start_lines_action; do
        line_to_modify_action=$((start_line_action - 2))
        if [[ "$line_to_modify_action" -ge 1 ]]; then
            sed -i "${line_to_modify_action}s/,[[:space:]]*$//" "$file_path"
        fi
    done
    
    if [[ -n "$start_line_outbounds" ]]; then
        line_to_modify_outbounds_1=$((start_line_outbounds - 2))
        line_to_modify_outbounds_2=$((start_line_outbounds - 1))
        if [[ "$line_to_modify_outbounds_1" -ge 1 ]]; then
            sed -i "$line_to_modify_outbounds_1 s/.*/    }/" "$file_path"
            sed -i "$line_to_modify_outbounds_2 s/.*/  ],/" "$file_path"
        fi
    fi
}

# 生成 HTTP 配置
function generate_http_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    tls_enabled=true
    local tag_label
    generate_unique_tag      
    set_listen_port
    socks_naive_multiple_users
    get_local_ip
    generate_tls_config
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" -v tls_config="$tls_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"http\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"set_system_proxy\": false,"; print "      \"users\": [" users ""; print "      ]" tls_config ""; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 AnyTLS 配置
function generate_anytls_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    tls_enabled=true
    local tag_label
    generate_unique_tag      
    set_listen_port
    anytls_multiple_users
    get_local_ip
    generate_tls_config
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" -v tls_config="$tls_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"anytls\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"users\": [" users ""; print "      ]" tls_config ""; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 Direct 配置
function generate_Direct_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v target_address="$target_address" -v override_port="$override_port" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"direct\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"proxy_protocol\": false,"; print "      \"override_address\": \"" target_address "\","; print "      \"override_port\": " override_port; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 Shadowsocks 配置
function generate_ss_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    configure_multiplex
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v ss_method="$ss_method" -v ss_password="$ss_password" -v multiplex_config="$multiplex_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"shadowsocks\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"method\": \"" ss_method "\","; print "      \"password\": \"" ss_password "\"" multiplex_config ""; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 VMess 配置
function generate_vmess_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    local tag_label
    generate_unique_tag
    select_vmess_type
    set_listen_port
    vmess_multiple_users
    generate_transport_config

    if [[ "$transport_grpc" != true ]] && [[ "$transport_http" != true ]]; then
        configure_multiplex
    fi

    get_local_ip
    generate_tls_config
    check_firewall_configuration
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" -v transport_config="$transport_config" -v tls_config="$tls_config" -v multiplex_config="$multiplex_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"vmess\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port "," transport_config ""; print "      \"users\": [" users ""; print "      ]" tls_config "" multiplex_config ""; print "    },"; found=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 SOCKS 配置
function generate_socks_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    set_listen_port
    socks_naive_multiple_users
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"socks\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"users\": [" users ""; print "      ]"; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 NaiveProxy 配置
function generate_naive_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    disable_option=true
    local tag_label
    generate_unique_tag
    set_listen_port
    socks_naive_multiple_users
    get_local_ip
    select_certificate_option
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" -v domain="$domain" -v certificate_path="$certificate_path" -v private_key_path="$private_key_path" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"naive\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"users\": [" users ""; print "      ],"; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" domain "\","; print "        \"certificate_path\": \"" certificate_path "\","; print "        \"key_path\": \"" private_key_path "\""; print "      }"; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 TUIC 配置
function generate_tuic_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    set_listen_port
    tuic_multiple_users
    select_congestion_control
    get_local_ip
    set_ech_config
    select_certificate_option
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    local found_inbounds=0
    local server_name="$domain"

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
    fi

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" -v congestion_control="$congestion_control" -v server_name="$server_name" -v certificate_path="$certificate_path" -v private_key_path="$private_key_path" -v ech_server_config="$ech_server_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"tuic\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"users\": [" users ""; print "      ],"; print "      \"congestion_control\": \"" congestion_control "\","; print "      \"auth_timeout\": \"3s\","; print "      \"zero_rtt_handshake\": false,"; print "      \"heartbeat\": \"10s\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" server_name "\","; print "        \"alpn\": ["; print "          \"h3\""; print "        ],"; print "        \"certificate_path\": \"" certificate_path "\","; print "        \"key_path\": \"" private_key_path "\"" ech_server_config ""; print "      }"; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 Hysteria 配置
function generate_Hysteria_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    set_listen_port
    set_up_speed
    set_down_speed
    hysteria_multiple_users
    configure_obfuscation
    get_local_ip
    set_ech_config
    ask_enable_port_forwarding
    select_certificate_option
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    local found_inbounds=0
    local server_name="$domain"

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
    fi

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v obfs_config="$obfs_config" -v users="$users" -v server_name="$server_name" -v certificate_path="$certificate_path" -v private_key_path="$private_key_path" -v ech_server_config="$ech_server_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"hysteria\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"up_mbps\": " up_mbps ","; print "      \"down_mbps\": " down_mbps ","obfs_config""; print "      \"users\": [" users ""; print "      ],"; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" server_name "\","; print "        \"alpn\": ["; print "          \"h3\""; print "        ],"; print "        \"certificate_path\": \"" certificate_path "\","; print "        \"key_path\": \"" private_key_path "\"" ech_server_config ""; print "      }"; print "    },"; found_inbounds=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 ShadowTLS 配置
function generate_shadowtls_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    tag_label1="$tag_label"
    generate_unique_tag
    tag_label2="$tag_label"
    set_listen_port
    select_encryption_method
    shadowtls_multiple_users
    set_ss_password
    set_target_server
    configure_multiplex
    local found_inbounds=0

    awk -v tag_label1="$tag_label1" -v tag_label2="$tag_label2" -v listen_port="$listen_port" -v users="$users" -v target_server="$target_server" -v ss_method="$ss_method" -v ss_password="$ss_password" -v multiplex_config="$multiplex_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label1 "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"shadowtls\","; print "      \"tag\": \"" tag_label1 "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"version\": 3,"; print "      \"users\": [" users ""; print "      ],"; print "      \"handshake\": {"; print "        \"server\": \"" target_server "\","; print "        \"server_port\": 443"; print "      },"; print "      \"strict_mode\": true,"; print "      \"detour\": \"" tag_label2 "\""; print "    },"; print "    {"; print "      \"type\": \"shadowsocks\","; print "      \"tag\": \"" tag_label2 "\","; print "      \"listen\": \"127.0.0.1\","; print "      \"method\": \"" ss_method "\","; print "      \"password\": \"" ss_password "\"" multiplex_config ""; print "    },"; found=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 Juicity 配置
function generate_juicity_config() {
    local config_file="/usr/local/etc/juicity/config.json"
    set_listen_port
    set_uuid
    set_user_password
    select_congestion_control
    get_local_ip
    select_certificate_option
    local cert_path="$certificate_path"
    local key_path="$private_key_path"

    awk -v listen_port="$listen_port" -v user_uuids="$user_uuids" -v user_passwords="$user_passwords" -v certificate_path="$certificate_path" -v private_key_path="$private_key_path" -v congestion_control="$congestion_control" 'BEGIN { print "{"; printf "  \"listen\": \":%s\",\n", listen_port; printf "  \"users\": {\n"; printf "    \"%s\": \"%s\"\n", user_uuids, user_passwords; printf "  },\n"; printf "  \"certificate\": \"%s\",\n", certificate_path; printf "  \"private_key\": \"%s\",\n", private_key_path; printf "  \"congestion_control\": \"%s\",\n", congestion_control; printf "  \"disable_outbound_udp443\": true,\n"; print "  \"log_level\": \"info\""; print "}"}' > "$config_file"
}

# 生成 Vless 配置
function generate_vless_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    select_vless_type
    set_listen_port
    vless_multiple_users
    generate_transport_config
    generate_reality_config

    if [[ "$flow_type" != xtls-rprx-vision ]] && [[ "$transport_grpc" != true ]] && [[ "$transport_http" != true ]]; then
        configure_multiplex
    fi

    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" -v transport_config="$transport_config" -v reality_config="$reality_config" -v multiplex_config="$multiplex_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"vless\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port "," transport_config ""; print "      \"users\": [" users ""; print "      ]"reality_config"" multiplex_config ""; print "    },"; found=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 Hysteria2 配置
function generate_Hy2_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    set_listen_port
    set_up_speed
    set_down_speed
    hy2_multiple_users
    configure_quic_obfuscation
    set_fake_domain
    get_local_ip
    set_ech_config
    ask_enable_port_forwarding
    select_certificate_option
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    local found_inbounds=0
    local server_name="$domain"

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
    fi

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v obfs_config="$obfs_config" -v users="$users" -v fake_domain="$fake_domain" -v server_name="$server_name" -v certificate_path="$certificate_path" -v private_key_path="$private_key_path" -v ech_server_config="$ech_server_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"hysteria2\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port ","; print "      \"up_mbps\": " up_mbps ","; print "      \"down_mbps\": " down_mbps ","obfs_config""; print "      \"users\": [" users ""; print "      ],"; print "      \"ignore_client_bandwidth\": false,"; print "      \"masquerade\": \"https://" fake_domain "\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" server_name "\","; print "        \"alpn\": ["; print "          \"h3\""; print "        ],"; print "        \"certificate_path\": \"" certificate_path "\","; print "        \"key_path\": \"" private_key_path "\"" ech_server_config ""; print "      }"; print "    },"; found=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
}

# 生成 Trojan 配置
function generate_trojan_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local tag_label
    generate_unique_tag
    select_trojan_type
    set_listen_port
    trojan_multiple_users
    generate_transport_config

    if [[ "$transport_grpc" != true ]] && [[ "$transport_http" != true ]]; then
        configure_multiplex
    fi

    get_local_ip
    generate_tls_config
    local cert_path="$certificate_path"
    local key_path="$private_key_path"
    check_firewall_configuration
    local found_inbounds=0

    awk -v tag_label="$tag_label" -v listen_port="$listen_port" -v users="$users" -v transport_config="$transport_config" -v tls_config="$tls_config" -v multiplex_config="$multiplex_config" '
        /"inbounds": \[/{found_inbounds=1}
        { print; if ($0 ~ /^        "inbound": \[/) print "          \"" tag_label "\"," }
        found_inbounds && /^  "inbounds": \[/{print "    {"; print "      \"type\": \"trojan\","; print "      \"tag\": \"" tag_label "\","; print "      \"listen\": \"::\","; print "      \"listen_port\": " listen_port "," transport_config ""; print "      \"users\": [" users ""; print "      ]" tls_config "" multiplex_config ""; print "    },"; found=0}
    ' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"
} 

# 更新路由规则
function update_route_file() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local geosite_list=$(IFS=,; echo "${rule_set[*]}") 
    local geosite_formatted=$(sed 's/,/,\\n          /g' <<< "$geosite_list")
    local inbound_values=$(jq -r '.route.rules[].inbound // empty' "$config_file" | jq -s add | jq -r 'unique')

    echo "正在配置 WireGuard..."

    sed -i '/"route": {/a\    "rule_set": [\n        ],' "$config_file"

    for geosite in "${rule_set[@]}"; do
      geosite_clean=$(echo "$geosite" | sed 's/"//g')
      sed -i '/"rule_set": \[/!b; a\{"type": "remote", "tag": "'"$geosite_clean"'", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/'"$geosite_clean"'.srs", "download_detour": "direct"},' "$config_file"
    done

    sed -i '/"rules": \[/!b; a\{"rule_set": ['"$geosite_formatted"'], "outbound": "wg-ep"},' "$config_file"

    sed -i ':a;N;$!ba;s/},\n\s*]/}\n    ]/' "$config_file"

    jq '.route.rules |= (map(select(.action == "sniff")) + map(select(.action != "sniff")))' "$config_file" > tmp.json && mv tmp.json "$config_file"

    jq --argjson inbound "$inbound_values" '.route.rules |= map(if .outbound == "wg-ep" then {inbound: $inbound} + . else . end)' "$config_file" > tmp.json && mv tmp.json "$config_file"
}

# 配置 WireGuard
function Configure_endpoints() {
    local config_file="/usr/local/etc/sing-box/config.json"

    awk -v server="$server" -v server_port="$server_port" -v local_address_ipv4="$local_address_ipv4" -v local_address_ipv6="$local_address_ipv6" -v private_key="$private_key" -v peer_public_key="$peer_public_key" -v reserved="$reserved" -v mtu="$mtu" '{
        if ($0 ~ /^  "inbounds": \[/) { print "  \"endpoints\": ["; print "    {"; print "      \"type\": \"wireguard\","; print "      \"tag\": \"wg-ep\","; print "      \"mtu\": " mtu ","; print "      \"address\": ["; print "        \"" local_address_ipv4 "\","; print "        \"" local_address_ipv6 "\""; print "      ],"; print "      \"private_key\": \"" private_key "\","; print "      \"peers\": ["; print "        {"; print "          \"address\": \"" server "\","; print "          \"port\": " server_port ","; print "          \"public_key\": \"" peer_public_key "\","; print "          \"allowed_ips\": ["; print "            \"0.0.0.0/0\","; print "            \"::/0\""; print "          ],"; print "          \"reserved\": " reserved; print "        }"; print "      ]"; print "    }"; print "  ],"
        }
        print $0
    }' "$config_file" > "$config_file.tmp"

    mv "$config_file.tmp" "$config_file"

    echo "WireGuard 配置完成。"
}

# 生成 sing-box 手机端配置信息
function write_phone_client_file() {
    local dir="/usr/local/etc/sing-box"
    local phone_client="${dir}/phone_client.json"

    if [[ ! -s "${phone_client}" ]]; then
        awk 'BEGIN { print "{"; print "  \"log\": {"; print "    \"disabled\": false,"; print "    \"level\": \"info\","; print "    \"timestamp\": true"; print "  },"; print "  \"dns\": {"; print "    \"servers\": ["; print "      {"; print "        \"tag\": \"dns_proxy\","; print "        \"type\": \"https\","; print "        \"server\": \"1.1.1.1\","; print "        \"detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"tag\": \"dns_direct\","; print "        \"type\": \"https\","; print "        \"server\": \"223.5.5.5\""; print "      }"; print "    ],"; print "    \"rules\": ["; print "      {"; print "        \"clash_mode\": \"Direct\","; print "        \"server\": \"dns_direct\""; print "      },"; print "      {"; print "        \"clash_mode\": \"Global\","; print "        \"server\": \"dns_proxy\""; print "      },"; print "      {"; print "        \"rule_set\": \"geosite-category-ads-all\","; print "        \"action\": \"reject\""; print "      },"; print "      {"; print "        \"rule_set\": \"geosite-geolocation-cn\","; print "        \"server\": \"dns_direct\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"and\","; print "        \"rules\": ["; print "          {"; print "            \"rule_set\": \"geosite-geolocation-!cn\","; print "            \"invert\": true"; print "          },"; print "          {"; print "            \"rule_set\": \"geoip-cn\""; print "          }"; print "        ],"; print "        \"server\": \"dns_proxy\","; print "        \"client_subnet\": \"114.114.114.114/24\""; print "      }"; print "    ],"; print "    \"final\": \"dns_proxy\","; print "    \"strategy\": \"ipv4_only\","; print "    \"independent_cache\": true"; print "  },"; print "  \"route\": {"; print "    \"rule_set\": ["; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geosite-category-ads-all\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs\","; print "        \"download_detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geosite-geolocation-cn\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs\","; print "        \"download_detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geosite-geolocation-!cn\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs\","; print "        \"download_detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geoip-cn\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs\","; print "        \"download_detour\": \"Proxy\""; print "      }"; print "    ],"; print "    \"default_domain_resolver\": \"dns_direct\","; print "    \"rules\": ["; print "      {"; print "        \"inbound\": \"tun-in\","; print "        \"action\": \"sniff\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"or\","; print "        \"rules\": ["; print "          {"; print "            \"protocol\": \"dns\""; print "          },"; print "          {"; print "            \"port\": 53"; print "          }"; print "        ],"; print "        \"action\": \"hijack-dns\""; print "      },"; print "      {"; print "        \"clash_mode\": \"Direct\","; print "        \"outbound\": \"direct-out\""; print "      },"; print "      {"; print "        \"clash_mode\": \"Global\","; print "        \"outbound\": \"Proxy\""; print "      },"; print "      {"; print "        \"ip_is_private\": true,"; print "        \"outbound\": \"direct-out\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"or\","; print "        \"rules\": ["; print "          {"; print "            \"port\": 853"; print "          },"; print "          {"; print "            \"network\": \"udp\","; print "            \"port\": 443"; print "          },"; print "          {"; print "            \"protocol\": \"stun\""; print "          }"; print "        ],"; print "        \"action\": \"reject\""; print "      },"; print "      {"; print "        \"rule_set\": \"geosite-geolocation-cn\","; print "        \"outbound\": \"direct-out\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"and\","; print "        \"rules\": ["; print "          {"; print "            \"rule_set\": \"geoip-cn\""; print "          },"; print "          {"; print "            \"rule_set\": \"geosite-geolocation-!cn\","; print "            \"invert\": true"; print "          }"; print "        ],"; print "        \"outbound\": \"direct-out\""; print "      }"; print "    ],"; print "    \"final\": \"Proxy\","; print "    \"auto_detect_interface\": true"; print "  },"; print "  \"inbounds\": ["; print "    {"; print "      \"type\": \"tun\","; print "      \"tag\": \"tun-in\","; print "      \"address\": ["; print "        \"172.18.0.1/30\","; print "        \"fdfe:dcba:9876::1/126\""; print "      ],"; print "      \"mtu\": 1400,"; print "      \"auto_route\": true,"; print "      \"strict_route\": true,"; print "      \"stack\": \"gvisor\""; print "    }"; print "  ],"; print "  \"outbounds\": ["; print "    {"; print "      \"type\": \"urltest\","; print "      \"tag\": \"auto\","; print "      \"outbounds\": ["; print "      ],"; print "      \"url\": \"https://www.gstatic.com/generate_204\","; print "      \"interval\": \"1m\","; print "      \"tolerance\": 50,"; print "      \"interrupt_exist_connections\": false"; print "    },"; print "    {"; print "      \"type\": \"selector\","; print "      \"tag\": \"Proxy\","; print "      \"outbounds\": ["; print "        \"auto\""; print "      ],"; print "      \"default\": \"\","; print "      \"interrupt_exist_connections\": false"; print "    },"; print "    {"; print "      \"type\": \"direct\","; print "      \"tag\": \"direct-out\""; print "    }"; print "  ],"; print "  \"experimental\": {"; print "    \"cache_file\": {"; print "      \"enabled\": true,"; print "      \"store_fakeip\": false,"; print "      \"store_rdrc\": true"; print "    },"; print "    \"clash_api\": {"; print "      \"external_controller\": \"127.0.0.1:9090\","; print "      \"external_ui\": \"Dashboard\","; print "      \"external_ui_download_url\": \"https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip\","; print "      \"external_ui_download_detour\": \"Proxy\","; print "      \"default_mode\": \"Rule\""; print "    }"; print "  }"; print "}" }' > "${phone_client}"
    fi
}

# 生成 sing-box 电脑端配置信息
function write_win_client_file() {
    local dir="/usr/local/etc/sing-box"
    local win_client="${dir}/win_client.json"

    if [[ ! -s "${win_client}" ]]; then
        awk 'BEGIN { print "{"; print "  \"log\": {"; print "    \"disabled\": false,"; print "    \"level\": \"info\","; print "    \"timestamp\": true"; print "  },"; print "  \"dns\": {"; print "    \"servers\": ["; print "      {"; print "        \"tag\": \"dns_proxy\","; print "        \"type\": \"https\","; print "        \"server\": \"1.1.1.1\","; print "        \"detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"tag\": \"dns_direct\","; print "        \"type\": \"https\","; print "        \"server\": \"223.5.5.5\""; print "      }"; print "    ],"; print "    \"rules\": ["; print "      {"; print "        \"clash_mode\": \"Direct\","; print "        \"server\": \"dns_direct\""; print "      },"; print "      {"; print "        \"clash_mode\": \"Global\","; print "        \"server\": \"dns_proxy\""; print "      },"; print "      {"; print "        \"rule_set\": \"geosite-category-ads-all\","; print "        \"action\": \"reject\""; print "      },"; print "      {"; print "        \"rule_set\": \"geosite-geolocation-cn\","; print "        \"server\": \"dns_direct\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"and\","; print "        \"rules\": ["; print "          {"; print "            \"rule_set\": \"geosite-geolocation-!cn\","; print "            \"invert\": true"; print "          },"; print "          {"; print "            \"rule_set\": \"geoip-cn\""; print "          }"; print "        ],"; print "        \"server\": \"dns_proxy\","; print "        \"client_subnet\": \"114.114.114.114/24\""; print "      }"; print "    ],"; print "    \"final\": \"dns_proxy\","; print "    \"strategy\": \"ipv4_only\","; print "    \"independent_cache\": true"; print "  },"; print "  \"route\": {"; print "    \"rule_set\": ["; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geosite-category-ads-all\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs\","; print "        \"download_detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geosite-geolocation-cn\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs\","; print "        \"download_detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geosite-geolocation-!cn\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs\","; print "        \"download_detour\": \"Proxy\""; print "      },"; print "      {"; print "        \"type\": \"remote\","; print "        \"tag\": \"geoip-cn\","; print "        \"format\": \"binary\","; print "        \"url\": \"https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs\","; print "        \"download_detour\": \"Proxy\""; print "      }"; print "    ],"; print "    \"default_domain_resolver\": \"dns_direct\","; print "    \"rules\": ["; print "      {"; print "        \"inbound\": \"mixed-in\","; print "        \"action\": \"sniff\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"or\","; print "        \"rules\": ["; print "          {"; print "            \"protocol\": \"dns\""; print "          },"; print "          {"; print "            \"port\": 53"; print "          }"; print "        ],"; print "        \"action\": \"hijack-dns\""; print "      },"; print "      {"; print "        \"clash_mode\": \"Direct\","; print "        \"outbound\": \"direct-out\""; print "      },"; print "      {"; print "        \"clash_mode\": \"Global\","; print "        \"outbound\": \"Proxy\""; print "      },"; print "      {"; print "        \"ip_is_private\": true,"; print "        \"outbound\": \"direct-out\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"or\","; print "        \"rules\": ["; print "          {"; print "            \"port\": 853"; print "          },"; print "          {"; print "            \"network\": \"udp\","; print "            \"port\": 443"; print "          },"; print "          {"; print "            \"protocol\": \"stun\""; print "          }"; print "        ],"; print "        \"action\": \"reject\""; print "      },"; print "      {"; print "        \"rule_set\": \"geosite-geolocation-cn\","; print "        \"outbound\": \"direct-out\""; print "      },"; print "      {"; print "        \"type\": \"logical\","; print "        \"mode\": \"and\","; print "        \"rules\": ["; print "          {"; print "            \"rule_set\": \"geoip-cn\""; print "          },"; print "          {"; print "            \"rule_set\": \"geosite-geolocation-!cn\","; print "            \"invert\": true"; print "          }"; print "        ],"; print "        \"outbound\": \"direct-out\""; print "      }"; print "    ],"; print "    \"final\": \"Proxy\","; print "    \"auto_detect_interface\": true"; print "  },"; print "  \"inbounds\": ["; print "    {"; print "      \"type\": \"mixed\","; print "      \"tag\": \"mixed-in\","; print "      \"listen\": \"::\","; print "      \"listen_port\": 1080,"; print "      \"set_system_proxy\": false"; print "    }"; print "  ],"; print "  \"outbounds\": ["; print "    {"; print "      \"type\": \"urltest\","; print "      \"tag\": \"auto\","; print "      \"outbounds\": ["; print "      ],"; print "      \"url\": \"https://www.gstatic.com/generate_204\","; print "      \"interval\": \"1m\","; print "      \"tolerance\": 50,"; print "      \"interrupt_exist_connections\": false"; print "    },"; print "    {"; print "      \"type\": \"selector\","; print "      \"tag\": \"Proxy\","; print "      \"outbounds\": ["; print "        \"auto\""; print "      ],"; print "      \"default\": \"\","; print "      \"interrupt_exist_connections\": false"; print "    },"; print "    {"; print "      \"type\": \"direct\","; print "      \"tag\": \"direct-out\""; print "    }"; print "  ],"; print "  \"experimental\": {"; print "    \"cache_file\": {"; print "      \"enabled\": true,"; print "      \"store_fakeip\": false,"; print "      \"store_rdrc\": true"; print "    },"; print "    \"clash_api\": {"; print "      \"external_controller\": \"127.0.0.1:9090\","; print "      \"external_ui\": \"Dashboard\","; print "      \"external_ui_download_url\": \"https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip\","; print "      \"external_ui_download_detour\": \"Proxy\","; print "      \"default_mode\": \"Rule\""; print "    }"; print "  }"; print "}" }' > "${win_client}"
    fi
}

# 更新客户端配置文件信息
function update_client_file() {
    local phone_file="/usr/local/etc/sing-box/phone_client.json"
    local win_file="/usr/local/etc/sing-box/win_client.json"
    local phone_tag_value=$(jq -r '.outbounds[0].tag' "$phone_file")
    local win_tag_value=$(jq -r '.outbounds[0].tag' "$win_file")

    awk -v tag="$phone_tag_value" '{if ($0 ~ /"outbounds": \[/) outbounds_section=1; if (outbounds_section && $0 ~ /"default": /) {sub(/"default": "[^"]*"/, "\"default\": \"" tag "\"")} print}' "$phone_file" > tmp.json && mv tmp.json "$phone_file"
    awk -v tag="$win_tag_value" '{if ($0 ~ /"outbounds": \[/) outbounds_section=1; if (outbounds_section && $0 ~ /"default": /) {sub(/"default": "[^"]*"/, "\"default\": \"" tag "\"")} print}' "$win_file" > tmp.json && mv tmp.json "$win_file"
}

# 生成 clash 配置信息
function write_clash_yaml() {
    local dir="/usr/local/etc/sing-box"
    local clash_yaml="${dir}/clash.yaml"

    if [[ ! -s "${clash_yaml}" ]]; then
        awk 'BEGIN { print "mixed-port: 7890"; print "allow-lan: true"; print "bind-address: \"*\""; print "find-process-mode: strict"; print "mode: rule"; print "unified-delay: true"; print "tcp-concurrent: true"; print "log-level: info"; print "ipv6: true"; print "global-client-fingerprint: chrome"; print "external-controller: 127.0.0.1:9090"; print "external-ui: ui"; print "external-ui-url: \"https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip\""; print "tun:"; print "  enable: true"; print "  stack: system"; print "  dns-hijack:"; print "    - 0.0.0.0:53"; print "  auto-detect-interface: true"; print "  auto-route: true"; print "  auto-redirect: false"; print "  strict-route: true"; print "  mtu: 1400"; print "profile:"; print "  store-selected: true"; print "  store-fake-ip: true"; print "sniffer:"; print "  enable: true"; print "  sniff:"; print "    TLS:"; print "      ports: [443, 8443]"; print "    HTTP:"; print "      ports: [80, 8080-8880]"; print "      override-destination: true"; print "    QUIC:"; print "      ports: [443, 8443]"; print "  skip-domain:"; print "    - \"+.push.apple.com\""; print "dns:"; print "  enable: true"; print "  cache-algorithm: arc"; print "  prefer-h3: false"; print "  respect-rules: true"; print "  ipv6: true"; print "  default-nameserver:"; print "    - 1.1.1.1"; print "    - 8.8.8.8"; print "    - 223.5.5.5"; print "    - 119.29.29.29"; print "  enhanced-mode: fake-ip"; print "  fake-ip-range: 198.18.0.1/16"; print "  fake-ip-filter:"; print "    - \"*.lan\""; print "    - \"*.local\""; print "    - \"*.localdomain\""; print "    - \"*.example\""; print "    - \"*.invalid\""; print "    - \"*.localhost\""; print "    - \"*.test\""; print "    - \"*.home.arpa\""; print "    - \"*.direct\""; print "  nameserver-policy:"; print "    \"rule-set:category_ads_all\": "; print "      - rcode://success"; print "    \"rule-set:cn_domain,private_domain\":"; print "      - https://dns.alidns.com/dns-query"; print "      - https://doh.pub/dns-query"; print "  nameserver:"; print "    - https://cloudflare-dns.com/dns-query"; print "    - https://dns.google/dns-query"; print "  proxy-server-nameserver:"; print "    - https://dns.alidns.com/dns-query"; print "    - https://doh.pub/dns-query"; print "proxies:"; print "proxy-groups:"; print "  - name: Proxy"; print "    type: select"; print "    proxies:"; print "      - auto"; print "  - name: auto"; print "    type: url-test"; print "    proxies:"; print "    url: \"https://cp.cloudflare.com/generate_204\""; print "    interval: 300"; print "rules:"; print "  - RULE-SET,private_ip,DIRECT,no-resolve"; print "  - RULE-SET,category_ads_all,REJECT"; print "  - RULE-SET,private_domain,DIRECT"; print "  - RULE-SET,google_domain,Proxy"; print "  - RULE-SET,cn_domain,DIRECT"; print "  - RULE-SET,cn_ip,DIRECT"; print "  - MATCH,Proxy"; print "rule-anchor:"; print "  ip: &ip {type: http, interval: 86400, behavior: ipcidr, format: mrs}"; print "  domain: &domain {type: http, interval: 86400, behavior: domain, format: mrs}"; print "rule-providers:"; print "  private_domain:"; print "    <<: *domain"; print "    url: \"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs\""; print "  cn_domain:"; print "    <<: *domain"; print "    url: \"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs\""; print "  google_domain:"; print "    <<: *domain"; print "    url: \"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo-lite/geosite/google.mrs\""; print "  category_ads_all:"; print "    <<: *domain"; print "    url: \"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ads-all.mrs\""; print "  private_ip:"; print "    <<: *ip"; print "    url: \"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/private.mrs\""; print "  cn_ip:"; print "    <<: *ip"; print "    url: \"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs\""; }' > "${clash_yaml}"
    fi
}

# 生成 NaiveProxy 客户端配置信息
function write_naive_client_file() {
    local naive_client_file="$naive_client_filename"

    awk -v naive_client_file="$naive_client_file" 'BEGIN { print "{"; print "  \"listen\":  \"socks://127.0.0.1:1080\","; print "  \"proxy\": \"https://user_name:user_password@server_name:listen_port\""; print "}" }' > "$naive_client_file"
}

# 生成 Shadowsocks Windows 客户端配置
function generate_shadowsocks_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local proxy_name

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    while true; do
        proxy_name="ss-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v ss_method="$ss_method" -v ss_password="$ss_password" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"shadowsocks\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"method\": \"" ss_method "\", "; print "      \"password\": \"" ss_password "\"" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 Shadowsocks 手机客户端配置
function generate_shadowsocks_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local proxy_name

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    while true; do
        proxy_name="ss-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v ss_method="$ss_method" -v ss_password="$ss_password" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"shadowsocks\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"method\": \"" ss_method "\", "; print "      \"password\": \"" ss_password "\"" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 Shadowsocks Clash 客户端配置
function generate_shadowsocks_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="ss-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v ss_method="$ss_method" -v ss_password="$ss_password" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: ss"; print "    server:", local_ip; print "    port:", listen_port; print "    cipher:", ss_method; print "    password:", "\"" ss_password "\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 Juicity Windows 客户端配置
function generate_juicity_win_client_config() {
    local client_file="/usr/local/etc/juicity/client.json"
    local server_name="$domain"
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    awk -v listen_port="$listen_port" -v server_value="$server_value" -v user_uuids="$user_uuids" -v user_passwords="$user_passwords" -v server_name="$server_name" -v tls_insecure="$tls_insecure" -v congestion_control="$congestion_control" 'BEGIN { print "{"; printf "  \"listen\": \":%s\",\n", 1080; printf "  \"server\": \"%s:%s\",\n", server_value, listen_port; printf "  \"uuid\": \"%s\",\n", user_uuids; printf "  \"password\": \"%s\",\n", user_passwords; printf "  \"sni\": \"%s\",\n", server_name; printf "  \"allow_insecure\": %s,\n", tls_insecure; printf "  \"congestion_control\": \"%s\",\n", congestion_control; printf "  \"log_level\": \"info\"\n"; print "}"}' > "$client_file"

    echo "客户端配置文件已保存至$client_file，请下载后使用！"
}

# 生成 TUIC 手机客户端配置
function generate_tuic_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="tuic-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v user_password="$user_password" -v congestion_control="$congestion_control" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"tuic\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\", "; print "      \"password\": \"" user_password "\", "; print "      \"congestion_control\": \""congestion_control"\","; print "      \"udp_relay_mode\": \"native\","; print "      \"zero_rtt_handshake\": false,"; print "      \"heartbeat\": \"10s\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\", "; print "        \"alpn\": ["; print "          \"h3\""; print "        ]" ech_client_config ""; print "      }"; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 TUIC Windows 客户端配置
function generate_tuic_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="tuic-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v user_password="$user_password" -v congestion_control="$congestion_control" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"tuic\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\", "; print "      \"password\": \"" user_password "\", "; print "      \"congestion_control\": \""congestion_control"\","; print "      \"udp_relay_mode\": \"native\","; print "      \"zero_rtt_handshake\": false,"; print "      \"heartbeat\": \"10s\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\", "; print "        \"alpn\": ["; print "          \"h3\""; print "        ]" ech_client_config ""; print "      }"; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 TUIC Clash 客户端配置
function generate_tuic_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="tuic-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v user_password="$user_password" -v congestion_control="$congestion_control" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    server:", server_value; print "    port:", listen_port; print "    type: tuic"; print "    uuid:", user_uuid; print "    password:", user_password; print "    sni:", server_name; print "    alpn: [h3]"; print "    request-timeout: 8000"; print "    udp-relay-mode: native"; print "    skip-cert-verify:", tls_insecure; print "    congestion-controller:", congestion_control; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 SOCKS Windows 客户端配置
function generate_socks_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local proxy_name

    while true; do
        proxy_name="socks-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_name="$user_name" -v user_password="$user_password" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"socks\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"username\": \"" user_name "\", "; print "      \"password\": \"" user_password "\" "; print "    },";}
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 SOCKS 手机客户端配置
function generate_socks_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local proxy_name

    while true; do
        proxy_name="socks-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_name="$user_name" -v user_password="$user_password" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"socks\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"username\": \"" user_name "\", "; print "      \"password\": \"" user_password "\" "; print "    },";}
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 SOCKS Clash 客户端配置
function generate_socks_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="socks-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_name="$user_name" -v user_password="$user_password" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: socks5"; print "    server:", local_ip; print "    port:", listen_port; print "    username:", user_name; print "    password:", user_password; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 Hysteria Windows 客户端配置
function generate_Hysteria_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$obfs_password" ]]; then
        obfs_config="\n      \"obfs\": \"$obfs_password\","
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    if [[ -z "$start_port" ]] || [[ -z "$end_port" ]]; then
        server_ports_config="\"server_port\": $listen_port"
    else
        server_ports_config="\"server_ports\": [\n        \"$start_port:$end_port\"\n      ]"
    fi

    while true; do
        proxy_name="Hysteria-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v server_ports_config="$server_ports_config" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v obfs_config="$obfs_config" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"hysteria\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      " server_ports_config ","; print "      \"up_mbps\": " down_mbps ", "; print "      \"down_mbps\": " up_mbps ","obfs_config""; print "      \"auth_str\": \""user_password"\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\", "; print "        \"alpn\": ["; print "          \"h3\""; print "        ]" ech_client_config ""; print "      }"; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 Hysteria 手机客户端配置
function generate_Hysteria_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$obfs_password" ]]; then
        obfs_config="\n      \"obfs\": \"$obfs_password\","
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    if [[ -z "$start_port" ]] || [[ -z "$end_port" ]]; then
        server_ports_config="\"server_port\": $listen_port"
    else
        server_ports_config="\"server_ports\": [\n        \"$start_port:$end_port\"\n      ]"
    fi

    while true; do
        proxy_name="Hysteria-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v server_ports_config="$server_ports_config" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v obfs_config="$obfs_config" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"hysteria\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      " server_ports_config ","; print "      \"up_mbps\": " down_mbps ", "; print "      \"down_mbps\": " up_mbps ","obfs_config""; print "      \"auth_str\": \""user_password"\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\", "; print "        \"alpn\": ["; print "          \"h3\""; print "        ]" ech_client_config ""; print "      }"; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 Hysteria Clash 客户端配置
function generate_Hysteria_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$obfs_password" ]]; then
        obfs_config="
    obfs: $obfs_password"
    fi

    if [[ -n "$start_port" ]] && [[ -n "$end_port" ]]; then
        ports_config="
    ports: $start_port-$end_port"
    else
        ports_config=""
    fi

    while true; do
        proxy_name="hysteria-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v ports_config="$ports_config" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v user_password="$user_password" -v obfs_config="$obfs_config" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: hysteria"; print "    server:", server_value; print "    port:", listen_port ports_config; print "    auth-str:", user_password obfs_config; print "    sni:", server_name; print "    skip-cert-verify:", tls_insecure; print "    alpn:"; print "      - h3"; print "    protocol: udp"; print "    up: \"" down_mbps " Mbps\""; print "    down: \"" up_mbps " Mbps\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VMess Windows 客户端配置
function generate_vmess_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local proxy_name
    local server_name="$domain"
    local server_value
    local tls_insecure

    if [[ -z "$domain" && -n "$domain_name" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    elif [[ -z "$domain" && -z "$domain_name" ]]; then
        server_value="$local_ip"
    elif [[ -z "$domain_name" && -n "$domain" ]]; then
        server_name="$domain"
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    if [[ -n "$ech_config" ]]; then
      ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"pq_signature_schemes_enabled\": true,\n          \"dynamic_record_sizing_disabled\": false,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="vmess-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    if  [[ -n "$domain" || -n "$domain_name" ]]; then
        awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_config="$transport_config" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" -v multiplex_client_config="$multiplex_client_config" '
      /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vmess\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\"," transport_config " "; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      },"; print "      \"security\": \"auto\","; print "      \"alter_id\": 0,"; print "      \"packet_encoding\": \"xudp\"" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }
    {print}' "$win_client_file" > "$win_client_file.tmp"
    else
        awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
      /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vmess\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\"," transport_config " "; print "      \"security\": \"auto\","; print "      \"alter_id\": 0,"; print "      \"packet_encoding\": \"xudp\"" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }
    {print}' "$win_client_file" > "$win_client_file.tmp"
    fi

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 VMess 手机客户端配置
function generate_vmess_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local proxy_name
    local server_name="$domain"
    local server_value
    local tls_insecure

    if [[ -z "$domain" && -n "$domain_name" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    elif [[ -z "$domain" && -z "$domain_name" ]]; then
        server_value="$local_ip"
    elif [[ -z "$domain_name" && -n "$domain" ]]; then
        server_name="$domain"
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"pq_signature_schemes_enabled\": true,\n          \"dynamic_record_sizing_disabled\": false,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="vmess-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    if  [[ -n "$domain" || -n "$domain_name" ]]; then
        awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_config="$transport_config" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" -v multiplex_client_config="$multiplex_client_config" '
      /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vmess\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\"," transport_config " "; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      },"; print "      \"security\": \"auto\","; print "      \"alter_id\": 0,"; print "      \"packet_encoding\": \"xudp\"" multiplex_client_config ""; print "    },";}       
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }     
    {print}' "$phone_client_file" > "$phone_client_file.tmp"
    else
        awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
      /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vmess\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\"," transport_config " "; print "      \"security\": \"auto\","; print "      \"alter_id\": 0,"; print "      \"packet_encoding\": \"xudp\"" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }
    {print}' "$phone_client_file" > "$phone_client_file.tmp"
    fi

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 VMess+TCP Clash 客户端配置
function generate_vmess_tcp_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vmess-tcp-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vmess"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    alterId: 0"; print "    cipher: auto"; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VMess+TCP+TLS Clash 客户端配置
function generate_vmess_tcp_tls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="vmess-tcp-tls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vmess"; print "    server:", server_value; print "    port:", listen_port; print "    uuid:", user_uuid; print "    alterId: 0"; print "    cipher: auto"; print "    tls: true"; print "    skip-cert-verify:", tls_insecure; print "    servername: " server_name; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VMess+WebSocket Clash 客户端配置
function generate_vmess_ws_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vmess-ws-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_path="$transport_path" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vmess"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    alterId: 0"; print "    cipher: auto"; print "    network: ws"; print "    ws-opts:"; print "      path: " transport_path; print "      max-early-data: 2048"; print "      early-data-header-name: Sec-WebSocket-Protocol"; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VMess+WebSocket+TLS Clash 客户端配置
function generate_vmess_ws_tls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="vmess-ws-tls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_path="$transport_path" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vmess"; print "    server:", server_value; print "    port:", listen_port; print "    uuid:", user_uuid; print "    alterId: 0"; print "    cipher: auto"; print "    network: ws"; print "    tls: true"; print "    skip-cert-verify:", tls_insecure; print "    servername:", server_name; print "    ws-opts:"; print "      path: " transport_path; print "      max-early-data: 2048"; print "      early-data-header-name: Sec-WebSocket-Protocol"; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VMess+gRPC Clash 客户端配置
function generate_vmess_grpc_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vmess-grpc-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_service_name="$transport_service_name" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vmess"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    alterId: 0"; print "    cipher: auto"; print "    network: grpc"; print "    grpc-opts:"; print "      grpc-service-name:", "\"" transport_service_name "\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VMess+gRPC+TLS Clash 客户端配置
function generate_vmess_grpc_tls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="vmess-grpc-tls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_service_name="$transport_service_name" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vmess"; print "    server:", server_value; print "    port:", listen_port; print "    uuid:", user_uuid; print "    alterId: 0"; print "    cipher: auto"; print "    network: grpc"; print "    tls: true"; print "    skip-cert-verify:", tls_insecure; print "    servername:", server_name; print "    grpc-opts:"; print "      grpc-service-name:", "\"" transport_service_name "\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 HTTP 手机客户端配置
function generate_http_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="http-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_name="$user_name" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"http\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"username\": \"" user_name "\", "; print "      \"password\": \"" user_password "\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      }"; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 HTTP Windows 客户端配置
function generate_http_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="http-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_name="$user_name" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"http\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"username\": \"" user_name "\", "; print "      \"password\": \"" user_password "\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      }"; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 HTTP Clash 客户端配置
function generate_http_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="http-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_name="$user_name" -v user_password="$user_password" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: http"; print "    server:", server_value; print "    port:", listen_port; print "    username:", user_name; print "    password:", user_password; print "    tls: true"; print "    sni:", server_name; print "    skip-cert-verify:", tls_insecure; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 AnyTLS 手机客户端配置
function generate_anytls_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="anytls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"anytls\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"password\": \"" user_password "\","; print "      \"idle_session_check_interval\": \"30s\","; print "      \"idle_session_timeout\": \"30s\","; print "      \"min_idle_session\": 5,"; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      }"; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 AnyTLS Windows 客户端配置
function generate_anytls_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="anytls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"anytls\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"password\": \"" user_password "\","; print "      \"idle_session_check_interval\": \"30s\","; print "      \"idle_session_timeout\": \"30s\","; print "      \"min_idle_session\": 5,"; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      }"; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 AnyTLS Clash 客户端配置
function generate_anytls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="anytls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_name="$user_name" -v user_password="$user_password" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: anytls"; print "    server:", server_value; print "    port:", listen_port; print "    password:", user_password; print "    udp: true"; print "    idle-session-check-interval: 30"; print "    idle-session-timeout: 30"; print "    min-idle-session: 5"; print "    sni:", server_name; print "    alpn:"; print "      - h2"; print "      - http/1.1"; print "    skip-cert-verify:", tls_insecure; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 Hysteria2 手机客户端配置
function generate_Hysteria2_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$obfs_password" ]]; then
        obfs_config="\n      \"obfs\": {\n        \"type\": \"salamander\",\n        \"password\": \"$obfs_password\"\n      },"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    if [[ -z "$start_port" || -z "$end_port" ]]; then
        server_ports_config="\"server_port\": $listen_port"
    else
        server_ports_config="\"server_ports\": [\n        \"$start_port:$end_port\"\n      ]"
    fi

    while true; do
        proxy_name="Hysteria2-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v server_ports_config="$server_ports_config" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v obfs_config="$obfs_config" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"hysteria2\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      " server_ports_config ","; print "      \"up_mbps\": " down_mbps ", "; print "      \"down_mbps\": " up_mbps ","obfs_config""; print "      \"password\": \"" user_password "\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\", "; print "        \"alpn\": ["; print "          \"h3\""; print "        ]" ech_client_config ""; print "      }"; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 Hysteria2 Windows 客户端配置
function generate_Hysteria2_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$obfs_password" ]]; then
        obfs_config="\n      \"obfs\": {\n        \"type\": \"salamander\",\n        \"password\": \"$obfs_password\"\n      },"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    if [[ -z "$start_port" || -z "$end_port" ]]; then
        server_ports_config="\"server_port\": $listen_port"
    else
        server_ports_config="\"server_ports\": [\n        \"$start_port:$end_port\"\n      ]"
    fi

    while true; do
        proxy_name="Hysteria2-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v server_ports_config="$server_ports_config" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v obfs_config="$obfs_config" -v user_password="$user_password" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"hysteria2\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      " server_ports_config ","; print "      \"up_mbps\": " down_mbps ", "; print "      \"down_mbps\": " up_mbps ","obfs_config""; print "      \"password\": \"" user_password "\","; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\", "; print "        \"alpn\": ["; print "          \"h3\""; print "        ]" ech_client_config ""; print "      }"; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 Hysteria2 Clash 客户端配置
function generate_Hysteria2_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$obfs_password" ]]; then
        obfs_config="
    obfs: salamander
    obfs-password: $obfs_password"
    fi

    if [[ -n "$start_port" && -n "$end_port" ]]; then
        ports_config="
    ports: $start_port-$end_port"
    else
        ports_config=""
    fi

    while true; do
        proxy_name="hysteria2-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v ports_config="$ports_config" -v up_mbps="$up_mbps" -v down_mbps="$down_mbps" -v user_password="$user_password" -v obfs_config="$obfs_config" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: hysteria2"; print "    server:", server_value; print "    port:", listen_port ports_config; print "    password:", user_password obfs_config; print "    alpn:"; print "      - h3"; print "    sni:", server_name; print "    skip-cert-verify:", tls_insecure; print "    up: \"" down_mbps " Mbps\""; print "    down: \"" up_mbps " Mbps\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VLESS Windows 客户端配置
function generate_vless_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local proxy_name
    local server_name_in_config=$(jq -r '.inbounds[0].tls.server_name' "$config_file")

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    while true; do
        proxy_name="vless-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    if [[ "$server_name_in_config" != "null" ]]; then
    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v flow_type="$flow_type" -v public_key="$public_key" -v short_id="$short_id" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vless\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\", "; print "      \"flow\": \"" flow_type "\"," transport_config ""; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" server_name "\", "; print "        \"utls\": {"; print "          \"enabled\": true,"; print "          \"fingerprint\": \"chrome\""; print "        },"; print "        \"reality\": {"; print "          \"enabled\": true,"; print "          \"public_key\": \"" public_key "\","; print "          \"short_id\": \"" short_id "\""; print "        }"; print "      }" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"
    else
    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v flow_type="$flow_type" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vless\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\"," transport_config ""; print "      \"flow\": \"" flow_type "\"" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"
    fi

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 VLESS 手机客户端配置
function generate_vless_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local proxy_name
    local server_name_in_config=$(jq -r '.inbounds[0].tls.server_name' "$config_file")

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    while true; do
        proxy_name="vless-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    if [[ "$server_name_in_config" != "null" ]]; then
    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v flow_type="$flow_type" -v public_key="$public_key" -v short_id="$short_id" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vless\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\", "; print "      \"flow\": \"" flow_type "\"," transport_config ""; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" server_name "\", "; print "        \"utls\": {"; print "          \"enabled\": true,"; print "          \"fingerprint\": \"chrome\""; print "        },"; print "        \"reality\": {"; print "          \"enabled\": true,"; print "          \"public_key\": \"" public_key "\","; print "          \"short_id\": \"" short_id "\""; print "        }"; print "      }" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"
    else
    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v flow_type="$flow_type" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"vless\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"uuid\": \"" user_uuid "\"," transport_config ""; print "      \"flow\": \"" flow_type "\"" multiplex_client_config ""; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"
    fi

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 VLESS+TCP Clash 客户端配置
function generate_vless_tcp_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vless-tcp-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vless"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    network: tcp"; print "    udp: true"; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VLESS+WebSocket Clash 客户端配置
function generate_vless_ws_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vless-ws-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_path="$transport_path" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vless"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    network: ws"; print "    udp: true"; print "    ws-opts:"; print "      path: " transport_path; print "      max-early-data: 2048"; print "      early-data-header-name: Sec-WebSocket-Protocol"; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VLESS+gRPC Clash 客户端配置
function generate_vless_grpc_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vless-grpc-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v transport_service_name="$transport_service_name" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vless"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    network: grpc"; print "    udp: true"; print "    grpc-opts:"; print "      grpc-service-name:", "\"" transport_service_name "\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VLESS+Vision+REALITY Clash 客户端配置
function generate_vless_reality_vision_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vless-reality-vision-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v public_key="$public_key" -v short_id="$short_id" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vless"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    network: tcp"; print "    udp: true"; print "    tls: true"; print "    flow: xtls-rprx-vision"; print "    servername:", server_name; print "    reality-opts:"; print "      public-key:", public_key; print "      short-id:", short_id; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 VLESS+gRPC+REALITY Clash 客户端配置
function generate_vless_reality_grpc_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="vless-reality-grpc-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v server_name="$server_name" -v listen_port="$listen_port" -v user_uuid="$user_uuid" -v public_key="$public_key" -v short_id="$short_id" -v transport_service_name="$transport_service_name" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: vless"; print "    server:", local_ip; print "    port:", listen_port; print "    uuid:", user_uuid; print "    network: grpc"; print "    udp: true"; print "    tls: true"; print "    flow: "; print "    servername:", server_name; print "    reality-opts:"; print "      public-key:", public_key; print "      short-id:", short_id; print "    grpc-opts:"; print "      grpc-service-name:", "\"" transport_service_name "\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 Trojan 手机客户端配置
function generate_trojan_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local proxy_name
    local server_name="$domain"
    local server_value
    local tls_insecure

    if [[ -z "$domain" && -n "$domain_name" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    elif [[ -z "$domain" && -z "$domain_name" ]]; then
        server_value="$local_ip"
    elif [[ -z "$domain_name" && -n "$domain" ]]; then
        server_name="$domain"
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="trojan-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file"; then
            break
        fi
    done

    if  [[ -n "$domain" || -n "$domain_name" ]]; then
    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_password="$user_password" -v transport_config="$transport_config" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"trojan\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"password\": \"" user_password "\"," transport_config " "; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      }"multiplex_client_config""; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"
    else
    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_password="$user_password" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"trojan\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port "," transport_config " "; print "      \"password\": \"" user_password "\""multiplex_client_config""; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"
    fi

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 Trojan Windows 客户端配置
function generate_trojan_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local proxy_name
    local server_name="$domain"
    local server_value
    local tls_insecure

    if [[ -z "$domain" && -n "$domain_name" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    elif [[ -z "$domain" && -z "$domain_name" ]]; then
        server_value="$local_ip"
    elif [[ -z "$domain_name" && -n "$domain" ]]; then
        server_name="$domain"
        server_value="$domain"
        tls_insecure="false"
    fi

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    if [[ -n "$ech_config" ]]; then
        ech_client_config=",\n        \"ech\": {\n          \"enabled\": true,\n          \"config\": [\n$ech_config\n          ]\n        }"
    fi

    while true; do
        proxy_name="trojan-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file"; then
            break
        fi
    done

    if  [[ -n "$domain" || -n "$domain_name" ]]; then
    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_password="$user_password" -v transport_config="$transport_config" -v tls_insecure="$tls_insecure" -v ech_client_config="$ech_client_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"trojan\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" server_value "\", "; print "      \"server_port\": " listen_port ","; print "      \"password\": \"" user_password "\"," transport_config " "; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"insecure\": " tls_insecure ","; print "        \"server_name\": \"" server_name "\"" ech_client_config ""; print "      }"multiplex_client_config""; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"
    else
    awk -v proxy_name="$proxy_name" -v local_ip="$local_ip" -v listen_port="$listen_port" -v user_password="$user_password" -v transport_config="$transport_config" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"trojan\","; print "      \"tag\": \"" proxy_name "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port "," transport_config " "; print "      \"password\": \"" user_password "\""multiplex_client_config""; print "    },";} 
   /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"
    fi

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 Trojan+TCP Clash 客户端配置
function generate_trojan_tcp_tls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="trojan-tcp-tls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
       fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_password="$user_password" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: trojan"; print "    server:", server_value; print "    port:", listen_port; print "    password:", user_password; print "    udp: true"; print "    sni:", server_name; print "    skip-cert-verify:", tls_insecure; print "    alpn:"; print "      - h2"; print "      - http/1.1"; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 Trojan+WebSocket+TLS Clash 客户端配置
function generate_trojan_ws_tls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="trojan-ws-tls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_password="$user_password" -v transport_path="$transport_path" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: trojan"; print "    server:", server_value; print "    port:", listen_port; print "    password:", "\"" user_password "\""; print "    network: ws"; print "    sni:", server_name; print "    skip-cert-verify:", tls_insecure; print "    udp: true"; print "    ws-opts:"; print "      path:", transport_path; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 Trojan+gRPC+TLS Clash 客户端配置
function generate_trojan_grpc_tls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local server_name="$domain"
    local proxy_name
    local server_value
    local tls_insecure

    if [[ -z "$domain" ]]; then
        server_name="$domain_name"
        server_value="$local_ip"
        tls_insecure="true"
    else
        server_value="$domain"
        tls_insecure="false"
    fi

    while true; do
        proxy_name="trojan-grpc-tls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v server_value="$server_value" -v server_name="$server_name" -v listen_port="$listen_port" -v user_password="$user_password" -v transport_service_name="$transport_service_name" -v tls_insecure="$tls_insecure" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: trojan"; print "    server:", server_value; print "    port:", listen_port; print "    password:", "\"" user_password "\""; print "    network: grpc"; print "    sni:", server_name; print "    udp: true"; print "    skip-cert-verify:", tls_insecure; print "    grpc-opts:"; print "      grpc-service-name:", "\"" transport_service_name "\""; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 ShadowTLS Windows 客户端配置
function generate_shadowtls_win_client_config() {
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local proxy_name
    local shadowtls_out

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    while true; do
        proxy_name="shadowtls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        shadowtls_out="stl-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$win_client_file" && ! grep -q "name: $shadowtls_out" "$win_client_file" && [ "$proxy_name" != "$shadowtls_out" ]; then
            break
        fi
    done

    awk -v shadowtls_out="$shadowtls_out" -v proxy_name="$proxy_name" -v method="$method" -v ss_password="$ss_password" -v local_ip="$local_ip" -v listen_port="$listen_port" -v stls_password="$stls_password" -v user_input="$user_input" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"shadowsocks\","; print "      \"tag\": \"" proxy_name "\","; print "      \"method\": \"" method "\", "; print "      \"password\": \"" ss_password "\","; print "      \"detour\": \"" shadowtls_out "\""multiplex_client_config""; print "    },"; print "    {"; print "      \"type\": \"shadowtls\","; print "      \"tag\": \"" shadowtls_out "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"version\": 3, "; print "      \"password\": \""stls_password"\", "; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" user_input "\", "; print "        \"utls\": {"; print "          \"enabled\": true,"; print "          \"fingerprint\": \"chrome\" "; print "        }"; print "      }"; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$win_client_file" > "$win_client_file.tmp"

    mv "$win_client_file.tmp" "$win_client_file"
}

# 生成 ShadowTLS 手机客户端配置
function generate_shadowtls_phone_client_config() {
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local proxy_name
    local shadowtls_out

    if [[ -n "$multiplex_config" && -n "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $down_mbps,\n          \"down_mbps\": $up_mbps\n        }\n      }"
    elif [[ -n "$multiplex_config" && -z "$brutal_config" ]]; then
        multiplex_client_config=",\n      \"multiplex\": {\n        \"enabled\": true,\n        \"protocol\": \"h2mux\",\n        \"max_connections\": 1,\n        \"min_streams\": 4,\n        \"padding\": false\n      }"
    fi

    while true; do
        proxy_name="shadowtls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        shadowtls_out="stl-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$phone_client_file" && ! grep -q "name: $shadowtls_out" "$phone_client_file" && [ "$proxy_name" != "$shadowtls_out" ]; then
            break
        fi
    done

    awk -v shadowtls_out="$shadowtls_out" -v proxy_name="$proxy_name" -v method="$method" -v ss_password="$ss_password" -v local_ip="$local_ip" -v listen_port="$listen_port" -v stls_password="$stls_password" -v user_input="$user_input" -v multiplex_client_config="$multiplex_client_config" '
    /^  "outbounds": \[/ {print; getline; print "    {"; print "      \"type\": \"shadowsocks\","; print "      \"tag\": \"" proxy_name "\","; print "      \"method\": \"" method "\", "; print "      \"password\": \"" ss_password "\","; print "      \"detour\": \"" shadowtls_out "\""multiplex_client_config""; print "    },"; print "    {"; print "      \"type\": \"shadowtls\","; print "      \"tag\": \"" shadowtls_out "\","; print "      \"server\": \"" local_ip "\", "; print "      \"server_port\": " listen_port ","; print "      \"version\": 3, "; print "      \"password\": \""stls_password"\", "; print "      \"tls\": {"; print "        \"enabled\": true,"; print "        \"server_name\": \"" user_input "\", "; print "        \"utls\": {"; print "          \"enabled\": true,"; print "          \"fingerprint\": \"chrome\" "; print "        }"; print "      }"; print "    },";} 
    /^      "outbounds": \[/ {print; getline; if ($0 ~ /^      \],$/) {print "        \"" proxy_name "\""} else {print "        \"" proxy_name "\", "} }    
    {print}' "$phone_client_file" > "$phone_client_file.tmp"

    mv "$phone_client_file.tmp" "$phone_client_file"
}

# 生成 ShadowTLS Clash 客户端配置
function generate_shadowtls_yaml() {
    local filename="/usr/local/etc/sing-box/clash.yaml"
    local proxy_name

    while true; do
        proxy_name="shadowtls-$(head /dev/urandom | tr -dc '0-9' | head -c 4)"
        if ! grep -q "name: $proxy_name" "$filename"; then
            break
        fi
    done

    awk -v proxy_name="$proxy_name" -v method="$method" -v ss_password="$ss_password" -v local_ip="$local_ip" -v listen_port="$listen_port" -v stls_password="$stls_password" -v user_input="$user_input" '/^proxies:$/ {print; print "  - name: " proxy_name; print "    type: ss"; print "    server:", local_ip; print "    port:", listen_port; print "    cipher:", method; print "    password:", "\"" ss_password "\""; print "    plugin: shadow-tls"; print "    plugin-opts:"; print "      host: \"" user_input "\""; print "      password:", "\"" stls_password "\""; print "      version: 3"; print ""; next} /- name: Proxy/ { print; flag_proxy=1; next } flag_proxy && flag_proxy++ == 3 { print "      - " proxy_name } /- name: auto/ { print; flag_auto=1; next } flag_auto && flag_auto++ == 3 { print "      - " proxy_name } 1' "$filename" > temp_file && mv temp_file "$filename"
}

# 生成 NaiveProxy Windows 客户端配置
function generate_naive_win_client_config() {
    local naive_client_file="$naive_client_filename"

    sed -i -e "s,user_name,$user_name," -e "s,user_password,$user_password," -e "s,listen_port,$listen_port," -e "s,server_name,$domain," "$naive_client_file"
    echo "电脑端配置文件已保存至$naive_client_file，请下载后使用！"
}

# 提取节点配置中的协议类型和标签
function extract_types_tags() {
    local config_files=("$sing_box_config_file" "$juicity_config_file")
    local detour_tag wireguard_type type tag
    local i=0 max_length=0
    filtered_tags=()
    types=()

    if [[ ! -f "$sing_box_config_file" && ! -f "$juicity_config_file" ]]; then
        echo "未检测到节点配置，请搭建节点后再使用本选项！"
        exit 1
    fi

    for cfg in "${config_files[@]}"; do
        if [[ -f "$cfg" ]]; then
            if [[ "$cfg" == "$sing_box_config_file" ]]; then
                mapfile -t tags < <(jq -r '.inbounds[] | select(.tag != null) | .tag' "$cfg")
                detour_tag=$(jq -r '.inbounds[] | select(.type == "shadowtls") | .detour' "$cfg")
                wireguard_type=$(jq -r '(.endpoints // []) | map(select(.type == "wireguard") | .type)[]?' "$cfg")
                for tag in "${tags[@]}"; do
                    [[ $tag != "$detour_tag" ]] && filtered_tags+=("$tag")
                done
                [[ -n "$wireguard_type" ]] && filtered_tags+=("wg-ep")
            elif [[ "$cfg" == "$juicity_config_file" ]]; then
                filtered_tags+=("juicity-in")
            fi

            for tag in "${filtered_tags[@]:i}"; do
                if [[ "$cfg" == "$sing_box_config_file" && "$tag" == "wg-ep" ]]; then
                    type="$wireguard_type"
                elif [[ "$cfg" == "$sing_box_config_file" ]]; then
                    type=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .type' "$cfg")
                else
                    type="juicity"
                fi
                types[i]="$type"
                (( ${#tag} > max_length )) && max_length=${#tag}
                printf "%d). 协议类型: %-20s 入站标签: %s\n" "$((++i))" "$type" "$tag"
            done
        fi
    done
}

# 选择要删除的节点
function select_node_choice() {
    local choice valid_choice=false

    while [[ $valid_choice == false ]]; do
        read -p "请选择要删除的节点配置（请输入对应的数字，输入 0 返回主菜单）: " choice
        if [[ $choice == 0 ]]; then
            return 1
        elif [[ ! $choice =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#types[@]} ]]; then
            echo -e "${RED}错误：无效的选择，请重新输入！${NC}"
        else
            valid_choice=true
        fi
    done

    selected_tag="${filtered_tags[choice-1]}"
    selected_type="${types[choice-1]}"
    if [[ "$selected_type" != "juicity" ]]; then
        listen_port=$(jq -r --arg selected_tag "$selected_tag" '.inbounds[] | select(.tag == $selected_tag) | .listen_port' "$sing_box_config_file" | awk '{print int($0)}')
    fi
}

# 删除配置文件中相关配置
function process_config_deletion() {
    if [[ "$selected_type" == "wireguard" ]]; then
        jq 'del(.endpoints)' "$sing_box_config_file" > "$temp_json" && mv "$temp_json" "$sing_box_config_file"
        jq '.route.rules |= map(select(.outbound != "wg-ep"))' "$sing_box_config_file" > "$temp_json" && mv "$temp_json" "$sing_box_config_file"
        jq 'del(.route.rule_set)' "$sing_box_config_file" > "$temp_json" && mv "$temp_json" "$sing_box_config_file"
    elif [[ "$selected_type" == "juicity" ]]; then
        systemctl stop juicity.service
        systemctl disable juicity.service
        rm -rf /etc/systemd/system/juicity.service
        rm -rf /usr/local/etc/juicity
        rm -rf /usr/local/bin/juicity-server
    else
        detour_tag=$(jq -r --arg selected_tag "$selected_tag" '.inbounds[] | select(.type == "shadowtls" and .tag == $selected_tag) | .detour' "$sing_box_config_file")
        jq --arg selected_tag "$selected_tag" --arg detour_tag "$detour_tag" '.inbounds |= map(select(.tag != $selected_tag and .tag != $detour_tag))' "$sing_box_config_file" > "$temp_json" && mv "$temp_json" "$sing_box_config_file"
        jq --arg selected_tag "$selected_tag" '.route.rules |= map(.inbound |= map(select(. != $selected_tag)))' "$sing_box_config_file" > "$temp_json" && mv "$temp_json" "$sing_box_config_file"
    fi
}

# 删除 output 中对应端口的条目
function process_output_file_deletion() {
    if [[ "$selected_type" != "wireguard" && "$selected_type" != "juicity" ]]; then
        awk -v port="$listen_port" '$0 ~ "监听端口: " port {print; in_block=1; next} in_block && NF == 0 {in_block=0} !in_block' "$sing_box_output_file" > "$sing_box_output_file.tmp1"
        mv "$sing_box_output_file.tmp1" "$sing_box_output_file"
        awk -v port="$listen_port" '$0 ~ "监听端口: " port {start=NR; next} {lines[NR]=$0} END {for (i=1; i<=NR; i++) if (i < start - 4 || i > start) print lines[i]}' "$sing_box_output_file" > "$sing_box_output_file.tmp2"
        mv "$sing_box_output_file.tmp2" "$sing_box_output_file"
        sed -i '/./,$!d' "$sing_box_output_file"
    fi
}

# 提取 Clash 配置相关标签
function process_clash_yaml_deletion() {
    if [[ -f "$clash_yaml" && "$selected_type" != "juicity" ]]; then
        awk '/proxies:/ {in_proxies_block=1} in_proxies_block && /- name:/ {name = $3} in_proxies_block && /port:/ {port = $2; print "Name:", name, "Port:", port}' "$clash_yaml" > "$temp_yaml"
        matching_clash_tag=$(grep "Port: $listen_port" "$temp_yaml" | awk '{print $2}')
    fi
}

# 检查防火墙端口转发规则
function process_firewall_rules_deletion() {
    for table in iptables ip6tables; do
        if command -v $table &> /dev/null; then
            while read -r line; do
                if [[ "$line" =~ (tcp|udp)[[:space:]]+dpts?:([0-9]+):([0-9]+)[^[:alnum:]]+to::([0-9]+) ]]; then
                    protocol="${BASH_REMATCH[1]}"
                    d_start="${BASH_REMATCH[2]}"
                    d_end="${BASH_REMATCH[3]}"
                    d_target="${BASH_REMATCH[4]}"
                    if [[ "$d_target" == "$listen_port" ]]; then
                        start_port="$d_start"
                        end_port="$d_end"
                        break 2
                    fi
                fi
            done < <($table -t nat -nL PREROUTING)
        fi
    done
}

# 提取客户端要删除的标签
function process_client_files_deletion() {
    if [[ -f "$phone_client_file" && -f "$win_client_file" ]]; then
        if [[ -n "$listen_port" ]]; then
            if [[ -n "$start_port" && -n "$end_port" ]]; then
                phone_matching_tags=$(jq -r --arg target "$start_port:$end_port" '.outbounds[] | select((.server_ports // []) | index($target)) | .tag' "$phone_client_file")
                win_matching_tags=$(jq -r --arg target "$start_port:$end_port" '.outbounds[] | select((.server_ports // []) | index($target)) | .tag' "$win_client_file")
            else
                phone_matching_tags=$(jq -r --argjson listen_port "$listen_port" '.outbounds[] | select(.server_port == $listen_port) | .tag' "$phone_client_file")
                win_matching_tags=$(jq -r --argjson listen_port "$listen_port" '.outbounds[] | select(.server_port == $listen_port) | .tag' "$win_client_file")
            fi
        fi
        delete_tags_from_client "$phone_matching_tags" "$phone_client_file"
        delete_tags_from_client "$win_matching_tags" "$win_client_file"
    fi
}

# 更新客户端 JSON 配置和防火墙规则
function delete_tags_from_client() {
    local tags="$1"
    local client_file="$2"

    if [[ ! -f "$client_file" ]]; then
        return
    fi

    echo "$tags" | while read -r tag; do
        if [[ -n "$tag" ]]; then
            if [[ -n "$start_port" && -n "$end_port" ]]; then
                target_port_range="$start_port:$end_port"
                tag_port_range=$(jq -r --arg tag "$tag" '.outbounds[] | select(.tag == $tag) | (.server_ports // [])[0]' "$client_file")
                if [[ "$tag_port_range" == "$target_port_range" ]]; then
                    for table in iptables ip6tables; do
                        if command -v $table &> /dev/null; then
                            rules=$($table -t nat -nL PREROUTING --line-numbers)
                            echo "$rules" | while read -r line; do
                                if [[ "$line" =~ ^([0-9]+)[[:space:]].*(tcp|udp)[[:space:]]+dpts?:$start_port:$end_port.*to::[0-9]+ ]]; then
                                    rule_num="${BASH_REMATCH[1]}"
                                    $table -t nat -D PREROUTING "$rule_num"
                                fi
                            done
                        fi
                    done
                fi
            fi

            jq --arg tag "$tag" '.outbounds |= map(select(.tag != $tag))' "$client_file" > "$temp_json" && mv "$temp_json" "$client_file"

            local matching_detour=$(jq -r --arg tag "$tag" '.outbounds[] | select(.detour == $tag) | .detour' "$client_file")
            local matching_detour_tag=$(jq -r --arg detour "$matching_detour" '.outbounds[] | select(.detour == $detour) | .tag' "$client_file")

            awk -v tag="$tag" '!/^      "outbounds": \[$/,/^\s*]/{if (!($0 ~ "^ * \"" tag "\"")) print; else next; }' "$client_file" > "$client_file.tmp"
            mv "$client_file.tmp" "$client_file"

            if [[ "$tag" == "$matching_detour" ]]; then
                jq --arg detour "$matching_detour" '.outbounds |= map(select(.detour != $detour))' "$client_file" > "$temp_json" && mv "$temp_json" "$client_file"
                awk -v detour_tag="$matching_detour_tag" '!/^      "outbounds": \[$/,/^\s*]/{if (!($0 ~ "^ * \"" detour_tag "\"")) print; else next; }' "$client_file" > "$client_file.tmp"
                mv "$client_file.tmp" "$client_file"
            fi
        fi
    done
}

# 整理客户端配置文件格式
function cleanup_files_and_restart() {
    if [[ -n "$matching_clash_tag" && "$selected_type" != "wireguard" ]]; then
        echo "$matching_clash_tag" | while read -r tag; do
            if [[ -n "$tag" ]]; then
                escaped_tag=$(printf '%q' "$tag")
                sed -i "/^  - name: $escaped_tag$/,/^\s*$/d" "$clash_yaml"
                sed -i "/proxy-groups:/,/^\s*$/ {/      - $escaped_tag/d}" "$clash_yaml"
            fi
        done
    fi

    if [[ -f "$phone_client_file" ]]; then
        awk '{if ($0 ~ /],$/ && p ~ /,$/) sub(/,$/, "", p); if (NR > 1) print p; p = $0;}END{print p;}' "$phone_client_file" > "$phone_client_file.tmp"
        mv "$phone_client_file.tmp" "$phone_client_file"
    fi

    if [[ -f "$win_client_file" ]]; then
        awk '{if ($0 ~ /],$/ && p ~ /,$/) sub(/,$/, "", p); if (NR > 1) print p; p = $0;}END{print p;}' "$win_client_file" > "$win_client_file.tmp"
        mv "$win_client_file.tmp" "$win_client_file"
    fi

    if [[ -f "$temp_yaml" ]]; then
        rm "$temp_yaml"
    fi

    if ! jq -e 'select(.inbounds[] | .listen == "::")' "$sing_box_config_file" > /dev/null; then
        sed -i 's/^        "inbound": \[\],/        "inbound": [\n        ],/' "$sing_box_config_file"
        sed -i 's/^  "inbounds": \[\],/  "inbounds": [\n  ],/' "$sing_box_config_file"
        sed -i 's/^      "outbounds": \[\],/      "outbounds": [\n      ],/' "$win_client_file"
        sed -i 's/^      "outbounds": \[\],/      "outbounds": [\n      ],/' "$phone_client_file"
    fi

    update_client_file
    systemctl restart sing-box
}

# 删除指定节点的配置信息
function delete_choice() {
    local sing_box_config_file="/usr/local/etc/sing-box/config.json"
    local juicity_config_file="/usr/local/etc/juicity/config.json"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local sing_box_output_file="/usr/local/etc/sing-box/output.txt"
    local clash_yaml="/usr/local/etc/sing-box/clash.yaml"
    local temp_yaml="/usr/local/etc/sing-box/temp.yaml"
    local temp_json="/usr/local/etc/sing-box/temp.json"

    extract_types_tags
    if ! select_node_choice; then
        return 1
    fi
    process_config_deletion
    process_output_file_deletion
    process_clash_yaml_deletion
    process_firewall_rules_deletion
    process_client_files_deletion
    cleanup_files_and_restart

    echo "已删除 $selected_type 的配置信息，服务端及客户端配置信息已更新，请下载新的配置文件使用！"
}

# 显示 NaiveProxy 节点配置信息
function display_naive_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt" 
    local num_users=${#user_names[@]}

    echo -e "${CYAN}NaiveProxy 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $domain" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"        
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "用 户 名                                  密  码" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i=0; i<num_users; i++)); do
        local user_name="${user_names[i]}"
        local user_password="${user_passwords[i]}"       
        printf "%-38s %s\n" "$user_name" "$user_password" | tee -a "$output_file"
    done      

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 NaiveProxy 客户端配置文件
function generate_naive_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local naive_client_file="$naive_client_filename"
    local num_users=${#user_names[@]}     

    for ((i=0; i<num_users; i++)); do
        local user_name="${user_names[i]}"
        local user_password="${user_passwords[i]}"        
        generate_naive_random_filename
        write_naive_client_file
        generate_naive_win_client_config "$user_name" "$user_password" "$listen_port" "$domain"        
    done
}

# 显示 Direct 节点配置信息
function display_Direct_config() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local override_address=$(jq -r '.inbounds[0].override_address' "$config_file")    

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    echo -e "${CYAN}Direct 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "中转地址: $local_ip" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "目标地址: $override_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "目标端口: $override_port" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 显示并生成 Juicity 节点配置信息
function display_juicity_config() {
    local config_file="/usr/local/etc/juicity/config.json"
    local output_file="/usr/local/etc/juicity/output.txt"
    local server_address
    local congestion_control=$(jq -r '.congestion_control' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" ]]; then
        server_address="$local_ip"
    else
        server_address="$domain"
    fi

    echo -e "${CYAN}Juicity 节点配置信息：${NC}" | tee -a "$output_file"     
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $server_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file" 
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"  
    echo "UUID：$user_uuids         密码：$user_passwords      " | tee -a "$output_file" 
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file" 
    echo "拥塞控制算法: $congestion_control" | tee -a "$output_file" 
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    
    echo "分享链接："
    juicity-server generate-sharelink -c "$config_file"
    
    generate_juicity_win_client_config
    echo "配置信息已保存至 $output_file"
}

# 显示 HTTP 节点配置信息
function display_http_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local num_users=${#user_names[@]}
    local server_address

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" ]]; then
        server_address="$local_ip"
    else
        server_address="$domain"
    fi

    echo -e "${CYAN}HTTP 节点配置信息：${NC}" | tee -a "$output_file"     
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $server_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"        
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "用 户 名                                  密  码" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i=0; i<num_users; i++)); do
        local user_name="${user_names[i]}"
        local user_password="${user_passwords[i]}"       
        printf "%-38s %s\n" "$user_name" "$user_password" | tee -a "$output_file"
    done      

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file" 
}

# 生成 HTTP 客户端配置文件
function display_http_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml" 
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json" 
    local win_client_file="/usr/local/etc/sing-box/win_client.json" 
    local num_users=${#user_names[@]}

    for ((i=0; i<num_users; i++)); do
        local user_name="${user_names[i]}"
        local user_password="${user_passwords[i]}"  

        if [[ "$enable_ech" == true ]]; then
            write_phone_client_file
            write_win_client_file
            generate_http_win_client_config "$user_password"
            generate_http_phone_client_config "$user_password"
        else
            write_phone_client_file
            write_win_client_file
            generate_http_win_client_config "$user_password"
            generate_http_phone_client_config "$user_password"
            ensure_clash_yaml
            write_clash_yaml
            generate_http_yaml
        fi
    done

    if [[ "$enable_ech" == true ]]; then
        echo "手机端配置文件已保存至 $phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至 $win_client_file，请下载后使用！"
    else
        echo "手机端配置文件已保存至 $phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至 $win_client_file，请下载后使用！"
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi
}

# 显示 AnyTLS 节点配置信息
function display_anytls_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local num_users=${#user_names[@]}
    local server_address

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" ]]; then
        server_address="$local_ip"
    else
        server_address="$domain"
    fi

    echo -e "${CYAN}AnyTLS 节点配置信息：${NC}" | tee -a "$output_file"     
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $server_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"        
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "用 户 名                                  密  码" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i=0; i<num_users; i++)); do
        local user_name="${user_names[i]}"
        local user_password="${user_passwords[i]}"       
        printf "%-38s %s\n" "$user_name" "$user_password" | tee -a "$output_file"
    done      

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file" 
}

# 生成 AnyTLS 客户端配置文件
function display_anytls_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml" 
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json" 
    local win_client_file="/usr/local/etc/sing-box/win_client.json" 
    local num_users=${#user_names[@]}

    for ((i=0; i<num_users; i++)); do
        local user_name="${user_names[i]}"
        local user_password="${user_passwords[i]}"  

        if [[ "$enable_ech" == true ]]; then
            write_phone_client_file
            write_win_client_file
            generate_anytls_win_client_config "$user_password"
            generate_anytls_phone_client_config "$user_password"
        else
            write_phone_client_file
            write_win_client_file
            generate_anytls_win_client_config "$user_password"
            generate_anytls_phone_client_config "$user_password"
            ensure_clash_yaml
            write_clash_yaml
            generate_anytls_yaml
        fi
    done

    if [[ "$enable_ech" == true ]]; then
        echo "手机端配置文件已保存至 $phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至 $win_client_file，请下载后使用！"
    else
        echo "手机端配置文件已保存至 $phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至 $win_client_file，请下载后使用！"
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi
}

# 显示 TUIC 节点配置信息
function display_tuic_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local server_address
    local congestion_control=$(jq -r '.inbounds[0].congestion_control' "$config_file")
    local alpn=$(jq -r '.inbounds[0].tls.alpn[0]' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" ]]; then
        server_address="$local_ip"
    else
        server_address="$domain"
    fi

    echo -e "${CYAN}TUIC 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $server_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "用户密码列表:" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"
    echo "  用户名                    UUID                             密码" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i=0; i<${#user_names[@]}; i++)); do
        user_name="${user_names[$i]}"
        user_uuid="${user_uuids[$i]}"
        user_password="${user_passwords[$i]}"
        printf "%-13s %-42s %s\n" "$user_name" "$user_uuid" "$user_password" | tee -a "$output_file"
    done

    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "拥塞控制算法: $congestion_control" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "ALPN: $alpn" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 TUIC 客户端配置文件
function display_tuic_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local congestion_control=$(jq -r '.inbounds[0].congestion_control' "$config_file")
    local alpn=$(jq -r '.inbounds[0].tls.alpn[0]' "$config_file")
    local num_users=${#user_uuids[@]}

    for ((i=0; i<num_users; i++)); do
        local user_uuid="${user_uuids[i]}"
        local user_password="${user_passwords[i]}"

        if [[ "$enable_ech" == true ]]; then
            write_phone_client_file
            write_win_client_file
            generate_tuic_win_client_config "$user_uuid" "$user_password"
            generate_tuic_phone_client_config "$user_uuid" "$user_password"
        else
            write_phone_client_file
            write_win_client_file
            generate_tuic_win_client_config "$user_uuid" "$user_password"
            generate_tuic_phone_client_config "$user_uuid" "$user_password"
            ensure_clash_yaml
            write_clash_yaml
            generate_tuic_yaml
        fi
    done

    if [[ "$enable_ech" == true ]]; then
        echo "手机端配置文件已保存至 $phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至 $win_client_file，请下载后使用！"
    else
        echo "手机端配置文件已保存至 $phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至 $win_client_file，请下载后使用！"
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi
}

# 显示 Shadowsocks 配置文件信息
function display_Shadowsocks_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local ss_method=$(jq -r '.inbounds[0].method' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    echo -e "${CYAN}Shadowsocks 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $local_ip" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "加密方式: $ss_method" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "密码: $ss_passwords" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 Shadowsocks 客户端配置文件
function display_Shadowsocks_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local ss_method=$(jq -r '.inbounds[0].method' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    write_phone_client_file
    write_win_client_file
    generate_shadowsocks_win_client_config
    generate_shadowsocks_phone_client_config
    ensure_clash_yaml
    write_clash_yaml
    generate_shadowsocks_yaml

    echo "手机端配置文件已保存至 $phone_client_file，请下载后使用！"
    echo "电脑端配置文件已保存至 $win_client_file，请下载后使用！"
    echo "Clash配置文件已保存至 $clash_file，请下载使用！"
}

# 显示 SOCKS 节点配置信息
function display_socks_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    echo -e "${CYAN}SOCKS 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $local_ip" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "用户密码列表:" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"
    echo "用户名                                 密码" | tee -a "$output_file"

    for ((i=0; i<${#user_names[@]}; i++)); do
        user_name="${user_names[$i]}"
        user_password="${user_passwords[$i]}"
        printf "%-35s %s\n" "$user_name" "$user_password" | tee -a "$output_file"
    done

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "节点配置信息已保存至 $output_file"
}

# 生成 SOCKS 客户端配置文件
function display_socks_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local num_users=${#user_names[@]}

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    for ((i=0; i<num_users; i++)); do
        local user_name="${user_names[i]}"
        local user_password="${user_passwords[i]}"
        write_phone_client_file
        write_win_client_file
        generate_socks_win_client_config "$user_name" "$user_password"
        generate_socks_phone_client_config "$user_name" "$user_password"
        ensure_clash_yaml
        write_clash_yaml
        generate_socks_yaml
    done

    echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
    echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
    echo "Clash配置文件已保存至 $clash_file ,请下载使用！"
}

# 显示 Hysteria 节点配置信息
function display_Hysteria_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local server_address
    local alpn=$(jq -r '.inbounds[0].tls.alpn[0]' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" ]]; then
        server_address="$local_ip"
    else
        server_address="$domain"
    fi

    echo -e "${CYAN}Hysteria 节点配置信息：${NC}"  | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}"  | tee -a "$output_file"
    echo "服务器地址：$server_address"  | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}"  | tee -a "$output_file"
    echo "监听端口: $listen_port"  | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}"  | tee -a "$output_file"
    echo "端口跳跃范围: $start_port:$end_port"  | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}"  | tee -a "$output_file"
    echo "上行速度：${up_mbps}Mbps"  | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}"  | tee -a "$output_file"
    echo "下行速度：${down_mbps}Mbps"  | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}"  | tee -a "$output_file"
    echo "ALPN：$alpn"  | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}"  | tee -a "$output_file"
    echo "用户名                                   密码"  | tee -a "$output_file"
    echo "------------------------------------------------------------------------------"  | tee -a "$output_file"

    for ((i=0; i<${#user_names[@]}; i++)); do
        user_name="${user_names[$i]}"
        user_password="${user_passwords[$i]}"
        printf "%-35s %s\n" "$user_name" "$user_password" | tee -a "$output_file"
    done

    if [[ -n "$obfs_password" ]]; then
        echo -e "${CYAN}------------------------------------------------------------------------------${NC}"  | tee -a "$output_file"
        echo "obfs混淆密码：$obfs_password"  | tee -a "$output_file"
    fi

    echo -e "${CYAN}==============================================================================${NC}"  | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 Hysteria 客户端配置文件
function display_Hysteria_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local alpn=$(jq -r '.inbounds[0].tls.alpn[0]' "$config_file")

    for ((i=0; i<${#user_passwords[@]}; i++)); do
        user_password="${user_passwords[$i]}"
        
        if [[ "$enable_ech" == true ]]; then
            write_phone_client_file
            write_win_client_file
            generate_Hysteria_win_client_config "$user_password"
            generate_Hysteria_phone_client_config "$user_password"
        else
            write_phone_client_file
            write_win_client_file
            generate_Hysteria_win_client_config "$user_password"
            generate_Hysteria_phone_client_config "$user_password"
            ensure_clash_yaml
            write_clash_yaml
            generate_Hysteria_yaml
        fi
    done

    if [[ "$enable_ech" == true ]]; then
        echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
    else
        echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi
}

# 显示 Hysteria2 节点配置信息
function display_Hy2_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local server_address
    local alpn=$(jq -r '.inbounds[0].tls.alpn[0]' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" ]]; then
        server_address="$local_ip"
    else
        server_address="$domain"
    fi

    echo -e "${CYAN}Hysteria2 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址：$server_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "端口跳跃范围: $start_port:$end_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "上行速度：${up_mbps}Mbps" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "下行速度：${down_mbps}Mbps" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "ALPN：$alpn" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "用户名                                  密码" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i=0; i<${#user_names[@]}; i++)); do
        user_name="${user_names[$i]}"
        user_password="${user_passwords[$i]}"
        printf "%-35s %s\n" "$user_name" "$user_password" | tee -a "$output_file"
    done

    if [[ -n "$obfs_password" ]]; then
        echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
        echo "QUIC 流量混淆器密码：$obfs_password" | tee -a "$output_file"
    fi

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 Hysteria2 客户端配置文件
function display_Hy2_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local alpn=$(jq -r '.inbounds[0].tls.alpn[0]' "$config_file")

    for ((i=0; i<${#user_passwords[@]}; i++)); do
        user_password="${user_passwords[$i]}"

        if [[ "$enable_ech" == true ]]; then
            write_phone_client_file
            write_win_client_file
            generate_Hysteria2_win_client_config "$user_password"
            generate_Hysteria2_phone_client_config "$user_password"
        else
            write_phone_client_file
            write_win_client_file
            generate_Hysteria2_win_client_config "$user_password"
            generate_Hysteria2_phone_client_config "$user_password"
            ensure_clash_yaml
            write_clash_yaml
            generate_Hysteria2_yaml
        fi
    done

    if [[ "$enable_ech" == true ]]; then
        echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
    else
        echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi
}

# 显示 VLESS 节点配置信息
function display_reality_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local flow_type=$(jq -r '.inbounds[0].users[0].flow' "$config_file")
    local transport_type=$(jq -r '.inbounds[0].transport.type' "$config_file")
    local server_name=$(jq -r '.inbounds[0].tls.server_name' "$config_file")
    local target_server=$(jq -r '.inbounds[0].tls.reality.handshake.server' "$config_file")
    local transport_service_name=$(jq -r '.inbounds[0].transport.service_name' "$config_file")
    local local_public_key="$public_key"

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ "$flow_type" == "xtls-rprx-vision" ]]; then
        transport_type="tcp"
    fi

    echo -e "${CYAN}VLESS 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $local_ip" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "UUID列表:" | tee -a "$output_file"

    for ((i=0; i<${#user_uuids[@]}; i++)); do
        user_uuid="${user_uuids[$i]}"
        echo "$user_uuid" | tee -a "$output_file"
    done

    if [[ -n "$flow_type" ]]; then
        echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
        echo "流控类型: $flow_type" | tee -a "$output_file"
    fi

    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"

    if [[ "$transport_type" != "null" ]]; then
        echo "传输协议: $transport_type" | tee -a "$output_file"
        if [[ "$transport_type" == "ws" || "$transport_type" == "httpupgrade" ]]; then
            echo "路径: $transport_path" | tee -a "$output_file"
        elif [[ "$transport_type" == "grpc" ]]; then
            echo "grpc-service-name: $transport_service_name" | tee -a "$output_file"
        fi
    else
        echo "传输协议: tcp" | tee -a "$output_file"
    fi

    if [[ -n "$server_name" && "$server_name" != "null" ]]; then
        echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
        echo "ServerName: $server_name" | tee -a "$output_file"
    fi

    if [[ -n "$target_server" && "$target_server" != "null" ]]; then
        echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
        echo "目标网站地址: $target_server" | tee -a "$output_file"
    fi

    if [[ -n "$short_id" ]]; then
        echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
        echo "Short ID:" | tee -a "$output_file"
        for ((i=0; i<${#short_ids[@]}; i++)); do
            short_id="${short_ids[$i]}"
            echo "$short_id" | tee -a "$output_file"
        done
    fi

    if [[ -n "$public_key" ]]; then
        echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
        echo "PublicKey: $public_key" | tee -a "$output_file"
    fi

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 VLESS 客户端配置文件
function display_reality_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local flow_type=$(jq -r '.inbounds[0].users[0].flow' "$config_file")
    local transport_type=$(jq -r '.inbounds[0].transport.type' "$config_file")
    local server_name=$(jq -r '.inbounds[0].tls.server_name' "$config_file")
    local target_server=$(jq -r '.inbounds[0].tls.reality.handshake.server' "$config_file")
    local transport_service_name=$(jq -r '.inbounds[0].transport.service_name' "$config_file")
    local local_public_key="$public_key"

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    for ((i=0; i<${#user_uuids[@]}; i++)); do
        local user_uuid="${user_uuids[$i]}"
        write_phone_client_file
        write_win_client_file

        if [[ "$server_name" == "null" ]] && [[ "$transport_type" == "null" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vless_tcp_yaml
            generate_vless_win_client_config
            generate_vless_phone_client_config
        elif [[ "$server_name" == "null" ]] && [[ "$transport_type" == "ws" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vless_ws_yaml
            generate_vless_win_client_config
            generate_vless_phone_client_config
        elif [[ "$server_name" == "null" ]] && [[ "$transport_type" == "grpc" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vless_grpc_yaml
            generate_vless_win_client_config
            generate_vless_phone_client_config
        elif [[ "$server_name" == "null" ]] && [[ "$transport_type" == "httpupgrade" ]]; then
            generate_vless_win_client_config
            generate_vless_phone_client_config
        fi

        for ((j=0; j<${#short_ids[@]}; j++)); do
            local short_id="${short_ids[$j]}"
            write_phone_client_file
            write_win_client_file

            if [[ -n "$server_name" ]] && [[ "$server_name" != "null" ]] && [[ "$transport_type" == "null" ]]; then
                ensure_clash_yaml
                write_clash_yaml
                generate_vless_reality_vision_yaml
                generate_vless_win_client_config
                generate_vless_phone_client_config
            elif [[ -n "$server_name" ]] && [[ "$server_name" != "null" ]] && [[ "$transport_type" == "http" ]]; then
                generate_vless_win_client_config
                generate_vless_phone_client_config
            elif [[ -n "$server_name" ]] && [[ "$server_name" != "null" ]] && [[ "$transport_type" == "grpc" ]]; then
                ensure_clash_yaml
                write_clash_yaml
                generate_vless_reality_grpc_yaml
                generate_vless_win_client_config
                generate_vless_phone_client_config
            fi
        done
    done

    if [[ "$transport_type" != "http" && "$transport_type" != "httpupgrade" ]]; then
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi

    echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
    echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
}

# 显示 VMess 节点配置信息
function display_vmess_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local server_address
    local transport_type=$(jq -r '.inbounds[0].transport.type' "$config_file")
    local transport_path=$(jq -r '.inbounds[0].transport.path' "$config_file")
    local transport_service_name=$(jq -r '.inbounds[0].transport.service_name' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" && -n "$domain_name" ]]; then
        server_address="$local_ip"
    elif [[ -z "$domain" && -z "$domain_name" ]]; then
        server_address="$local_ip"
    elif [[ -n "$domain" ]]; then
        server_address="$domain"
    fi

    echo -e "${CYAN}VMess 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $server_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "UUID列表:" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i=0; i<${#user_uuids[@]}; i++)); do
        user_uuid="${user_uuids[$i]}"
        echo "$user_uuid" | tee -a "$output_file"
    done

    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"

    if [[ "$transport_type" != "null" ]]; then
        echo "传输协议: $transport_type" | tee -a "$output_file"
        if [[ "$transport_type" == "ws" ]]; then
            echo "路径: $transport_path" | tee -a "$output_file"
        elif [[ "$transport_type" == "httpupgrade" ]]; then
            echo "路径: $transport_path" | tee -a "$output_file"
        elif [[ "$transport_type" == "grpc" ]]; then
            echo "grpc-service-name: $transport_service_name" | tee -a "$output_file"
        fi
    else
        echo "传输协议: tcp" | tee -a "$output_file"
    fi

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 VMess 客户端配置文件
function display_vmess_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local transport_type=$(jq -r '.inbounds[0].transport.type' "$config_file")
    local transport_path=$(jq -r '.inbounds[0].transport.path' "$config_file")
    local transport_service_name=$(jq -r '.inbounds[0].transport.service_name' "$config_file")
    local show_clash_message=true

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    for ((i=0; i<${#user_uuids[@]}; i++)); do
        user_uuid="${user_uuids[$i]}"
        write_phone_client_file
        write_win_client_file
        generate_vmess_win_client_config
        generate_vmess_phone_client_config

        if [[ "$enable_ech" != true && -z "$domain" && -z "$domain_name" && "$transport_type" == "null" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vmess_tcp_yaml
        elif [[ "$enable_ech" != true && -z "$domain" && -z "$domain_name" && "$transport_type" == "ws" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vmess_ws_yaml
        elif [[ "$enable_ech" != true && -z "$domain" && -z "$domain_name" && "$transport_type" == "grpc" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vmess_grpc_yaml
        elif [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" == "null" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vmess_tcp_tls_yaml
        elif [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" == "ws" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vmess_ws_tls_yaml
        elif [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" == "grpc" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_vmess_grpc_tls_yaml
        elif [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" == "http" ]]; then
            show_clash_message=false
        fi
    done

    if [[ "$transport_type" == "http" || "$transport_type" == "httpupgrade" || "$enable_ech" == true ]]; then
        echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
    else
        echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
        echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi
}

# 显示 Trojan 节点配置信息
function display_trojan_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local server_address
    local transport_type=$(jq -r '.inbounds[0].transport.type' "$config_file")
    local transport_path=$(jq -r '.inbounds[0].transport.path' "$config_file")
    local transport_service_name=$(jq -r '.inbounds[0].transport.service_name' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    if [[ -z "$domain" && -n "$domain_name" ]]; then
        server_address="$local_ip"
    elif [[ -z "$domain" && -z "$domain_name" ]]; then
        server_address="$local_ip"
    elif [[ -n "$domain" ]]; then
        server_address="$domain"
    fi

    echo -e "${CYAN}Trojan 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $server_address" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "密码列表:" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i = 0; i < ${#user_passwords[@]}; i++)); do
        user_password="${user_passwords[i]}"
        echo "$user_password" | tee -a "$output_file"
    done

    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"

    if [[ "$transport_type" != "null" ]]; then
        echo "传输协议: $transport_type" | tee -a "$output_file"
        if [[ "$transport_type" == "ws" ]]; then
            echo "路径: $transport_path" | tee -a "$output_file"
        elif [[ "$transport_type" == "httpupgrade" ]]; then
            echo "路径: $transport_path" | tee -a "$output_file"
        elif [[ "$transport_type" == "grpc" ]]; then
            echo "grpc-service-name: $transport_service_name" | tee -a "$output_file"
        fi
    else
        echo "传输协议: tcp" | tee -a "$output_file"
    fi

    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 Trojan 客户端配置文件
function display_trojan_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local transport_type=$(jq -r '.inbounds[0].transport.type' "$config_file")
    local transport_path=$(jq -r '.inbounds[0].transport.path' "$config_file")
    local transport_service_name=$(jq -r '.inbounds[0].transport.service_name' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi 

    for ((i = 0; i < ${#user_passwords[@]}; i++)); do
        user_password="${user_passwords[i]}"
        write_phone_client_file
        write_win_client_file
        generate_trojan_win_client_config
        generate_trojan_phone_client_config

        if [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" == "null" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_trojan_tcp_tls_yaml
        elif [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" == "ws" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_trojan_ws_tls_yaml
        elif [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" == "grpc" ]]; then
            ensure_clash_yaml
            write_clash_yaml
            generate_trojan_grpc_tls_yaml
        fi       
    done

    if [[ "$enable_ech" != true && ( -n "$domain" || -n "$domain_name" ) && "$transport_type" != "http" && "$transport_type" != "httpupgrade" ]]; then
        echo "Clash配置文件已保存至 $clash_file，请下载使用！"
    fi    

    echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
    echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
}

# 显示 ShadowTLS 节点配置信息
function display_shadowtls_config_info() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local output_file="/usr/local/etc/sing-box/output.txt"
    local user_input=$(jq -r '.inbounds[0].handshake.server' "$config_file")
    local method=$(jq -r '.inbounds[1].method' "$config_file")

    if [[ -n "$ip_v4" ]]; then
        local_ip="$ip_v4"
    elif [[ -n "$ip_v6" ]]; then
        local_ip="$ip_v6"
    fi

    echo -e "${CYAN}ShadowTLS 节点配置信息：${NC}" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "服务器地址: $local_ip" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "监听端口: $listen_port" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "加密方式: $method" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "ShadowTLS用户名                  ShadowTLS密码" | tee -a "$output_file"
    echo "------------------------------------------------------------------------------" | tee -a "$output_file"

    for ((i = 0; i < ${#stls_passwords[@]}; i++)); do
        local stls_password="${stls_passwords[i]}"
        printf "%-25s %s\n" "$user_name" "$stls_password" | tee -a "$output_file"
    done 

    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "Shadowsocks 密码: $ss_passwords" | tee -a "$output_file"
    echo -e "${CYAN}------------------------------------------------------------------------------${NC}" | tee -a "$output_file"
    echo "握手服务器地址: $user_input" | tee -a "$output_file"
    echo -e "${CYAN}==============================================================================${NC}" | tee -a "$output_file"
    echo "" >> "$output_file"
    echo "配置信息已保存至 $output_file"
}

# 生成 ShadowTLS 客户端配置文件
function display_shadowtls_config_files() {
    local config_file="/usr/local/etc/sing-box/config.json"
    local clash_file="/usr/local/etc/sing-box/clash.yaml"
    local phone_client_file="/usr/local/etc/sing-box/phone_client.json"
    local win_client_file="/usr/local/etc/sing-box/win_client.json"
    local user_input=$(jq -r '.inbounds[0].handshake.server' "$config_file")
    local method=$(jq -r '.inbounds[1].method' "$config_file")

    for ((i = 0; i < ${#stls_passwords[@]}; i++)); do
        local stls_password="${stls_passwords[i]}"
        write_phone_client_file
        write_win_client_file
        generate_shadowtls_win_client_config "$stls_password"
        generate_shadowtls_phone_client_config "$stls_password"
        ensure_clash_yaml
        write_clash_yaml
        generate_shadowtls_yaml
    done

    echo "手机端配置文件已保存至$phone_client_file，请下载后使用！"
    echo "电脑端配置文件已保存至$win_client_file，请下载后使用！"
    echo "Clash配置文件已保存至 $clash_file，请下载使用！"
}

# 查看已保存的配置信息文件
function view_saved_config() {
    local config_paths=(
        "/usr/local/etc/sing-box/output.txt"
        "/usr/local/etc/juicity/output.txt"
    )
    local found=false

    for path in "${config_paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "配置信息文件 ($path):"
            cat "$path"
            found=true
        fi
    done

    if [[ "$found" == false ]]; then
        echo "未找到保存的配置信息文件！"
    fi
}

# 卸载 sing-box
function uninstall_sing_box() {
    echo "开始卸载 sing-box..."
    systemctl stop sing-box
    systemctl disable sing-box
    rm -rf /usr/local/bin/sing-box
    rm -rf /usr/local/etc/sing-box
    rm -rf /etc/systemd/system/sing-box.service

    for table in iptables ip6tables; do
        if command -v $table &> /dev/null; then
            $table -t nat -F &>/dev/null
        fi
    done

    systemctl daemon-reload
    echo "sing-box 卸载完成。"
}

# 卸载 juicity
function uninstall_juicity() {
    echo "开始卸载 juicity..."
    systemctl stop juicity.service
    systemctl disable juicity.service
    rm -rf /etc/systemd/system/juicity.service
    rm -rf /usr/local/etc/juicity
    rm -rf /usr/local/bin/juicity-server
    echo "juicity 卸载完成。"
}

# 更新代理工具
function update_proxy_tool() {
    if [[ -e /usr/local/bin/juicity-server ]]; then
        install_latest_juicity
    fi

    if [[ -e /usr/local/bin/sing-box ]]; then
        select_sing_box_install_option
    fi
}

# 卸载已安装的代理工具
function uninstall() {
    local uninstall_sing_box=false
    local uninstall_juicity=false

    if [[ -f "/etc/systemd/system/sing-box.service" ]] || [[ -f "/usr/local/bin/sing-box" ]] || [[ -d "/usr/local/etc/sing-box/" ]]; then
        uninstall_sing_box=true
    fi

    if [[ -f "/etc/systemd/system/juicity.service" ]] || [[ -f "/usr/local/bin/juicity-server" ]] || [[ -d "/usr/local/etc/juicity/" ]]; then
        uninstall_juicity=true
    fi

    if [[ "$uninstall_sing_box" == true ]]; then
        uninstall_sing_box
    fi

    if [[ "$uninstall_juicity" == true ]]; then
        uninstall_juicity
    fi    
}

# 检查 WireGuard 配置
function check_wireguard_config() {
    local config_file="/usr/local/etc/sing-box/config.json"

    if grep -q "wireguard" "$config_file"; then
        echo -e "${RED}Warp 已安装，请勿重复安装！${NC}"
        exit 1
    fi
}

# 更新安装脚本
function Update_Script() {
    wget -N -O /usr/local/bin/singbox.sh https://raw.githubusercontent.com/sky22333/shell/main/proxy/singbox.sh && chmod +x /usr/local/bin/singbox.sh && ln -sf /usr/local/bin/singbox.sh /usr/local/bin/singbox
}

# 添加定时任务以自动更新证书
function add_cron_job() {
    if command -v crontab > /dev/null && crontab -l | grep -q "singbox.sh"; then
        echo "Cron job already exists."
    else
        (crontab -l 2>/dev/null ; echo "0 3 * * 1 /bin/bash /root/singbox.sh 18 >> /usr/local/etc/certificate.log 2>&1") | crontab -
        echo "Cron job added successfully."
    fi
}

# 查找 juicity 服务
function check_juicity_installed() {
    if systemctl list-unit-files | grep -q juicity.service && [[ -e /usr/local/etc/juicity ]]; then
        echo -e "${RED}juicity 服务已安装，请不要重新安装！${NC}"
        return
    else
        juicity_install
    fi
}

# 安装 Juicity 并配置相关服务
function juicity_install() {
    configure_dns64
    enable_bbr
    create_juicity_folder  
    install_latest_juicity
    get_local_ip
    generate_juicity_config
    add_cron_job
    configure_juicity_service
    systemctl daemon-reload
    systemctl enable juicity.service
    systemctl start juicity.service
    systemctl restart juicity.service
    display_juicity_config
}

# 安装 Direct 并配置相关服务
function Direct_install() {
    install_sing_box
    enable_bbr    
    log_outbound_config    
    set_listen_port
    set_override_address
    set_override_port
    generate_Direct_config
    modify_config_format
    modify_route_rules
    check_firewall_configuration 
    systemctl daemon-reload   
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    get_local_ip    
    display_Direct_config
}

# 安装 Shadowsocks 并配置相关服务
function Shadowsocks_install() {
    install_sing_box
    enable_bbr
    log_outbound_config    
    set_listen_port
    select_encryption_method
    set_ss_password
    generate_ss_config
    modify_config_format
    modify_route_rules
    check_firewall_configuration 
    systemctl daemon-reload   
    systemctl enable sing-box   
    systemctl start sing-box
    systemctl restart sing-box
    get_local_ip
    display_Shadowsocks_config_info
    display_Shadowsocks_config_files
    update_client_file
}

# 安装 SOCKS 并配置相关服务
function socks_install() {
    install_sing_box
    enable_bbr
    log_outbound_config    
    generate_socks_config
    modify_config_format
    modify_route_rules
    check_firewall_configuration 
    systemctl daemon-reload   
    systemctl enable sing-box   
    systemctl start sing-box
    systemctl restart sing-box
    get_local_ip
    display_socks_config_info
    display_socks_config_files
    update_client_file
}

# 安装 NaiveProxy 并配置相关服务
function NaiveProxy_install() {
    install_sing_box
    enable_bbr
    log_outbound_config        
    generate_naive_config
    add_cron_job
    modify_config_format
    modify_route_rules  
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    display_naive_config_info
    generate_naive_config_files
}

# 安装 HTTP 并配置相关服务
function http_install() {
    install_sing_box
    enable_bbr
    log_outbound_config        
    generate_http_config
    add_cron_job
    modify_config_format
    modify_route_rules  
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    display_http_config_info
    display_http_config_files
    update_client_file
}

# 安装 AnyTLS 并配置相关服务
function anytls_install() {
    install_sing_box
    enable_bbr
    log_outbound_config        
    generate_anytls_config
    add_cron_job
    modify_config_format
    modify_route_rules  
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    display_anytls_config_info
    display_anytls_config_files
    update_client_file
}

# 安装 Tuic 并配置相关服务
function tuic_install() {
    install_sing_box
    enable_bbr
    log_outbound_config    
    generate_tuic_config
    add_cron_job
    modify_config_format
    modify_route_rules  
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    get_local_ip 
    display_tuic_config_info
    display_tuic_config_files
    update_client_file
}

# 安装 Hysteria 并配置相关服务
function Hysteria_install() {
    install_sing_box
    enable_bbr  
    log_outbound_config    
    generate_Hysteria_config
    add_cron_job
    modify_config_format
    modify_route_rules 
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    display_Hysteria_config_info
    display_Hysteria_config_files
    update_client_file
}

# 安装 ShadowTLS 并配置相关服务
function shadowtls_install() {
    install_sing_box
    enable_bbr
    log_outbound_config 
    generate_shadowtls_config
    modify_config_format
    modify_route_rules
    check_firewall_configuration      
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    get_local_ip    
    display_shadowtls_config_info
    display_shadowtls_config_files
    update_client_file
}

# 安装 Reality 并配置相关服务
function reality_install() {
    install_sing_box
    enable_bbr
    log_outbound_config         
    generate_vless_config 
    modify_config_format
    modify_route_rules
    check_firewall_configuration              
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    get_local_ip    
    display_reality_config_info
    display_reality_config_files
    update_client_file
}

# 安装 Hysteria 2 并配置相关服务
function Hysteria2_install() {
    install_sing_box
    enable_bbr  
    log_outbound_config    
    generate_Hy2_config
    add_cron_job
    modify_config_format
    modify_route_rules
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    display_Hy2_config_info
    display_Hy2_config_files
    update_client_file
}

# 安装 Trojan 并配置相关服务
function trojan_install() {
    install_sing_box
    enable_bbr 
    log_outbound_config
    generate_trojan_config
    add_cron_job
    modify_config_format
    modify_route_rules
    systemctl daemon-reload      
    systemctl enable sing-box 
    systemctl start sing-box
    systemctl restart sing-box
    display_trojan_config_info
    display_trojan_config_files
    update_client_file
}

# 安装 VMess 并配置相关服务
function vmess_install() {
    install_sing_box
    enable_bbr
    log_outbound_config 
    get_local_ip
    generate_vmess_config
    add_cron_job
    modify_config_format
    modify_route_rules
    systemctl daemon-reload   
    systemctl enable sing-box
    systemctl start sing-box
    systemctl restart sing-box
    display_vmess_config_info
    display_vmess_config_files
    update_client_file
}

# 安装 WireGuard 并配置相关服务
function wireguard_install() {
    check_wireguard_config
    check_config_file_existence
    select_unlocked_items
    geosite=()
    update_rule_set
    update_route_file
    generate_warp_info
    extract_variables_and_cleanup
    Configure_endpoints
    systemctl restart sing-box
}

# 更新 TLS 证书
function Update_certificate() {
    get_local_ip
    extract_tls_info
    validate_tls_info
    Reapply_certificates
}

# 自动更新 TLS 证书
function run_option() {
    case "$1" in
        "18")
            Update_certificate
            exit 0 
            ;;
    esac
}

# 主菜单
function main_menu() {
echo "╔════════════════════════════════════════════════════════════════════════╗"
echo -e "║ ${CYAN}脚本快捷方式${NC}： singbox                                                 ║"
echo "╠════════════════════════════════════════════════════════════════════════╣"
echo "║ 请选择要执行的操作：                                                   ║"
echo -e "║${CYAN} [1]${NC}  SOCKS                             ${CYAN} [2]${NC}   Direct                   ║"
echo -e "║${CYAN} [3]${NC}  HTTP                              ${CYAN} [4]${NC}   VMess                    ║"
echo -e "║${CYAN} [5]${NC}  VLESS                             ${CYAN} [6]${NC}   TUIC                     ║"
echo -e "║${CYAN} [7]${NC}  Juicity                           ${CYAN} [8]${NC}   AnyTLS                   ║"
echo -e "║${CYAN} [9]${NC}  Trojan                            ${CYAN} [10]${NC}  Hysteria                 ║"
echo -e "║${CYAN} [11]${NC} Hysteria2                         ${CYAN} [12]${NC}  ShadowTLS                ║"
echo -e "║${CYAN} [13]${NC} NaiveProxy                        ${CYAN} [14]${NC}  Shadowsocks              ║"
echo -e "║${CYAN} [15]${NC} WireGuard                         ${CYAN} [16]${NC}  更新证书                 ║"
echo -e "║${CYAN} [17]${NC} 节点信息                          ${CYAN} [18]${NC}  节点管理                 ║"
echo -e "║${CYAN} [19]${NC} 更新内核                          ${CYAN} [20]${NC}  更新脚本                 ║"
echo -e "║${CYAN} [21]${NC} 卸载                              ${CYAN} [0]${NC}   退出                     ║"
echo "╚════════════════════════════════════════════════════════════════════════╝"

    local choice
    read -p "请选择 [0-21]: " choice

    case $choice in
        1)
            socks_install
            exit 0
            ;;
        2)
            Direct_install
            exit 0
            ;;
        3)
            http_install
            exit 0
            ;;
        4)
            vmess_install
            exit 0
            ;;
        5)
            reality_install
            exit 0
            ;;
        6)
            tuic_install
            exit 0
            ;;
        7)
            check_juicity_installed
            exit 0
            ;;
        8)
            anytls_install
            exit 0
            ;;
        9)
            trojan_install
            exit 0
            ;;
        10)
            Hysteria_install
            exit 0
            ;;
        11)
            Hysteria2_install
            exit 0
            ;;
        12)
            shadowtls_install
            exit 0
            ;;
        13)
            NaiveProxy_install
            exit 0
            ;;
        14)
            Shadowsocks_install
            exit 0
            ;;
        15)
            wireguard_install
            exit 0
            ;;
        16)
            Update_certificate
            ;;
        17)
            view_saved_config
            exit 0
            ;;
        18)
            if delete_choice; then
                exit 0
            else
                main_menu
            fi
            ;;
        19)
            update_proxy_tool
            exit 0
            ;;
        20)
            Update_Script
            exit 0
            ;;
        21)
            uninstall
            exit 0
            ;;
        0)
            echo "感谢使用脚本。再见！"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择，请重新输入。${NC}"
            main_menu
            ;;
    esac
}

# 检查必需依赖
check_dependencies

if [[ $# -eq 0 ]]; then
    main_menu
else
    run_option "$1"
fi

main_menu
