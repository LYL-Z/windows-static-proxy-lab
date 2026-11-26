/* Loopback-only socket probe. Dials 127.0.0.1 and records the first Winsock
 * stage that fails: bind, connect, send, or recv. No other address is used.
 */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0601
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static int appcontainer_token(void) {
    HANDLE token = NULL;
    DWORD value = 0;
    DWORD size = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return -1;
    }
    if (!GetTokenInformation(token, TokenIsAppContainer, &value, sizeof(value), &size)) {
        CloseHandle(token);
        return -1;
    }
    CloseHandle(token);
    return value ? 1 : 0;
}

static int emit(const wchar_t *path, const char *stage, int err, int contained) {
    FILE *file = _wfopen(path, L"wb");
    if (!file) {
        return 80;
    }
    if (fprintf(file, "{\"stage\":\"%s\",\"winerror\":%d,\"appcontainer\":%d}\n",
                stage, err, contained) < 0) {
        fclose(file);
        return 80;
    }
    if (fclose(file) != 0) {
        return 80;
    }
    return err == 0 ? 0 : err;
}

static int hex32(const wchar_t *value) {
    return value != NULL && wcslen(value) == 32 &&
           wcsspn(value, L"0123456789abcdef") == 32;
}

static int copy_ascii(char *dest, size_t cap, const wchar_t *src) {
    size_t i;
    if (!src) {
        return 0;
    }
    for (i = 0; src[i] != L'\0'; ++i) {
        if (src[i] > 127 || i + 1 >= cap) {
            return 0;
        }
        dest[i] = (char)src[i];
    }
    dest[i] = '\0';
    return 1;
}

static int connect_bounded(SOCKET sock, const struct sockaddr *endpoint, int length) {
    u_long nonblocking = 1;
    fd_set writable;
    fd_set failed;
    struct timeval deadline;
    int selected;
    int error = 0;
    int size = (int)sizeof(error);

    if (ioctlsocket(sock, FIONBIO, &nonblocking) != 0) {
        return WSAGetLastError();
    }
    if (connect(sock, endpoint, length) != 0) {
        error = WSAGetLastError();
        if (error != WSAEWOULDBLOCK) {
            return error;
        }
        FD_ZERO(&writable);
        FD_ZERO(&failed);
        FD_SET(sock, &writable);
        FD_SET(sock, &failed);
        deadline.tv_sec = 2;
        deadline.tv_usec = 0;
        selected = select(0, NULL, &writable, &failed, &deadline);
        if (selected == SOCKET_ERROR) {
            return WSAGetLastError();
        }
        if (selected == 0) {
            return WSAETIMEDOUT;
        }
        if (getsockopt(sock, SOL_SOCKET, SO_ERROR, (char *)&error, &size) != 0) {
            return WSAGetLastError();
        }
        if (error != 0) {
            return error;
        }
    }
    nonblocking = 0;
    if (ioctlsocket(sock, FIONBIO, &nonblocking) != 0) {
        return WSAGetLastError();
    }
    return 0;
}

static int exchange(int port, const char *role, const char *marker, const wchar_t *result_path) {
    WSADATA wsa;
    SOCKET sock = INVALID_SOCKET;
    struct sockaddr_in local_addr;
    struct sockaddr_in remote_addr;
    char payload[64];
    char reply[64];
    int payload_len;
    int sent_total = 0;
    int got_total = 0;
    int started = 0;
    int contained = appcontainer_token();
    DWORD timeout = 2000;
    const char *stage = "ok";
    int result = 0;

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        stage = "startup";
        result = WSAGetLastError();
        goto done;
    }
    started = 1;
    sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) {
        stage = "socket";
        result = WSAGetLastError();
        goto done;
    }
    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family = AF_INET;
    local_addr.sin_port = 0;
    local_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(sock, (struct sockaddr *)&local_addr, (int)sizeof(local_addr)) != 0) {
        stage = "bind";
        result = WSAGetLastError();
        goto done;
    }
    memset(&remote_addr, 0, sizeof(remote_addr));
    remote_addr.sin_family = AF_INET;
    remote_addr.sin_port = htons((u_short)port);
    remote_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    result = connect_bounded(sock, (struct sockaddr *)&remote_addr, (int)sizeof(remote_addr));
    if (result != 0) {
        stage = "connect";
        goto done;
    }
    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, (int)sizeof(timeout)) != 0 ||
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, (int)sizeof(timeout)) != 0) {
        stage = "send";
        result = WSAGetLastError();
        goto done;
    }
    payload_len = snprintf(payload, sizeof(payload), "%s %s\n", role, marker);
    if (payload_len < 1 || payload_len >= (int)sizeof(payload)) {
        stage = "send";
        result = 64;
        goto done;
    }
    while (sent_total < payload_len) {
        int sent = send(sock, payload + sent_total, payload_len - sent_total, 0);
        if (sent == SOCKET_ERROR) {
            stage = "send";
            result = WSAGetLastError();
            goto done;
        }
        if (sent == 0) {
            stage = "send";
            result = 64;
            goto done;
        }
        sent_total += sent;
    }
    while (got_total < payload_len && got_total < (int)sizeof(reply)) {
        int received = recv(sock, reply + got_total, payload_len - got_total, 0);
        if (received == SOCKET_ERROR) {
            stage = "recv";
            result = WSAGetLastError();
            goto done;
        }
        if (received == 0) {
            stage = "recv";
            result = 64;
            goto done;
        }
        got_total += received;
    }
    if (got_total != payload_len || memcmp(reply, payload, (size_t)payload_len) != 0) {
        stage = "recv";
        result = 64;
    }

done:
    if (sock != INVALID_SOCKET) {
        closesocket(sock);
    }
    if (started) {
        WSACleanup();
    }
    return emit(result_path, stage, result, contained);
}

int wmain(int argc, wchar_t **argv) {
    char role[32];
    char marker[33];
    wchar_t *end = NULL;
    long port;

    if (argc != 5) {
        return 65;
    }
    port = wcstol(argv[1], &end, 10);
    if (end == argv[1] || (end && *end != L'\0') || port < 1 || port > 65535) {
        return 65;
    }
    if ((wcscmp(argv[2], L"control") != 0 && wcscmp(argv[2], L"appcontainer") != 0) ||
        !hex32(argv[3]) || !copy_ascii(role, sizeof(role), argv[2]) ||
        !copy_ascii(marker, sizeof(marker), argv[3])) {
        return 65;
    }
    return exchange((int)port, role, marker, argv[4]);
}
