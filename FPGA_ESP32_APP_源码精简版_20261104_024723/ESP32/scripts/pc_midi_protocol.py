"""Bounded MIDI parser and PC-to-ESP32 event framing."""
from dataclasses import dataclass
from collections import defaultdict, deque
import secrets
import struct

from ble_protocol import crc16

FRAME_SIZE = 20
NOTE_ON = 1
NOTE_OFF = 2
NOTE_ON_BATCH = 0x20
NOTE_OFF_BATCH = 0x21
ALL_NOTES_OFF = 0x22
HEARTBEAT = 0x23
HELLO = 0x24
DRAIN_STATUS = 0x25
OK = 0
STATUS_FULL = 0x16
STATUS_DUPLICATE = 0x17
STATUS_UNKNOWN_OFF = 0x18
STATUS_BAD_EVENT = 0x19
STATUS_BUSY = 0x11
STATUS_STALE_SESSION = 0x1A
STATUS_SEQUENCE = 0x1B
MIDI_PROTOCOL_VERSION = 2
FPGA_BUILD = 0x50314D06
MIDI_CAPABILITIES = 0x0F
MIDI_ID_MIN = 0xA000
MIDI_ID_MAX = 0xBFFF
MIDI_ID_CAPACITY = MIDI_ID_MAX - MIDI_ID_MIN + 1
MIDI_PAYLOAD_MAX = 8
SESSION_TOKEN_MAX = 0xFFFFFFFF
PC_MAGIC = 0xB3
DEFAULT_MAX_EVENTS = 1_000_000
SUPPORTED_ERROR_STATUSES = frozenset((1, 2, 3, 4, 0x10, 0x11, 0x12, 0x13,
                                      0x14, 0x15, STATUS_FULL, STATUS_DUPLICATE,
                                      STATUS_UNKNOWN_OFF, STATUS_BAD_EVENT,
                                      STATUS_STALE_SESSION, STATUS_SEQUENCE))
SESSION_NO_SESSION = 0
SESSION_ACTIVE = 1
SESSION_QUIESCING = 2
SESSION_DRAINED = 3
SESSION_FAULT = 4
SESSION_STATES = frozenset((SESSION_NO_SESSION, SESSION_ACTIVE,
                            SESSION_QUIESCING, SESSION_DRAINED, SESSION_FAULT))
REQUEST_OPS = frozenset((NOTE_ON_BATCH, NOTE_OFF_BATCH, ALL_NOTES_OFF,
                         HEARTBEAT, HELLO, DRAIN_STATUS))
RESPONSE_OPS = frozenset((op | 0x80 for op in REQUEST_OPS)) | frozenset((0xFF,))


class MidiError(ValueError):
    pass


@dataclass(frozen=True)
class MidiEvent:
    time_ns: int
    kind: int
    channel: int
    note: int
    velocity: int
    track: int


@dataclass(frozen=True)
class MidiCommand:
    opcode: int
    request_id: int
    payload: bytes
    status: int
    version: int
    session_token: int
    is_response: bool


def _token_bytes(session_token):
    if type(session_token) is not int or not 0 <= session_token <= SESSION_TOKEN_MAX:
        raise MidiError('session token must be a 32-bit unsigned integer')
    return bytes((session_token >> 24,)) + (session_token & 0xFFFFFF).to_bytes(3, 'little')


def encode_command(opcode, request_id, payload=b'', *, session_token=0):
    """Encode a v2 request; the 32-bit session token is outside its payload."""
    if opcode not in REQUEST_OPS:
        raise MidiError('unsupported PC MIDI opcode')
    if type(request_id) is not int or not 0 <= request_id <= 0xFFFF:
        raise MidiError('request ID must be a 16-bit unsigned integer')
    if not isinstance(payload, (bytes, bytearray, memoryview)) or len(payload) > MIDI_PAYLOAD_MAX:
        raise MidiError('invalid PC MIDI payload')
    token = _token_bytes(session_token)
    raw = bytearray(FRAME_SIZE)
    raw[0] = PC_MAGIC
    raw[1] = MIDI_PROTOCOL_VERSION
    raw[2] = opcode
    raw[3] = token[0]
    raw[4:6] = request_id.to_bytes(2, 'little')
    raw[6] = len(payload)
    raw[7:7 + len(payload)] = payload
    raw[15:18] = token[1:]
    raw[18:20] = crc16(raw[:18]).to_bytes(2, 'little')
    return bytes(raw)


