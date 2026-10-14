"""Control Tuya devices over the LAN using their reported specifications."""
import json
import math
from pathlib import Path
import time
import tinytuya

LOCAL = Path(__file__).resolve().parent.parent / 'local'
ALIASES = {
    'ac': {'power': ['power', 'switch'], 'temperature': ['temp_set'],
           'ambient': ['temp_current'], 'mode': ['mode'], 'fan': ['windspeed'],
           'eco': ['eco', 'mode_eco'], 'sleep': ['sleep'],
           'vertical': ['up_down_wind'], 'horizontal': ['switch_horizontal'], 'unit': ['c_f']},
    'lamp': {'power': ['switch_led'], 'light_mode': ['work_mode'],
             'brightness': ['bright_value', 'bright_value_v2'],
             'color': ['colour_data', 'colour_data_v2'], 'white_temperature': ['temp_value', 'temp_value_v2']}
}


def mapping(schema):
    fields = {}
    spec = schema.get('specification', {})
    writable = {str(f['dp_id']) for f in spec.get('functions', [])}
    for entry in spec.get('status', []) + spec.get('functions', []):
        values = entry.get('values', '{}')
        if isinstance(values, str):
            try:
                values = json.loads(values)
            except ValueError:
                values = {}
        fields[entry['code'].lower()] = {'dp': str(entry['dp_id']), 'spec': values,
                                       'type': entry['type'].lower(), 'writable': str(entry['dp_id']) in writable}
    for service in (schema.get('model') or {}).get('services', []):
        for prop in service.get('properties', []):
            fields[prop['code'].lower()] = {'dp': str(prop['abilityId']), 'spec': prop['typeSpec'],
                'type': prop['typeSpec']['type'].lower(), 'writable': 'w' in prop.get('accessMode', '')}
    return fields


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def hsv_decode(value):
    if not isinstance(value, str) or len(value) != 12:
        raise ValueError('Formato de cor local não reconhecido.')
    try:
        h, s, v = (int(value[i:i+4], 16) for i in (0, 4, 8))
    except ValueError:
        raise ValueError('Formato de cor local não reconhecido.') from None
    if h > 360 or s > 1000 or v > 1000:
        raise ValueError('Cor fora da faixa documentada.')
    return {'h': h / 360, 's': s / 1000, 'v': v / 1000}


def hsv_encode(value):
    if not isinstance(value, dict) or any(not number(value.get(k)) or not 0 <= value[k] <= 1 for k in ('h', 's', 'v')):
        raise ValueError('Selecione uma cor válida.')
    return ''.join(f'{round(value[k] * maximum):04x}' for k, maximum in [('h', 360), ('s', 1000), ('v', 1000)])


