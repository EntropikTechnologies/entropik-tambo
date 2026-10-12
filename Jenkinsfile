// Tambo (self-hosted) — dev deployment to AWS ECS, same model as decode-backend:
// build on the Jenkins agent with nerdctl, push to ECR, force a new ECS deployment.
//
//   dev -> account 081063778907, ap-south-1, cluster decode-ecs-cluster-dev-in
//
// One-time prerequisites (ECR repos, RDS, secrets, ALB, task definitions, ECS services)
// must already exist; this pipeline only builds, pushes and redeploys.
pipeline {
  agent {
    label 'jenkins-backend-agent'
  }

  parameters {
    string(name: 'BRANCH', defaultValue: 'main', description: 'Branch to build')
    booleanParam(name: 'RUN_MIGRATIONS', defaultValue: true, description: 'Run DB migrations as a one-off ECS task before redeploying services')
    booleanParam(name: 'FORCE_NO_CACHE', defaultValue: false, description: 'Build with --no-cache')
  }

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 60, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    GIT_REPO       = 'EntropikTechnologies/entropik-tambo'
    AWS_PROFILE    = 'ENTROPIKTECH_DEV'
    AWS_REGION     = 'ap-south-1'
    ECR_ACCOUNT_ID = '081063778907'
    ECR_REGISTRY   = '081063778907.dkr.ecr.ap-south-1.amazonaws.com'

    ECS_CLUSTER     = 'decode-ecs-cluster-dev-in'
    API_SERVICE     = 'decode-ecs-tambo-api-service-dev-in'   // confirm the real service names
    WEB_SERVICE     = 'decode-ecs-tambo-web-service-dev-in'
    API_TASK_FAMILY = 'decode-ecs-tambo-api-dev-in'           // task definition family used for the migration task
    API_CONTAINER   = 'tambo-api'                             // container name inside that task definition
    MIGRATION_SUBNETS         = 'subnet-05045ecaf8362686f,subnet-04cf5e32d038fd155,subnet-0ee0f4fc64415827e'            // private subnets (comma separated)
    MIGRATION_SECURITY_GROUPS = 'sg-0fc9457b4696e8a5b'                // must be allowed to reach RDS

    API_IMAGE_NAME = 'tambo-api'
    WEB_IMAGE_NAME = 'tambo-web'

    // Baked into the web bundle at build time (Next.js inlines NEXT_PUBLIC_*).
    // Requires the matching ARG/ENV in apps/web/Dockerfile.
    TAMBO_PUBLIC_API_URL = 'https://api.dev.tambo.entropik.io'
  }

  stages {
    stage('Checkout') {
      steps {
        git branch: params.BRANCH,
            url: "https://github.com/${env.GIT_REPO}.git",
            credentialsId: 'github-credentials'
        script {
          env.GIT_COMMIT_SHORT = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.IMAGE_TAG = "${env.BUILD_TIMESTAMP}.${env.BUILD_NUMBER}.${env.GIT_COMMIT_SHORT}"
          echo "Deploying ${env.GIT_COMMIT_SHORT} as ${env.IMAGE_TAG}"
        }
        sh '''
          nerdctl info >/dev/null 2>&1 || true
          if ! pgrep -x buildkitd >/dev/null 2>&1; then
            buildkitd &
            sleep 3
          fi
        '''
      }
    }

    stage('Build & Push Images') {
      parallel {
        stage('tambo-api') {
          steps {
            sh '''
              set -euo pipefail
              aws ecr get-login-password --region "$AWS_REGION" | nerdctl login --username AWS --password-stdin "$ECR_REGISTRY"
              IMAGE="$ECR_REGISTRY/$API_IMAGE_NAME"
              CACHE_FLAG=""
              if [ "${FORCE_NO_CACHE}" = "true" ]; then CACHE_FLAG="--no-cache"; fi
              nerdctl build $CACHE_FLAG \
                --cache-from type=registry,ref=$IMAGE:latest \
                --cache-to type=inline \
                --platform linux/amd64 \
                --output type=image,name=$IMAGE:latest,push=true \
                -f apps/api/Dockerfile .
              nerdctl pull "$IMAGE:latest"
              nerdctl tag "$IMAGE:latest" "$IMAGE:$IMAGE_TAG"
              nerdctl push "$IMAGE:$IMAGE_TAG"
            '''
          }
        }
        stage('tambo-web') {
          steps {
            sh '''
              set -euo pipefail
              aws ecr get-login-password --region "$AWS_REGION" | nerdctl login --username AWS --password-stdin "$ECR_REGISTRY"
              IMAGE="$ECR_REGISTRY/$WEB_IMAGE_NAME"
              CACHE_FLAG=""
              if [ "${FORCE_NO_CACHE}" = "true" ]; then CACHE_FLAG="--no-cache"; fi
              nerdctl build $CACHE_FLAG \
                --cache-from type=registry,ref=$IMAGE:latest \
                --cache-to type=inline \
                --platform linux/amd64 \
                --build-arg NEXT_PUBLIC_TAMBO_API_URL="$TAMBO_PUBLIC_API_URL" \
                --output type=image,name=$IMAGE:latest,push=true \
                -f apps/web/Dockerfile .
              nerdctl pull "$IMAGE:latest"
              nerdctl tag "$IMAGE:latest" "$IMAGE:$IMAGE_TAG"
              nerdctl push "$IMAGE:$IMAGE_TAG"
            '''
          }
        }
      }
    }

    stage('DB Migration') {
      when { expression { params.RUN_MIGRATIONS } }
      steps {
        // One-off task from the API task definition (it already has DATABASE_URL from Secrets Manager).
        // The service still runs the previous image; migrations must stay backwards compatible.
        sh '''
          set -euo pipefail
          TASK_ARN=$(aws ecs run-task \
            --region "$AWS_REGION" --cluster "$ECS_CLUSTER" \
            --launch-type FARGATE --task-definition "$API_TASK_FAMILY" \
            --network-configuration "awsvpcConfiguration={subnets=[$MIGRATION_SUBNETS],securityGroups=[$MIGRATION_SECURITY_GROUPS],assignPublicIp=DISABLED}" \
            --overrides "{\\"containerOverrides\\":[{\\"name\\":\\"$API_CONTAINER\\",\\"command\\":[\\"npm\\",\\"-w\\",\\"@tambo-ai-cloud/db\\",\\"run\\",\\"db:migrate\\"]}]}" \
            --query 'tasks[0].taskArn' --output text)
          aws ecs wait tasks-stopped --region "$AWS_REGION" --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN"
          EXIT_CODE=$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN" \
            --query "tasks[0].containers[?name=='$API_CONTAINER'].exitCode | [0]" --output text)
          echo "Migration exit code: $EXIT_CODE"
          [ "$EXIT_CODE" = "0" ]
        '''
      }
    }

    stage('Deploy to ECS') {
      steps {
        sh '''
          set -euo pipefail
          for svc in "$API_SERVICE" "$WEB_SERVICE"; do
            aws ecs update-service --region "$AWS_REGION" --cluster "$ECS_CLUSTER" \
              --service "$svc" --force-new-deployment --no-cli-pager >/dev/null
          done
          aws ecs wait services-stable --region "$AWS_REGION" --cluster "$ECS_CLUSTER" \
            --services "$API_SERVICE" "$WEB_SERVICE"
        '''
      }
    }
  }

  post {
    always {
      sh 'nerdctl image prune -f || true'
    }
  }
}
