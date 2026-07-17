# Reuse the shared snapdragon-gateway code as a base image; this repo only
# layers the be-gateway identity + route config on top.
ARG GATEWAY_IMAGE=snapdragon-systems/snapdragon-gateway:dev
FROM ${GATEWAY_IMAGE}
ENV SPRING_APPLICATION_NAME=snapdragon-be-gateway
COPY application-be.yml /app/config/application-be.yml
COPY liquibase/changelog /app/liquibase/changelog
ENV SPRING_CONFIG_ADDITIONAL_LOCATION=file:/app/config/
# application-be.yml is a profile-specific document (application-{profile}.yml).
# SPRING_CONFIG_ADDITIONAL_LOCATION above only adds a SEARCH DIRECTORY — it does
# NOT activate a profile — so Boot reads that file only when profile "be" is
# active.
#
# An earlier comment here hypothesised that the shared snapdragon-gateway base
# image activates a "be" profile derived from SPRING_APPLICATION_NAME. That is
# FALSE and has been removed: the base image activates no profile at all
# (verified on its origin/main — no SPRING_PROFILES_ACTIVE / spring.profiles /
# setAdditionalProfiles reference anywhere in that repo; SPRING_APPLICATION_NAME
# feeds only spring.application.name). Without the line below the overlay is
# silently never read and the image falls back to the base application.yml's
# api-default route (/api/** -> api:8080) — i.e. the WRONG route table rather
# than an obvious failure. Mirrors the canonical fix in snapdragon-generator's
# snapdragon-gateway chart (SPRING_PROFILES_ACTIVE=routes).
#
# This ENV is a DEFAULT only: `docker run -e SPRING_PROFILES_ACTIVE=…` or a k8s
# env entry REPLACES it (replaces, not appends — pass "be,other" to keep this
# file loading alongside another profile).
ENV SPRING_PROFILES_ACTIVE=be
EXPOSE 8080
