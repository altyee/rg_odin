package rtsample

import sdl "vendor:sdl3"
import "core:fmt"

init_sdl_window :: proc(wx: i32, wy: i32) -> (window: ^sdl.Window) {

    wx := i32(1920)
    wy := i32(1080)
    window = sdl.CreateWindow("Main Window", wx, wy, sdl.WindowFlags{});
    if window == nil {
        fmt.eprintln(sdl.GetError())
        return
    }
    return window
    // defer sdl.DestroyWindow(window)

    // prop := sdl.GetWindowProperties(window)
    // window_handle := cast(dxgi.HWND)sdl.GetPointerProperty(prop, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
}
