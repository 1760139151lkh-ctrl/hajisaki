"""Verify ownership of a live loopback TCP peer before releasing pairing credentials."""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import ipaddress
import os
import socket


def same_windows_user(peer_address: str, peer_port: int, server_port: int) -> bool:
    if os.name != "nt" or peer_port <= 0:
        return False
    try:
        address = ipaddress.ip_address(peer_address)
        if not address.is_loopback or address.version != 4:
            return False
        return _check_ipv4(address.packed, peer_port, server_port)
    except (OSError, ValueError, OverflowError):
        return False


def _check_ipv4(peer_bytes: bytes, peer_port: int, server_port: int) -> bool:
    class Row(ctypes.Structure):
        _fields_ = [(name, wintypes.DWORD) for name in (
            "state", "local_address", "local_port", "remote_address", "remote_port", "pid")]

    helper = ctypes.WinDLL("iphlpapi", use_last_error=True)
    helper.GetExtendedTcpTable.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD), wintypes.BOOL,
                                          wintypes.ULONG, ctypes.c_int, wintypes.ULONG]
    helper.GetExtendedTcpTable.restype = wintypes.DWORD
    size = wintypes.DWORD()
    result = helper.GetExtendedTcpTable(None, ctypes.byref(size), False, socket.AF_INET, 5, 0)
    if result not in (0, 122) or not size.value or size.value > 32 * 1024**2:
        return False
    buffer = ctypes.create_string_buffer(size.value)
    if helper.GetExtendedTcpTable(buffer, ctypes.byref(size), False, socket.AF_INET, 5, 0):
        return False
    count = wintypes.DWORD.from_buffer(buffer).value
    row_size = ctypes.sizeof(Row)
    if count > (size.value - ctypes.sizeof(wintypes.DWORD)) // row_size:
        return False
    for index in range(count):
        row = Row.from_buffer_copy(buffer, ctypes.sizeof(wintypes.DWORD) + index * row_size)
        if (row.state == 5 and socket.ntohs(row.local_port & 0xFFFF) == peer_port
                and socket.ntohs(row.remote_port & 0xFFFF) == server_port
                and int(row.local_address).to_bytes(4, "little") == peer_bytes
                and ipaddress.ip_address(int(row.remote_address).to_bytes(4, "little")).is_loopback):
            return _same_process_owner(row.pid)
    return False


def _same_process_owner(pid: int) -> bool:
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    security = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    security.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    security.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                            wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    security.EqualSid.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    process = kernel.OpenProcess(0x1000, False, pid)
    if not process:
        return False
    tokens = []
    sid_buffers = []
    try:
        for handle in (kernel.GetCurrentProcess(), process):
            token = wintypes.HANDLE()
            if not security.OpenProcessToken(handle, 8, ctypes.byref(token)):
                return False
            tokens.append(token)
            size = wintypes.DWORD()
            security.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
            if not size.value or size.value > 65536:
                return False
            buffer = ctypes.create_string_buffer(size.value)
            if not security.GetTokenInformation(token, 1, buffer, size, ctypes.byref(size)):
                return False
            sid_buffers.append(buffer)
        sid_a = ctypes.c_void_p.from_buffer(sid_buffers[0]).value
        sid_b = ctypes.c_void_p.from_buffer(sid_buffers[1]).value
        return bool(security.EqualSid(sid_a, sid_b))
    finally:
        for token in tokens:
            kernel.CloseHandle(token)
        kernel.CloseHandle(process)
