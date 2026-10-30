"""No listener: pure fictional server-state/route tests for the product fixture."""
import copy
import importlib.util
from pathlib import Path
import sys
import threading
import time
from types import SimpleNamespace
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'apple/qa'))
import watched_contract as watched


class Handler:
    def __init__(self, path='/Items', user='library-tv-watched-test', base='', owner=True, body=None):
        self.path=path;self.base_path=base;self.server=SimpleNamespace(server_port=18970)
        self.name=user;self.authorized=owner;self.body=body;self.output=None;self.status=None
    def user(self):return self.name
    def owns(self):return self.authorized
    def read_body(self):return self.body
    def respond(self,value=None,status=200):self.output=copy.deepcopy(value);self.status=status


class WatchedContractTests(unittest.TestCase):
    def setUp(self):watched.STATES.clear();watched.HOLDS.clear()
    def testUnauthenticatedParityIdentityDoesNotExposeStateOrMutationControls(self):
        spec=importlib.util.spec_from_file_location('parity_identity_test',Path(__file__).with_name('run-library-fixture.py'))
        parity=importlib.util.module_from_spec(spec);spec.loader.exec_module(parity)
        parity.OWNER='owned-parity-identity-regression'
        for path,method,status in [('/qa/parity-identity','GET',200),('/qa/parity-state','GET',403),('/qa/watched-control','POST',403)]:
            handler=object.__new__(parity.ParityHandler)
            handler.path=path;handler.headers={};handler.server=SimpleNamespace(server_port=18970)
            handler.user=lambda:None
            responses=[]
            handler.respond=lambda value=None,status=200:responses.append((status,value))
            getattr(handler,'do_'+method)()
            self.assertEqual(responses[0][0],status)
            if status==200:
                self.assertEqual(responses[0][1]['kind'],'reel-tv-library-parity')
                self.assertEqual(responses[0][1]['owner'],parity.OWNER)
                self.assertEqual(responses[0][1]['port'],18970)
            else:self.assertIsNone(responses[0][1])
        self.assertEqual(watched.STATES,{})
    def call(self,path,method='GET',**kwargs):
        handler=Handler(path,**kwargs);self.assertTrue(watched.handle(handler,method,path.split('?')[0]));return handler
    def testServerCountsUseCompleteDescendantsAndZeroDoesNotInventPlayed(self):
        h=Handler();_,rows,_,_=watched.rows(h)
        self.assertEqual(rows['library-title-003']['UserData']['UnplayedItemCount'],2)
        self.assertEqual(rows['library-title-012']['UserData']['UnplayedItemCount'],0)
        self.assertFalse(rows['library-title-012']['UserData']['Played'])
        changed=self.call('/UserPlayedItems/library-title-003?userId=library-tv-watched-test','POST')
        self.assertEqual(changed.status,200);self.assertEqual(changed.output['UnplayedItemCount'],0)
        record=watched.state(h)['requests'][0]
        self.assertEqual(record['descendants'],['library-episode-01','library-episode-02','library-episode-03','library-episode-04'])
        self.assertEqual(self.call('/Items/library-title-006').output['UserData']['UnplayedItemCount'],2)
    def testSeasonAndPlaylistServerScopeDeduplicatesOnlyUnderlyingLeaves(self):
        self.call('/UserPlayedItems/library-season-003-1','DELETE')
        self.assertEqual(self.call('/Items/library-title-003').output['UserData']['UnplayedItemCount'],3)
        self.call('/UserPlayedItems/library-playlist-1','POST')
        receipt=watched.state(Handler())['requests'][-1]
        self.assertEqual(len(receipt['descendants']),len(set(receipt['descendants'])))
        entries=self.call('/Playlists/library-playlist-1/Items?limit=60').output['Items']
        self.assertEqual(len(entries),8);self.assertEqual(entries[0]['Id'],entries[2]['Id']);self.assertNotEqual(entries[0]['PlaylistItemId'],entries[2]['PlaylistItemId'])
    def testUnknownCountModesPreserveOtherUserDataAndNeverAffectLeaf(self):
        for mode,expected in [('missing',None),('invalid','unknown'),('negative',-1),('overflow',10**40),('zero',0),('large',123456789)]:
            self.call('/qa/watched-control','POST',body={'countMode':mode})
            value=self.call('/Items/library-title-003').output['UserData']
            self.assertEqual(value.get('UnplayedItemCount'),expected);self.assertIn('Played',value)
            self.assertNotIn('UnplayedItemCount',self.call('/Items/library-episode-01').output['UserData'])
    def testBeforeFailureWritesNothingAndAfterFailureRecordsPossibleCommit(self):
        for mode,status,committed in [('before403',403,False),('before404',404,False),('before503',503,False),('after503',503,True),('afterMalformed',200,True)]:
            self.call('/qa/watched-control','POST',body={'reset':True,'failID':'library-title-003','failure':mode,'failures':1})
            result=self.call('/UserPlayedItems/library-title-003','POST');self.assertEqual(result.status,status)
            state=watched.state(Handler());self.assertEqual(state['requests'][0]['committed'],committed)
            self.assertEqual(len(state['played']),4 if committed else 0)
    def testOwnerAndUserBasepathScopesCannotMutateOrInspectOtherState(self):
        self.assertEqual(self.call('/qa/watched-state',owner=False).status,403)
        self.assertEqual(self.call('/qa/watched-control','POST',owner=False,body={'reset':True}).status,403)
        self.assertEqual(self.call('/UserPlayedItems/library-title-003?userId=foreign','POST').status,403)
        self.assertEqual(watched.state(Handler())['played'],{})
        self.call('/UserPlayedItems/library-title-003','POST',base='/alternate')
        self.assertEqual(self.call('/Items/library-title-003').output['UserData']['UnplayedItemCount'],2)
        self.assertEqual(self.call('/Items/library-title-003',base='/alternate').output['UserData']['UnplayedItemCount'],0)
    def testTypedControlsRejectUnknownTargetsModesBooleansAndUnboundedDelay(self):
        for body in [{'arbitraryPath':'/tmp'}, {'failID':'foreign'}, {'delayMS':True}, {'delayMS':3001}, {'failures':6}, {'failure':'anything'}, {'episodeOnly':1}, {'reset':False}]:
            self.assertEqual(self.call('/qa/watched-control','POST',body=body).status,400)
    def testHeldWriteRequiresExplicitReleaseAndDeniedReadsDoNotReplayIt(self):
        self.call('/qa/watched-control','POST',body={'holdID':'library-episode-01'})
        handler=Handler('/UserPlayedItems/library-episode-01')
        thread=threading.Thread(target=watched.handle,args=(handler,'POST','/UserPlayedItems/library-episode-01'));thread.start()
        try:
            for _ in range(100):
                if watched.state(Handler())['requests']:break
                time.sleep(.001)
            self.assertTrue(thread.is_alive());self.assertFalse(watched.state(Handler())['requests'][0]['committed'])
            self.call('/qa/watched-control','POST',body={'releaseWrites':True,'denyReads':True})
            thread.join(timeout=1);self.assertFalse(thread.is_alive());self.assertEqual(handler.status,200)
            self.assertEqual(self.call('/Items/library-episode-01').status,503)
            self.call('/qa/watched-control','POST',body={'denyReads':False})
            self.assertTrue(self.call('/Items/library-episode-01').output['UserData']['Played'])
            self.assertEqual(len(watched.state(Handler())['requests']),1)
        finally:
            watched.HOLDS[watched.key(handler)].set();thread.join(timeout=1)
    def testDetailTypeCasesKeepPageLeafSeparateAndMediaChoicesAreOriginalFixtureData(self):
        for kind in ['missing','PluginFolder','MusicAlbum','MusicArtist','PhotoAlbum']:
            self.call('/qa/watched-control','POST',body={'detailID':'library-episode-02','detailType':kind})
            value=self.call('/Items/library-episode-02').output
            self.assertEqual(value.get('Type'),None if kind=='missing' else kind)
            self.assertTrue(value['UserData']['Played'])
        self.call('/qa/watched-control','POST',body={'reset':True})
        value=self.call('/Items/library-title-002').output
        self.assertEqual(len(value['MediaSources']),2)
        self.assertEqual(value['MediaSources'][1]['Name'],'Owned alternate')
        self.assertEqual(value['MediaSources'][1]['MediaStreams'][2]['DisplayTitle'],'Spanish owned AAC')

    def testEpochResetFencesDelayedOldCommitWithoutOpeningAnySocket(self):
        self.call('/qa/watched-control','POST',body={'delayID':'library-title-003','delayMS':150})
        handler=Handler('/UserPlayedItems/library-title-003')
        thread=threading.Thread(target=watched.handle,args=(handler,'POST','/UserPlayedItems/library-title-003'));thread.start()
        for _ in range(100):
            if watched.state(Handler())['requests']:break
            time.sleep(.001)
        self.call('/qa/watched-control','POST',body={'reset':True})
        thread.join(timeout=1);self.assertFalse(thread.is_alive());self.assertEqual(handler.status,409)
        self.assertEqual(watched.state(Handler())['played'],{})


if __name__=='__main__':unittest.main()
