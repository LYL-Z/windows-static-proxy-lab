/* Windows-only test fixture. This program can contact only the loopback echo fixture.
 * "launch" starts a single socket probe with zero AppContainer capabilities, then exits.
 * The test owns one fresh, temporary AppContainer profile. No inherited handles or exemptions.
 */
#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <userenv.h>
#include <sddl.h>
#include <stdio.h>
#include <wchar.h>
#include <string.h>

/* Distinguish the fixture's deadline (72) from an actual Winsock error. */
static int connect_bounded(SOCKET s, const struct sockaddr *endpoint, int length) {
    u_long nonblocking = 1;
    if (ioctlsocket(s, FIONBIO, &nonblocking) != 0) return WSAGetLastError();
    if (connect(s, endpoint, length) != 0) {
        int error = WSAGetLastError();
        if (error != WSAEWOULDBLOCK) return error;
        fd_set writable, failed;
        FD_ZERO(&writable);
        FD_ZERO(&failed);
        FD_SET(s, &writable);
        FD_SET(s, &failed);
        struct timeval deadline = {2, 0};
        int count = select(0, NULL, &writable, &failed, &deadline);
        if (count == SOCKET_ERROR) return WSAGetLastError();
        if (count == 0) return 72;
        int size = sizeof(error);
        if (getsockopt(s, SOL_SOCKET, SO_ERROR, (char *)&error, &size) != 0) return WSAGetLastError();
        if (error != 0) return error;
    }
    nonblocking = 0;
    return ioctlsocket(s, FIONBIO, &nonblocking) == 0 ? 0 : WSAGetLastError();
}

static BOOL valid_challenge(const wchar_t *value) {
    return wcslen(value) == 16 && wcsspn(value, L"0123456789abcdef") == 16;
}

static int wait_for_observer(const wchar_t *challenge) {
    wchar_t gate[32768];
    DWORD size = GetModuleFileNameW(NULL, gate, ARRAYSIZE(gate));
    if (!size || size >= ARRAYSIZE(gate) - 24) return 68;
    swprintf(gate + size, ARRAYSIZE(gate) - size, L".gate-%ls", challenge);
    ULONGLONG until = GetTickCount64() + 5000;
    do {
        if (GetFileAttributesW(gate) != INVALID_FILE_ATTRIBUTES) return 0;
        Sleep(20);
    } while (GetTickCount64() < until);
    return 73;
}

