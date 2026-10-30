"""Pure source policy checks. No SDK, archive, server, browser or device runs."""
from pathlib import Path
import sys
import unittest
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import wgt

class SourcePolicyTests(unittest.TestCase):
    def test_expected_identity_and_privileges(self):
        value=wgt.validate_config((ROOT/'src/config.xml').read_bytes())
        self.assertEqual(value['appId'],'ReelClient.Reel')
        self.assertEqual(value['packageId'],'ReelClient')
    def test_expanded_privilege_rejected(self):
        data=(ROOT/'src/config.xml').read_bytes().replace(b'tv.inputdevice',b'filesystem.read')
        with self.assertRaises(ValueError):wgt.validate_config(data)
    def test_remote_script_policy_rejected(self):
        data=(ROOT/'src/config.xml').read_bytes().replace(b"script-src 'self'",b"script-src 'self' https://untrusted.invalid")
        with self.assertRaises(ValueError):wgt.validate_config(data)
    def test_runtime_identity_is_fixed_data(self):
        data=(ROOT/'src/reel-config.js').read_bytes();wgt.validate_runtime_config(data)
        for value in [data+b'window.extra=true;',data.replace(b"platform: 'tizen'",b"platform: 'webos'")]:
            with self.assertRaises(ValueError):wgt.validate_runtime_config(value)
if __name__=='__main__':unittest.main(verbosity=2)
