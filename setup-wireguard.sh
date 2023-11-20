#!/bin/bash
set -o errexit -o pipefail -o nounset

readonly endpoint="$ENDPOINT"
readonly endpoint_public_key="$ENDPOINT_PUBLIC_KEY"
readonly private_ips="$PRIVATE_IPS"
readonly allowed_ips="$ALLOWED_IPS"
readonly private_key="$PRIVATE_KEY"
readonly dns_servers="$DNS_SERVERS"
readonly keep_alive="$KEEP_LIVE"

readonly minport=51000
readonly maxport=51999

ifname="wg$( openssl rand -hex 4 )"
readonly ifname
port="$( shuf "--input-range=$minport-$maxport" --head-count=1 )"
readonly port

install_wg_tools() {
    sudo apt-get update || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends wireguard resolvconf
}

readonly private_key_path=/tmp/private.key

wg_tools_cleanup() {
    rm -f -- "$private_key_path"
}

via_wg_tools() {
    install_wg_tools
    trap wg_tools_cleanup EXIT

    (
        set -o errexit -o nounset -o pipefail
        umask 0077
        echo "$private_key" > "$private_key_path"
    )

    if [[ -n ${dns_servers} ]]; then
      resolv_file="/etc/resolvconf/resolv.conf.d/head"
      sudo tee ${resolv_file} <<< $(sed '/^nameserver/d' ${resolv_file})
      for d in ${dns_servers//,/ }; do echo "nameserver ${d}" | sudo tee -a ${resolv_file}; done
      sudo resolvconf --enable-updates
      sudo resolvconf -u
    fi

    sudo ip link add dev "$ifname" type wireguard

    local delim=,
    local ip
    while IFS= read -d "$delim" -r ip; do
        sudo ip addr add "$ip" dev "$ifname"
    done < <( printf -- "%s$delim\\0" "$private_ips" )

    sudo wg set "$ifname" \
        listen-port "$port" \
        private-key "$private_key_path"

    additional_wg_args=()

    if [ -n "$keep_alive" ]; then
        additional_wg_args+=(persistent-keepalive "${keep_alive}")
    fi

    sudo wg set "$ifname" \
        peer "$endpoint_public_key" \
        endpoint "$endpoint" \
        allowed-ips "$allowed_ips" \
        ${additional_wg_args[@]+"${additional_wg_args[@]}"}

    sudo ip link set "$ifname" up

    for i in ${allowed_ips//,/ }; do sudo ip route replace "$i" dev "$ifname"; done

}

via_wg_tools
