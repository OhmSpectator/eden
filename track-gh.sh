#!/bin/bash

HOSTS=(index.docker.io registry-1.docker.io docker.io)

IPS=()
for HOST in "${HOSTS[@]}"; do
    NEWIPS=$(dig +short "$HOST" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    for ip in $NEWIPS; do
        IPS+=("$ip")
    done
done

IPS=($(printf "%s\n" "${IPS[@]}" | sort -u))

COND=""
for ip in "${IPS[@]}"; do
    IFS=. read -r a b c d <<< "$ip"
    HEX=$(printf "0x%02x%02x%02x%02x" $d $c $b $a)
    [ -z "$COND" ] && COND="\$dip == $HEX" || COND="$COND || \$dip == $HEX"
done

cat > /tmp/track-registry.bt <<EOF
kprobe:tcp_v4_connect
{
    \$addr = (struct sockaddr_in *)arg1;
    \$dip = \$addr->sin_addr.s_addr;
    if ($COND) {
        printf("PID: %d CMD: %s DST: %d.%d.%d.%d\\n",
            pid, comm,
            (\$dip & 0xff),
            (\$dip >> 8) & 0xff,
            (\$dip >> 16) & 0xff,
            (\$dip >> 24) & 0xff
        );
    }
}
EOF

echo "Tracking all TCP connects to: ${IPS[*]}"
sudo bpftrace /tmp/track-registry.bt
rm /tmp/track-registry.bt

