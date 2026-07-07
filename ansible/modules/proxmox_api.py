#!/usr/bin/python
# -*- coding: utf-8 -*-
"""Shared Proxmox API helper used by all modules in this collection."""

import json
import time
import ssl
import urllib.request
import urllib.parse
import urllib.error


class ProxmoxAPI:
    """Lightweight Proxmox REST API client — no external dependencies."""

    def __init__(self, api_url, api_token, verify_ssl=False, timeout=30):
        self.base = api_url.rstrip("/") + "/api2/json"
        self.token = api_token
        self.timeout = timeout
        self.ctx = ssl.create_default_context()
        if not verify_ssl:
            self.ctx.check_hostname = False
            self.ctx.verify_mode = ssl.CERT_NONE

    # -- HTTP primitives ------------------------------------------------

    def _request(self, method, path, data=None):
        url = self.base + path
        headers = {"Authorization": f"PVEAPIToken={self.token}"}
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            resp = urllib.request.urlopen(req, timeout=self.timeout, context=self.ctx)
            return json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode() if exc.fp else str(exc)
            raise RuntimeError(f"HTTP {exc.code} on {method} {path}: {detail}") from exc

    def get(self, path):
        return self._request("GET", path).get("data")

    def post(self, path, **kwargs):
        return self._request("POST", path, data=kwargs).get("data")

    def put(self, path, **kwargs):
        return self._request("PUT", path, data=kwargs).get("data")

    def delete(self, path):
        return self._request("DELETE", path).get("data")

    # -- Task polling ---------------------------------------------------

    def wait_task(self, node, upid, timeout=120, interval=3):
        elapsed = 0
        while elapsed < timeout:
            status = self.get(f"/nodes/{node}/tasks/{upid}/status")
            if status.get("status") == "stopped":
                if status.get("exitstatus") == "OK":
                    return True
                raise RuntimeError(f"Task failed: {status.get('exitstatus')}")
            time.sleep(interval)
            elapsed += interval
        raise RuntimeError(f"Task timed out after {timeout}s")

    def post_task(self, node, path, timeout=120, **kwargs):
        upid = self.post(path, **kwargs)
        if upid:
            self.wait_task(node, upid, timeout=timeout)
        return upid

    # -- Convenience ----------------------------------------------------

    def next_vmid(self):
        return int(self.get("/cluster/nextid"))

    def guest_type(self, node, vmid):
        """Return 'lxc' or 'qemu' for a given VMID."""
        try:
            self.get(f"/nodes/{node}/lxc/{vmid}/status/current")
            return "lxc"
        except RuntimeError:
            pass
        try:
            self.get(f"/nodes/{node}/qemu/{vmid}/status/current")
            return "qemu"
        except RuntimeError:
            pass
        return None
