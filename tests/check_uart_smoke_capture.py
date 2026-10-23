"""Parse an already-saved UART byte capture; this tool never opens a TTY."""
from pathlib import Path
import argparse, json, stat

PREFIX = b'\x55' * 4 + b'MCDUART1'
FRAME_BYTES = 16


def expected_frame(sequence):
    return PREFIX + bytes([1, sequence, sequence ^ 0xa4, 10])


def inspect(data):
    if len(data) > 65536: raise ValueError('Capture exceeds the bounded 64 KiB parser limit')
    found = []
    cursor = 0
    while True:
        offset = data.find(PREFIX, cursor)
        if offset < 0: break
        frame = data[offset:offset+FRAME_BYTES]
        if len(frame) != FRAME_BYTES: raise ValueError('Truncated identity frame')
        if frame[12] != 1 or frame[13] > 3 or frame[14] != (frame[13] ^ 0xa4) or frame[15] != 10:
            raise ValueError('Invalid identity version/sequence/check/terminator')
        if found and offset != found[-1]['offset'] + FRAME_BYTES:
            raise ValueError('Unexpected bytes between identity frames')
        found.append({'offset': offset, 'sequence': frame[13], 'hex': frame.hex()})
        cursor = offset + FRAME_BYTES
    if [item['sequence'] for item in found] != [0, 1, 2, 3]:
        raise ValueError('Expected exactly one bounded sequence of four ordered identity frames')
    return {'schema': 'megacd-uart-smoke-capture-v1', 'frames': found, 'bytes': len(data),
            'prefix_or_suffix_noise_bytes': len(data) - 4*FRAME_BYTES,
            'identity_bytes_accepted': True, 'hardware_transport_proven': False,
            'note': 'Only a separately provenance-bound actual board capture can establish hardware reception.'}


def selftest():
    golden = b''.join(expected_frame(i) for i in range(4))
    assert inspect(golden)['identity_bytes_accepted']
    assert inspect(b'\0\xff'+golden+b'\0')['prefix_or_suffix_noise_bytes'] == 3
    bad = [b'', golden[:-1], golden + golden[:16], golden[16:], golden[:16]+b'\xff'+golden[16:],
           b''.join(expected_frame(i) for i in [0, 2, 1, 3])]
    for position in [12, 13, 14, 15]:
        changed = bytearray(golden)
        changed[position] ^= 0x80
        bad.append(bytes(changed))
    for data in bad:
        try: inspect(data)
        except ValueError: pass
        else: raise AssertionError('Accepted invalid capture')
    return {'pure_parser_cases': 2 + len(bad), 'passed': True, 'RTL_simulation_or_board_action': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=Path)
    parser.add_argument('--selftest', action='store_true')
    args = parser.parse_args()
    if args.selftest:
        print(json.dumps(selftest()))
    elif args.capture:
        path = args.capture.absolute()
        # A normal disk file is required; device paths and live pipes are rejected.
        if path.is_symlink() or not stat.S_ISREG(path.stat().st_mode): parser.error('Expected a saved ordinary capture file')
        with path.open('rb') as inp: data = inp.read(65537)
        print(json.dumps(inspect(data), indent=2))
    else: parser.error('Choose --selftest or --capture')


if __name__ == '__main__': main()
