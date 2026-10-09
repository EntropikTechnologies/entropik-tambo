# Self-hosting Tambo on AWS ECS (Fargate)

How to run the Tambo stack on AWS, sign in, and connect an application (for
example the decode backend) to it.

> **Status: not yet deployed.** This guide was written from the repo's
> Dockerfiles, `docker-compose.yml` and source, and from the local Docker setup in
> [README.md](README.md), which does work. None of the AWS steps have been run
> end to end. Treat the commands as templates, and fix this file when something
> turns out different.

Audience: engineers with AWS access who deploy and operate this.

## 1. What gets deployed

```
                        Internet
                           |
                     ALB (HTTPS, ACM cert)
          host rule /           \ host rule
   tambo.<domain>               tambo-api.<domain>
          |                            |
   ECS service "web"            ECS service "api"
   (Next.js, port 3000)         (NestJS, port 3000)
          \_______________  ___________/
                          \/
        RDS PostgreSQL 17        S3 bucket (file attachments)
```

| Piece | AWS service | Notes |
|---|---|---|
| `web` (dashboard, login) | ECS Fargate service | Image built from `apps/web/Dockerfile` |
| `api` (REST API, Swagger) | ECS Fargate service | Image built from `apps/api/Dockerfile` |
| PostgreSQL 17 | RDS | Replaces the compose `postgres` container |
| File storage | S3 | Replaces the compose `minio` (local: RustFS) container |
| Images | ECR | Two repositories |
| Secrets | Secrets Manager | Injected into tasks as env vars |
| Logs | CloudWatch Logs | One log group per service |
| TLS and routing | ALB + ACM + Route 53 | Two hostnames, one ALB |

Both containers listen on port 3000. The compose file maps them to 8260 (web) and
8261 (api) on the host only. On AWS the ALB does that job.

## 2. Prerequisites

- AWS account, a VPC with 2+ private and 2+ public subnets, and NAT egress (the API
  calls the OpenAI API).
- A domain in Route 53 (or DNS you control) and an ACM certificate covering both
  hostnames.
- Docker with `buildx`, AWS CLI v2 configured for the target account.
- An OpenAI API key, and OAuth credentials for a login method (section 9).

Set these once per shell. Everything below uses them.

```bash
export AWS_REGION=ap-south-1
export AWS_ACCOUNT=<12-digit-account-id>
export ECR=$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
export TAG=$(git -C /Users/sibi/entropik-tambo rev-parse --short HEAD)
export WEB_URL=https://tambo.<domain>
export API_URL=https://tambo-api.<domain>
```

## 3. Build and push the images

Build from the repo root. Fargate runs `linux/amd64` by default, so set the
platform explicitly; an Apple Silicon Mac builds `arm64` otherwise and the task
fails with `exec format error`.

```bash
cd /Users/sibi/entropik-tambo

aws ecr create-repository --repository-name tambo-api --region $AWS_REGION
aws ecr create-repository --repository-name tambo-web --region $AWS_REGION
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR

docker buildx build --platform linux/amd64 -f apps/api/Dockerfile -t $ECR/tambo-api:$TAG --push .
docker buildx build --platform linux/amd64 -f apps/web/Dockerfile -t $ECR/tambo-web:$TAG --push .
```

If your network blocks `registry.npmjs.org` (the build fails with
`npm error code ECONNRESET`), add
`--build-arg NPM_REGISTRY=https://registry.yarnpkg.com/` to both builds. The
Dockerfiles in this repo already accept that argument (see README.md).

Always push an immutable tag (the commit hash), not only `latest`. Task
definitions then point at an exact image and rollback is a task-definition
revision change.

**Web public URL.** The web app reads `NEXT_PUBLIC_TAMBO_API_URL`. Next.js normally
inlines `NEXT_PUBLIC_*` values at build time, and the Dockerfile has no build arg
for it. After the first deploy, open the dashboard, check the browser network tab,
and confirm requests go to `$API_URL`. If they go to `http://localhost:8261`, the
value was baked in at build; the fix is to add an `ARG`/`ENV` for it to
`apps/web/Dockerfile` and rebuild with `--build-arg`.

