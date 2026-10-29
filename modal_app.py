"""
Modal deploy layer
==================

Serves the AgentOS FastAPI app on Modal. The container image is built from
the repo's own Dockerfile, so the runtime is identical to every other
sibling; Modal ignores the Dockerfile ENTRYPOINT (no wait-for-db gate is
needed — the database is external Neon, which is always up).

Two settings are load-bearing:

- ``min_containers=1`` keeps one container always warm: the in-process
  scheduler and MCP streams die with scale-to-zero.
- ``max_containers=1`` keeps the verified single-instance baseline. Follow
  docs/scaling.md before enabling multiple containers.

``@modal.concurrent`` lets that single container serve parallel requests —
without it Modal feeds one request at a time and MCP streams would starve
the REST API.

Configuration comes from the ``agentos-secrets`` Modal secret, created and
managed by ``scripts/modal/up.sh`` / ``env-sync.sh`` (it carries every key
in the env file: OPENAI_API_KEY and the Claude Engineer credential, the
discrete DB_* values for Neon, PGSSLMODE=require — Neon requires TLS and
libpq honors the env var, so the portable core needs no change — AGENTOS_URL
+ MCP_CONNECT_SECRET for MCP OAuth, and JWT config once minted).

Optional AgentCore engineering uses S3 checkpoints without an API volume.
See docs/harnesses.md for setup and docs/scaling.md before adding replicas.
"""

# Deploy-layer dependency: `modal` is deliberately not in the core
# requirements.txt (that file is byte-identical family-wide), so mypy runs
# without it installed.
import modal  # type: ignore[import-not-found]

image = modal.Image.from_dockerfile("Dockerfile").env({"SANDBOX_PROVIDER": "agentcore"})

modal_app = modal.App("agentos")


@modal_app.function(
    image=image,
    secrets=[modal.Secret.from_name("agentos-secrets")],
    cpu=2.0,
    memory=4096,
    min_containers=1,
    max_containers=1,
)
@modal.concurrent(max_inputs=100)
@modal.asgi_app(label="agentos")
def serve():
    from app.main import app as agentos_asgi

    return agentos_asgi
