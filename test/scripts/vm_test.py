"""Boundary checks for the host-side VM gate; no real daemon mutations."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('nano_vm', str(Path(__file__).resolve().parents[2] / 'bin/vm'))
spec = importlib.util.spec_from_loader(loader.name, loader)
vm = importlib.util.module_from_spec(spec)
loader.exec_module(vm)

class GateTest(unittest.TestCase):
    def config(self):
        return {'status':'Running', 'vmType':'vz', 'config': {
            'mounts':[{'location':str(vm.MOUNTS), 'writable':True}],
            'ssh':{'forwardAgent':False},
            'networks':[{'lima':'user-v2'}],
            'portForwards':[{'guestIP':'0.0.0.0','proto':'any','ignore':True}]}}

    def check(self, config):
        import json
        status = {'runtime':'docker','docker_socket':'unix://' + str(vm.HOME / 'nano/docker.sock')}
        with patch.object(vm, 'run', side_effect=[json.dumps(status), json.dumps(config)]), patch.object(vm.platform, 'system', return_value='Darwin'):
            return vm.inspect_vm()

    def test_scoped_profile(self):
        self.check(self.config())

    def test_shared_home_rejected(self):
        c = self.config(); c['config']['mounts'][0]['location'] = str(Path.home())
        with self.assertRaises(RuntimeError): self.check(c)

    def test_extra_mount_rejected(self):
        c = self.config(); c['config']['mounts'].append({'location':'/tmp','writable':True})
        with self.assertRaises(RuntimeError): self.check(c)

    def test_automatic_ports_rejected(self):
        c = self.config(); c['config']['portForwards'].append({'guestPort':4000,'hostIP':'0.0.0.0'})
        with self.assertRaises(RuntimeError): self.check(c)

    def test_agent_forwarding_rejected(self):
        c = self.config(); c['config']['ssh']['forwardAgent'] = True
        with self.assertRaises(RuntimeError): self.check(c)

    def test_bridged_network_rejected(self):
        c = self.config(); c['config']['networks'] = [{'socket':'/tmp/vmnet.sock'}]
        with self.assertRaises(RuntimeError): self.check(c)

if __name__ == '__main__': unittest.main()