def encode_response(request_raw, *, status=OK, payload=b'', opcode=None,
                    session_token=None):
    request = decode_command(request_raw)
    if request.is_response:
        raise MidiError('cannot respond to another response')
    if not isinstance(payload, (bytes, bytearray, memoryview)) or len(payload) > 7:
        raise MidiError('MIDI response info exceeds seven bytes')
    response_opcode = (request.opcode | 0x80) if opcode is None else opcode
    if response_opcode not in RESPONSE_OPS:
        raise MidiError('unsupported MIDI response opcode')
    token = request.session_token if session_token is None else session_token
    token_bytes = _token_bytes(token)
    raw = bytearray(FRAME_SIZE)
    raw[0] = PC_MAGIC
    raw[1] = MIDI_PROTOCOL_VERSION
    raw[2] = response_opcode
    raw[3] = status
    raw[4:6] = request.request_id.to_bytes(2, 'little')
    raw[6] = 1 + len(payload)  # token high byte occupies response byte 7.
    raw[7] = token_bytes[0]
    raw[8:8 + len(payload)] = payload
    raw[15:18] = token_bytes[1:]
    raw[18:20] = crc16(raw[:18]).to_bytes(2, 'little')
    return bytes(raw)


def decode_command(frame):
    if not isinstance(frame, (bytes, bytearray, memoryview)) or len(frame) != FRAME_SIZE:
        raise MidiError('frame must be exactly 20 bytes')
    raw = bytes(frame)
    if raw[0] != PC_MAGIC or crc16(raw[:18]) != int.from_bytes(raw[18:20], 'little'):
        raise MidiError('bad PC MIDI frame magic or CRC')
    if raw[1] != MIDI_PROTOCOL_VERSION:
        raise MidiError('unsupported PC MIDI protocol version')
    request_id, length = int.from_bytes(raw[4:6], 'little'), raw[6]
    if raw[2] in REQUEST_OPS:
        if length > MIDI_PAYLOAD_MAX or any(raw[7 + length:15]):
            raise MidiError('invalid MIDI request length or padding')
        token = (raw[3] << 24) | int.from_bytes(raw[15:18], 'little')
        return MidiCommand(raw[2], request_id, raw[7:7 + length], OK,
                           raw[1], token, False)
    if raw[2] not in RESPONSE_OPS or not 1 <= length <= 8:
        raise MidiError('invalid MIDI response opcode or info length')
    info_length = length - 1
    if any(raw[8 + info_length:15]):
        raise MidiError('invalid MIDI response padding')
    token = (raw[7] << 24) | int.from_bytes(raw[15:18], 'little')
    return MidiCommand(raw[2], request_id, raw[8:8 + info_length], raw[3],
                       raw[1], token, True)


def _unpack_note_ons(payload):
    if len(payload) not in (4, 7):
        raise MidiError('invalid packed NoteOn payload length')
    count = 1 if len(payload) == 4 else 2
    packed = int.from_bytes(payload, 'little')
    if packed >> (27 * count):
        raise MidiError('nonzero packed NoteOn padding bits')
    rows = []
    for index in range(count):
        record = (packed >> (27 * index)) & ((1 << 27) - 1)
        event_id = MIDI_ID_MIN + (record & 0x1FFF)
        note, velocity = (record >> 13) & 0x7F, (record >> 20) & 0x7F
        if not 1 <= velocity <= 127:
            raise MidiError('invalid NoteOn velocity')
        rows.append((event_id, note, velocity))
    if len({row[0] for row in rows}) != len(rows):
        raise MidiError('duplicate NoteOn ID within batch')
    return tuple(rows)


def _unpack_note_offs(payload):
    counts_by_length = {2: 1, 4: 2, 5: 3, 7: 4}
    count = counts_by_length.get(len(payload))
    if count is None:
        raise MidiError('invalid packed NoteOff payload length')
    packed = int.from_bytes(payload, 'little')
    if packed >> (13 * count):
        raise MidiError('nonzero packed NoteOff padding bits')
    ids = tuple(MIDI_ID_MIN + ((packed >> (13 * index)) & 0x1FFF)
                for index in range(count))
    if len(ids) != len(set(ids)):
        raise MidiError('duplicate NoteOff ID within batch')
    return ids


