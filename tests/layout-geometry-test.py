#!/usr/bin/env python3
"""Geometry compatibility: target the right divider and never recreate panes."""
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
spec = importlib.util.spec_from_file_location('layout_helper', Path(sys.path[0])/'layout-helper.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Geometry(unittest.TestCase):
    def setUp(self):
        helper.ABSOLUTE_RATIO_SUPPORTED = True
        self.tree = {'type':'split','direction':'right','ratio':.5,
                     'first':{'type':'pane','pane_id':'work'},
                     'second':{'type':'split','direction':'right','ratio':.5,
                               'first':{'type':'pane','pane_id':'git'},
                               'second':{'type':'pane','pane_id':'settings'}}}
        self.rects = {'work':{'x':0,'width':100},'git':{'x':100,'width':50},
                      'settings':{'x':150,'width':50}}
        self.calls = []

    def legacy_rpc(self, method, params):
        self.calls.append((method, params))
        if method == 'layout.set_split_ratio':
            raise helper.RpcError(method, {'code':'invalid_request',
                'message':'invalid request: unknown variant `layout.set_split_ratio`'})
        self.assertEqual(method, 'pane.resize')
        return {'resize':{'changed':True}}

    def test_legacy_grow_region_uses_left_edge_of_right_subtree(self):
        with patch.object(helper, 'rpc', self.legacy_rpc):
            width = helper.set_subtree_width('git', self.tree, self.rects, (True,), 150)
        self.assertAlmostEqual(width, 150)
        self.assertEqual(self.calls[-1], ('pane.resize', {'pane_id':'git','direction':'left','amount':.25}))

    def test_legacy_shrink_region_uses_workspace_boundary(self):
        with patch.object(helper, 'rpc', self.legacy_rpc):
            width = helper.set_subtree_width('git', self.tree, self.rects, (True,), 60)
        self.assertAlmostEqual(width,60)
        method, params = self.calls[-1]
        self.assertEqual((method, params['pane_id'], params['direction']), ('pane.resize','work','right'))
        self.assertAlmostEqual(params['amount'],.2)

    def test_legacy_inner_split_targets_inner_boundary(self):
        with patch.object(helper, 'rpc', self.legacy_rpc):
            helper.set_ratio('git',self.tree,self.rects,(True,),.7)
        self.assertEqual(self.calls[-1][1]['pane_id'], 'git')
        self.assertEqual(self.calls[-1][1]['direction'], 'right')

    def test_only_unknown_method_rejection_allows_fallback(self):
        for error in [TimeoutError('no response'),
                      helper.RpcError('layout.set_split_ratio', {'code':'split_not_found'})]:
            with self.subTest(error=error), patch.object(helper, 'rpc', side_effect=error) as rpc:
                with self.assertRaises(type(error)):
                    helper.set_ratio('git',self.tree,self.rects,(),.7)
                self.assertEqual(rpc.call_count,1)

    def test_single_pane_tab_is_not_resized(self):
        with patch.object(helper,'rpc') as rpc:
            result = helper.set_subtree_width('git',{'type':'pane','pane_id':'git'},
                                              {'git':{'x':0,'width':200}},(),110)
        self.assertFalse(result)
        rpc.assert_not_called()

    def test_capped_region_width_is_returned_for_inner_sizing(self):
        with patch.object(helper,'rpc',return_value={}):
            width = helper.set_subtree_width('git',self.tree,self.rects,(True,),500)
        self.assertAlmostEqual(width,180)


if __name__ == '__main__':
    unittest.main()
