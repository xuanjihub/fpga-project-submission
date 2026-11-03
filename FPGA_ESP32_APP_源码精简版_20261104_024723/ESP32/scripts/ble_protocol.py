"""Pure, strict N07 BLE diagnostic codec.

Contract: firmware/ble_bridge_v1/PROTOCOL.md. CRC covers frame integrity.
"""
from dataclasses import dataclass
import struct

SERVICE_UUID = '4a1dee0d-24f4-4f1a-8db6-d329a5a0d69d'
INFO_UUID = '4a1dee0d-24f4-4f1a-8db6-d329a5a0d69e'
COMMAND_UUID = '4a1dee0d-24f4-4f1a-8db6-d329a5a0d69f'
RESULT_UUID = '4a1dee0d-24f4-4f1a-8db6-d329a5a0d6a0'
DEVICE_NAME = 'FPGA-BLE-N07'
MAGIC = 0xB1
VERSION = 1
FRAME_SIZE = 20
MAX_PAYLOAD = 11
PING = 0x01
GET_INFO = 0x02
PING_RESPONSE = 0x81
INFO_RESPONSE = 0x82
ERROR_RESPONSE = 0xFF
OK = 0x00
UNSUPPORTED_OPCODE = 0x01
BAD_VERSION = 0x02
BAD_PAYLOAD = 0x03
REQUEST_ID_CONFLICT = 0x04
FPGA_NOT_CONNECTED = 0x10
INFO_PAYLOAD = bytes.fromhex('000001000137304e140b03')


class ProtocolError(ValueError):
    """A frame, information block, or business response violates the contract."""


def _unsigned(value, limit, field):
    if type(value) is not int or not 0 <= value <= limit:
        raise ProtocolError(f'{field} must be an integer in 0..{limit}')
    return value


def _bytes(value, field):
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise ProtocolError(field + ' must be bytes-like')
    return bytes(value)


def crc16(data):
    """CRC16-CCITT-FALSE: init FFFF/poly1021/no reflection/no final XOR."""
    crc = 0xFFFF
    for byte in _bytes(data, 'CRC input'):
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


@dataclass(frozen=True)
class Frame:
    opcode: int
    request_id: int
    payload: bytes = b''
    status: int = 0
    version: int = VERSION

    def encode(self):
        opcode = _unsigned(self.opcode, 0xFF, 'opcode')
        request_id = _unsigned(self.request_id, 0xFFFF, 'request_id')
        status = _unsigned(self.status, 0xFF, 'status')
        version = _unsigned(self.version, 0xFF, 'version')
        payload = _bytes(self.payload, 'payload')
        if len(payload) > MAX_PAYLOAD:
            raise ProtocolError('payload exceeds 11 bytes')
        body = struct.pack('<BBBBHB', MAGIC, version, opcode, status, request_id, len(payload))
        body += payload + bytes(MAX_PAYLOAD - len(payload))
        return body + struct.pack('<H', crc16(body))


def decode_frame(data):
    """Decode only structural fields; unsupported versions are business errors.

    Direction-specific checks (request status, expected response semantics) are
    intentionally explicit in decode_request/validate_response below.
    """
    raw = _bytes(data, 'frame')
    if len(raw) != FRAME_SIZE:
        raise ProtocolError('frame must be exactly 20 bytes')
    if raw[0] != MAGIC:
        raise ProtocolError('bad frame magic')
    if crc16(raw[:18]) != int.from_bytes(raw[18:20], 'little'):
        raise ProtocolError('bad frame CRC')
    length = raw[6]
    if length > MAX_PAYLOAD:
        raise ProtocolError('payload length exceeds 11')
    if any(raw[7 + length:18]):
        raise ProtocolError('nonzero frame padding')
    return Frame(opcode=raw[2], status=raw[3], request_id=int.from_bytes(raw[4:6], 'little'),
                 payload=raw[7:7 + length], version=raw[1])


def decode_request(data):
    frame = decode_frame(data)
    if frame.status != 0:
        raise ProtocolError('request status must be zero')
    return frame


