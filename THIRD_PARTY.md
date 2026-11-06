# Third-party code

## LG-USB-2-ETH0

The interface swap in `app/bin/usbeth.sh` (`rename_if`, `swap_in`, `swap_out`, `free_eth_name`), the watcher
idea, the recovery after the swap and the Wi-Fi fallback are adapted from
[LG-USB-2-ETH0](https://github.com/ohmybahgosh/LG-USB-2-ETH0), commit `3ec818a81ea7`. Detection of the
built-in port was rewritten for the A1, where it is a virtual device.

```
MIT License

Copyright (c) 2025 OhMyBahGosh

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Realtek r8152

`driver/r8152.c` is Realtek's driver as distributed by LG in the TV's open source package (GPL-2.0).
