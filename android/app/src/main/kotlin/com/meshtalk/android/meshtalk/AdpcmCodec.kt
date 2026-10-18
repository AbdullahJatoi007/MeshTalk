package com.meshtalk.android.meshtalk

/**
 * IMA ADPCM: 16-bit PCM -> 4 bits per sample (4:1).
 * At 8 kHz mono that's 32 kbps, light enough for a Bluetooth link.
 *
 * Frame layout (self-contained, so a lost frame never corrupts the next):
 *   [0..1] first predictor, int16 little-endian
 *   [2]    step index (0..88)
 *   [3..]  samples, two per byte, low nibble first
 */
object AdpcmCodec {
    private val INDEX_TABLE = intArrayOf(-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8)

    private val STEP_TABLE = intArrayOf(
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
        32767,
    )

    const val HEADER = 3

    private fun clamp16(v: Int) = if (v > 32767) 32767 else if (v < -32768) -32768 else v
    private fun clampIndex(v: Int) = if (v > 88) 88 else if (v < 0) 0 else v

    private fun delta(step: Int, nibble: Int): Int {
        var d = step shr 3
        if (nibble and 4 != 0) d += step
        if (nibble and 2 != 0) d += step shr 1
        if (nibble and 1 != 0) d += step shr 2
        return d
    }

    /** Encoder keeps its step index between frames for better quality. */
    class Encoder {
        private var index = 0

        fun encode(samples: ShortArray, n: Int): ByteArray {
            val out = ByteArray(HEADER + (n + 1) / 2)
            var predictor = samples[0].toInt()
            out[0] = (predictor and 0xFF).toByte()
            out[1] = ((predictor shr 8) and 0xFF).toByte()
            out[2] = index.toByte()
            for (i in 0 until n) {
                val step = STEP_TABLE[index]
                var diff = samples[i].toInt() - predictor
                var nibble = 0
                if (diff < 0) {
                    nibble = 8
                    diff = -diff
                }
                if (diff >= step) { nibble = nibble or 4; diff -= step }
                if (diff >= step shr 1) { nibble = nibble or 2; diff -= step shr 1 }
                if (diff >= step shr 2) { nibble = nibble or 1 }
                val d = delta(step, nibble)
                predictor = clamp16(if (nibble and 8 != 0) predictor - d else predictor + d)
                index = clampIndex(index + INDEX_TABLE[nibble])
                val pos = HEADER + i / 2
                if (i % 2 == 0) {
                    out[pos] = (nibble and 0x0F).toByte()
                } else {
                    out[pos] = (out[pos].toInt() or (nibble shl 4)).toByte()
                }
            }
            return out
        }
    }

    /** Decodes one frame; null if it's malformed. */
    fun decode(data: ByteArray): ShortArray? {
        if (data.size <= HEADER) return null
        var predictor = (data[0].toInt() and 0xFF) or (data[1].toInt() shl 8)
        predictor = predictor.toShort().toInt()
        var index = data[2].toInt() and 0xFF
        if (index > 88) return null
        val n = (data.size - HEADER) * 2
        val out = ShortArray(n)
        for (i in 0 until n) {
            val b = data[HEADER + i / 2].toInt() and 0xFF
            val nibble = if (i % 2 == 0) b and 0x0F else (b shr 4) and 0x0F
            val d = delta(STEP_TABLE[index], nibble)
            predictor = clamp16(if (nibble and 8 != 0) predictor - d else predictor + d)
            index = clampIndex(index + INDEX_TABLE[nibble])
            out[i] = predictor.toShort()
        }
        return out
    }
}
