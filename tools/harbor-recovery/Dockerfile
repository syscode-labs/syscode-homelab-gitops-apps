FROM postgres:16-alpine

RUN apk add --no-cache aws-cli bash

LABEL org.opencontainers.image.title="Harbor PostgreSQL recovery helper"
LABEL org.opencontainers.image.description="PostgreSQL and OCI S3 tools for deterministic Harbor backup/restore"

ENTRYPOINT ["/bin/bash"]
