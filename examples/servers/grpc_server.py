#!/usr/bin/env python3
"""Small UTCP gRPC server used by examples/grpc.rb."""

from concurrent import futures
import json
import os
from pathlib import Path
import signal
import sys

ROOT = Path(__file__).resolve().parents[2]
VENV_ROOT = ROOT / ".venv-grpc"
VENV_PYTHON = VENV_ROOT / "bin" / "python"
if VENV_PYTHON.exists() and Path(sys.prefix).resolve() != VENV_ROOT.resolve():
    os.execv(str(VENV_PYTHON), [str(VENV_PYTHON), __file__, *sys.argv[1:]])

try:
    import grpc
except ImportError as error:
    raise SystemExit(
        "Missing grpcio. Run: make grpc-python-setup"
    ) from error

GENERATED_DIR = ROOT / "examples" / "generated"
sys.path.insert(0, str(GENERATED_DIR))

try:
    import utcp_pb2
    import utcp_pb2_grpc
except (ImportError, RuntimeError) as error:
    raise SystemExit(
        "Missing or incompatible generated gRPC stubs. Run: make grpc-python-setup"
    ) from error


class UTCPService(utcp_pb2_grpc.UTCPServiceServicer):
    def GetManual(self, _request, _context):
        return utcp_pb2.Manual(
            version="1.0.0",
            tools=[
                utcp_pb2.Tool(
                    name="echo",
                    description="Echo a JSON message from the Python gRPC server",
                )
            ],
        )

    def CallTool(self, request, context):
        tool_name = request.tool.rsplit(".", 1)[-1]
        if tool_name != "echo":
            context.abort(grpc.StatusCode.NOT_FOUND, f"unknown tool: {request.tool}")

        try:
            arguments = json.loads(request.args_json or "{}")
        except json.JSONDecodeError as error:
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, f"invalid args_json: {error}")

        if not isinstance(arguments, dict):
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, "args_json must contain an object")

        value = arguments.get("message", arguments.get("msg"))
        return utcp_pb2.ToolCallResponse(result_json=json.dumps({"echo": value}))

    def CallToolStream(self, request, context):
        yield self.CallTool(request, context)


def main():
    port = int(os.environ.get("PORT", "50051"))
    address = f"127.0.0.1:{port}"
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=4))
    utcp_pb2_grpc.add_UTCPServiceServicer_to_server(UTCPService(), server)
    if server.add_insecure_port(address) == 0:
        raise RuntimeError(f"unable to bind grpc://{address}")

    server.start()
    print(f"Listening on grpc://{address} (Python)", file=sys.stderr, flush=True)

    stopping = False

    def shutdown(_signal_number, _frame):
        nonlocal stopping
        if not stopping:
            stopping = True
            server.stop(grace=2)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        server.wait_for_termination()
    finally:
        server.stop(grace=0)


if __name__ == "__main__":
    main()