def validate_request(frame):
    """Validate one host request, including the operation-specific payload."""
    command = decode_command(frame)
    if command.is_response or command.version != MIDI_PROTOCOL_VERSION:
        raise MidiError('MIDI request version/direction is invalid')
    if command.opcode == HEARTBEAT:
        if command.request_id != 0:
            raise MidiError('heartbeat requires request ID zero')
    elif command.request_id == 0:
        raise MidiError('request ID zero is reserved for heartbeat')
    if command.opcode not in REQUEST_OPS:
        raise MidiError('unsupported PC MIDI opcode')
    if command.opcode == HELLO and command.session_token == 0:
        raise MidiError('HELLO requires a nonzero candidate session token')
    if command.opcode not in (HELLO, DRAIN_STATUS) and command.session_token == 0:
        raise MidiError('this MIDI command requires a nonzero session token')
    payload = command.payload
    if command.opcode == NOTE_ON_BATCH:
        _unpack_note_ons(payload)
    elif command.opcode == NOTE_OFF_BATCH:
        _unpack_note_offs(payload)
    elif payload:
        raise MidiError('control MIDI command payload must be empty')
    return command


def validate_response(request_raw, response_raw):
    request, response = validate_request(request_raw), decode_command(response_raw)
    if not response.is_response or response.version != request.version or response.request_id != request.request_id:
        raise MidiError('response version, direction or request ID mismatch')
    if request.opcode != HELLO and response.session_token != request.session_token:
        raise MidiError('response session token mismatch')
    if response.opcode not in (request.opcode | 0x80, 0xFF):
        raise MidiError('response opcode mismatch')
    if response.opcode == 0xFF:
        if response.status not in SUPPORTED_ERROR_STATUSES:
            raise MidiError('invalid protocol rejection status')
        if request.opcode == HELLO and response.status == STATUS_BUSY:
            if response.session_token == 0 or len(response.payload) != 7:
                raise MidiError('invalid busy HELLO response')
            state, build, voices, capabilities = _decode_profile(response.payload)
            if state not in SESSION_STATES or (build, voices, capabilities) != (
                    FPGA_BUILD, 32, MIDI_CAPABILITIES):
                raise MidiError('connected FPGA profile/session state is invalid')
            return response
        raise MidiError(f'MIDI request rejected with status 0x{response.status:02X}')
    if response.status != OK:
        raise MidiError(f'MIDI command was not acknowledged: 0x{response.status:02X}')
    if request.opcode == HELLO:
        if response.session_token == 0 or len(response.payload) != 7:
            raise MidiError('invalid MIDI HELLO response')
        state, build, voices, capabilities = _decode_profile(response.payload)
        if state not in SESSION_STATES or (build, voices, capabilities) != (
                FPGA_BUILD, 32, MIDI_CAPABILITIES):
            raise MidiError('connected FPGA does not match the PC MIDI profile')
    elif request.opcode == DRAIN_STATUS:
        if len(response.payload) != 3 or response.payload[0] not in SESSION_STATES:
            raise MidiError('invalid MIDI drain-status response')
    elif request.opcode == ALL_NOTES_OFF:
        if len(response.payload) != 1 or response.payload[0] not in (
                SESSION_QUIESCING, SESSION_DRAINED):
            raise MidiError('invalid MIDI quiesce response')
    elif response.payload:
        raise MidiError('unexpected MIDI response info')
    return response


def _decode_profile(payload):
    if len(payload) != 7:
        raise MidiError('invalid MIDI profile response')
    return (payload[0], int.from_bytes(payload[1:5], 'little'),
            payload[5], payload[6])


def batch_count(command):
    if command.opcode == NOTE_ON_BATCH:
        return len(_unpack_note_ons(command.payload))
    if command.opcode == NOTE_OFF_BATCH:
        return len(_unpack_note_offs(command.payload))
    raise MidiError('not a MIDI note batch')


