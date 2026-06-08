# PrivateCodeAgent Design Document

## Purpose

PrivateCodeAgent provides a private coding-agent environment that keeps the LLM endpoint and project execution environment under the user's control.

The current architecture is:

```text
User
  -> Browser
  -> Coder
  -> Project Workspace
       - code-server
       - code-server chat model configured for vLLM
       - Git repository
       - Runtime packages including uv
       - Project-specific environment variables
  -> vLLM / Gemma 4
```

The implementation in this repository turns that into an AWS EC2 + Docker Compose system. The EC2 instance has no public IP and is accessed through AWS Systems Manager port forwarding.

## Design Goals

- One project maps to one Coder workspace.
- Coder manages users directly; there is no Keycloak or external OIDC service.
- A workspace owns a persistent project volume and its own Git working tree.
- Code editing and AI assistance happen inside code-server.
- vLLM serves Gemma 4 through an OpenAI-compatible private endpoint.
- Bootstrap resources are staged in private S3 instead of GitHub user content.
- Runtime checks and deployment should remain command-driven; this repository should not require live EC2 access during static development.

## Main Components

### AWS Layer

Files:

- `main.tf`
- `variables.tf`
- `outputs.tf`
- `templates/cloud-init.yaml.tftpl`

The AWS layer creates:

- A VPC with public and private subnets.
- A private EC2 instance using the AWS Deep Learning AMI SSM parameter.
- VPC endpoints for SSM, SSM messages, EC2 messages, Secrets Manager, CloudWatch Logs, and S3.
- Optional NAT Gateway egress for Docker image pulls, package installation, and Hugging Face model download.
- A private S3 bucket and bootstrap ZIP object containing the required app resources.
- A Secrets Manager secret for the Hugging Face token.

The EC2 instance writes the Compose stack and Coder workspace template under `/opt/private-code-agent`.

The EC2 user data does not embed the full Compose file or Coder template. EC2 user data has a small size limit, so cloud-init writes a compact `start.sh`; that script downloads the Terraform-generated bootstrap ZIP from private S3 and copies `app/` and `aws/` into `/opt/private-code-agent`.

### Compose Layer

File:

- `app/docker-compose.yml`

Services:

- `vllm`
- `coder`
- `coder-postgres`

The Compose stack intentionally does not include LibreChat, Open WebUI, Keycloak, or OpenHands. The goal of this project is a project-based coding workspace with code-server's AI features configured for the private vLLM endpoint.

### Identity Layer

Coder handles user management directly. Coder password authentication remains enabled, and the initial administrator is created through Coder's first-run setup screen after opening `http://localhost:7080` through SSM port forwarding.

Removing Keycloak also removes the need to keep a second local port-forward session open for OIDC and avoids managing realm import state.

### Workspace Layer

Files:

- `app/coder-template/main.tf`
- `app/coder-template/build/Dockerfile`

The workspace is a Coder template backed by Docker. The template creates:

- A project Docker volume.
- A workspace Docker container.
- A Docker network dedicated to the workspace.
- A code-server Coder app.
- Coder metadata for project name, directory, and vLLM model.

The workspace image installs common development tools and `uv`. The workspace startup script writes `/home/coder/.local/share/code-server/User/chatLanguageModels.json` with:

```text
vendor: customendpoint
apiType: chat-completions
url: http://host.docker.internal:8000/v1/chat/completions
model: google/gemma-4-31B-it-qat-w4a16-ct
```

The same vLLM connection values are exported through OpenAI-compatible and generic LLM environment variables:

```text
OPENAI_API_BASE_URL=http://host.docker.internal:8000/v1
OPENAI_BASE_URL=http://host.docker.internal:8000/v1
LLM_BASE_URL=http://host.docker.internal:8000/v1
LLM_MODEL=<Gemma model>
VLLM_BASE_URL=http://host.docker.internal:8000/v1
VLLM_MODEL=<Gemma model>
```

### LLM Layer

Files:

- `app/docker-compose.yml`
- `variables.tf`
- `templates/cloud-init.yaml.tftpl`

vLLM exposes an OpenAI-compatible API on host port `8000` inside the private
deployment boundary. Access is restricted by the private subnet, SSM-only
ingress, and Docker host boundary.

The Gemma 4 defaults are tuned for a single private coding workspace:

```text
VLLM_MODEL=google/gemma-4-31B-it-qat-w4a16-ct
VLLM_SPECULATIVE_CONFIG={"method":"mtp","model":"google/gemma-4-31B-it-qat-q4_0-unquantized-assistant","num_speculative_tokens":4}
--max-model-len 131072
--gpu-memory-utilization 0.95
--max-num-seqs 1
--kv-cache-dtype fp8
--enable-auto-tool-choice
--tool-call-parser gemma4
--reasoning-parser gemma4
```

