import struct
import unittest
from build import check_elf_alignment

class NativeAlignmentTest(unittest.TestCase):
    def elf(self, alignment):
        data = bytearray(120)
        data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1)
        struct.pack_into("<I", data, 64, 1)
        struct.pack_into("<Q", data, 64 + 48, alignment)
        return bytes(data)
    def test_accepts_16k_load_segments(self):
        check_elf_alignment(self.elf(16384))
    def test_rejects_4k_and_truncated_elf(self):
        for value in [self.elf(4096), self.elf(16384)[:80], b"not an ELF"]:
            with self.assertRaises(ValueError):
                check_elf_alignment(value)

if __name__ == "__main__":
    unittest.main()
