"""Disposable process/source fixtures only; never contact the shared node."""
import unittest, tempfile, pathlib, importlib.machinery, importlib.util, os, json, sys, time
loader = importlib.machinery.SourceFileLoader('watchdog',str(pathlib.Path(__file__).parents[1]/'bin/seed-watchdog'))
spec = importlib.util.spec_from_loader(loader.name,loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
class SafetyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rigel-safety-test-')
        self.base = pathlib.Path(self.tmp.name); self.app = self.base/'app'; self.app.mkdir()
        (self.app/'source').write_text('good')
        self.settings = self.base/'settings.json'; mod.atomic(self.settings,{'key':'secret','other':42})
        self.w = mod.Watchdog(dict(app=str(self.app),state=str(self.base/'state'),command=[sys.executable,'-c','import time; time.sleep(30)'],probe=[sys.executable,'-c','pass'],credentials=[dict(path=str(self.settings),keys=['key'])],backoff=0,stop_timeout=.1,max_attempts=2))
    def tearDown(self): self.w.stop(); self.tmp.cleanup()
    def certify(self):
        self.w.start(); mod.atomic(self.w.state/'attestation.json',{'boot':self.w.token}); self.w.certify()
    def test_rollback_preserves_uncommitted_and_untracked(self):
        self.certify(); (self.app/'source').write_text('broken'); (self.app/'new').write_text('work')
        self.w.stop(); self.assertTrue(self.w.rollback())
        self.assertEqual((self.app/'source').read_text(),'good')
        evidence = next(self.w.state.glob('source-evidence-*'))
        self.assertEqual((evidence/'new').read_text(),'work'); self.assertEqual((evidence/'source').read_text(),'broken')
    def test_stale_attestation_and_late_edits(self):
        self.w.start(); mod.atomic(self.w.state/'attestation.json',{'boot':'old'}); self.w.certify()
        self.assertFalse((self.w.state/'good').exists())
        (self.app/'source').write_text('later')
        mod.atomic(self.w.state/'attestation.json',{'boot':self.w.token}); self.w.certify()
        self.assertFalse((self.w.state/'good').exists())
    def test_credentials_missing_invalid_rejected_and_newer_valid(self):
        self.certify(); mod.atomic(self.settings,{'key':'new','other':99}); self.assertFalse(self.w.credentials())
        mod.atomic(self.w.state/'rejected.json',{str(self.settings):{'key':mod.fingerprint('secret')}})
        self.assertFalse(self.w.credentials())
        mod.atomic(self.w.state/'rejected.json',{str(self.settings):{'key':mod.fingerprint('new')}})
        self.assertTrue(self.w.credentials()); self.assertEqual(mod.read(self.settings)['other'],99)
        self.settings.write_text('broken json'); self.assertTrue(self.w.credentials())
        self.assertEqual(mod.read(self.settings)['key'],'secret')
        self.assertEqual(self.settings.stat().st_mode & 0o777,0o600)
        self.assertNotIn('secret',(self.w.state/'events.jsonl').read_text())
    def test_real_dead_process_restart_budget_persists(self):
        self.certify(); self.w.child.kill(); self.w.child.wait()
        self.assertTrue(self.w.recover('exit')); self.assertIsNone(self.w.child.poll())
        self.assertTrue(self.w.recover('exit')); self.assertFalse(self.w.recover('exit'))
        replacement = mod.Watchdog(self.w.c); self.assertEqual(replacement.attempts,2)
        self.assertTrue((self.w.state/'exhausted').exists())
    def test_unbootable_source_recovers_from_good(self):
        script = self.app/'boot.py'
        script.write_text('import time; time.sleep(30)')
        self.w.c['command']=[sys.executable,str(script)]
        self.certify(); self.w.stop(); script.write_text('not valid python !!!')
        self.w.start(); self.w.child.wait(timeout=2)
        self.assertTrue(self.w.recover('exit')); self.w.child.wait(timeout=2)
        self.assertTrue(self.w.recover('exit'))
        time.sleep(.05); self.assertIsNone(self.w.child.poll())
        self.assertIn('time.sleep',script.read_text())
    def test_real_hung_probe_is_bounded(self):
        self.w.c['probe']=[sys.executable,'-c','import time; time.sleep(20)']; self.w.c['timeout']=.05
        start=time.monotonic(); self.assertFalse(self.w.probe()); self.assertLess(time.monotonic()-start,1)
    def test_disabled_does_not_kill_child(self):
        self.w.start(); (self.w.state/'disabled').touch(); self.assertFalse(self.w.recover('test'))
        self.assertIsNone(self.w.child.poll()); self.assertEqual(self.w.attempts,0)
    def test_state_inside_source_refused(self):
        with self.assertRaises(ValueError): mod.Watchdog(dict(self.w.c,state=str(self.app/'state')))
if __name__ == '__main__': unittest.main()
