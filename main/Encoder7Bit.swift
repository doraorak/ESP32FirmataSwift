// Encoder7Bit — pack/unpack 8-bit data as 7-bit SysEx bytes (shared by messages and the scheduler).

/* ==== Encoder7Bit helpers (8-bit data packed into 7-bit bytes), shared by the
    Scheduler and used against the shared `frameBuf`.
   ==================== */
func sched7BitDecode(_ outBytes: Int, _ inp: [UInt8], _ out: inout [UInt8]) {
  let inLen = inp.count
  for i in 0..<outBytes {
    let j = i << 3
    let pos = j / 7
    let shift = UInt8(j % 7)
    let lo = pos < inLen ? inp[pos] : 0
    let hi = (pos + 1) < inLen ? inp[pos + 1] : 0
    out[i] = (lo >> shift) | UInt8((UInt16(hi) << (7 - shift)) & 0xFF)
  }
}
func sched7BitOutBytes(_ encodedLen: Int) -> Int { (encodedLen * 7) >> 3 }

// Decode a 32-bit little-endian value from 5 Encoder7Bit-packed bytes.
func sched7BitTime(_ enc5: [UInt8]) -> UInt32 {
  var decoded = [UInt8](repeating: 0, count: 4)
  sched7BitDecode(4, enc5, &decoded)
  return UInt32(decoded[0]) | (UInt32(decoded[1]) << 8) | (UInt32(decoded[2]) << 16) | (UInt32(decoded[3]) << 24)
}

// Encoder7Bit encode one byte into frameBuf, carrying state in shift/prev.
func sched7BitPut(_ n: inout Int, _ shift: inout UInt8, _ prev: inout UInt8, _ d: UInt8) {
  if shift == 0 {
    frameBuf[n] = d & 0x7F; n += 1; shift = 1; prev = d >> 7
  } else {
    frameBuf[n] = UInt8(((UInt16(d) << shift) & 0x7F) | UInt16(prev)); n += 1
    if shift == 6 { frameBuf[n] = d >> 1; n += 1; shift = 0 }
    else { shift += 1; prev = d >> (8 - shift) }
  }
}
