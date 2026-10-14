"""Command contract tests use fake devices and never access the network."""
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from device_control import Controller, hsv_encode, hsv_decode
from unittest.mock import patch


def prop(dp, code, kind, **spec):
    return {'abilityId': dp, 'code': code, 'accessMode': 'rw', 'typeSpec': {'type': kind, **spec}}


DEVICES = [{'id': 'fake-ac', 'name': 'Ar', 'ip': '192.0.2.1', 'key': 'not-a-real-key00', 'version': '3.5'},
           {'id': 'fake-lamp', 'name': 'Luz', 'ip': '192.0.2.2', 'key': 'not-a-real-key00', 'version': '3.3'}]
SCHEMAS = [
    {'id': 'fake-ac', 'specification': {'category': 'kt'}, 'model': {'services': [{'properties': [
        prop(1, 'Power', 'bool'), prop(2, 'temp_set', 'value', min=160, max=900, scale=1, step=10),
        prop(4, 'mode', 'enum', range=['cold','hot','wet','wind','auto']),
        prop(5, 'windspeed', 'enum', range=['low','mid','high','auto']), prop(8, 'eco', 'bool'),
        prop(19, 'C_F', 'enum', range=['C','F']), prop(33, 'switch_horizontal', 'bool'),
        prop(105, 'up_down_wind', 'bool'), prop(102, 'sleep', 'bool')]}]}},
    {'id': 'fake-lamp', 'specification': {'category': 'dj'}, 'model': {'services': [{'properties': [
        prop(20, 'switch_led', 'bool'), prop(21, 'work_mode', 'enum', range=['white','colour','scene','music']),
        prop(22, 'bright_value', 'value', min=10,max=1000),
        prop(23, 'temp_value', 'value', min=0,max=1000), prop(24, 'colour_data', 'string')]}]}}
]


