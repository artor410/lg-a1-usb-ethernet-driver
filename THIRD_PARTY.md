# Código de terceiros

## LG-USB-2-ETH0

A troca de nomes de interface em `app/bin/usbeth.sh` (`rename_if`, `swap_in`, `swap_out`, `free_eth_name` e
a ideia do vigia) foi adaptada de [LG-USB-2-ETH0](https://github.com/ohmybahgosh/LG-USB-2-ETH0), commit
`3ec818a81ea7`. A detecção da porta própria foi reescrita para o A1, onde ela é um dispositivo virtual.

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

`driver/r8152.c` é o driver da Realtek distribuído pela LG no pacote de código aberto da TV (GPL-2.0).