def parse_info(data):
    """Refuse different stage/firmware/capabilities; this client is N07-only."""
    raw = _bytes(data, 'INFO')
    if len(raw) != 11:
        raise ProtocolError('INFO must be exactly 11 bytes')
    stage, major, minor, patch, build_id, frame_size, max_payload, caps = struct.unpack('<BBBBIBBB', raw)
    if (stage, major, minor, patch, build_id, frame_size, max_payload, caps) != (
            0, 0, 1, 0, 0x4E303701, FRAME_SIZE, MAX_PAYLOAD, 0x03):
        raise ProtocolError('incompatible INFO stage, firmware, build, sizes, or capabilities')
    return {'stage': stage, 'firmware': f'{major}.{minor}.{patch}', 'build_id': f'{build_id:08X}',
            'frame_size': frame_size, 'max_payload': max_payload, 'capabilities': caps,
            'fpga_status': 'FPGA_NOT_CONNECTED'}


def validate_response(request, response, *, expect_conflict=False, expected_info=None):
    """Check ID and every business field."""
    if not isinstance(request, Frame):
        request = decode_request(request)
    else:
        request = decode_request(request.encode())
    frame = response if isinstance(response, Frame) else decode_frame(response)
    # Validate Frame objects too.
    frame = decode_frame(frame.encode())
    if frame.version != VERSION:
        raise ProtocolError('response uses an unsupported version')
    if frame.request_id != request.request_id:
        raise ProtocolError('response request ID mismatch')
    if expect_conflict:
        expected = (ERROR_RESPONSE, REQUEST_ID_CONFLICT, b'')
    elif request.version != VERSION:
        expected = (ERROR_RESPONSE, BAD_VERSION, b'')
    elif request.opcode == PING:
        expected = (PING_RESPONSE, OK, request.payload)
    elif request.opcode == GET_INFO and request.payload:
        expected = (ERROR_RESPONSE, BAD_PAYLOAD, b'')
    elif request.opcode == GET_INFO:
        parse_info(frame.payload)
        if expected_info is not None and frame.payload != _bytes(expected_info, 'expected INFO'):
            raise ProtocolError('GET_INFO disagrees with the real INFO characteristic read')
        expected = (INFO_RESPONSE, FPGA_NOT_CONNECTED, INFO_PAYLOAD)
    else:
        expected = (ERROR_RESPONSE, UNSUPPORTED_OPCODE, b'')
    if (frame.opcode, frame.status, frame.payload) != expected:
        raise ProtocolError('unexpected business opcode/status/payload')
    return frame


class DiagnosticModel:
    """Offline one-entry retry model."""
    def __init__(self):
        self.disconnect()

    def disconnect(self):
        self.cached_request = None
        self.cached_response = None

    def handle(self, raw, *, subscribed=True):
        request = decode_request(raw)
        if not subscribed:
            raise ProtocolError('RESULT subscription is required')
        raw = bytes(raw)
        if self.cached_request is not None and request.request_id == decode_request(self.cached_request).request_id:
            if raw == self.cached_request:
                return self.cached_response
            return Frame(ERROR_RESPONSE, request.request_id, status=REQUEST_ID_CONFLICT).encode()
        if request.version != VERSION:
            response = Frame(ERROR_RESPONSE, request.request_id, status=BAD_VERSION)
        elif request.opcode == PING:
            response = Frame(PING_RESPONSE, request.request_id, payload=request.payload)
        elif request.opcode == GET_INFO and request.payload:
            response = Frame(ERROR_RESPONSE, request.request_id, status=BAD_PAYLOAD)
        elif request.opcode == GET_INFO:
            response = Frame(INFO_RESPONSE, request.request_id, status=FPGA_NOT_CONNECTED, payload=INFO_PAYLOAD)
        else:
            response = Frame(ERROR_RESPONSE, request.request_id, status=UNSUPPORTED_OPCODE)
        self.cached_request = raw
        self.cached_response = response.encode()
        return self.cached_response
