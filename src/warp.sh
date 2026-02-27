#!/bin/bash

# warp.sh - 自动配置 Cloudflare WARP 出口
# 安装完 sing-box 后调用此脚本，所有流量走 WARP 出去

setup_warp() {
    msg warn "配置 Cloudflare WARP 出口..."

    local wgcf_bin=$is_core_dir/bin/wgcf
    local wgcf_dir=$is_core_dir/warp
    local wgcf_profile=$wgcf_dir/wgcf-profile.conf

    # 下载 wgcf
    if [[ ! -f $wgcf_bin ]]; then
        local wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v2.2.26/wgcf_2.2.26_linux_${is_arch}"
        msg warn "下载 wgcf > $wgcf_url"
        if ! _wget -q -t 3 "$wgcf_url" -O "$wgcf_bin"; then
            msg err "下载 wgcf 失败，跳过 WARP 配置"
            return 1
        fi
        chmod +x "$wgcf_bin"
    fi

    # 生成 WARP 账号和配置
    mkdir -p "$wgcf_dir"
    cd "$wgcf_dir"

    if [[ ! -f "$wgcf_profile" ]]; then
        "$wgcf_bin" register --accept-tos &>/dev/null || {
            msg err "注册 WARP 账号失败，跳过 WARP 配置"
            return 1
        }
        "$wgcf_bin" generate &>/dev/null || {
            msg err "生成 WARP 配置失败，跳过 WARP 配置"
            return 1
        }
    fi

    # 解析 wgcf-profile.conf
    local private_key peer_pub ep_host ep_port ep_ip warp_ipv4 warp_ipv6

    private_key=$(grep '^PrivateKey' "$wgcf_profile" | cut -d= -f2- | tr -d ' ')
    peer_pub=$(grep '^PublicKey' "$wgcf_profile" | cut -d= -f2- | tr -d ' ')
    local endpoint=$(grep '^Endpoint' "$wgcf_profile" | cut -d= -f2- | tr -d ' ')
    ep_host=${endpoint%:*}
    ep_port=${endpoint##*:}
    warp_ipv4=$(grep '^Address' "$wgcf_profile" | grep -oE '172\.[0-9.]+/[0-9]+' | head -1)
    warp_ipv6=$(grep '^Address' "$wgcf_profile" | grep -oE '[0-9a-f:]+/[0-9]+' | head -1)

    # 解析 endpoint IP
    ep_ip=$(getent hosts "$ep_host" 2>/dev/null | awk '{print $1}' | head -1)
    [[ -z $ep_ip ]] && ep_ip=$(python3 -c "import socket; print(socket.gethostbyname('$ep_host'))" 2>/dev/null)
    [[ -z $ep_ip ]] && {
        msg err "无法解析 WARP endpoint IP，跳过 WARP 配置"
        return 1
    }

    # 构建地址列表
    local addr_json="[\"$warp_ipv4\"]"
    [[ $warp_ipv6 ]] && addr_json="[\"$warp_ipv4\",\"$warp_ipv6\"]"

    # 注入 endpoints 和 route.final 到 config.json
    python3 - <<EOF
import json, sys

config_path = "$is_config_json"
try:
    c = json.load(open(config_path))
except Exception as e:
    print(f"读取 config.json 失败: {e}")
    sys.exit(1)

warp_endpoint = {
    "tag": "warp",
    "type": "wireguard",
    "address": $addr_json,
    "private_key": "$private_key",
    "peers": [
        {
            "address": "$ep_ip",
            "port": $ep_port,
            "public_key": "$peer_pub",
            "allowed_ips": ["0.0.0.0/0", "::/0"]
        }
    ],
    "mtu": 1280
}

c["endpoints"] = [warp_endpoint]
c.setdefault("route", {})["final"] = "warp"

json.dump(c, open(config_path, "w"), indent=2, ensure_ascii=False)
print("WARP endpoint 写入成功")
EOF

    [[ $? -ne 0 ]] && return 1

    # 验证配置
    if ! $is_core_bin check -c $is_config_json &>/dev/null; then
        msg err "sing-box 配置验证失败，跳过 WARP 配置"
        return 1
    fi

    msg ok "✅ WARP 出口配置完成 (endpoint: $ep_ip:$ep_port)"
    return 0
}
