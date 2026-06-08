terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

provider "coder" {}
provider "docker" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

variable "project_name" {
  type        = string
  description = "Project name. One project maps to one Coder workspace and one persistent project volume."
  default     = "private-project"
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9_.-]{1,62}$", var.project_name))
    error_message = "Use 2-63 letters, numbers, dots, underscores, or hyphens, starting with a letter or number."
  }
}

variable "git_repository_url" {
  type        = string
  description = "Optional Git repository URL to clone into the project directory on first start."
  default     = ""
}

variable "project_env" {
  type        = string
  description = "Optional project-specific environment variables in KEY=VALUE format, one per line."
  default     = ""
  sensitive   = true
}

locals {
  username       = data.coder_workspace_owner.me.name
  workspace_name = lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9_.-]/", "-"))
  project_slug   = lower(replace(var.project_name, "/[^a-zA-Z0-9_.-]/", "-"))
  project_dir    = "/home/coder/projects/${local.project_slug}"
  env_file       = "/home/coder/.private-code-agent/${local.project_slug}.env"
  vllm_base_url  = "http://host.docker.internal:8000/v1"
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p \
      /home/coder/projects \
      /home/coder/.private-code-agent \
      /home/coder/.local/share/code-server/User \
      "${local.project_dir}"

    if ! command -v code-server >/dev/null 2>&1; then
      curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server
      export PATH="/tmp/code-server/bin:$PATH"
    fi

    if [ ! -d "${local.project_dir}/.git" ]; then
      if [ -n "${var.git_repository_url}" ]; then
        git clone "${var.git_repository_url}" "${local.project_dir}"
      else
        git -C "${local.project_dir}" init
        printf '# %s\n' "${var.project_name}" > "${local.project_dir}/README.md"
        git -C "${local.project_dir}" add README.md
        git -C "${local.project_dir}" -c user.name="PrivateCodeAgent" -c user.email="private-code-agent@local" commit -m "Initial project" || true
      fi
    fi

    cat > "${local.env_file}" <<'ENV'
    OPENAI_API_BASE_URL=${local.vllm_base_url}
    OPENAI_BASE_URL=${local.vllm_base_url}
    LLM_BASE_URL=${local.vllm_base_url}
    LLM_MODEL=__VLLM_MODEL__
    VLLM_BASE_URL=${local.vllm_base_url}
    VLLM_MODEL=__VLLM_MODEL__
    ${var.project_env}
    ENV
    chmod 0600 "${local.env_file}"

    cat > /home/coder/.local/share/code-server/User/chatLanguageModels.json <<'JSON'
    [
      {
        "name": "vLLM",
        "vendor": "customendpoint",
        "apiType": "chat-completions",
        "models": [
          {
            "id": "__VLLM_MODEL__",
            "name": "Gemma 4 31B QAT",
            "url": "http://host.docker.internal:8000/v1/chat/completions",
            "toolCalling": true,
            "vision": true,
            "maxInputTokens": 128000,
            "maxOutputTokens": 16000
          }
        ]
      }
    ]
    JSON
    chmod 0600 /home/coder/.local/share/code-server/User/chatLanguageModels.json

    set -a
    . "${local.env_file}"
    set +a

    code-server --auth none --port 13337 "${local.project_dir}" >/tmp/code-server.log 2>&1 &
  EOT

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    OPENAI_API_BASE_URL = local.vllm_base_url
    OPENAI_BASE_URL     = local.vllm_base_url
    LLM_BASE_URL        = local.vllm_base_url
    LLM_MODEL           = "__VLLM_MODEL__"
    VLLM_BASE_URL       = local.vllm_base_url
    VLLM_MODEL          = "__VLLM_MODEL__"
  }

  metadata {
    display_name = "CPU"
    key          = "0_cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM"
    key          = "1_ram"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

resource "coder_app" "code_server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337/?folder=${local.project_dir}"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 12
  }
}

resource "docker_volume" "project" {
  name = "pca-${data.coder_workspace.me.id}-project"
  lifecycle {
    ignore_changes = all
  }
}

resource "docker_network" "workspace" {
  count = data.coder_workspace.me.start_count
  name  = "pca-${local.workspace_name}"
}

resource "docker_image" "workspace" {
  name = "private-code-agent-workspace:${data.coder_workspace.me.id}"
  build {
    context = "${path.module}/build"
  }
  triggers = {
    dir_sha1 = sha1(join("", [for f in fileset(path.module, "build/*") : filesha1("${path.module}/${f}")]))
  }
}

resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  image    = docker_image.workspace.name
  name     = "pca-${data.coder_workspace_owner.me.name}-${local.workspace_name}"
  hostname = local.project_slug
  command  = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "OPENAI_API_BASE_URL=${local.vllm_base_url}",
    "OPENAI_BASE_URL=${local.vllm_base_url}",
    "LLM_BASE_URL=${local.vllm_base_url}",
    "LLM_MODEL=__VLLM_MODEL__",
    "VLLM_BASE_URL=${local.vllm_base_url}",
    "VLLM_MODEL=__VLLM_MODEL__"
  ]
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  networks_advanced {
    name = docker_network.workspace[0].name
  }
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.project.name
    read_only      = false
  }
}

resource "coder_metadata" "project" {
  count       = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id
  item {
    key   = "project"
    value = var.project_name
  }
  item {
    key   = "directory"
    value = local.project_dir
  }
  item {
    key   = "vLLM"
    value = "__VLLM_MODEL__"
  }
}
