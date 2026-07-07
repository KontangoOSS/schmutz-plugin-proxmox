FROM alpine:3.20
RUN apk add --no-cache bash curl jq coreutils util-linux openssh-client sshpass \
    python3 py3-pip && \
    pip3 install --break-system-packages ansible-core && \
    rm -rf /root/.cache
COPY lib/ /plugin/lib/
COPY plugin.sh /plugin/
COPY ansible/ /plugin/ansible/
ENV ANSIBLE_CONFIG=/plugin/ansible/ansible.cfg
ENTRYPOINT ["bash", "/plugin/plugin.sh"]
