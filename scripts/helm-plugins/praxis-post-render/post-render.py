#!/usr/bin/env python3
import sys

import yaml

for resource in yaml.safe_load_all(sys.stdin):
    if resource is None:
        continue
    if (
        resource.get("kind") == "Deployment"
        and resource["metadata"].get("labels", {}).get("app.kubernetes.io/name") == "praxis-gateway"
    ):
        spec = resource["spec"]["template"]["spec"]
        spec.setdefault("volumes", []).append({"name": "state", "emptyDir": {}})
        container = next(c for c in spec["containers"] if c["name"] == "praxis")
        container.setdefault("volumeMounts", []).append(
            {"name": "state", "mountPath": "/var/lib/praxis"}
        )
    yaml.safe_dump(resource, sys.stdout, explicit_start=True, sort_keys=False)