static int exchange(int port, int family, int type, int expect_container, const wchar_t *challenge) {
    HANDLE token;
    DWORD is_container = 0, size = 0;
    WSADATA startup;
    struct sockaddr_storage endpoint = {0};
    int length;
    char reply[16], payload[16];
    for (size_t i = 0; i < sizeof(payload); ++i) payload[i] = (char)challenge[i];
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return 61;
    BOOL read = GetTokenInformation(token, TokenIsAppContainer, &is_container, sizeof(is_container), &size);
    CloseHandle(token);
    if (!read || !!is_container != expect_container) return 62;
    if (expect_container) {
        int gate = wait_for_observer(challenge);
        if (gate) return gate;
    }
    if (WSAStartup(MAKEWORD(2,2), &startup) != 0) return 63;
    if (family == AF_INET) {
        struct sockaddr_in *v4 = (struct sockaddr_in *)&endpoint;
        v4->sin_family = AF_INET;
        v4->sin_port = htons((u_short)port);
        v4->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        length = sizeof(*v4);
    } else {
        struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&endpoint;
        v6->sin6_family = AF_INET6;
        v6->sin6_port = htons((u_short)port);
        v6->sin6_addr = in6addr_loopback;
        length = sizeof(*v6);
    }
    SOCKET s = socket(family, type, 0);
    if (s == INVALID_SOCKET) return WSAGetLastError();
    DWORD timeout = 2000;
    int result = connect_bounded(s, (struct sockaddr *)&endpoint, length);
    if (result == 0 &&
        (setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout)) != 0 ||
         setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, sizeof(timeout)) != 0)) {
        result = WSAGetLastError();
    }
    if (result == 0) {
        int sent = send(s, payload, sizeof(payload), 0);
        if (sent == SOCKET_ERROR) result = WSAGetLastError();
        else if (sent != sizeof(payload)) result = 64;
    }
    if (result == 0) {
        size_t total = 0;
        do {
            int received = recv(s, reply + total, (int)(sizeof(reply) - total), 0);
            if (received == SOCKET_ERROR) { result = WSAGetLastError(); break; }
            total += received;
            if (received == 0 || type == SOCK_DGRAM) break;
        } while (total < sizeof(reply));
        if (!result && (total != sizeof(payload) || memcmp(reply, payload, sizeof(payload)) != 0)) result = 64;
    }
    closesocket(s);
    WSACleanup();
    return result;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 3) return 65;
    if (wcsncmp(argv[2], L"V69.SocketTest.", 15) == 0 && wcslen(argv[2]) == 47 &&
        wcsspn(argv[2] + 15, L"0123456789abcdef") == 32 && wcscmp(argv[1], L"remove") == 0)
        return FAILED(DeleteAppContainerProfile(argv[2])) ? 71 : 0;
    if (wcscmp(argv[1], L"create") == 0 || wcscmp(argv[1], L"launch") == 0) {
        PSID sid = NULL;
        if (wcsncmp(argv[2], L"V69.SocketTest.", 15) || wcslen(argv[2]) != 47 ||
            wcsspn(argv[2] + 15, L"0123456789abcdef") != 32) return 65;
        if (wcscmp(argv[1], L"create") == 0) {
            LPWSTR value = NULL;
            HRESULT result = CreateAppContainerProfile(argv[2], argv[2], L"Temporary socket test", NULL, 0, &sid);
            if (FAILED(result)) { fprintf(stderr, "CreateAppContainerProfile %lx\n", (unsigned long)result); return 66; }
            if (!ConvertSidToStringSidW(sid, &value)) { DeleteAppContainerProfile(argv[2]); return 67; }
            wprintf(L"%ls\n", value);
            LocalFree(value);
            FreeSid(sid);
            return 0;
        }
        if (FAILED(DeriveAppContainerSidFromAppContainerName(argv[2], &sid))) return 66;
        if (argc != 7 || !valid_challenge(argv[6])) return 65;
        const int port = _wtoi(argv[3]);
        if (port <= 0 || port > 65535) return 65;
        wchar_t exe[32768], command[96], system_dir[MAX_PATH];
        DWORD n = GetModuleFileNameW(NULL, exe, ARRAYSIZE(exe));
        if (!n || n >= ARRAYSIZE(exe) || !GetSystemDirectoryW(system_dir, MAX_PATH)) return 68;
        swprintf(command, ARRAYSIZE(command), L"probe contained %d %d %d %ls", port, _wtoi(argv[4]), _wtoi(argv[5]), argv[6]);
        STARTUPINFOEXW info = {0};
        PROCESS_INFORMATION child = {0};
        SECURITY_CAPABILITIES caps = {0};
        caps.AppContainerSid = sid;
        SIZE_T bytes = 0;
        info.StartupInfo.cb = sizeof(info);
        InitializeProcThreadAttributeList(NULL, 1, 0, &bytes);
        info.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, bytes);
        if (!info.lpAttributeList || !InitializeProcThreadAttributeList(info.lpAttributeList, 1, 0, &bytes)) return 69;
        BOOL started = UpdateProcThreadAttribute(info.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, &caps, sizeof(caps), NULL, NULL)
            && CreateProcessW(exe, command, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                              NULL, system_dir, &info.StartupInfo, &child);
        DWORD error = started ? 0 : GetLastError();
        DeleteProcThreadAttributeList(info.lpAttributeList);
        HeapFree(GetProcessHeap(), 0, info.lpAttributeList);
        FreeSid(sid);
        if (!started) { fprintf(stderr, "CreateProcess/attribute error %lu\n", error); return 70; }
        printf("%lu\n", child.dwProcessId);
        CloseHandle(child.hThread);
        CloseHandle(child.hProcess);
        return 0;
    }
    if (argc != 6 || !valid_challenge(argv[5])) return 65;
    int port = _wtoi(argv[2]);
    if (port < 1 || port > 65535) return 65;
    return exchange(port, _wtoi(argv[3]) == 6 ? AF_INET6 : AF_INET,
                    _wtoi(argv[4]) == 2 ? SOCK_DGRAM : SOCK_STREAM, wcscmp(argv[1], L"contained") == 0, argv[5]);
}
