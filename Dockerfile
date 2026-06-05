# Reuse the shared snapdragon-gateway code as a base image; this repo only
# layers the be-gateway identity + route config on top.
ARG GATEWAY_IMAGE=snapdragon-systems/gateway:dev
FROM ${GATEWAY_IMAGE}
ENV SPRING_APPLICATION_NAME=snapdragon-be-gateway
COPY application-be.yml /app/config/application-be.yml
COPY liquibase/changelog /app/liquibase/changelog
ENV SPRING_CONFIG_ADDITIONAL_LOCATION=file:/app/config/
EXPOSE 8080
