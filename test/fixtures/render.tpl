# managed by shipit
${DOMAIN} {
	reverse_proxy 127.0.0.1:$PORT {
		header_up X-Forwarded-For {remote_host}
	}
	# not listed, so left alone: $HOME ${OTHER} $$
}
