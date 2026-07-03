# Reuse the shared snapdragon-gateway code as a base image; this repo only
# layers the be-gateway identity + route config on top.
ARG GATEWAY_IMAGE=snapdragon-systems/snapdragon-gateway:dev
FROM ${GATEWAY_IMAGE}
ENV SPRING_APPLICATION_NAME=snapdragon-be-gateway
# NOTE: application-be.yml uses Spring Boot's application-{profile}.yml naming
# convention (profile "be"), but only SPRING_CONFIG_ADDITIONAL_LOCATION is set
# below -- that just adds a search directory, it does not activate a profile.
# This relies on the shared snapdragon-gateway base image activating a "be"
# profile (e.g. derived from SPRING_APPLICATION_NAME); if that base-image
# behavior ever changes, this overlay file would silently stop being loaded
# and SPRING_PROFILES_ACTIVE=be would need to be set explicitly here.
COPY application-be.yml /app/config/application-be.yml
COPY liquibase/changelog /app/liquibase/changelog
ENV SPRING_CONFIG_ADDITIONAL_LOCATION=file:/app/config/
EXPOSE 8080
