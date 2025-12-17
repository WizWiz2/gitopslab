FROM alpine:3.20

RUN apk add --no-cache curl bash git jq yq docker-cli
RUN curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash \
    && curl -sSL -o /usr/local/bin/kubectl https://dl.k8s.io/release/v1.29.4/bin/linux/amd64/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/v2.10.7/argocd-linux-amd64 \
    && chmod +x /usr/local/bin/argocd

WORKDIR /workspace
CMD ["/bin/sh"]