The `gemma4` tool and reasoning parser flags are retained so vLLM can handle Gemma 4 tool-call output and reasoning-channel tokens consistently for OpenAI-compatible clients.

## Decisions

### Use AWS SSM Port Forwarding Instead Of Public Ingress

The implementation keeps the instance private and exposes Coder and vLLM access through SSM port forwarding.

Reasoning:

- It avoids introducing DNS, TLS, reverse proxy, public security groups, and internet-facing auth surface in the first implementation.
- It keeps the system private by default.

### Stage Bootstrap Files In Private S3

Terraform creates a local bootstrap ZIP with the required app files, uploads it to a private S3 bucket, and grants the EC2 instance role `s3:GetObject` for that object.

Reasoning:

- EC2 user data remains under the size limit.
- First boot no longer depends on GitHub user content.
- The existing S3 gateway endpoint lets the private instance retrieve the object without public S3 routing.

### Bind vLLM For Workspace Containers

vLLM is published as `8000:8000` instead of `127.0.0.1:8000:8000`.

Reasoning:

- Workspace containers call vLLM through `http://host.docker.internal:8000/v1`.
- Docker containers cannot reach a host service that is published only on host loopback through the host-gateway address.
- SSM local port forwarding to destination port `8000` still works because the service remains available on the EC2 host.

### Use Docker Workspaces Instead Of Kubernetes Or Separate EC2 Instances

Coder supports several provisioning targets. This implementation uses the Docker provider and local Docker engine on the GPU EC2 instance.

Reasoning:

- It is the smallest useful architecture for one private host.
- It keeps the workspace near the vLLM endpoint.
- It matches Coder's documented Docker workspace template model.

### Use One Persistent Docker Volume Per Workspace Project

The Coder template creates a persistent Docker volume named from `data.coder_workspace.me.id`.

Reasoning:

- A stopped workspace should retain the project Git tree and local files.
- The immutable workspace ID avoids accidental volume replacement when display names change.

### Clone Or Initialize Git On First Start

The workspace parameter `git_repository_url` is optional.

Behavior:

- If a URL is provided, the workspace clones it into `/home/coder/projects/<project_name>`.
- If no URL is provided, the workspace initializes a new Git repository with a README.

### Substitute Runtime Values During cloud-init

The repository stores placeholders such as `__VLLM_MODEL__`.

At boot, `templates/cloud-init.yaml.tftpl` writes `.env`, and replaces placeholders in:

- `coder-template/main.tf`

The replacement logic lives in `app/render-runtime-config.py` so the same rendering step can be rerun manually after refreshing `/opt/private-code-agent/coder-template`.

## Implementation Notes And Caveats

### Coder Provider Version Did Not Support `startup_script_timeout`

The first template version used `startup_script_timeout`, but `terraform validate` against the resolved `coder/coder` provider version rejected it as an unsupported argument.

Resolution:

- Removed `startup_script_timeout` from `app/coder-template/main.tf`.

### Root Terraform And Coder Template Need Separate Provider Locks

There are two Terraform configurations:

- Root AWS deployment.
- Coder workspace template.

Each has its own `.terraform.lock.hcl`.

### Docker Socket Access Is A Deliberate Trust Boundary

The Coder server mounts `/var/run/docker.sock` so it can provision workspace containers.

Security implication:

- Docker socket access is effectively host-level control.
- This design is acceptable for a private single-user or highly trusted deployment, but not enough for hostile multi-tenant isolation.

### Network Egress Is Still Required By Default

The default deployment creates a NAT Gateway.

Reasoning:

- The instance needs to pull Docker images.
- vLLM needs Hugging Face model artifacts.
- code-server installation and workspace package installation require external package sources unless pre-staged.

Operational implication:

- A fully air-gapped version needs a private image registry, preloaded model cache, package mirrors, and a replacement for online code-server installation.

### vLLM Startup Can Be Slow

Gemma 4 QAT/MTP on `g6e.xlarge` can take time to download and initialize.

Operational implication:

- Use `docker compose logs -f vllm`.
- Treat model download/loading time separately from real service failure.
- vLLM is ready when logs show application startup completion.

## Validation

Use static validation first:

```bash
terraform fmt -recursive
terraform init
terraform validate
terraform -chdir=app/coder-template fmt
terraform -chdir=app/coder-template init
terraform -chdir=app/coder-template validate
docker compose -f app/docker-compose.yml config --quiet
```

Do not run `terraform apply` or live EC2 runtime checks unless explicitly requested.

## Future Design Work

- Pin Coder and vLLM image versions after runtime verification.
- Pre-stage code-server artifacts if internet egress should be removed.
- Add backup and restore procedures for:
  - Coder Postgres
  - Docker project volumes
  - Hugging Face model cache
- Consider a stronger workspace isolation backend if multiple untrusted users will share the system.
