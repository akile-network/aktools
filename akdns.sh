#!/usr/bin/env bash

DOMAIN="www.google.com"
COUNT=5
TIMEOUT=1

DNS_LIST=(
  "66.66.66.66"
  "45.207.157.146"
  "108.160.138.51"
)

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "AKDNS Speed Test"
echo "Domain : $DOMAIN"
echo "Count  : $COUNT"
echo "Timeout: ${TIMEOUT}s"
echo "------------------------------------"

for dns in "${DNS_LIST[@]}"; do
  for ((i=1; i<=COUNT; i++)); do
    (
      time=$(dig @"$dns" "$DOMAIN" \
        +stats +time=$TIMEOUT +tries=1 2>/dev/null \
        | awk '/Query time/ {print $4}')

      if [[ -n "$time" ]]; then
        echo "$dns $time" >> "$TMPDIR/result"
      else
        echo "$dns 1000" >> "$TMPDIR/result"
      fi
    ) &
  done
done

wait

echo -e "\nAverage response time:"

RESULT=$(awk '
{
  sum[$1] += $2
  cnt[$1]++
}
END {
  for (dns in sum) {
    avg = sum[dns] / cnt[dns]
    printf "%d %s\n", avg, dns
  }
}
' "$TMPDIR/result" | sort -n)

echo "$RESULT" | awk '{printf "%s ms\t%s\n", $1, $2}'

BEST_DNS=$(echo "$RESULT" | head -n1 | awk '{print $2}')

echo -e "\n🏆 Best DNS: $BEST_DNS"
echo "------------------------------------"
echo "Replace DNS commands:"

echo
echo "# 临时生效（立刻测试用）"
echo "sudo resolvectl dns \$(resolvectl status | awk '/Link/ {print \$2; exit}') $BEST_DNS"

echo
echo "# /etc/resolv.conf（非 systemd-resolved）"
echo "sudo sed -i '1s|^|nameserver $BEST_DNS\n|' /etc/resolv.conf"

echo
echo "# NetworkManager"
echo "nmcli con show"
echo "nmcli con mod <connection-name> ipv4.dns \"$BEST_DNS\""
echo "nmcli con up <connection-name>"
