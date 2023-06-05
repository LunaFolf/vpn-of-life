#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

NS_NAME="folfvpn"
NS_EXEC="ip netns exec $NS_NAME"
NS_EXEC_SUDO=$SUDO_USER
PRIMARY_INTERFACE=$(ip route | grep default | awk '{print $5}')


set -u
set -e
set -o pipefail

start_vpn() {
  echo "Add networking interface"
  ip netns add $NS_NAME

  echo "Start the loopback interface in the namespace"
  $NS_EXEC ip addr add 127.0.0.1/8 dev lo
  $NS_EXEC ip link set lo up

  echo "Create virtual network interfaces that will let OpenVPN access the real network"
  ip link add vpn0 type veth peer name vpn1
  ip link set vpn0 up
  ip addr add 10.200.200.1/24 dev vpn0

  echo "Move vpn1 into the namespace"
  ip link set vpn1 netns $NS_NAME

  echo "Configure IP addresses and routing within the namespace"
  $NS_EXEC ip addr add 10.200.200.2/24 dev vpn1
  $NS_EXEC ip link set dev vpn1 mtu 1492
  $NS_EXEC ip link set dev vpn1 up
  $NS_EXEC ip route add default via 10.200.200.1 dev vpn1

  echo "Configure the nameserver to use inside the namespace"
  mkdir -p /etc/netns/$NS_NAME
  echo "nameserver 1.1.1.1" > /etc/netns/$NS_NAME/resolv.conf

  echo "Testing nameserver access"
  $NS_EXEC ping -c 3 1.1.1.1

  echo "Testing full network access"
  $NS_EXEC ping -c 3 www.google.com

  echo "Start OpenVPN in the background"
  $NS_EXEC openvpn --config ./uk_manchester-aes-128-cbc-udp-dns.ovpn --auth-user-pass credentials.txt --data-ciphers AES-256-GCM:AES-128-GCM:aes-128-cbc &

  echo "Wait for OpenVPN to establish a connection"
  while ! $NS_EXEC ip link show dev tun0 >/dev/null 2>&1 ; do
    sleep 0.5
  done

  echo "Enable IP forwarding"
  echo 1 > /proc/sys/net/ipv4/ip_forward

  echo "Setting up NAT"
  iptables -t nat -A POSTROUTING -s 10.200.200.0/24 -o $PRIMARY_INTERFACE -j MASQUERADE
  iptables -A FORWARD -i $PRIMARY_INTERFACE -o vpn0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -A FORWARD -i vpn0 -o $PRIMARY_INTERFACE -j ACCEPT

  # wait for the tunnel interface to come up
  while ! $NS_EXEC ip link show dev tun0 >/dev/null 2>&1 ; do
  echo "Waiting for tunnel interface to come up"
  sleep 0.1
  done
}

stop_vpn() {
  echo "Stopping OpenVPN"
  ip netns pids $NS_NAME | xargs -rd'\n' kill

  echo "Delete the network namespace"
  ip netns del $NS_NAME
  ip link del vpn0

  echo "Cleaning up NAT settings"
  iptables -t nat -D POSTROUTING -s 10.200.200.0/24 -o $PRIMARY_INTERFACE -j MASQUERADE
  iptables -D FORWARD -i $PRIMARY_INTERFACE -o vpn0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -D FORWARD -i vpn0 -o $PRIMARY_INTERFACE -j ACCEPT
}

trap stop_vpn EXIT

start_vpn

$NS_EXEC sudo -u $NS_EXEC_SUDO google-chrome --user-data-dir="/tmp/vpn-chrome"