"""Real disposable BEAM integration. No access to nano node, credentials or /data.
Run: PYTHONDONTWRITEBYTECODE=1 python3 test/seed_safety_beam_test.py
Uses tiny independent BEAM fixture; model-success attestation is simulated, not
an authenticated provider test. Source compile, RPC stall and OS death are real.
"""
import unittest, tempfile, pathlib, importlib.machinery, importlib.util, os, sys, time, signal, uuid, subprocess
loader=importlib.machinery.SourceFileLoader('watchdog',str(pathlib.Path(__file__).parents[1]/'bin/seed-watchdog'))
spec=importlib.util.spec_from_loader(loader.name,loader); mod=importlib.util.module_from_spec(spec); loader.exec_module(mod)
class BeamTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='rigel-safety-beam-'); base=pathlib.Path(self.tmp.name)
        self.app=base/'app'; self.app.mkdir(); self.name='safety'+uuid.uuid4().hex
        host=subprocess.check_output(['hostname','-s'],text=True).strip()
        target=self.name+'@'+host
        self.boot=self.app/'boot.exs'
        self.boot.write_text('File.write!(Path.join(System.fetch_env!("SEED_SAFETY_DIR"), "attestation.json"), "{\\\"boot\\\":\\\"#{System.fetch_env!("SEED_SAFETY_BOOT")}\\\"}")\nProcess.sleep(:infinity)\n'.replace('\\\"','\\"'))
        probe=['elixir','--erl','+S 1:1 +A 1','--sname','probe'+uuid.uuid4().hex,'--cookie','fixture-only','-e',':net_kernel.connect_node(:"'+target+'"); r = :rpc.call(:"'+target+'", :erlang, :system_info, [:otp_release], 500); System.halt(if is_list(r), do: 0, else: 1)']
        self.w=mod.Watchdog(dict(app=str(self.app),state=str(base/'state'),command=['elixir','--erl','+S 1:1 +A 1','--sname',self.name,'--cookie','fixture-only',str(self.boot)],probe=probe,timeout=8,stop_timeout=.2,backoff=0,max_attempts=3))
    def tearDown(self): self.w.stop(); self.tmp.cleanup()
    def ready(self):
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            if self.w.child.poll() is not None: self.fail('fixture exited during boot')
            if self.w.probe() and mod.read(self.w.state/'attestation.json',{}).get('boot') == self.w.token: self.w.certify(); return
            time.sleep(.1)
        self.fail('fixture never responded')
    def test_real_beam_dead_hung_and_unbootable_source(self):
        self.w.start(); self.ready(); self.assertTrue((self.w.state/'good').exists())
        self.w.child.kill(); self.w.child.wait(timeout=5)
        self.assertTrue(self.w.recover('exit')); self.ready()
        os.kill(self.w.child.pid,signal.SIGSTOP)
        self.assertFalse(self.w.probe())
        self.assertTrue(self.w.recover('unresponsive')); self.ready()
        self.w.stop(); self.boot.write_text('this is not valid Elixir ???')
        self.w.start(); self.w.child.wait(timeout=15)
        self.assertNotEqual(self.w.child.returncode,0)
        self.assertTrue(self.w.recover('exit')); self.ready()
        evidence=list(self.w.state.glob('source-evidence-*'))
        self.assertTrue(any('not valid' in (p/'boot.exs').read_text() for p in evidence))
    def test_monitor_only_never_launches_or_recovers(self):
        self.w.c['monitor_only']=True
        self.w.c['probe']=['sh','-c','exit 1']; self.w.c['interval']=.05
        config=self.w.state/'config.json'; mod.atomic(config,self.w.c)
        monitor=subprocess.Popen([sys.executable,str(pathlib.Path(__file__).parents[1]/'bin/seed-watchdog'),str(config)],stdout=subprocess.DEVNULL)
        try:
            deadline=time.monotonic()+3
            while time.monotonic()<deadline and mod.read(self.w.state/'status.json',{}).get('event')!='monitor_failure': time.sleep(.02)
            status=mod.read(self.w.state/'status.json',{})
            self.assertEqual(status['event'],'monitor_failure'); self.assertFalse(status['protected'])
            self.assertFalse(list(self.w.state.glob('launch-*')))
        finally: monitor.terminate(); monitor.wait(timeout=5)
if __name__=='__main__': unittest.main()