def _read_vlq(data, offset, limit):
    value = 0
    for _ in range(4):
        if offset >= limit:
            raise MidiError('truncated variable-length quantity')
        byte = data[offset]
        offset += 1
        value = (value << 7) | (byte & 0x7F)
        if not byte & 0x80:
            return value, offset
    raise MidiError('variable-length quantity exceeds four bytes')


def _parse_track(data, track_index, max_events=DEFAULT_MAX_EVENTS):
    events = []
    offset = tick = order = 0
    running = None
    track_ended = False
    while offset < len(data):
        delta, offset = _read_vlq(data, offset, len(data))
        tick += delta
        if offset >= len(data):
            raise MidiError(f'track {track_index}: missing event status')
        status = data[offset]
        if status & 0x80:
            offset += 1
            if status < 0xF0:
                running = status
        elif running is not None:
            status = running
        else:
            raise MidiError(f'track {track_index}: data byte without running status')

        if status == 0xFF:
            running = None
            if offset >= len(data):
                raise MidiError(f'track {track_index}: truncated meta event')
            meta_type = data[offset]
            offset += 1
            length, offset = _read_vlq(data, offset, len(data))
            end = offset + length
            if end > len(data):
                raise MidiError(f'track {track_index}: truncated meta payload')
            payload = data[offset:end]
            offset = end
            if meta_type == 0x51:
                if length != 3:
                    raise MidiError('tempo meta event must contain 3 bytes')
                tempo = int.from_bytes(payload, 'big')
                if tempo == 0:
                    raise MidiError('tempo must be nonzero')
                events.append((tick, track_index, order, 'tempo', tempo, 0, 0))
                if len(events) > max_events:
                    raise MidiError(f'track {track_index}: MIDI event count exceeds limit {max_events}')
                order += 1
            if meta_type == 0x2F:
                if length != 0:
                    raise MidiError(f'track {track_index}: End of Track event must have zero length')
                if offset != len(data):
                    raise MidiError(f'track {track_index}: data follows End of Track event')
                track_ended = True
                break
            continue

        if status in (0xF0, 0xF7):
            running = None
            length, offset = _read_vlq(data, offset, len(data))
            offset += length
            if offset > len(data):
                raise MidiError(f'track {track_index}: truncated SysEx payload')
            continue

        if status >= 0xF0:
            lengths = {0xF1: 1, 0xF2: 2, 0xF3: 1, 0xF6: 0,
                       0xF8: 0, 0xFA: 0, 0xFB: 0, 0xFC: 0, 0xFE: 0}
            if status not in lengths:
                raise MidiError(f'track {track_index}: unsupported system status 0x{status:02x}')
            offset += lengths[status]
            if offset > len(data):
                raise MidiError(f'track {track_index}: truncated system event')
            if status < 0xF8:
                running = None
            continue

        kind, channel = status & 0xF0, status & 0x0F
        count = 1 if kind in (0xC0, 0xD0) else 2
        if offset + count > len(data):
            raise MidiError(f'track {track_index}: truncated channel event')
        first = data[offset]
        second = data[offset + 1] if count == 2 else 0
        if first & 0x80 or second & 0x80:
            raise MidiError(f'track {track_index}: channel data byte has status bit set')
        offset += count
        if kind == 0x90 and second:
            events.append((tick, track_index, order, 'on', channel, first, second))
            if len(events) > max_events:
                raise MidiError(f'track {track_index}: MIDI event count exceeds limit {max_events}')
            order += 1
        elif kind == 0x80 or (kind == 0x90 and second == 0):
            velocity = second if kind == 0x80 else 0
            events.append((tick, track_index, order, 'off', channel, first, velocity))
            if len(events) > max_events:
                raise MidiError(f'track {track_index}: MIDI event count exceeds limit {max_events}')
            order += 1
    if not track_ended:
        raise MidiError(f'track {track_index}: missing End of Track event')
    return events


