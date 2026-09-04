# ci-cd-test

Spring Boot application with a GitHub Actions CI/CD pipeline.

## Pipeline

| Event | Workflow | Result |
| --- | --- | --- |
| Pull request to `main` | CI | Java 21 build, tests, and executable JAR verification |
| Push to `main` or `develop` | CI | Java 21 build and tests |
| Push to `main` | CD | Container image is built and published to GitHub Container Registry (GHCR) |
| Push to `main` with deployment enabled | CD | The immutable image tag is pulled and started on the production server |

The CD workflow publishes both `sha-<commit>` and `latest`. Production always uses the SHA tag, so a deploy is reproducible and never depends on a moving tag.

## Run locally

```bash
./gradlew bootRun
```

The health endpoint used by Docker is available at `http://localhost:8080/actuator/health`.

To build and run the container locally:

```bash
docker build -t ci-cd-test:local .
docker run --rm -p 8080:8080 ci-cd-test:local
```

## Enable production deployment

Image publishing works automatically after the project is pushed to GitHub. The server deployment is deliberately disabled until a production environment is configured.

1. In GitHub, create an environment named `production` and add required reviewers if appropriate.
2. Add these **environment secrets**:
   - `DEPLOY_HOST`: server host name or IP
   - `DEPLOY_USER`: SSH user with permission to run Docker
   - `DEPLOY_SSH_KEY`: private key for that user
   - `DEPLOY_PATH`: absolute server directory for `compose.prod.yaml`, such as `/opt/ci-cd-test`
   - `DEPLOY_PORT` (optional): SSH port; defaults to `22`
3. Add the environment variable `DEPLOY_ENABLED` with the value `true`.
4. On the server, install Docker Engine with the Compose plugin and log in once to GHCR using a fine-grained personal access token with **Packages: Read** permission:

   ```bash
   echo "<GHCR_READ_TOKEN>" | docker login ghcr.io -u "<GITHUB_USER>" --password-stdin
   ```

The deployment workflow transfers only the Compose manifest, pulls the newly published SHA-tagged image, then recreates the service. It does not send a package token to GitHub Actions.

## GitHub package visibility

New GHCR packages are normally private. Keep the server login above for private images, or explicitly change the package visibility in GitHub if you want the image to be publicly pullable.
