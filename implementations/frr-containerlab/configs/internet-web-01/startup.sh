#!/bin/sh
set -e

ip addr add 198.18.3.10/24 dev eth1
ip route del default || true
ip route add default via 198.18.3.1 dev eth1

mkdir -p /www/cgi-bin
cat > /www/index.html << 'EOF'
<html><body><h1>internet-web-01</h1><p>ESI external test endpoint</p></body></html>
EOF

cat > /www/http-handler.sh << 'EOF'
#!/bin/sh
read request_line || exit 0
path=$(printf "%s" "$request_line" | cut -d" " -f2)

remote_ip=$(netstat -tn 2>/dev/null | grep ":80 " | grep -v LISTEN | head -n1 | tr -s " " | cut -d" " -f5 | cut -d: -f1)
[ -n "$remote_ip" ] || remote_ip="unknown"

if [ "$path" = "/cgi-bin/client-ip.sh" ]; then
	body="remote_addr=$remote_ip"
	ctype="text/plain"
else
	body="<html><body><h1>internet-web-01</h1><p>ESI external test endpoint</p></body></html>"
	ctype="text/html"
fi

len=$(printf "%s" "$body" | wc -c)
printf "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" "$ctype" "$len" "$body"
EOF
chmod +x /www/http-handler.sh

# Package-free tiny HTTP service using BusyBox netcat.
# Run one request per nc process; restart immediately for the next client.
nohup sh -c 'while true; do nc -l -p 80 -e /www/http-handler.sh; done' >/tmp/internet-web-httpd.log 2>&1 &