class Controller:
    def __init__(self, devices=None, schemas=None, factory=None):
        devices = devices if devices is not None else json.loads((LOCAL / 'devices.json').read_text())
        schemas = schemas if schemas is not None else json.loads((LOCAL / 'schema.json').read_text())
        self.devices = {}
        self.fields = {}
        self.factory = factory or tinytuya.Device
        self.last = {}
        for schema in schemas:
            category = schema.get('specification', {}).get('category')
            role = {'kt': 'ac', 'dj': 'lamp'}.get(category)
            matches = [d for d in devices if d['id'] == schema['id']]
            if role and len(matches) == 1:
                self.devices[role] = matches[0]
                raw = mapping(schema)
                self.fields[role] = {name: next((raw[a] for a in codes if a in raw), None)
                                     for name, codes in ALIASES[role].items()}
        if set(self.devices) != {'ac', 'lamp'}:
            raise ValueError('As especificações não correspondem aos dois aparelhos configurados.')

    def connect(self, role):
        item = self.devices[role]
        device = self.factory(item['id'], item['ip'], item['key'], version=float(item['version']))
        device.set_socketTimeout(3)
        device.set_socketRetryLimit(1)
        # The AC negotiates a 3.5 session; the legacy 3.3 lamp uses short connections.
        device.set_socketPersistent(float(item['version']) >= 3.4)
        return device

    def raw(self, response):
        if not isinstance(response, dict) or not isinstance(response.get('dps'), dict) or not response['dps']:
            raise ValueError('Não foi possível ler o aparelho pela rede local.')
        return response['dps']

    def value(self, role, name, dps):
        entry = self.fields[role].get(name)
        return dps.get(entry['dp']) if entry else None

    def limits(self, role, name):
        spec = self.fields[role][name]['spec']
        scale = 10 ** spec.get('scale', 0)
        return spec.get('min', 0)/scale, spec.get('max', 100)/scale, max(1, spec.get('step', 1))/scale

    def temperature_limits(self):
        low, high, step = self.limits('ac', 'temperature')
        # The model shares Celsius/Fahrenheit limits (maximum 90); never offer 90 °C.
        return max(16, low), min(32, high), max(1, step)

    def available(self, role, name, dps):
        entry = self.fields[role].get(name)
        return bool(entry and entry['writable'] and entry['dp'] in dps)

    def describe(self, role, dps):
        output = {'connected': True, 'capabilities': {}}
        for name, entry in self.fields[role].items():
            if not entry or entry['dp'] not in dps:
                continue
            raw = dps[entry['dp']]
            if entry['type'] in ('bool', 'boolean'):
                if isinstance(raw, bool):
                    output[name] = raw
            elif entry['type'] == 'enum':
                output[name] = raw
            elif entry['type'] in ('value', 'integer') and number(raw):
                output[name] = raw / 10 ** entry['spec'].get('scale', 0)
            if self.available(role, name, dps):
                output['capabilities'][name] = {'options': entry['spec'].get('range', [])}
        if role == 'ac':
            if 'temperature' in output:
                low, high, step = self.temperature_limits()
                output['capabilities']['temperature'].update(min=low, max=high, step=step)
            output['airflow'] = 'both' if output.get('vertical') and output.get('horizontal') else 'vertical' if output.get('vertical') else 'horizontal' if output.get('horizontal') else 'off'
            if self.available(role, 'vertical', dps) and self.available(role, 'horizontal', dps):
                output['capabilities']['airflow'] = {'options': ['off', 'vertical', 'horizontal', 'both']}
        else:
            try:
                output['color'] = hsv_decode(self.value(role, 'color', dps))
            except ValueError:
                output['capabilities'].pop('color', None)
            mode = output.get('light_mode')
            if mode == 'colour' and 'color' in output:
                output['brightness'] = round(output['color']['v'] * 100)
            elif 'brightness' in output:
                maximum = self.fields[role]['brightness']['spec']['max']
                output['brightness'] = round(output['brightness'] / maximum * 100)
            if 'white_temperature' in output:
                output['white_temperature'] /= self.fields[role]['white_temperature']['spec']['max']
            if 'light_mode' in output['capabilities']:
                output['capabilities']['light_mode']['options'] = [v for v in output['capabilities']['light_mode']['options'] if v in ('white', 'colour')]
        return output

    def result(self, states):
        result = dict(states)
        for role, state in states.items():
            result[role + '_connected'] = state['connected']
        if 'ac' in states:
            result['temperature'] = states['ac'].get('temperature')
        result['error'] = None if all(s['connected'] for s in states.values()) else 'Um dos aparelhos está sem conexão local.'
        return result

    def status(self, roles=('ac', 'lamp')):
        states = {}
        for role in roles:
            device = self.connect(role)
            try:
                for attempt in range(2):
                    try:
                        dps = self.raw(device.status())
                        break
                    except Exception:
                        if attempt == 1:
                            raise
                        device.close()
                        time.sleep(0.15)
                        device = self.connect(role)
                self.last[role] = dps
                states[role] = self.describe(role, dps)
            except Exception:
                states[role] = {'connected': False, 'capabilities': {}}
            finally:
                device.close()
        return self.result(states)

    def payload(self, role, name, requested, dps):
        if role not in self.fields or name not in (*self.fields[role], 'airflow'):
            raise ValueError('Controle não reconhecido.')
        if name == 'airflow':
            if role != 'ac' or requested not in ('off', 'vertical', 'horizontal', 'both'):
                raise ValueError('Selecione uma oscilação válida.')
            if not all(self.available(role, n, dps) for n in ('vertical', 'horizontal')):
                raise ValueError('Oscilação não disponível neste aparelho.')
            return {self.fields[role]['vertical']['dp']: requested in ('vertical', 'both'),
                    self.fields[role]['horizontal']['dp']: requested in ('horizontal', 'both')}
        if not self.available(role, name, dps):
            raise ValueError('Controle indisponível no estado atual do aparelho.')
        entry = self.fields[role][name]
        if role == 'ac' and name == 'temperature':
            if self.value(role, 'unit', dps) != 'C':
                raise ValueError('Selecione Celsius no aplicativo antes de ajustar a temperatura.')
            low, high, step = self.temperature_limits()
            if not number(requested) or not low <= requested <= high or abs((requested-low)/step-round((requested-low)/step)) > 0.001:
                raise ValueError('Temperatura fora da faixa disponível.')
            return {entry['dp']: round(requested * 10 ** entry['spec'].get('scale', 0))}
        if role == 'lamp' and name == 'color':
            if not self.available(role, 'light_mode', dps):
                raise ValueError('Modo de cor indisponível.')
            return {self.fields[role]['light_mode']['dp']: 'colour', entry['dp']: hsv_encode(requested)}
        if role == 'lamp' and name == 'brightness':
            if not number(requested) or not 1 <= requested <= 100:
                raise ValueError('Brilho deve ficar entre 1 e 100%.')
            mode = self.value(role, 'light_mode', dps)
            if mode == 'colour':
                color = hsv_decode(self.value(role, 'color', dps))
                color['v'] = requested / 100
                return {self.fields[role]['color']['dp']: hsv_encode(color)}
            if mode != 'white':
                raise ValueError('Escolha luz branca ou colorida para ajustar o brilho.')
            return {entry['dp']: round(requested / 100 * entry['spec']['max'])}
        if role == 'lamp' and name == 'white_temperature':
            if not number(requested) or not 0 <= requested <= 1:
                raise ValueError('Temperatura de cor inválida.')
            return {self.fields[role]['light_mode']['dp']: 'white', entry['dp']: round(requested * entry['spec']['max'])}
        if entry['type'] in ('bool', 'boolean'):
            if not isinstance(requested, bool):
                raise ValueError('O controle exige ligado ou desligado.')
        elif entry['type'] == 'enum':
            if not isinstance(requested, str) or requested not in entry['spec'].get('range', []):
                raise ValueError('Opção não disponível no aparelho.')
            if role == 'lamp' and name == 'light_mode' and requested not in ('white', 'colour'):
                raise ValueError('Este app oferece os modos branco e colorido.')
        else:
            raise ValueError('Este controle ainda não é suportado.')
        return {entry['dp']: requested}

    def set(self, role, name, requested):
        if role not in self.devices:
            raise ValueError('Aparelho não reconhecido.')
        device = self.connect(role)
        try:
            for attempt in range(2):
                try:
                    before = self.raw(device.status())
                    break
                except Exception:
                    if attempt == 1:
                        raise
                    device.close()
                    time.sleep(0.15)
                    device = self.connect(role)
            payload = self.payload(role, name, requested, before)
            if not all(before.get(k) == v for k,v in payload.items()):
                # Temperature uses one DP: skip the optional command ACK and verify by reading.
                device.set_multiple_values(payload, nowait=(role == 'ac' and name == 'temperature'))
            after = dict(before)
            confirmed_fields = set()
            for attempt in range(3):
                try:
                    observed = self.raw(device.status())
                    after.update(observed)
                    confirmed_fields.update(observed)
                    if all(k in confirmed_fields and after.get(k) == v for k,v in payload.items()):
                        self.last[role] = after
                        return self.result({role: self.describe(role, after)})
                except Exception:
                    # Retry only the read on a fresh connection; never resend the command.
                    device.close()
                    if attempt < 2:
                        device = self.connect(role)
                if attempt < 2:
                    time.sleep(0.15)
            raise ValueError('O aparelho não confirmou o comando solicitado.')
        finally:
            device.close()