def parse_smf(source, *, max_events=DEFAULT_MAX_EVENTS):
    """Parse SMF format 0/1 with PPQN timing and tempo changes.

    Non-note channel events and non-tempo metadata are consumed but not
    synthesized. Format 2 and SMPTE divisions are intentionally rejected.
    """
    if type(max_events) is not int or max_events < 1:
        raise MidiError('max_events must be a positive integer')
    data = bytes(source)
    if len(data) < 14 or data[:4] != b'MThd':
        raise MidiError('missing Standard MIDI File header')
    header_length = int.from_bytes(data[4:8], 'big')
    if header_length < 6 or 8 + header_length > len(data):
        raise MidiError('invalid Standard MIDI File header length')
    fmt, tracks, division = struct.unpack('>HHH', data[8:14])
    if fmt not in (0, 1) or not 1 <= tracks <= 256 or (fmt == 0 and tracks != 1):
        raise MidiError('only SMF format 0/1 with a valid track count is supported')
    if division == 0 or division & 0x8000:
        raise MidiError('SMPTE/zero MIDI time division is not supported; use PPQN')
    offset = 8 + header_length
    all_events = []
    for track_index in range(tracks):
        if offset + 8 > len(data) or data[offset:offset + 4] != b'MTrk':
            raise MidiError(f'missing MTrk chunk {track_index}')
        length = int.from_bytes(data[offset + 4:offset + 8], 'big')
        start, end = offset + 8, offset + 8 + length
        if end > len(data):
            raise MidiError(f'truncated MTrk chunk {track_index}')
        remaining_limit = max_events - len(all_events)
        track_events = _parse_track(data[start:end], track_index, remaining_limit)
        if fmt == 1 and track_index != 0 and any(event[3] == 'tempo' for event in track_events):
            raise MidiError(f'track {track_index}: format 1 tempo events must be in track 0')
        all_events.extend(track_events)
        if len(all_events) > max_events:
            raise MidiError(f'MIDI event count exceeds limit {max_events}')
        offset = end
    if offset != len(data):
        raise MidiError('unexpected bytes after declared MIDI tracks')

    all_events.sort(key=lambda item: (item[0], item[1], item[2]))
    current_tick = elapsed_ns = remainder = 0
    tempo = 500_000
    result = []
    for tick, track_index, _, event_type, a, b, c in all_events:
        delta = tick - current_tick
        numerator = remainder + delta * tempo * 1000
        step_ns, remainder = divmod(numerator, division)
        elapsed_ns += step_ns
        current_tick = tick
        if event_type == 'tempo':
            tempo = a
        else:
            result.append(MidiEvent(elapsed_ns,
                                    NOTE_ON if event_type == 'on' else NOTE_OFF,
                                    a, b, c, track_index))
    if not result:
        raise MidiError('MIDI file contains no note events')
    return tuple(result)


