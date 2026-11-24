package utils

import "core:fmt"
import "core:os"
import "core:sys/windows"

check :: proc(res: windows.HRESULT, message: string) {
    if res >= 0 { return }
    fmt.printf("%v. Error code: %0x\n", message, u32(res))
    os.exit(-1)
}

align_up :: proc(value: u64, alignment: u64) -> u64 {
    return (value + alignment - 1) & ~(alignment - 1)
}
