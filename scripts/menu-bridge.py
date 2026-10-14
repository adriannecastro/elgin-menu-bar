"""JSON bridge for LAN access; status polls read only and writes require explicit commands."""
import argparse
import json
from device_control import Controller


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['status', 'temperature', 'set'])
    parser.add_argument('arguments', nargs='*')
    args = parser.parse_args()
    controller = None
    error = None
    result = None
    roles = ('ac', 'lamp')
    try:
        controller = Controller()
        if args.command == 'temperature':
            if len(args.arguments) != 1:
                raise ValueError('Informe a temperatura.')
            roles = ('ac',)
            result = controller.set('ac', 'temperature', float(args.arguments[0]))
        elif args.command == 'set':
            if len(args.arguments) != 3:
                raise ValueError('Informe aparelho, controle e valor.')
            role, control, value = args.arguments
            if role in ('ac', 'lamp'): roles = (role,)
            result = controller.set(role, control, json.loads(value))
        elif args.arguments:
            raise ValueError('A consulta de estado não aceita comandos adicionais.')
    except ValueError as exc:
        error = str(exc)
    except Exception:
        error = 'Não foi possível completar a operação local.'
    try:
        result = result if result is not None else controller.status(roles) if controller else {'ac_connected': False, 'lamp_connected': False, 'temperature': None}
    except Exception:
        result = {'ac_connected': False, 'lamp_connected': False, 'temperature': None}
    if error:
        result['error'] = error
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
