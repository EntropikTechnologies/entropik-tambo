# Local Tambo (self-hosted) test

Local-only check that a self-hosted Tambo behaves like Tambo Cloud for the three
endpoints `src/services/tambo_service.py` uses. Not a deployment artifact.

`run-local.sh` wraps Tambo's own scripts (`scripts/cloud/*`) and its
`docker-compose.yml`: Web (:8260), API (:8261), PostgreSQL 17 (:5433) and MinIO
(:9000/:9001). The Tambo clone and `docker.env` are gitignored.

```bash
cd /Users/sibi/entropik-tambo/local-docker
export OPENAI_API_KEY=sk-...   # optional; otherwise edit docker.env (repo root)
./run-local.sh setup           # clone + docker.env with generated secrets
# edit docker.env (repo root): OpenAI key (if not exported) and a login method
./run-local.sh up              # first run builds the images (several minutes)
./run-local.sh init            # DB migrations
```

Then open http://localhost:8260, sign in, create a project and an API key.

Deploying to AWS (ECS Fargate) and connecting an app to it: see [AWS-ECS.md](AWS-ECS.md).

## Smoke test

```bash
export TB=http://localhost:8261 KEY=<api-key>

curl -s -X POST $TB/v1/threads -H "x-api-key: $KEY" -H "Content-Type: application/json" \
  -d '{"userKey":"local-test","initialMessages":[{"role":"user","content":[{"type":"text","text":"Test study brief"}]}]}'

curl -N -X POST $TB/v1/threads/<THREAD_ID>/runs -H "x-api-key: $KEY" \
  -H "Content-Type: application/json" -H "Accept: text/event-stream" \
  -d '{"userKey":"local-test","message":{"role":"user","content":[{"type":"text","text":"Write a short summary"}]},"availableComponents":[],"toolChoice":"required"}'

curl -s "$TB/v1/threads/<THREAD_ID>/runs/<RUN_ID>?userKey=local-test" -H "x-api-key: $KEY"
```

Must match what `src/usecases/tambo.py` parses:
- thread response has `id` (or `thread_id` / `data.id`)
- SSE contains `tambo.component.start` and `tambo.component.props_delta`
- poll reaches `status` `completed` or `succeeded`
- `x-api-key` is accepted

## Point the backend at it

In your local env (not committed):

```
TAMBO_BASE_URL=http://localhost:8261
TAMBO_API_KEY=<api-key>
```

If the backend runs in Docker, use `http://host.docker.internal:8261`.

## Run and stop

All commands run from `local-docker`. Docker Desktop must be running.

| Task | Command |
|---|---|
| Start (builds on first run) | `./run-local.sh up` |
| Apply DB migrations (first run, and after Tambo upgrades) | `./run-local.sh init` |
| Follow logs | `./run-local.sh logs` |
| Stop, keep data | `./run-local.sh down` |
| Stop and delete all data (Postgres + storage volumes) | `./run-local.sh reset` |

Day to day: `up` to start, `down` to stop. `init` is only needed once, and `reset`
is the only command that loses data (you will need to run `init` again after it).

### Check that it is running

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'   # 4 containers, all Up
curl -s -o /dev/null -w "web %{http_code}\n" http://localhost:8260
curl -s -o /dev/null -w "api %{http_code}\n" http://localhost:8261
curl -s http://localhost:9000/health                              # storage
```

| Service | Container | Port |
|---|---|---|
| Web | `tambo_web` | 8260 |
| API | `tambo_api` | 8261 |
| PostgreSQL 17 | `tambo_postgres` | 5433 |
| S3 storage | `tambo_minio` | 9000 (API), 9001 (console) |

## Local changes to the Tambo clone

This folder sits inside the `entropik-tambo` repo, which is the Tambo source the
stack builds from. These edits are uncommitted working-tree changes there
(`docker-compose.yml`, `apps/*/Dockerfile`, `docker-compose.override.yml`); `docker.env`
is gitignored. `COMPOSE_PROJECT_NAME=tambo-src` in `docker.env` keeps the volume
names from the original checkout, so existing data is reused.

**Storage image.** `minio/minio` is no longer pullable from Docker Hub or Quay
(`pull access denied`). `docker-compose.yml` uses `rustfs/rustfs:latest`
instead: `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` set to `minioadmin`, `user: root`,
and the healthcheck URL is `http://localhost:9000/health`. The service and container
keep the names `minio` / `tambo_minio`.

**npm mirror.** Only needed if your network blocks `registry.npmjs.org` (the build
fails with `npm error code ECONNRESET`). Check with
`curl -I https://registry.npmjs.org/npm`. If it hangs but
`curl -I https://registry.yarnpkg.com/` works:

```bash
cd ..   # repo root
perl -0pi -e 's|(FROM node:22-alpine AS base\n)|$1ARG NPM_REGISTRY=https://registry.npmjs.org/\nENV npm_config_registry=\$NPM_REGISTRY\n|' apps/api/Dockerfile apps/web/Dockerfile
cat > docker-compose.override.yml <<'EOF'
services:
  api:
    build: { args: { NPM_REGISTRY: "https://registry.yarnpkg.com/" } }
  web:
    build: { args: { NPM_REGISTRY: "https://registry.yarnpkg.com/" } }
EOF
```

Delete `docker-compose.override.yml` when you are on a network that reaches npm.

## Troubleshooting

- **Nothing starts, log ends in a pull or build error:** `up` writes to the terminal;
  rerun it as `./run-local.sh up 2>&1 | tee /tmp/tambo-up.log` and read the last
  40 lines. A failed `up` can still look like it succeeded in some wrappers, so
  confirm with `docker ps`.
- **Can't sign in at :8260:** no login method is configured. Set
  `GOOGLE_CLIENT_ID`/`SECRET`, `GITHUB_CLIENT_ID`/`SECRET`, or `RESEND_API_KEY` +
  `EMAIL_FROM_DEFAULT` in `docker.env (repo root)`, then `./run-local.sh down && ./run-local.sh up`.
- **Port already in use:** something else holds 8260, 8261, 5433, 9000 or 9001.
  Find it with `lsof -i :<port>`.
- **Env changes not picked up:** `docker.env` is read at start, so restart with
  `down` then `up`.
