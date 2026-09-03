#!/usr/bin/env python3
"""Call the generated UTCP gRPC stub against the example server."""

import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
VENV_ROOT = ROOT / ".venv-grpc"
VENV_PYTHON = VENV_ROOT / "bin" / "python"
if VENV_PYTHON.exists() and Path(sys.prefix).resolve() != VENV_ROOT.resolve():
    os.execv(str(VENV_PYTHON), [str(VENV_PYTHON), __file__, *sys.argv[1:]])

try:
    import grpc
except ImportError as error:
    raise SystemExit("Missing grpcio. Run: make grpc-python-setup") from error


GENERATED_DIR = Path(__file__).resolve().parent / "generated"
sys.path.insert(0, str(GENERATED_DIR))

try:
    import utcp_pb2
    import utcp_pb2_grpc
except (ImportError, RuntimeError) as error:
    raise SystemExit(
        "Missing or incompatible generated gRPC stubs. Run: make grpc-python-setup"
    ) from error


def main():
    host = os.environ.get("UTCP_GRPC_HOST", "127.0.0.1")
    port = int(os.environ.get("UTCP_GRPC_PORT", "50051"))
    with grpc.insecure_channel(f"{host}:{port}") as channel:
        stub = utcp_pb2_grpc.UTCPServiceStub(channel)
        manual = stub.GetManual(utcp_pb2.Empty(), timeout=5)
        print("tools:", ", ".join(tool.name for tool in manual.tools))

        response = stub.CallTool(
            utcp_pb2.ToolCallRequest(
                tool="echo",
                args_json=json.dumps({"message": "Hello from Python gRPC client"}),
            ),
            timeout=5,
        )
        print(json.loads(response.result_json))


if __name__ == "__main__":
    main()
