# snapdragon-be-gateway

Per-node-type instance of the Snapdragon Spring Cloud Gateway. Backend front door — API + matrix + mastodon.

It is **the same image and code as [snapdragon-gateway](https://github.com/Snapdragon-Systems/snapdragon-gateway)** — only the
`SPRING_APPLICATION_NAME`, the Postgres-backed route set (Liquibase), and the
downstream URIs differ. Build `FROM` the shared gateway image so every device
runs identical, audited gateway code. Validates the internal Casdoor JWT; no
external login is exposed.

```bash
docker build -t snapdragon-systems/be-gateway:dev .
```
