"""Offline contract tests for reviewed, manual Harbor storage rollout."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'clusters/oci-lab/apps/harbor-storage'
CLAIMS = {
    'redis': ('data-oci-lab-harbor-redis-0', '5dce0d11-96f3-48da-8d24-7876e526efc7'),
    'database': ('database-data-oci-lab-harbor-database-0', '2789d037-4bb8-4946-88e4-d9977e68354c'),
    'jobservice': ('oci-lab-harbor-jobservice', 'd6158369-a237-4d72-b520-958d57811be2'),
}


class HarborStorage(unittest.TestCase):
    def test_pvs(self):
        docs = list(yaml.safe_load_all((BASE / 'manifests/persistent-volumes.yaml').read_text()))
        self.assertEqual(len(docs), 3)
        self.assertEqual({p['metadata']['name'] for p in docs}, {'oci-lab-harbor-' + n for n in CLAIMS})
        for p in docs:
            self.assertEqual(p['kind'], 'PersistentVolume')
            n = p['metadata']['name'].removeprefix('oci-lab-harbor-')
            name, uid = CLAIMS[n]
            s = p['spec']
            self.assertEqual(s['claimRef'], dict(apiVersion='v1', kind='PersistentVolumeClaim', namespace='harbor', name=name, uid=uid))
            self.assertEqual(s['storageClassName'], '')
            self.assertEqual(s['capacity'], {'storage': '1Gi'})
            self.assertEqual(s['accessModes'], ['ReadWriteOnce'])
            self.assertEqual(s['volumeMode'], 'Filesystem')
            self.assertEqual(s['persistentVolumeReclaimPolicy'], 'Retain')
            self.assertEqual(s['local'], {'path': '/var/mnt/harbor-' + n})
            self.assertNotIn('hostPath', s)
            self.assertEqual(s['nodeAffinity']['required']['nodeSelectorTerms'], [{'matchExpressions': [{'key': 'kubernetes.io/hostname', 'operator': 'In', 'values': ['ampere-vnic-1']}]}])
            self.assertEqual(p['metadata']['annotations']['argocd.argoproj.io/sync-options'], 'Prune=false,Delete=false')

    def test_directory_owner(self):
        d = ROOT / 'omni/cluster-templates'
        volumes = list(yaml.safe_load_all((d / 'patches/harbor-storage.yaml').read_text()))
        self.assertEqual(len(volumes), 3)
        self.assertEqual({v['name'] for v in volumes}, {'harbor-' + n for n in CLAIMS})
        for v in volumes:
            self.assertEqual(v, dict(apiVersion='v1alpha1', kind='UserVolumeConfig', name=v['name'], volumeType='directory'))
        template = list(yaml.safe_load_all((d / 'oci-lab.yaml').read_text()))
        for doc in template:
            refs = [p.get('file') for p in doc.get('patches', [])]
            self.assertEqual('patches/harbor-storage.yaml' in refs, doc['kind'] == 'ControlPlane')

    def test_manual_rollout(self):
        app = yaml.safe_load((BASE / 'application.yaml').read_text())
        self.assertEqual(app['spec']['syncPolicy']['automated'], dict(enabled=False, prune=False, selfHeal=False))
        self.assertEqual(app['spec']['destination'], dict(server='https://kubernetes.default.svc', namespace='harbor'))
        self.assertEqual(app['spec']['source']['path'], str(BASE.relative_to(ROOT) / 'manifests'))


if __name__ == '__main__':
    unittest.main()
