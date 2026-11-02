# Dedicated Cloady adapter. Does not execute the original VPS installer.
FROM ghcr.io/sagernet/sing-box:v1.14.2 AS singbox
FROM alpine:3.23
RUN apk add --no-cache ca-certificates nginx openssh-server python3 tini \
    && adduser -D -s /bin/sh nodeadmin \
    && mkdir -p /etc/sing-box /run/nginx /opt/cloady /data \
    && chmod 700 /data
COPY --from=singbox /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY setup.py show_node.py start.sh nginx.conf /opt/cloady/
RUN chmod +x /opt/cloady/start.sh /opt/cloady/show_node.py
EXPOSE 3000 2222/tcp
ENTRYPOINT ["/sbin/tini", "-g", "--", "/opt/cloady/start.sh"]
