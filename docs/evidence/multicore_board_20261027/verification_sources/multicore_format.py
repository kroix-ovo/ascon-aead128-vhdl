"""Version 1 layer scatter/gather and authenticated metadata. Public test key only."""
import hashlib
import json
import struct

KEY = bytes(range(16))
CHUNKS = 12


def digest(data):
    return hashlib.sha256(data).hexdigest()


def associated_data(model_id, manifest_id, layer, count, size, nonce_base):
    if not 0 <= nonce_base <= (1 << 128) - count:
        raise ValueError('Nonce range overflows 128 bits')
    if len(model_id) != 32 or len(manifest_id) != 32:
        raise ValueError('Model and manifest IDs must each be 32 bytes')
    return (struct.pack('<4I', 1, layer, count, size) + model_id + manifest_id
            + nonce_base.to_bytes(16, 'little'))


def gather(payload, manifest):
    """Validate the existing export, then gather each layer without changing it."""
    if (manifest['layers'] != CHUNKS or manifest['dtype'] != 'float32'
            or manifest['padding_bytes'] != 0
            or manifest['original_payload_bytes'] != len(payload)
            or manifest['original_payload_sha256'] != digest(payload)):
        raise ValueError('Adapter payload/geometry does not match manifest')
    entries = manifest['tensor_manifest']
    if [e['name'] for e in entries] != ['down_w', 'down_b', 'up_w', 'up_b']:
        raise ValueError('Unexpected tensor order')
    r, c = manifest['rank'], manifest['channels']
    if [e['shape'] for e in entries] != [[12,r,c], [12,r], [12,c,r], [12,c]]:
        raise ValueError('Unexpected tensor shapes')
    offset, chunks, mapping = 0, [bytearray() for _ in range(CHUNKS)], []
    for entry in entries:
        size = 4
        for dimension in entry['shape']:
            size *= dimension
        if entry['bytes'] != size or entry['payload_byte_offset'] != offset or size % CHUNKS:
            raise ValueError('Invalid tensor extent')
        stride = size // CHUNKS
        for layer in range(CHUNKS):
            start = offset + layer * stride
            mapping.append(dict(layer=layer, tensor=entry['name'], file_offset=start,
                                chunk_offset=len(chunks[layer]), bytes=stride))
            chunks[layer].extend(payload[start:start+stride])
        offset += size
    if offset != len(payload) or len(set(map(len,chunks))) != 1:
        raise ValueError('Invalid payload coverage')
    return list(map(bytes,chunks)), mapping


def scatter(chunks, mapping, size):
    restored = bytearray(size)
    for part in mapping:
        a, b, n = part['file_offset'], part['chunk_offset'], part['bytes']
        restored[a:a+n] = chunks[part['layer']][b:b+n]
    return bytes(restored)


def manifest_digest(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',',':')).encode()).digest()
