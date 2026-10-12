import unittest,math,sys,pathlib
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]))
from timeline import retained_ranges,retime_events,auto_scenes,camera_frames,expression,validate_scenes
class TimelineTests(unittest.TestCase):
 def test_overlapping_cuts_and_preview(self):
  self.assertEqual(retained_ranges(1,10,[{'start':2,'end':4},{'start':3,'end':5},{'start':8,'end':20}]),[[1,2.0],[5.0,8.0]])
  self.assertEqual(retained_ranges(1,10,[{'start':2,'end':5}],2,2),[[1,2.0],[5.0,8.0]])
  with self.assertRaises(ValueError):retained_ranges(0,10,[{'start':0,'end':10}])
 def test_deleted_clicks_and_boundary_seed(self):
  events=[{'t':i,'x':i/10,'y':.5,'click':i in [1,3,6]} for i in range(8)]
  result=retime_events(events,[[0,2],[5,8]],2)
  self.assertEqual([e['t'] for e in result if e['click']],[.5,1.5])
  seeds=[e for e in result if not e['click'] and e['t']==1]
  self.assertTrue(seeds)
  self.assertTrue(all(e['x']!=.3 for e in result))
 def test_merge_nearby_clicks_and_separate_distant(self):
  events=[{'t':t,'x':x,'y':.5,'click':True} for t,x in [(1,.4),(1.5,.45),(2,.9)]]
  scenes=auto_scenes(events,5)
  self.assertEqual(len(scenes),2)
  self.assertLessEqual(scenes[0]['end'],scenes[1]['start'])
  self.assertAlmostEqual(scenes[0]['x'],.425)
 def test_easing_and_projection(self):
  scenes=[{'start':1,'end':3,'x':.8,'y':.2,'factor':2}]
  frames=camera_frames(scenes,[[0,4]],1,60,4)
  self.assertEqual(frames[0],(1,0,0))
  self.assertEqual(frames[60],(1,0,0))
  self.assertAlmostEqual(frames[120][0],2)
  self.assertEqual(frames[180],(1,0,0))
  self.assertLess(max(abs(a[0]-b[0]) for a,b in zip(frames,frames[1:])),.06)
  for z,x,y in frames:
   self.assertGreaterEqual(x,0);self.assertLessEqual(x,1-1/z+1e-9)
   self.assertGreaterEqual(y,0);self.assertLessEqual(y,1-1/z+1e-9)
  clipped=camera_frames(scenes,[[0,1],[3,4]],1,60,2)
  self.assertTrue(all(f[0]==1 for f in clipped))
 def test_long_flat_expression_and_validation(self):
  self.assertEqual(expression([1.]*100000),'(1.000000+(0.000000)*clip((on-0)/99999,0,1))')
  with self.assertRaises(ValueError):validate_scenes([{'start':1,'end':3,'x':.5,'y':.5,'factor':2},{'start':2,'end':4,'x':.5,'y':.5,'factor':2}],5)
if __name__=='__main__':unittest.main()
