#!/bin/sh
set -eu

hostname ansible-awx 2>/dev/null || true

if command -v sshd >/dev/null 2>&1; then
	mkdir -p /run/sshd /root/.ssh
	chmod 700 /root/.ssh
	ssh-keygen -A
	/usr/sbin/sshd
fi