class FakeDevice:
    def __init__(self, dps):
        self.dps = dict(dps)
        self.writes = []
        self.closed = False
        self.reads = 0
        self.nowait = []
        self.persistent = False
    def set_socketTimeout(self, _): pass
    def set_socketRetryLimit(self, _): pass
    def set_socketPersistent(self, value): self.persistent = value
    def status(self):
        self.reads += 1
        return {'dps': dict(self.dps)}
    def set_multiple_values(self, value, nowait=False):
        self.nowait.append(nowait)
        self.writes.append(dict(value))
        self.dps.update(value)
    def close(self): self.closed = True


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.ac = FakeDevice({'1':True,'2':270,'4':'cold','5':'low','8':False,'19':'C','33':False,'102':False,'105':False})
        self.lamp = FakeDevice({'20':False,'21':'white','22':1000,'23':1000,'24':'000003e803e8'})
        self.controller = Controller(DEVICES,SCHEMAS,lambda device_id,*args,**kw:self.ac if device_id=='fake-ac' else self.lamp)
    def test_status_never_sends_commands(self):
        result=self.controller.status()
        self.assertTrue(result['ac_connected'])
        self.assertFalse(result['lamp']['power'])
        self.assertEqual(self.ac.writes+self.lamp.writes, [])
        self.assertNotIn('fake-ac',str(result))
        self.assertNotIn('not-a-real-key',str(result))
    def test_power_and_temperature_are_absolute(self):
        self.controller.set('ac','power',False)
        self.controller.set('ac','temperature',25)
        self.assertEqual(self.ac.writes,[{'1':False},{'2':250}])
        self.assertTrue(self.ac.closed)
    def test_rejects_invalid_commands_before_writing(self):
        for field,value in [('power','false'),('temperature',90),('temperature',float('nan')),('fan','unknown'),('mode','invalid')]:
            with self.assertRaises(ValueError):self.controller.set('ac',field,value)
        self.assertEqual(self.ac.writes,[])
    def test_temperature_returns_confirmed_state_without_reading_lamp(self):
        result = self.controller.set('ac', 'temperature', 25)
        self.assertEqual(result['temperature'], 25)
        self.assertEqual(self.ac.reads, 2) # Before validation and after confirmation.
        self.assertEqual(self.lamp.reads, 0)
        self.assertNotIn('lamp', result)
        self.assertTrue(self.ac.persistent)
        self.assertEqual(self.ac.nowait, [True])
    def test_targeted_status_does_not_query_other_device(self):
        result = self.controller.status(('ac',))
        self.assertTrue(result['ac_connected'])
        self.assertEqual(self.lamp.reads, 0)
        self.assertNotIn('lamp_connected', result)

    def test_color_read_failure_recovers_without_resending_command(self):
        original = self.lamp.status
        calls = 0
        def flaky():
            nonlocal calls
            calls += 1
            return {'Err': 'temporary'} if calls == 2 else original()
        self.lamp.status = flaky
        with patch('device_control.time.sleep'):
            result = self.controller.set('lamp', 'color', {'h':0.5, 's':1, 'v':0.6})
        self.assertTrue(result['lamp_connected'])
        self.assertEqual(len(self.lamp.writes), 1)
        self.assertEqual(result['lamp']['color']['h'], 0.5)
        self.assertFalse(self.lamp.persistent)
    def test_partial_color_updates_require_both_fields(self):
        original = self.lamp.status
        calls = 0
        def partial():
            nonlocal calls
            calls += 1
            if calls == 2: return {'dps': {'21': 'colour'}}
            if calls == 3: return {'dps': {'24': self.lamp.dps['24']}}
            return original()
        self.lamp.status = partial
        with patch('device_control.time.sleep'):
            result = self.controller.set('lamp', 'color', {'h':0.5,'s':1,'v':0.6})
        self.assertEqual(calls, 3)
        self.assertEqual(result['lamp']['light_mode'], 'colour')
        self.assertIn('power', result['lamp'])
        self.assertEqual(len(self.lamp.writes), 1)
    def test_status_retries_read_without_writing(self):
        original = self.lamp.status
        calls = 0
        def flaky():
            nonlocal calls
            calls += 1
            return {'Err': 'temporary'} if calls == 1 else original()
        self.lamp.status = flaky
        with patch('device_control.time.sleep'):
            result = self.controller.status(('lamp',))
        self.assertTrue(result['lamp_connected'])
        self.assertEqual(calls, 2)
        self.assertEqual(self.lamp.writes, [])
    def test_persistent_read_failure_is_not_reported_as_success(self):
        self.lamp.status = lambda: {'Err': 'offline'}
        with patch('device_control.time.sleep'):
            result = self.controller.status(('lamp',))
        self.assertFalse(result['lamp_connected'])
        self.assertIsNotNone(result['error'])
        self.assertEqual(self.lamp.writes, [])

    def test_celsius_is_required(self):
        self.ac.dps['19']='F'
        with self.assertRaises(ValueError):self.controller.set('ac','temperature',27)
        self.assertEqual(self.ac.writes,[])
    def test_sleep_eco_and_airflow(self):
        self.controller.set('ac','sleep',True)
        self.controller.set('ac','eco',True)
        self.controller.set('ac','airflow','both')
        self.assertEqual(self.ac.writes,[{'102':True},{'8':True},{'105':True,'33':True}])
    def test_mode_and_fan_come_from_schema(self):
        self.controller.set('ac','mode','wind')
        self.controller.set('ac','fan','high')
        self.assertEqual(self.ac.writes,[{'4':'wind'},{'5':'high'}])
    def test_white_brightness_does_not_turn_on_lamp(self):
        self.controller.set('lamp','brightness',45)
        self.assertEqual(self.lamp.writes,[{'22':450}])
        self.assertFalse(self.lamp.dps['20'])
    def test_color_sets_mode_and_hsv_without_power(self):
        self.controller.set('lamp','color',{'h':0.5,'s':1,'v':0.6})
        self.assertEqual(self.lamp.writes,[{'21':'colour','24':'00b403e80258'}])
        self.assertFalse(self.lamp.dps['20'])
        self.controller.set('lamp','brightness',30)
        color=hsv_decode(self.lamp.dps['24'])
        self.assertEqual(color,{'h':0.5,'s':1.0,'v':0.3})
    def test_white_temperature_and_scene_restriction(self):
        self.controller.set('lamp','white_temperature',0.2)
        self.assertEqual(self.lamp.writes,[{'21':'white','23':200}])
        with self.assertRaises(ValueError):self.controller.set('lamp','light_mode','scene')
    def test_malformed_color_is_rejected(self):
        for invalid in [{'h':2,'s':1,'v':1},{'h':0,'s':float('nan'),'v':1},'ff00ff']:
            with self.assertRaises(ValueError):hsv_encode(invalid)
    def test_same_power_does_not_send_another_command(self):
        self.controller.set('lamp','power',False)
        self.assertEqual(self.lamp.writes,[])
    def test_missing_ack_keeps_real_state_and_reports_failure(self):
        self.ac.set_multiple_values=lambda payload, **kw:self.ac.writes.append(payload)
        with patch('device_control.time.sleep'), self.assertRaises(ValueError):
            self.controller.set('ac','temperature',25)
        self.assertEqual(self.controller.status()['temperature'],27)


if __name__=='__main__':unittest.main()
