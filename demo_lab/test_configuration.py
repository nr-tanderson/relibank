from pathlib import Path
import unittest

import yaml


class MonitoringDefaults(unittest.TestCase):
    def test_credentials_are_optional_and_agent_requires_opt_in(self):
        manifests = list(yaml.safe_load_all(Path("demo_lab/k8s.yaml").read_text()))
        deployments = [item for item in manifests if item["kind"] == "Deployment"]
        self.assertEqual(len(deployments), 2)
        for deployment in deployments:
            container = deployment["spec"]["template"]["spec"]["containers"][0]
            environment = {item["name"]: item for item in container["env"]}
            self.assertEqual(environment["NEW_RELIC_ENABLED"]["value"], "${MONITORING_ENABLED}")
            self.assertTrue(environment["NEW_RELIC_LICENSE_KEY"]["valueFrom"]["secretKeyRef"]["optional"])
            self.assertIn('if [ "$NEW_RELIC_ENABLED" = true ]', container["args"][0])

    def test_failure_schedules_start_paused(self):
        manifests = list(yaml.safe_load_all(Path("demo_lab/k8s.yaml").read_text()))
        schedules = [item for item in manifests if item["kind"] == "CronJob"]
        self.assertEqual(len(schedules), 2)
        self.assertTrue(all(item["spec"]["suspend"] for item in schedules))