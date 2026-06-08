# vLLM + Gemma 4 QAT/MTP Configuration

Created: 2026-06-07

This document summarizes the purpose, rationale, and rollback strategy for the vLLM + Gemma 4 QAT/MTP configuration used by PrivateCodeAgent.

## Target Files

| Area | Files |
|---|---|
| Terraform variables | `variables.tf` |
| Docker Compose runtime | `app/docker-compose.yml` |
| EC2 bootstrap | `templates/cloud-init.yaml.tftpl` |

## Current Settings

| Item | Value |
|---|---|
| Instance | `g6e.xlarge` |
| GPU | 1 x NVIDIA L40S, 44 GiB accelerator memory |
| CPU/RAM | 4 vCPU / 32 GiB memory |
| Target model | `google/gemma-4-31B-it-qat-w4a16-ct` |
| MTP assistant | `google/gemma-4-31B-it-qat-q4_0-unquantized-assistant` |
| vLLM image | `vllm/vllm-openai:v0.22.1` |
| `max_model_len` | `131072` |
| `num_speculative_tokens` | `4` |
| `gpu_memory_utilization` | `0.95` |
| `max_num_seqs` | `1` |
| `kv_cache_dtype` | `fp8` |
| `limit_mm_per_prompt` | `{"image": 1, "audio": 0}` |
| `speculative_config` | `{"method":"mtp","model":"google/gemma-4-31B-it-qat-q4_0-unquantized-assistant","num_speculative_tokens":4}` |
| Attention backend | auto; do not use `VLLM_ATTENTION_BACKEND=FLASHINFER` |
| Tool calling | `--enable-auto-tool-choice`, `--tool-call-parser gemma4` |
| Reasoning parser | `--reasoning-parser gemma4` |

## Assumptions And Policy

| Viewpoint | Details |
|---|---|
| Goal | Use the already boot-validated `g6e.xlarge` setup as an aggressive demo profile |
| Changes from defaults | Increase MTP speculative depth, GPU memory utilization, and context length |
| Multimodal | Use text chat as the primary workload while allowing up to 1 image per prompt |
| Main constraint | Fit the 31B QAT model, assistant model, KV cache, and image-input headroom into a 44 GiB GPU |
| Stability policy | Prefer a single session with `max_num_seqs=1` to preserve long context and a smoother demo experience |

## Parameter Rationale