## 4. Database (RDS)

1. Create an RDS PostgreSQL **17** instance in the private subnets. Start with
   `db.t4g.small`, 20 GB gp3, Multi-AZ off for a trial, on for production.
2. Security group `tambo-db-sg`: allow TCP 5432 **only** from the ECS tasks' security
   group (`tambo-tasks-sg`, section 6).
3. Create database `tambo` and a dedicated user. Do not use the master user for the
   app.
4. Enable automated backups (7+ days) and deletion protection.

Build the connection string and URL-encode the password (special characters like
`@` or `/` break it):

```
DATABASE_URL=postgresql://tambo_app:<url-encoded-password>@<rds-endpoint>:5432/tambo
```

If RDS requires TLS (default for the `rds.force_ssl` parameter on PG15+), append
`?sslmode=require`.

## 5. Storage (S3)

The API stores chat attachments in S3. Its storage code only turns on when it has
an endpoint, region, **explicit access key and secret**, and a bucket. It does not
use the ECS task role, so you need an IAM user's access key.

1. Create a private bucket, for example `entropik-tambo-user-files`, with
   Block Public Access on and default encryption on.
2. Create an IAM user `tambo-s3` with a policy limited to that bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::entropik-tambo-user-files/*" },
    { "Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::entropik-tambo-user-files" }
  ]
}
```

3. Create an access key for it and store the pair in Secrets Manager (next
   section). Rotate it on a schedule.

Settings the API reads:

| Variable | Value |
|---|---|
| `S3_ENDPOINT` | `https://s3.<region>.amazonaws.com` |
| `S3_REGION` | your region |
| `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` | the IAM user's key (secret) |
| `S3_BUCKET` | the bucket name |

Create the bucket yourself in AWS. Tambo's `storage:init` script is for MinIO and
Supabase, so skip it.

## 6. Secrets, networking and IAM

### Secrets Manager

Create one secret per value (or one JSON secret and reference keys with
`arn:...:KEY::`). Generate the random ones with `openssl rand -hex 16`.

| Secret | Used by | Source |
|---|---|---|
| `DATABASE_URL` | api, web, migration task | section 4 |
| `API_KEY_SECRET` | api, web | `openssl rand -hex 16`, **never change after first use** |
| `PROVIDER_KEY_SECRET` | api, web | `openssl rand -hex 16`, **never change after first use** |
| `NEXTAUTH_SECRET` | web | `openssl rand -hex 16` |
| `OPENAI_API_KEY`, `FALLBACK_OPENAI_API_KEY`, `EXTRACTION_OPENAI_API_KEY` | api | OpenAI |
| `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | api | section 5 |
| `GOOGLE_CLIENT_SECRET` (or GitHub) | web | section 9 |

`API_KEY_SECRET` and `PROVIDER_KEY_SECRET` encrypt and sign stored keys. Losing or
rotating them invalidates every issued API key and stored provider key, so back
them up somewhere safe.

### Security groups

- `tambo-alb-sg`: inbound 443 from the internet (or your office/VPN range for an
  internal-only deployment).
- `tambo-tasks-sg`: inbound 3000 **only** from `tambo-alb-sg`.
- `tambo-db-sg`: inbound 5432 only from `tambo-tasks-sg`.

### IAM roles

- **Task execution role** (`tambo-exec-role`): attach
  `AmazonECSTaskExecutionRolePolicy` and allow `secretsmanager:GetSecretValue` on
  the secrets above. This is what pulls from ECR and injects secrets.
- **Task role** (`tambo-task-role`): no S3 permissions needed (see section 5). Add
  `ssmmessages:*` if you want `aws ecs execute-command` for debugging.

## 7. ECS

Create a cluster and two log groups.

```bash
aws ecs create-cluster --cluster-name tambo --region $AWS_REGION
aws logs create-log-group --log-group-name /ecs/tambo-api --region $AWS_REGION
aws logs create-log-group --log-group-name /ecs/tambo-web --region $AWS_REGION
```

### Task definitions

Fargate, `awsvpc`, `linux/amd64`. Start with 1 vCPU / 2 GB per task.

`api` container (save as `taskdef-api.json`, fill the `<...>` values, then
`aws ecs register-task-definition --cli-input-json file://taskdef-api.json`):

```json
{
  "family": "tambo-api",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "1024",
  "memory": "2048",
  "runtimePlatform": { "cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX" },
  "executionRoleArn": "arn:aws:iam::<account>:role/tambo-exec-role",
  "taskRoleArn": "arn:aws:iam::<account>:role/tambo-task-role",
  "containerDefinitions": [{
    "name": "api",
    "image": "<ECR>/tambo-api:<TAG>",
    "essential": true,
    "portMappings": [{ "containerPort": 3000 }],
    "environment": [
      { "name": "PORT", "value": "3000" },
      { "name": "NODE_ENV", "value": "production" },
      { "name": "S3_ENDPOINT", "value": "https://s3.<region>.amazonaws.com" },
      { "name": "S3_REGION", "value": "<region>" },
      { "name": "S3_BUCKET", "value": "entropik-tambo-user-files" }
    ],
    "secrets": [
      { "name": "DATABASE_URL", "valueFrom": "<secret-arn>" },
      { "name": "API_KEY_SECRET", "valueFrom": "<secret-arn>" },
      { "name": "PROVIDER_KEY_SECRET", "valueFrom": "<secret-arn>" },
      { "name": "OPENAI_API_KEY", "valueFrom": "<secret-arn>" },
      { "name": "FALLBACK_OPENAI_API_KEY", "valueFrom": "<secret-arn>" },
      { "name": "EXTRACTION_OPENAI_API_KEY", "valueFrom": "<secret-arn>" },
      { "name": "S3_ACCESS_KEY_ID", "valueFrom": "<secret-arn>" },
      { "name": "S3_SECRET_ACCESS_KEY", "valueFrom": "<secret-arn>" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/tambo-api",
        "awslogs-region": "<region>",
        "awslogs-stream-prefix": "api"
      }
    }
  }]
}
```

`web` container: same shape, family `tambo-web`, image `tambo-web`, log group
`/ecs/tambo-web`, with this `environment` and `secrets`:

```json
"environment": [
  { "name": "PORT", "value": "3000" },
  { "name": "NODE_ENV", "value": "production" },
  { "name": "NEXTAUTH_URL", "value": "https://tambo.<domain>" },
  { "name": "NEXT_PUBLIC_TAMBO_API_URL", "value": "https://tambo-api.<domain>" },
  { "name": "GOOGLE_CLIENT_ID", "value": "<id>" },
  { "name": "ALLOWED_LOGIN_DOMAIN", "value": "entropik.io" }
],
"secrets": [
  { "name": "DATABASE_URL", "valueFrom": "<secret-arn>" },
  { "name": "API_KEY_SECRET", "valueFrom": "<secret-arn>" },
  { "name": "PROVIDER_KEY_SECRET", "valueFrom": "<secret-arn>" },
  { "name": "NEXTAUTH_SECRET", "valueFrom": "<secret-arn>" },
  { "name": "GOOGLE_CLIENT_SECRET", "valueFrom": "<secret-arn>" }
]
```

`NEXTAUTH_URL` must be exactly the public web URL, scheme included, or sign-in
redirects break. `ALLOWED_LOGIN_DOMAIN` restricts sign-in to one verified email
domain; leave it out to allow anyone who can authenticate.

The images already define a container health check (`wget` against the port), so
no `healthCheck` block is needed in the task definition.

### ALB

1. Create an internet-facing ALB in the public subnets with `tambo-alb-sg`, an HTTPS
   :443 listener using the ACM certificate, and an HTTP :80 listener that redirects
   to 443.
2. Two target groups, type **ip**, protocol HTTP, port 3000:
   - `tambo-web-tg`: health check path `/`, success codes `200-399`.
   - `tambo-api-tg`: health check path `/health`, success codes `200`.
3. Listener rules by host header: `tambo.<domain>` forwards to `tambo-web-tg`,
   `tambo-api.<domain>` forwards to `tambo-api-tg`.
4. Route 53 alias records for both hostnames pointing at the ALB.

### Services

```bash
aws ecs create-service --cluster tambo --service-name tambo-api \
  --task-definition tambo-api --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<private-subnet-1>,<private-subnet-2>],securityGroups=[<tambo-tasks-sg>],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=<tambo-api-tg-arn>,containerName=api,containerPort=3000" \
  --health-check-grace-period-seconds 60 --region $AWS_REGION

aws ecs create-service --cluster tambo --service-name tambo-web \
  --task-definition tambo-web --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<private-subnet-1>,<private-subnet-2>],securityGroups=[<tambo-tasks-sg>],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=<tambo-web-tg-arn>,containerName=web,containerPort=3000" \
  --health-check-grace-period-seconds 60 --region $AWS_REGION
```

Run one task of each at first. Check whether sessions and the API behave correctly
with more than one before raising `--desired-count`.

If you turn on the API's rate limiter (`RATE_LIMIT_ENABLED=true`, off by default),
also set `TRUST_PROXY=1` on the `api` task. Behind the ALB every request otherwise
looks like it comes from the load balancer's IP, so all users share one limit.

## 8. Run the database migrations

Run this once before the first start, and again after every upgrade that ships new
migrations. Use a one-off task from the **api** task definition with a command
override.

```bash
aws ecs run-task --cluster tambo --launch-type FARGATE --task-definition tambo-api \
  --network-configuration "awsvpcConfiguration={subnets=[<private-subnet-1>],securityGroups=[<tambo-tasks-sg>],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"api","command":["sh","-lc","npm -w @tambo-ai-cloud/db run db:migrate"]}]}' \
  --region $AWS_REGION
```

Watch `/ecs/tambo-api` in CloudWatch for success, and confirm the task's exit code
is 0 with `aws ecs describe-tasks`.

Run the `npm` command directly as shown. Do not use `scripts/cloud/init-database.sh`
here: it prints the full `DATABASE_URL`, including the password, into the logs.

## 9. Login (OAuth)

Sign-in is needed to create projects and API keys. Pick one:

- **Google:** in Google Cloud Console create an OAuth client (Web). Authorized
  redirect URI: `https://tambo.<domain>/api/auth/callback/google` (the standard
  NextAuth callback path; confirm it against the error page if Google rejects it).
  Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.
- **GitHub:** same idea with `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET`; callback
  `https://tambo.<domain>/api/auth/callback/github`. Add them to the `web` task
  definition (they are listed in `docker.env.example`).
- **Email:** `RESEND_API_KEY` plus `EMAIL_FROM_DEFAULT`.

After changing a login setting, register a new task-definition revision and run
`aws ecs update-service --cluster tambo --service tambo-web --task-definition tambo-web --force-new-deployment`.

## 10. First use

1. Open `https://tambo.<domain>` and sign in.
2. Create a project. Under project settings add the LLM provider key if the
   dashboard asks for one (the `FALLBACK_OPENAI_API_KEY` env var covers the default).
3. Create an **API key** and copy it immediately; it is shown once.
4. Check the API from your machine:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://tambo-api.<domain>/health      # 200
curl -s -o /dev/null -w "%{http_code}\n" https://tambo-api.<domain>/api-json    # 200, OpenAPI spec
```

API docs (Swagger UI) are at `https://tambo-api.<domain>/api`. The UI and the spec
are served without authentication, so if the API hostname is public, consider
restricting `/api` and `/api-json` with an ALB listener rule or a WAF rule.

5. Run the smoke test from [README.md](README.md#smoke-test), replacing
   `http://localhost:8261` with `https://tambo-api.<domain>`.

## 11. Connect the decode backend

The decode backend reads two settings (`src/common/constants/common.py`):

| Variable | Value |
|---|---|
| `TAMBO_BASE_URL` | `https://tambo-api.<domain>` (default is `https://api.tambo.co`, which stops working after 31 Oct 2026) |
| `TAMBO_API_KEY` | the project API key from section 10 |

Set them wherever the backend gets its environment (Serverless config, Secrets
Manager, local `.env`). Keep the key out of git and out of any value the browser
receives; the backend calls Tambo server-side.

Requirements on the network path:
- If the backend runs in a VPC (Lambda or ECS), it needs outbound HTTPS to the API
  hostname. For a private API, use an internal ALB and a hostname that resolves
  inside the VPC, and put the backend's security group in the ALB's inbound rule.
- A Lambda outside the VPC can use the public hostname directly.

Test from the backend's environment:

```bash
curl -s -X POST "$TAMBO_BASE_URL/v1/threads" -H "x-api-key: $TAMBO_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"userKey":"connectivity-test","initialMessages":[{"role":"user","content":[{"type":"text","text":"ping"}]}]}'
```

A JSON response with an `id` means the URL and key are right. `401` means a wrong or
missing key; a connection timeout means a network or security-group problem.

## 12. Operations

**Logs:** CloudWatch groups `/ecs/tambo-api` and `/ecs/tambo-web`.
`aws logs tail /ecs/tambo-api --follow` streams them.

**Upgrade:**
1. Pull the new Tambo code, build and push new images with a new `$TAG`.
2. Take an RDS snapshot.
3. Register new task-definition revisions pointing at the new tag.
4. Run the migration task (section 8) using the new `tambo-api` revision.
5. `aws ecs update-service ... --task-definition <family>:<new-revision>` for api,
   then web.

**Roll back:** update each service to the previous task-definition revision. If a
migration already ran, restore the RDS snapshot you took in step 2; migrations are
not reversible.

**Stop to save cost:** set both services to `--desired-count 0`. RDS keeps billing
unless you stop it (RDS auto-restarts a stopped instance after 7 days).

**Backups:** RDS automated backups plus a manual snapshot before every upgrade. The
S3 bucket should have versioning on. Back up the two `*_KEY_SECRET` values.

## 13. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Task stops with `exec format error` | Image built for `arm64`. Rebuild with `--platform linux/amd64`. |
| Task stops, `CannotPullContainerError` | Task execution role lacks ECR access, or private subnets have no NAT or ECR endpoints. |
| Task stops, `ResourceInitializationError` for secrets | Execution role cannot read the secret, or no route to Secrets Manager from the subnet. |
| Target group shows tasks unhealthy | Wrong health path (`/health` for api, `/` for web), or `tambo-tasks-sg` does not allow port 3000 from the ALB. |
| API starts, then crashes on database errors | `DATABASE_URL` wrong, password not URL-encoded, RDS needs `?sslmode=require`, or `tambo-db-sg` blocks the tasks. |
| `relation ... does not exist` | Migrations were not run (section 8). |
| Sign-in loops or "redirect_uri_mismatch" | `NEXTAUTH_URL` or the OAuth redirect URI does not match the public URL exactly. |
| Dashboard calls `localhost:8261` | `NEXT_PUBLIC_TAMBO_API_URL` was baked in at build time (see end of section 3). |
| Attachments fail | S3 variables missing (the API silently disables storage), or the IAM user lacks access to the bucket. |
| All users hit rate limits | Rate limiter on without `TRUST_PROXY=1` behind the ALB. |
| Every API key stopped working | `API_KEY_SECRET` changed between deployments. Restore the old value. |

## 14. Cost and sizing (rough)

A single-AZ trial (2 Fargate tasks at 1 vCPU / 2 GB, one `db.t4g.small`, one ALB, a
NAT gateway) runs in the low hundreds of USD per month; the NAT gateway and ALB are
a large share. Check the AWS pricing calculator for your region before committing.