class MidiEventEncoder:
    """Map notes to IDs that are never reused during this encoder instance.

    NoteOff may begin a release tail while the device still retains the ID.
    A new playback session uses a fresh 32-bit device-checked token to reject
    stale frames.
    """
    def __init__(self, session_token=None):
        if session_token is None:
            session_token = 0
            while session_token == 0:
                session_token = secrets.randbits(32)
        if type(session_token) is not int or not 1 <= session_token <= SESSION_TOKEN_MAX:
            raise MidiError('session token must be a nonzero 32-bit unsigned integer')
        self.session_token = session_token
        self._next_id = MIDI_ID_MIN
        self._active = defaultdict(deque)
        self._active_ids = set()
        self._issued_ids = set()
        self.release_barrier_pending = False
        self.request_id = 1

    def _request_id(self):
        value = self.request_id
        if self.request_id == 0 or self.request_id > 0xFFFF:
            raise MidiError('MIDI session sequence exhausted; drain and open a new session')
        self.request_id += 1
        return value

    def _allocate(self):
        for _ in range(MIDI_ID_CAPACITY):
            candidate = self._next_id
            self._next_id = MIDI_ID_MIN if candidate == MIDI_ID_MAX else candidate + 1
            if candidate not in self._issued_ids:
                self._issued_ids.add(candidate)
                self._active_ids.add(candidate)
                return candidate
        raise MidiError('MIDI instance ID space exhausted')

    def map_event(self, event):
        if not 0 <= event.channel <= 15 or not 0 <= event.note <= 127:
            raise MidiError('MIDI event channel/note is outside the supported range')
        key = (event.channel, event.note)
        if event.kind == NOTE_ON:
            if not 1 <= event.velocity <= 127:
                raise MidiError('MIDI NoteOn velocity must be in 1..127')
            event_id = self._allocate()
            self._active[key].append(event_id)
            return (NOTE_ON_BATCH, (event_id, event.note, event.velocity))
        if event.kind != NOTE_OFF:
            raise MidiError('unknown MIDI event kind')
        queue = self._active.get(key)
        if not queue:
            return None
        event_id = queue.popleft()
        self._active_ids.remove(event_id)
        if not queue:
            self._active.pop(key, None)
        return (NOTE_OFF_BATCH, (event_id,))

    def batch(self, opcode, records):
        records = tuple(records)
        if opcode == NOTE_ON_BATCH:
            if not 1 <= len(records) <= 2 or any(len(row) != 3 for row in records):
                raise MidiError('NoteOn batches contain one or two events')
            packed = 0
            for index, (event_id, note, velocity) in enumerate(records):
                if (type(event_id) is not int or type(note) is not int or type(velocity) is not int or
                        not MIDI_ID_MIN <= event_id <= MIDI_ID_MAX or not 0 <= note <= 127 or
                        not 1 <= velocity <= 127):
                    raise MidiError('invalid NoteOn record')
                record = (event_id - MIDI_ID_MIN) | (note << 13) | (velocity << 20)
                packed |= record << (27 * index)
            payload = packed.to_bytes(4 if len(records) == 1 else 7, 'little')
        elif opcode == NOTE_OFF_BATCH:
            if not 1 <= len(records) <= 4 or any(len(row) != 1 for row in records):
                raise MidiError('NoteOff batches contain one to four events')
            packed = 0
            for index, (event_id,) in enumerate(records):
                if type(event_id) is not int or not MIDI_ID_MIN <= event_id <= MIDI_ID_MAX:
                    raise MidiError('invalid NoteOff ID')
                packed |= (event_id - MIDI_ID_MIN) << (13 * index)
            length = (13 * len(records) + 7) // 8
            payload = packed.to_bytes(length, 'little')
        else:
            raise MidiError('invalid MIDI batch opcode')
        request_id = self._request_id()
        return request_id, encode_command(opcode, request_id, payload,
                                          session_token=self.session_token)

    def heartbeat(self):
        return 0, encode_command(HEARTBEAT, 0, session_token=self.session_token)

    def hello(self):
        request_id = self._request_id()
        return request_id, encode_command(HELLO, request_id,
                                          session_token=self.session_token)

    def all_notes_off(self, session_token=None):
        token = self.session_token if session_token is None else session_token
        request_id = self._request_id()
        frame = encode_command(ALL_NOTES_OFF, request_id, session_token=token)
        self._active.clear()
        self._active_ids.clear()
        # This marks a requested device-side release barrier. Keep all IDs
        # issued in this encoder instance permanently unavailable.
        self.release_barrier_pending = True
        return request_id, frame

    def drain_status(self, session_token=None):
        token = self.session_token if session_token is None else session_token
        request_id = self._request_id()
        return request_id, encode_command(DRAIN_STATUS, request_id,
                                          session_token=token)


def iter_event_frames(events, encoder=None):
    """Yield (time_ns, request_id, bytes) batches without reordering events.

    Consecutive same-time events of the same kind are packed up to the protocol
    maximum (two NoteOns or four NoteOffs). A kind transition flushes the batch
    so same-tick NoteOff/NoteOn ordering remains the SMF order.
    """
    encoder = encoder or MidiEventEncoder()
    batch_time = batch_opcode = None
    records = []
    for event in events:
        mapped = encoder.map_event(event)
        if mapped is None:
            continue
        opcode, record = mapped
        limit = 2 if opcode == NOTE_ON_BATCH else 4
        if records and (event.time_ns != batch_time or opcode != batch_opcode or len(records) >= limit):
            request_id, frame = encoder.batch(batch_opcode, records)
            yield batch_time, request_id, frame
            records = []
        if not records:
            batch_time, batch_opcode = event.time_ns, opcode
        records.append(record)
    if records:
        request_id, frame = encoder.batch(batch_opcode, records)
        yield batch_time, request_id, frame