| Parameter | Why It Was Chosen | Tradeoff / Rollback | Main Basis |
|---|---|---|---|
| `instance_type=g6e.xlarge` | `g6.xlarge` has an L4 with 22 GiB, leaving little room for the 31B QAT model, assistant model, and KV cache. `g6e.xlarge` provides an L40S with 44 GiB. | CPU/RAM remain 4 vCPU / 32 GiB, so concurrency and modalities are constrained. | AWS accelerated instance specs |
| `model_id=google/gemma-4-31B-it-qat-w4a16-ct` | Google/HF provide this as a compressed-tensors QAT checkpoint for vLLM. The 31B model favors quality among dense Gemma 4 choices. | Prioritizes quality over speed. If memory is insufficient, move to a smaller Gemma 4 model. | Google QAT announcement, HF model card, Unsloth guide |
| `w4a16-ct` | The weight 4-bit / activation 16-bit compressed-tensors format fits vLLM native inference. | Do not set `--quantization`; let the model config's `quantization_config` drive detection. | vLLM engine args, LLM Compressor docs |
| `mtp_assistant_model_id` | The Gemma 4 assistant checkpoint is used by vLLM's Gemma 4 MTP path. Because the target model is 31B, the assistant is also from the 31B family. | It must be treated as `method=mtp`, not as a generic draft model. | vLLM MTP docs |
| `--speculative-config.method=mtp` | Uses the target model's native multi-token prediction capability for speculative decoding. | If an older vLLM release treats it as `draft_model`, upgrade vLLM. | vLLM MTP docs |
| `num_speculative_tokens=4` | vLLM docs describe a small starting value such as `1`; this profile raises it to `4` for a more aggressive demo setup. | It may not improve speed. If speed does not improve or memory pressure is high, reduce to `2`, then to `1`. | vLLM MTP docs |
| `max_model_len=131072` | The Gemma 4 31B model card advertises 256K context. On an L40S with 44 GiB, this keeps margin below the model maximum and aligns with the MTP assistant's 131,072 token limit. | On OOM, reduce to `98304` or `65536`. This is much more aggressive than Unsloth's practical 32K default. | HF model card, vLLM engine args, Unsloth guide |
| `gpu_memory_utilization=0.95` | Allocates more KV cache than the vLLM default `0.9` to prioritize long context. | Leaves less room for CUDA graphs, speculative decoding, long prefill, and image input. First reduce `max_model_len`, then roll back to `0.92`. | vLLM engine args |
| `max_num_seqs=1` | Prioritizes one long demo session and large code-context prompts over concurrent multi-user processing. | Reduces concurrent throughput. For multi-user demos, compare `2` with `max_model_len=65536`. | vLLM scheduling behavior |
| `kv_cache_dtype=fp8` | KV cache size directly affects context length and concurrency, making this a key memory-saving setting on a 44 GiB GPU. | May affect quality or stability. Compare with `auto`, but expect to reduce context length. | vLLM engine args |
| `limit_mm_per_prompt={"image":1,"audio":0}` | Gemma 4 31B supports image-text-to-text. Allow 1 image for image demos and disable audio, which is not the main target for this 31B setup. | Image input increases memory footprint. Use `image:0` if text-only stability is more important. | Google QAT announcement, vLLM engine args, HF model card |
| Attention backend auto | Let vLLM choose the backend automatically. Gemma 4 has heterogeneous head dimensions, so an explicitly requested backend may not be used. | If specifying a backend in the future, confirm vLLM support and verify the actual backend in startup logs. | vLLM runtime behavior |
| `vllm_image=vllm/vllm-openai:v0.22.1` | Pin the image because `latest` can change behavior. Gemma 4 QAT/MTP depends on newer vLLM functionality. | If issues appear, switch to a Gemma 4-specific tag or nightly image. | vLLM Gemma 4 recipe |
| `--enable-auto-tool-choice` + `--tool-call-parser gemma4` | Allows vLLM to parse Gemma 4 tool-call output for OpenAI-compatible tool calling. | Keep enabled for compatibility even when the client does not use tools. | vLLM Gemma 4 tool parser behavior |
| `--reasoning-parser gemma4` | Reduces the risk that Gemma 4 reasoning-channel tokens leak into normal responses. | Client-side UI support is still required to expose reasoning display or reasoning effort controls. | vLLM Gemma 4 reasoning parser behavior |

## Parameters Intentionally Left Unset

| Parameter | Why It Is Not Explicitly Set | When To Consider It |
|---|---|---|
| `--quantization` | When unset, vLLM checks the model config's `quantization_config`. The `w4a16-ct` model is a compressed-tensors QAT model, so detection is left to the model config. | Consider setting it only if detection fails or model loading breaks. |
| `--tensor-parallel-size` | `g6e.xlarge` has 1 GPU, so the default value of 1 is sufficient. | Consider it when moving to a multi-GPU instance. |
| CPU offload | The profile assumes the model fits in the 44 GiB GPU. CPU offload can virtually increase GPU memory, but it adds CPU-GPU transfer on each forward pass. | Use it only as a late fallback if smaller model/context choices are not acceptable. |
| `--enforce-eager` | Useful when isolating CUDA graph memory issues, but it may reduce speed. | Consider it if `0.95` / `131072` / `image:1` triggers CUDA graph-related OOM. |
| `--max-num-batched-tokens` | Can control long prefill behavior, but defaults depend on the vLLM version and chunked prefill behavior. | Tune it only after first trying `max_model_len`, `gpu_memory_utilization`, and `max_num_seqs`. |

## Logs To Check During Startup And Validation

