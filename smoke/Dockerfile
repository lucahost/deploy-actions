# The VPS's smoke app (lucahost/vps-gitops tenant "smoke", deploy repo lucahost/vps-app-smoke):
# nginx-unprivileged serving a page that names the commit it was built from. Its only job is to
# prove the deploy path (.github/workflows/smoke.yml → vps-deploy.yml). The base is the linux/amd64
# manifest the platform already runs (vps-gitops bootstrap/lib.sh, SMOKE_SRC_IMAGE).
FROM docker.io/nginxinc/nginx-unprivileged:1.31.7-alpine3.24@sha256:c3bcf3d1a53a027bfa515b9fe4fbbe7bf6b791476a5af853de439ad494b145bd
ARG GIT_SHA=unknown
USER root
COPY index.html /usr/share/nginx/html/index.html
RUN printf '%s\n' "$GIT_SHA" > /usr/share/nginx/html/version.txt \
 && chmod 0644 /usr/share/nginx/html/index.html /usr/share/nginx/html/version.txt
USER 101
