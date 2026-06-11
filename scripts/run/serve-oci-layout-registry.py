#!/usr/bin/env python3
"""Serve one OCI image layout as a minimal pull-only Docker registry."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


SHA256_RE = re.compile(r"^sha256:[0-9a-fA-F]{64}$")
RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class LayoutRegistry:
    def __init__(self, layout: Path) -> None:
        self.layout = layout
        self.index = self._load_json(layout / "index.json")

    @staticmethod
    def _load_json(path: Path) -> dict[str, Any]:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError(f"{path} is not a JSON object")
        return data

    def blob_path(self, digest: str) -> Path:
        algorithm, value = digest.split(":", 1)
        if algorithm != "sha256" or not re.fullmatch(r"[0-9a-fA-F]{64}", value):
            raise FileNotFoundError(digest)
        return self.layout / "blobs" / algorithm / value.lower()

    def manifest(self, reference: str) -> tuple[Path, str, str]:
        if SHA256_RE.fullmatch(reference):
            path = self.blob_path(reference)
            if not path.is_file():
                raise FileNotFoundError(reference)
            return path, self._digest(path), "application/vnd.oci.image.manifest.v1+json"

        for descriptor in self.index.get("manifests", []):
            annotations = descriptor.get("annotations", {})
            if annotations.get("org.opencontainers.image.ref.name") != reference:
                continue
            digest = descriptor["digest"]
            path = self.blob_path(digest)
            if not path.is_file():
                raise FileNotFoundError(digest)
            media_type = descriptor.get("mediaType", "application/vnd.oci.image.manifest.v1+json")
            return path, digest, media_type

        raise FileNotFoundError(reference)

    def tags(self) -> list[str]:
        tags: list[str] = []
        for descriptor in self.index.get("manifests", []):
            annotations = descriptor.get("annotations", {})
            tag = annotations.get("org.opencontainers.image.ref.name")
            if tag:
                tags.append(tag)
        return tags

    def blob(self, digest: str) -> tuple[Path, str, str]:
        path = self.blob_path(digest)
        if not path.is_file():
            raise FileNotFoundError(digest)
        return path, digest, mimetypes.guess_type(path.name)[0] or "application/octet-stream"

    @staticmethod
    def _digest(path: Path) -> str:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return "sha256:" + h.hexdigest()


class Handler(BaseHTTPRequestHandler):
    registry: LayoutRegistry

    server_version = "coco-oci-layout-registry/0.1"

    def do_GET(self) -> None:  # noqa: N802
        self._handle(send_body=True)

    def do_HEAD(self) -> None:  # noqa: N802
        self._handle(send_body=False)

    def log_message(self, fmt: str, *args: Any) -> None:
        print("%s - - [%s] %s" % (self.address_string(), self.log_date_time_string(), fmt % args), flush=True)

    def _handle(self, send_body: bool) -> None:
        path = unquote(urlparse(self.path).path)
        if path in {"/v2", "/v2/"}:
            self.send_response(HTTPStatus.OK)
            self.send_header("Docker-Distribution-API-Version", "registry/2.0")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if path.startswith("/v2/") and path.endswith("/tags/list"):
            name = path.removeprefix("/v2/").removesuffix("/tags/list").strip("/")
            self._send_json({"name": name, "tags": self.registry.tags()}, send_body)
            return

        try:
            if "/manifests/" in path:
                _, reference = path.rsplit("/manifests/", 1)
                file_path, digest, media_type = self.registry.manifest(reference)
            elif "/blobs/" in path:
                _, digest_ref = path.rsplit("/blobs/", 1)
                file_path, digest, media_type = self.registry.blob(digest_ref)
            else:
                raise FileNotFoundError(path)
        except (FileNotFoundError, ValueError):
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        self._send_file(file_path, digest, media_type, send_body)

    def _send_json(self, data: dict[str, Any], send_body: bool) -> None:
        body = (json.dumps(data, separators=(",", ":")) + "\n").encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Docker-Distribution-API-Version", "registry/2.0")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def _send_file(self, path: Path, digest: str, media_type: str, send_body: bool) -> None:
        size = path.stat().st_size
        start, end, partial = self._parse_range(size)
        length = end - start + 1

        self.send_response(HTTPStatus.PARTIAL_CONTENT if partial else HTTPStatus.OK)
        self.send_header("Docker-Distribution-API-Version", "registry/2.0")
        self.send_header("Docker-Content-Digest", digest)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", media_type)
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

        if not send_body:
            return

        with path.open("rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _parse_range(self, size: int) -> tuple[int, int, bool]:
        header = self.headers.get("Range")
        if not header:
            return 0, size - 1, False

        match = RANGE_RE.fullmatch(header.strip())
        if not match:
            self.send_error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            raise ValueError(header)

        first, last = match.groups()
        if first == "":
            suffix_len = int(last)
            start = max(size - suffix_len, 0)
            end = size - 1
        else:
            start = int(first)
            end = int(last) if last else size - 1

        if start >= size or end < start:
            self.send_error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            raise ValueError(header)

        return start, min(end, size - 1), True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--layout", required=True, type=Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=19000, type=int)
    args = parser.parse_args()

    registry = LayoutRegistry(args.layout)
    handler = type("OCIRegistryHandler", (Handler,), {"registry": registry})
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"Serving OCI layout {args.layout} on http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