| Check | What To Look For |
|---|---|
| Model load | `google/gemma-4-31B-it-qat-w4a16-ct` is loaded as compressed-tensors |
| Speculative config | Startup logs show `method='mtp'` |
| Assistant handling | The assistant checkpoint is not treated as a generic draft model |
| Memory | No OOM appears during startup or generation |
| Model API | `/v1/models` includes the served model name `google/gemma-4-31B-it-qat-w4a16-ct` |
| Chat API | `/v1/chat/completions` succeeds with a short text-only prompt |
| KV cache | Startup logs show KV cache capacity and maximum concurrency |
| Readiness | `Application startup complete.` appears |

If an older vLLM release treats the Gemma 4 assistant checkpoint as a `draft_model`, upgrade to a vLLM version that supports Gemma 4 MTP.

## Rollback Order For Failures

| Symptom | First Action | Next Action |
|---|---|---|
| Startup OOM | `max_model_len=98304` | `65536` |
| Generation OOM | Reduce `max_model_len` | `gpu_memory_utilization=0.92` |
| MTP does not improve speed | `num_speculative_tokens=2` | `1` |
| MTP is treated as `draft_model` | Update the vLLM image | Consider a Gemma 4-specific tag or nightly image |
| Image input is unstable | `image:0` | Revalidate in text-only mode |
| Quality regression is concerning | Compare `kv_cache_dtype=auto` | Reduce context length |
| Tool calling returns 400 | Confirm `--enable-auto-tool-choice` and `--tool-call-parser gemma4` | Check parsed args in vLLM logs |
| Reasoning token leakage | Confirm `--reasoning-parser gemma4` | Check client-side display handling |

## Source Notes

| Source | Information Used In This Configuration |
|---|---|
| Google: Gemma 4 with QAT | Compressed tensors for vLLM, modality memory footprint |
| Hugging Face: `google/gemma-4-31B-it-qat-w4a16-ct` | 31B total parameters, 256K context, compressed-tensors, image/audio modality notes |
| Hugging Face: assistant checkpoint | Gemma 4 31B MTP assistant model |
| vLLM MTP docs | `method=mtp`, Gemma 4 assistant checkpoint, `num_speculative_tokens`, older release caveat for `draft_model` |
| vLLM engine args | `max_model_len`, `gpu_memory_utilization`, `kv_cache_dtype`, `limit_mm_per_prompt`, `quantization_config`, CPU offload |
| vLLM / LLM Compressor | W4A16 compressed-tensors scheme |
| vLLM Gemma 4 recipe | Gemma 4 MTP has required supported images or nightly images in some periods |
| Unsloth Gemma 4 guide | 31B favors quality, 32K context as a practical starting default |
| AWS accelerated instance specs | Comparison between `g6.xlarge` L4 22 GiB and `g6e.xlarge` L40S 44 GiB |
| vLLM runtime validation | `gemma4` tool/reasoning parser, attention backend auto selection |

## Reference URLs

- Google: Gemma 4 with quantization-aware training: https://blog.google/innovation-and-ai/technology/developers-tools/quantization-aware-training-gemma-4/
- Unsloth: Gemma 4 QAT: https://unsloth.ai/docs/models/gemma-4/qat
- Unsloth: Gemma 4: https://unsloth.ai/docs/models/gemma-4
- Hugging Face: `google/gemma-4-31B-it-qat-w4a16-ct`: https://huggingface.co/google/gemma-4-31B-it-qat-w4a16-ct
- Hugging Face: `google/gemma-4-31B-it-qat-q4_0-unquantized-assistant`: https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-unquantized-assistant
- vLLM MTP docs: https://github.com/vllm-project/vllm/blob/main/docs/features/speculative_decoding/mtp.md
- vLLM engine args: https://docs.vllm.ai/en/v0.10.0/configuration/engine_args.html
- vLLM / LLM Compressor compression schemes: https://docs.vllm.ai/projects/llm-compressor/en/stable/steps/choosing-scheme/
- vLLM Gemma 4 recipe: https://recipes.vllm.ai/Google/gemma-4-E2B-it
- AWS accelerated instance specs: https://docs.aws.amazon.com/ec2/latest/instancetypes/ac.html
