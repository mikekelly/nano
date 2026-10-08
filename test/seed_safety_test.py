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
        self.w = mod.Watchdog(dict(app=str(self.app),state=str(self.base/'state'),command=[sys.executable,'-c','import time; time.sleep(30)'],probe=[sys.executable,'-c','pass'],credentials=[dict(path=str(self.settings),keys=['key'],provider='fixture')],backoff=0,stop_timeout=.1,max_attempts=2))
    def tearDown(self): self.w.stop(); self.tmp.cleanup()
    def certify(self):
        self.w.start(); mod.atomic(self.w.state/'attestation.json',{'boot':self.w.token,'providers':['fixture']}); self.w.certify()
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
        mod.atomic(self.w.state/'attestation.json',{'boot':self.w.token,'providers':['fixture']}); self.w.certify()
        self.assertFalse((self.w.state/'good').exists())
    def test_source_attestation_does_not_backup_unverified_provider(self):
        self.w.start(); mod.atomic(self.w.state/'attestation.json',{'boot':self.w.token})
        self.w.certify(); self.assertEqual(mod.read(self.w.state/'credentials.json'),[])
        mod.atomic(self.w.state/'attestation.json',{'boot':self.w.token,'providers':['unrelated']})
        self.w.certify(); self.assertEqual(mod.read(self.w.state/'credentials.json'),[])
        mod.atomic(self.w.state/'attestation.json',{'boot':self.w.token,'providers':['fixture']})
        self.w.certify(); self.assertEqual(mod.read(self.w.state/'credentials.json')[0]['values']['key'],'secret')
    def test_credentials_missing_invalid_rejected_and_newer_valid(self):
        self.certify(); mod.atomic(self.settings,{'key':'new','other':99}); self.assertFalse(self.w.credentials())
        mod.atomic(self.w.state/'rejected.json',{str(self.settings):{'key':mod.fingerprint('secret')}})
        self.assertFalse(self.w.credentials())
        mod.atomic(self.w.state/'rejected.json',{str(self.settings):{'key':mod.fingerprint('new')}})
        self.assertTrue(self.w.credentials()); self.assertEqual(mod.read(self.settings)['other'],99)
        self.settings.write_text('broken json'); self.assertTrue(self.w.credentials(apply=False))
        self.assertEqual(self.settings.read_text(),'broken json'); self.assertTrue(self.w.credentials())
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
    def chatgpt_setup(self):
        self.w.c['credentials']=[dict(path=str(self.settings),provider='chatgpt',kind='chatgpt')]
        self.tokens=dict(access_token='synthetic-access-1',refresh_token='synthetic-refresh-1',id_token='synthetic-id',account_id='synthetic-account',expires_at=2000000000,plan='plus',email='fixture@example.invalid')
        mod.atomic(self.settings,self.tokens); self.w.start()
        mod.atomic(self.w.state/'attestation.json',dict(boot=self.w.token,providers=['chatgpt']))
        self.w.certify()
    def test_chatgpt_complete_missing_malformed_partial_and_expiry(self):
        self.chatgpt_setup()
        self.assertEqual(mod.read(self.w.state/'credentials.json')[0]['values'],self.tokens)
        for corrupt in (None,'{malformed',dict(access_token=self.tokens['access_token']),dict(self.tokens,expires_at='broken'),dict(self.tokens,expires_at=True)):
            if corrupt is None: self.settings.unlink()
            elif isinstance(corrupt,str): self.settings.write_text(corrupt)
            else: mod.atomic(self.settings,corrupt)
            self.assertTrue(self.w.credentials()); self.assertEqual(mod.read(self.settings),self.tokens)
        self.assertEqual(self.settings.stat().st_mode & 0o777,0o600)
        self.assertNotIn('synthetic-access',(self.w.state/'events.jsonl').read_text())
    def test_chatgpt_rotation_exact_pair_rejection_and_backup_refresh(self):
        self.chatgpt_setup()
        rotated=dict(self.tokens,access_token='synthetic-access-2',refresh_token='synthetic-refresh-2',expires_at=2100000000)
        mod.atomic(self.settings,rotated); self.assertFalse(self.w.credentials())
        mod.atomic(self.w.state/'rejected.json',{str(self.settings):{'@chatgpt':mod.chatgpt_fingerprint(self.tokens)}})
        self.assertFalse(self.w.credentials())
        mod.atomic(self.w.state/'rejected.json',{str(self.settings):{'@chatgpt':mod.chatgpt_fingerprint(rotated)}})
        self.assertTrue(self.w.credentials()); self.assertEqual(mod.read(self.settings),self.tokens)
        mod.atomic(self.settings,rotated)
        mod.atomic(self.w.state/'attestation.json',dict(boot=self.w.token,providers=['chatgpt'],time=2))
        self.w.certify(); self.assertEqual(mod.read(self.w.state/'credentials.json')[0]['values'],rotated)
        self.settings.unlink(); self.assertTrue(self.w.credentials()); self.assertEqual(mod.read(self.settings),rotated)
    def test_chatgpt_partial_newer_generation_is_never_mixed(self):
        self.chatgpt_setup()
        partial={'refresh_token':'rotated-refresh-only','extra':'preserve'}
        mod.atomic(self.settings,partial); self.assertFalse(self.w.credentials())
        self.assertEqual(mod.read(self.settings),partial)
        self.assertIn('manual_intervention',(self.w.state/'events.jsonl').read_text())
    def test_chatgpt_invalid_schema_does_not_replace_verified_backup(self):
        self.chatgpt_setup()
        for index,invalid in enumerate((dict(self.tokens,expires_at=-1),dict(self.tokens,account_id=None),dict(self.tokens,refresh_token=42))):
            mod.atomic(self.settings,invalid)
            mod.atomic(self.w.state/'attestation.json',dict(boot=self.w.token,providers=['chatgpt'],time=index))
            self.w.certify()
            self.assertEqual(mod.read(self.w.state/'credentials.json')[0]['values'],self.tokens)
    def test_state_inside_source_refused(self):
        with self.assertRaises(ValueError): mod.Watchdog(dict(self.w.c,state=str(self.app/'state')))
if __name__ == '__main__': unittest.main()
