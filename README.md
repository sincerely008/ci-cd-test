# ci-cd-test

Spring Boot 애플리케이션을 Docker로 컨테이너화하고, GitHub Actions → AWS ECR → EC2 Docker Compose로 배포하는 예제입니다.

## Architecture

```text
GitHub Actions (CI) ── test · Docker build · app+PostgreSQL integration test
        │
        └── GitHub OIDC ──> Amazon ECR (sha-<commit>, latest)
                                      │
                                      └── EC2 Docker Compose
                                           ├── app (Spring Boot)
                                           └── db  (PostgreSQL 17 + named volume)
```

배포는 이동하는 `latest` 태그가 아닌 ECR 이미지 digest를 사용하므로, 실행 중인 이미지를 정확히 재현할 수 있습니다.

## Docker Compose: application + database

`compose.prod.yaml`은 앱과 PostgreSQL을 한 번에 실행합니다. 데이터베이스 포트는 호스트에 노출하지 않고 Compose 내부 네트워크에서 앱만 `db:5432`로 접근합니다. PostgreSQL 데이터는 `postgres-data` named volume에 저장됩니다.

```bash
cp .env.example .env
# .env의 POSTGRES_PASSWORD와 APP_SECURITY_PASSWORD를 안전한 값으로 교체

docker build -t ci-cd-test:local .
docker compose --env-file .env -f compose.prod.yaml up -d --wait

curl http://localhost:8080/actuator/health
curl -u app-admin:<APP_SECURITY_PASSWORD> \
  -H 'Content-Type: application/json' \
  -d '{"content":"postgres persistence proof"}' \
  http://localhost:8080/api/notes
```

컨테이너만 재생성하고 데이터는 유지하려면 `-v` 없이 내립니다.

```bash
docker compose --env-file .env -f compose.prod.yaml down
docker compose --env-file .env -f compose.prod.yaml up -d --wait
```

`docker compose down -v`는 PostgreSQL named volume까지 삭제하므로, 데이터를 보존해야 할 때는 사용하지 마세요.

## CI/CD

| Event | Workflow | Result |
| --- | --- | --- |
| Pull request to `main` | CI | Java 21 테스트·JAR·Docker 이미지 빌드·Compose 문법·앱/DB 실제 연동 검증 |
| Push to `main` | CD | GitHub OIDC로 ECR에 SHA 및 `latest` 이미지 태그 push |
| Push to `main` with deployment enabled | CD | EC2가 ECR에 로그인한 뒤 Compose를 healthcheck 완료까지 재기동 |

CI의 Compose 검증은 CI 전용 `.env.ci`와 PostgreSQL volume을 사용하며, 마지막에만 `down -v`로 정리합니다. 운영 데이터 볼륨에는 영향을 주지 않습니다.

## AWS ECR bootstrap

먼저 AWS CLI에서 EC2와 같은 리전으로 로그인합니다.

```bash
aws configure set region eu-north-1
aws login
aws sts get-caller-identity
```

그다음 ECR 저장소, lifecycle policy, GitHub OIDC push role, EC2 ECR pull role을 한 번에 구성합니다.

```bash
EC2_INSTANCE_ID=i-01dceceb9dae38c4c ./scripts/bootstrap-ecr.sh
```

스크립트는 다음을 수행합니다.

- `ci-cd-test` ECR repository 생성 및 push-on-scan 활성화
- SHA 태그 최신 30개 및 untagged 이미지 7일 보관 lifecycle policy 적용
- `main` 브랜치의 이 GitHub 저장소만 신뢰하는 GitHub OIDC IAM role 생성
- EC2의 기존 IAM role에 최소 ECR pull 권한을 추가하거나, role이 없으면 새 instance profile 연결
- GitHub repository variable `AWS_REGION`, `ECR_REPOSITORY`와 repository secret `AWS_GITHUB_ACTIONS_ROLE_ARN` 설정

배포 환경에는 아래 GitHub `production` environment secrets가 필요합니다. 값은 Git에 저장하지 않습니다.

- `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`, `DEPLOY_PATH`, `DEPLOY_PORT` (optional)
- `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- `APP_SECURITY_USER`, `APP_SECURITY_PASSWORD`

## Data migration note

이전 H2 `/app/data` named volume의 데이터는 PostgreSQL로 자동 이관되지 않습니다. 기존 H2 데이터를 보존해야 하면 새 배포 전에 백업·마이그레이션을 진행하고, 기존 볼륨에 `down -v`를 실행하지 마세요.
