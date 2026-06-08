# PrivateCodeAgent on AWS

PrivateCodeAgent is a private EC2-based Coder + vLLM stack for project-scoped coding workspaces.

## Architecture

- EC2 runs Docker Compose in a private subnet with no public IP.
- Access uses AWS Systems Manager Session Manager port forwarding.
- Coder manages users and one project as one workspace.
- Each Coder workspace provisions:
  - code-server / VS Code Server access through Coder Apps
  - a persistent Git project directory
  - runtime packages in an Ubuntu workspace image
  - `uv` preinstalled in the workspace image
  - a code-server chat language model config for the private vLLM endpoint
  - project-specific environment variables from the Coder workspace parameter
- vLLM exposes an OpenAI-compatible Gemma 4 endpoint on instance-local port `8000`.
- vLLM uses an aggressive Gemma 4 QAT/MTP profile for a single private coding workspace:
  - `google/gemma-4-31B-it-qat-w4a16-ct`
  - `google/gemma-4-31B-it-qat-q4_0-unquantized-assistant`
  - `--kv-cache-dtype fp8`
  - `--speculative-config`
  - `--enable-auto-tool-choice`
  - `--tool-call-parser gemma4`
  - `--reasoning-parser gemma4`

## Deploy

```bash
terraform init
terraform apply
```

The EC2 cloud-init payload is intentionally small. Terraform builds a bootstrap
ZIP from the required `app/` and `aws/` files, uploads it to a private S3 bucket,
and the instance downloads that object at first boot.

Set your Hugging Face token after the secret is created:

```bash
aws secretsmanager put-secret-value \
  --region us-west-2 \
  --secret-id private-code-agent/huggingface-token \
  --secret-string '<your-hf-token>'
```

Restart the app so the instance rereads the secret:

```bash
aws ssm start-session --region us-west-2 --target "$(terraform output -raw instance_id)"
sudo systemctl restart private-code-agent
```

## Access

Forward Coder:

```bash
aws ssm start-session \
  --region us-west-2 \
  --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters file://aws/ssm-parameters/coder-port-forward.json
```

Then open `http://localhost:7080`.

Optional vLLM API forwarding:

```bash
aws ssm start-session \
  --region us-west-2 \
  --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters file://aws/ssm-parameters/vllm-port-forward.json
```

## Initial Account

Coder manages users directly. Open `http://localhost:7080` through the Coder
port forward and create the initial Coder admin user in the setup screen.

## Coder Template

The workspace template is written to:

```text
/opt/private-code-agent/coder-template
```

Create the template from the Coder UI or from the EC2 instance after logging in with the Coder CLI. The EC2 host does not install the `coder` CLI directly, so run the CLI inside the Coder container.

First, keep the Coder SSM port forward open and log in to Coder in your local browser at `http://localhost:7080`. Then start a shell on the EC2 instance and log in the containerized CLI. The login command is:

```bash
cd /opt/private-code-agent
sudo docker compose exec coder coder login http://localhost:7080
```

If the CLI prints a browser authentication URL, open that URL locally while the Coder port forward is still running, approve the login, and return to the terminal. After the CLI login succeeds, push the template:

```bash
cd /opt/private-code-agent
sudo docker compose exec -w /opt/coder-template coder coder templates push private-project
```

If you manually refresh files under `/opt/private-code-agent/coder-template` from the GitHub repository, render the instance-local placeholders before pushing the template:

```bash
cd /opt/private-code-agent
sudo python3 ./render-runtime-config.py
sudo docker compose exec -w /opt/coder-template coder coder templates push private-project
```

When creating a workspace, set:

- `project_name`: the project name. This becomes the persistent project directory under `/home/coder/projects/<project_name>`.
- `git_repository_url`: optional. If set, the repository is cloned on first start.
- `project_env`: optional `KEY=VALUE` lines for project-specific environment variables.

The project workspace also receives:

```text
OPENAI_API_BASE_URL=http://host.docker.internal:8000/v1
OPENAI_BASE_URL=http://host.docker.internal:8000/v1
LLM_BASE_URL=http://host.docker.internal:8000/v1
LLM_MODEL=google/gemma-4-31B-it-qat-w4a16-ct
VLLM_BASE_URL=http://host.docker.internal:8000/v1
VLLM_MODEL=google/gemma-4-31B-it-qat-w4a16-ct
```

The workspace startup script also writes
`/home/coder/.local/share/code-server/User/chatLanguageModels.json` so
code-server is preconfigured to use the private vLLM model.

The vLLM container is exposed only inside the private deployment boundary.
Access is restricted by the private subnet, SSM-only ingress, and Docker host
networking.

## Runtime Checks

Check service status through SSM:

```bash
aws ssm start-session --region us-west-2 --target "$(terraform output -raw instance_id)"
sudo systemctl status private-code-agent --no-pager
cd /opt/private-code-agent
sudo docker compose ps
```

Wait for the systemd service and containers to become ready:

```bash
watch -n 5 'sudo systemctl status private-code-agent --no-pager; echo; sudo docker compose ps'
```

Follow vLLM startup:

```bash
sudo docker compose logs -f vllm
```

If a workspace starts but Coder shows `Agent is taking longer than expected to connect`, check the workspace container logs:

```bash
sudo docker ps --filter 'name=pca-' --format 'table {{.Names}}\t{{.Status}}'
sudo docker logs <workspace-container-name>
```

vLLM is ready when the log prints `Application startup complete.`.

If vLLM exits with a `--speculative-config` JSON parse error, confirm the value
is quoted in `.env`:

```bash
grep '^VLLM_SPECULATIVE_CONFIG=' /opt/private-code-agent/.env
```

The value should look like this, with single quotes around the JSON:

```text
VLLM_SPECULATIVE_CONFIG='{"method":"mtp","model":"google/gemma-4-31B-it-qat-q4_0-unquantized-assistant","num_speculative_tokens":4}'
```

After fixing `.env`, restart only vLLM:

```bash
sudo docker compose up -d vllm
```

Check Coder logs:

```bash
cd /opt/private-code-agent
sudo docker compose logs --tail=200 coder
```

If Coder logs `error: unrecognized subcommand "server"`, make sure the Compose
service does not override the image command. The official Coder image starts the
server by default.

If Coder logs `Using built-in PostgreSQL` or cannot create
`/home/coder/.config/coderv2`, verify that the service uses
`CODER_PG_CONNECTION_URL` and mounts `./data/coder` to `/home/coder/.config`.

If workspace creation fails with Docker socket `permission denied`, verify that
`.env` has `DOCKER_GID` set to the group id of `/var/run/docker.sock` and that
the Coder service includes that gid in `group_add`.

## Notes

- Default instance type is `g6e.xlarge`, which provides one NVIDIA L40S 44 GiB GPU.
- EC2 user data is limited to 16 KiB, so large Compose/template files are fetched from private S3 during boot instead of being embedded in `user_data`.
- Coder uses host networking so localhost-based SSM port forwarding stays simple.
- Workspaces use Docker on the EC2 host.
- If you require no internet egress at all, disable the NAT Gateway and pre-stage Docker images, Coder modules, code-server artifacts, Python/npm packages, and model artifacts through private channels first.
